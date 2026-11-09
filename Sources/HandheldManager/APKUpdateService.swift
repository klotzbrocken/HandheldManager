import Foundation

struct AndroidBuildTools {
    let aapt: URL
    let apksigner: URL
}

enum AndroidBuildToolsLocator {
    static func locate() -> AndroidBuildTools? {
        var roots: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let value = environment[key], !value.isEmpty { roots.append(URL(fileURLWithPath: value, isDirectory: true)) }
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk", isDirectory: true))
        roots.append(URL(fileURLWithPath: "/usr/local/share/android-sdk", isDirectory: true))
        for root in roots {
            let buildTools = root.appendingPathComponent("build-tools", isDirectory: true)
            guard let versions = try? FileManager.default.contentsOfDirectory(at: buildTools, includingPropertiesForKeys: nil) else { continue }
            for version in versions.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }) {
                let aapt = version.appendingPathComponent("aapt")
                let signer = version.appendingPathComponent("apksigner")
                if FileManager.default.isExecutableFile(atPath: aapt.path), FileManager.default.isExecutableFile(atPath: signer.path) {
                    return AndroidBuildTools(aapt: aapt, apksigner: signer)
                }
            }
        }
        // Android Studio SDK paths are preferred above, but accept an explicit
        // PATH setup too (for Homebrew or a manually configured SDK install).
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories {
            let base = URL(fileURLWithPath: directory, isDirectory: true)
            let aapt = base.appendingPathComponent("aapt")
            let signer = base.appendingPathComponent("apksigner")
            if FileManager.default.isExecutableFile(atPath: aapt.path), FileManager.default.isExecutableFile(atPath: signer.path) {
                return AndroidBuildTools(aapt: aapt, apksigner: signer)
            }
        }
        return nil
    }
}

private enum ExternalToolRunner {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 90) async throws -> String {
        let r = try await ProcessRunner.run(executable, arguments, timeout: timeout, outputLimit: 1024 * 1024)
        if r.timedOut { throw ManagerError.invalidAPK("Signatur- oder Manifestprüfung hat das Zeitlimit überschritten.") }
        if r.truncated { throw ManagerError.invalidAPK("Toolausgabe überschreitet 1 MiB.") }
        guard r.status == 0 else {
            let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.invalidAPK(message.isEmpty ? "Android Build Tool meldet Status \(r.status)." : message)
        }
        return r.stdout
    }
}

enum InstallFailure {
    static let signatureMismatch = "Die Signatur der neuen APK passt nicht zur installierten App. Android erlaubt dann kein Update über die vorhandene App; möglich wäre nur eine Deinstallation (App-Daten gehen verloren) und Neuinstallation. Prüfe, ob die Update-Quelle zu deiner installierten Variante gehört."

    static func friendly(_ error: Error) -> Error {
        let text = error.localizedDescription
        if text.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") { return ManagerError.invalidAPK(signatureMismatch) }
        if text.contains("INSTALL_FAILED_VERSION_DOWNGRADE") { return ManagerError.invalidAPK("Die geladene Version ist älter als die installierte; Android blockiert das Downgrade.") }
        if text.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") { return ManagerError.invalidAPK("Auf dem Gerät ist nicht genug Speicherplatz für die Installation frei.") }
        if text.contains("INSTALL_FAILED_NO_MATCHING_ABIS") { return ManagerError.invalidAPK("Die APK passt nicht zur Prozessorarchitektur des Geräts (falsche Variante geladen).") }
        return error
    }
}

final class APKUpdateService {
    private let adb: ADBClient
    private let tools: AndroidBuildTools?
    private let fileManager = FileManager.default

    init(adb: ADBClient, tools: AndroidBuildTools? = AndroidBuildToolsLocator.locate()) {
        self.adb = adb
        self.tools = tools
    }

    var toolsAvailable: Bool { tools != nil }

    func prepareDirectInstall(urls: [URL]) throws -> APKDirectInstallPreview {
        guard urls.count == 1, let sourceURL = urls.first,
              sourceURL.pathExtension.lowercased() == "apk" else {
            throw ManagerError.invalidAPK("Ohne Android Build Tools kann nur eine einzelne .apk-Datei ausgewählt werden. Für Split-APKs installiere aapt und apksigner.")
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw ManagerError.invalidAPK("APK-Datei ist nicht erreichbar.") }
        let id = UUID()
        let folder = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HandheldManager/DirectAPKs/\(id.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stagedURL = folder.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
            return APKDirectInstallPreview(id: id, url: stagedURL, sha256: try Hash.sha256(file: stagedURL))
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    func installDirect(_ preview: APKDirectInstallPreview, serial: String) async throws {
        guard fileManager.fileExists(atPath: preview.url.path),
              try Hash.sha256(file: preview.url) == preview.sha256 else {
            throw ManagerError.invalidAPK("APK-Datei hat sich seit der Hash-Prüfung geändert.")
        }
        do { _ = try await adb.device(serial: serial, arguments: ["install", "-r", preview.url.path], timeout: 300) }
        catch { throw InstallFailure.friendly(error) }
        discardDirect(preview)
    }

    func discardDirect(_ preview: APKDirectInstallPreview) {
        let folder = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HandheldManager/DirectAPKs/\(preview.id.uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: folder)
    }

    func prepare(urls: [URL], serial: String, discovery: DeviceDiscoveryService) async throws -> APKInstallPlan {
        guard let tools else { throw ManagerError.androidBuildToolsMissing }
        guard !urls.isEmpty, urls.count <= 40 else { throw ManagerError.invalidAPK("wähle 1 bis 40 APK-Dateien aus") }
        let planID = UUID()
        let stagingRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HandheldManager/StagedAPKs", isDirectory: true)
        let stagingFolder = stagingRoot.appendingPathComponent(planID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        do {
        var artifacts: [APKArtifact] = []
        for (index, sourceURL) in urls.enumerated() {
            guard sourceURL.pathExtension.lowercased() == "apk" else { throw ManagerError.invalidAPK("\(sourceURL.lastPathComponent) ist keine .apk-Datei") }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            guard fileManager.fileExists(atPath: sourceURL.path) else { throw ManagerError.invalidAPK("Datei ist nicht erreichbar: \(sourceURL.lastPathComponent)") }
            let localURL = stagingFolder.appendingPathComponent("\(index)-\(sourceURL.lastPathComponent)")
            try fileManager.copyItem(at: sourceURL, to: localURL)
            let badging = try await ExternalToolRunner.run(tools.aapt, arguments: ["dump", "badging", localURL.path])
            let package = try parsePackage(badging, file: sourceURL.lastPathComponent)
            let signatureOutput = try await ExternalToolRunner.run(tools.apksigner, arguments: ["verify", "--verbose", "--print-certs", "-Werr", localURL.path])
            let signers = try parseSignerDigests(signatureOutput, file: sourceURL.lastPathComponent)
            artifacts.append(APKArtifact(
                url: localURL,
                packageName: package.name,
                versionName: package.versionName,
                versionCode: package.versionCode,
                signerSHA256: signers,
                sha256: try Hash.sha256(file: localURL)
            ))
        }

        guard let first = artifacts.first else { throw ManagerError.invalidAPK("keine Dateien ausgewählt") }
        let samePackage = artifacts.allSatisfy { $0.packageName == first.packageName }
        let sameVersion = artifacts.allSatisfy { $0.versionCode == first.versionCode && $0.versionName == first.versionName }
        let sameSigner = artifacts.allSatisfy { $0.signerSHA256 == first.signerSHA256 }
        guard samePackage else { throw ManagerError.invalidAPK("Split-APK-Satz enthält verschiedene Paketnamen") }
        guard sameVersion else { throw ManagerError.invalidAPK("Split-APK-Satz enthält verschiedene Versionen") }
        guard sameSigner else { throw ManagerError.invalidAPK("Split-APK-Satz enthält verschiedene Signaturen") }

        let installed = try await discovery.packageDetails(serial: serial, packageName: first.packageName)
        var installedSigners: [String]?
        if let installed {
            guard first.versionCode >= (installed.versionCode ?? 0) else {
                throw ManagerError.invalidAPK("Downgrade blockiert: installiert ist VersionCode \(installed.versionCode ?? 0), ausgewählt ist \(first.versionCode)")
            }
            installedSigners = try await installedSignerDigests(serial: serial, packageName: first.packageName, tools: tools)
            guard installedSigners == first.signerSHA256 else {
                throw ManagerError.invalidAPK("Signaturschlüssel weicht von der installierten App ab. Die App wird nicht entfernt oder ersetzt.")
            }
        }
        return APKInstallPlan(
            id: planID, deviceSerial: serial, packageName: first.packageName, versionName: first.versionName, versionCode: first.versionCode,
            signerSHA256: first.signerSHA256, artifacts: artifacts,
            installedVersionName: installed?.versionName, installedVersionCode: installed?.versionCode,
            installedSignerSHA256: installedSigners
        )
        } catch {
            try? fileManager.removeItem(at: stagingFolder)
            throw error
        }
    }

    func install(_ plan: APKInstallPlan, serial: String) async throws {
        for artifact in plan.artifacts {
            guard fileManager.fileExists(atPath: artifact.url.path), try Hash.sha256(file: artifact.url) == artifact.sha256 else {
                throw ManagerError.invalidAPK("APK-Datei \(artifact.url.lastPathComponent) hat sich seit der Prüfung geändert.")
            }
        }
        let paths = plan.artifacts.map { $0.url.path }
        let arguments: [String] = paths.count == 1 ? ["install", "-r", paths[0]] : ["install-multiple", "-r"] + paths
        do { _ = try await adb.device(serial: serial, arguments: arguments, timeout: 300) }
        catch { throw InstallFailure.friendly(error) }
    }

    func discard(_ plan: APKInstallPlan) {
        let stagingFolder = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HandheldManager/StagedAPKs/\(plan.id.uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: stagingFolder)
    }

    func installedSignerDigests(serial: String, packageName: String, tools: AndroidBuildTools? = nil) async throws -> [String] {
        guard let tools = tools ?? self.tools else { throw ManagerError.androidBuildToolsMissing }
        let pathOutput = try await adb.shell(serial: serial, "pm path \(RemotePath.shellQuote(packageName))")
        let apkPaths = pathOutput.standardOutput.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("package:") else { return nil }
            return String(text.dropFirst("package:".count))
        }
        guard let base = apkPaths.first(where: { ($0 as NSString).lastPathComponent == "base.apk" }) ?? apkPaths.first else {
            throw ManagerError.invalidAPK("installierte APK-Datei konnte nicht über pm path gefunden werden")
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("HandheldManager-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }
        let local = folder.appendingPathComponent("installed.apk")
        try await adb.pull(serial: serial, remote: base, local: local)
        let output = try await ExternalToolRunner.run(tools.apksigner, arguments: ["verify", "--verbose", "--print-certs", "-Werr", local.path])
        return try parseSignerDigests(output, file: packageName)
    }

    private func parsePackage(_ output: String, file: String) throws -> (name: String, versionName: String?, versionCode: Int64) {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("package:") }) else {
            throw ManagerError.invalidAPK("Manifesteintrag fehlt in \(file)")
        }
        let text = String(line)
        guard let name = capture(#"name='([^']+)'"#, in: text, group: 1),
              let codeText = capture(#"versionCode='([0-9]+)'"#, in: text, group: 1),
              let code = Int64(codeText) else { throw ManagerError.invalidAPK("Paketname oder versionCode fehlt in \(file)") }
        return (name, capture(#"versionName='([^']*)'"#, in: text, group: 1), code)
    }

    private func parseSignerDigests(_ output: String, file: String) throws -> [String] {
        let pattern = #"(?i)certificate SHA-256 digest:\s*([0-9a-f]{64})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { throw ManagerError.invalidAPK("Signaturausgabe konnte nicht gelesen werden") }
        let range = NSRange(output.startIndex..., in: output)
        let digests = regex.matches(in: output, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: output) else { return nil }
            return String(output[range]).lowercased()
        }.sorted()
        guard !digests.isEmpty else { throw ManagerError.invalidAPK("SHA-256 Signaturzertifikat fehlt in \(file)") }
        return digests
    }

    private func capture(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
