import Foundation

struct FileOperationResult {
    let summary: String
    let sha256: String?
    let recoverableAt: String?
}

struct QuarantineRecord: Codable, Identifiable {
    let id: UUID
    let deviceSerial: String
    let originalPath: String
    let quarantinePath: String
    let createdAt: Date
}

final class DeviceDiscoveryService {
    private let adb: ADBClient
    init(adb: ADBClient) { self.adb = adb }

    func connections() async throws -> [DeviceConnection] { try await adb.listDevices() }

    func descriptor(for connection: DeviceConnection) async throws -> DeviceDescriptor {
        guard connection.state == "device" else { throw ManagerError.deviceNotReady(connection.state) }
        var descriptor = DeviceDescriptor(connection: connection)
        descriptor.manufacturer = try await adb.property(serial: connection.serial, key: "ro.product.manufacturer")
        descriptor.model = try await adb.property(serial: connection.serial, key: "ro.product.model")
        descriptor.device = try await adb.property(serial: connection.serial, key: "ro.product.device")
        descriptor.androidVersion = try await adb.property(serial: connection.serial, key: "ro.build.version.release")
        descriptor.apiLevel = try await adb.property(serial: connection.serial, key: "ro.build.version.sdk")
        descriptor.securityPatch = try await adb.property(serial: connection.serial, key: "ro.build.version.security_patch")
        descriptor.build = try await adb.property(serial: connection.serial, key: "ro.build.display.id")
        descriptor.fingerprint = try await adb.property(serial: connection.serial, key: "ro.build.fingerprint")
        descriptor.volumes = try await discoverVolumes(serial: connection.serial)
        descriptor.packages = try await installedPackages(serial: connection.serial)
        descriptor.homeActivities = (try? await homeActivities(serial: connection.serial)) ?? []
        descriptor.currentHomeActivity = try? await currentHomeActivity(serial: connection.serial)
        descriptor.canSetHomeActivity = (try? await canSetHomeActivity(serial: connection.serial)) ?? false
        descriptor.settingsActions = (try? await settingsActionAvailability(serial: connection.serial)) ?? []
        descriptor.reports = makeReports(descriptor)
        return descriptor
    }

    private func discoverVolumes(serial: String) async throws -> [StorageVolume] {
        let result = try await adb.shell(serial: serial, "sm list-volumes all")
        let rows = result.standardOutput.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        var volumes: [StorageVolume] = []
        for row in rows where row.count >= 3 && row[1] == "mounted" {
            let path: String
            let name: String
            let kind: StorageVolume.Kind
            if row[0] == "emulated;0" {
                path = "/storage/emulated/0"
                name = "Interner Speicher"
                kind = .internalStorage
            } else if row[0].hasPrefix("public:"), row[2] != "null" {
                path = "/storage/\(row[2])"
                name = "microSD"
                kind = .removable
            } else {
                continue
            }
            let quoted = RemotePath.shellQuote(path)
            let listing = try? await adb.shell(serial: serial, "ls -la \(quoted)")
            let capacity = try? await adb.shell(serial: serial, "df -k \(quoted)")
            let writable = (try? await adb.shell(serial: serial, "test -w \(quoted) && echo yes || echo no"))?.standardOutput.contains("yes") ?? false
            volumes.append(StorageVolume(
                id: path,
                name: name,
                path: path,
                kind: kind,
                readable: listing != nil,
                writable: writable,
                capacity: capacity.flatMap { Self.formatCapacity($0.standardOutput) }
            ))
        }
        return volumes
    }

    private func installedPackages(serial: String) async throws -> [InstalledPackage] {
        let allResult = try await adb.shell(serial: serial, "pm list packages")
        let thirdPartyResult = try await adb.shell(serial: serial, "pm list packages -3")
        let thirdParty = Set(thirdPartyResult.standardOutput.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line)
            return text.hasPrefix("package:") ? String(text.dropFirst("package:".count)) : nil
        })
        let versions = (try? await adb.shell(serial: serial, "dumpsys package packages", timeout: 60)).map { Self.parsePackageVersions($0.standardOutput) } ?? [:]
        let sizes = (try? await adb.shell(serial: serial, "dumpsys diskstats", timeout: 60)).map { Self.parsePackageStorage($0.standardOutput) } ?? [:]
        let packages: [InstalledPackage] = allResult.standardOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard text.hasPrefix("package:") else { return nil }
            let packageName = String(text.dropFirst("package:".count))
            let version = versions[packageName]
            return InstalledPackage(packageName: packageName, isEmulator: nil, versionName: version?.name, versionCode: version?.code, isSystemApp: !thirdParty.contains(packageName), storageBytes: sizes[packageName])
        }
        return EmulatorCatalog.annotate(packages).sorted {
            if $0.isEmulator != $1.isEmulator { return $0.isEmulator == true }
            return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
    }

    private static func parsePackageVersions(_ output: String) -> [String: (name: String?, code: Int64?)] {
        var result: [String: (name: String?, code: Int64?)] = [:]
        var currentPackage: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let range = text.range(of: #"^\s*Package \[([^\]]+)\]"#, options: .regularExpression) {
                let header = String(text[range])
                currentPackage = header.range(of: #"\[([^\]]+)\]"#, options: .regularExpression).map { String(header[$0].dropFirst().dropLast()) }
                if let currentPackage { result[currentPackage] = (nil, nil) }
                continue
            }
            guard let currentPackage else { continue }
            if let range = text.range(of: "versionName=") {
                let value = text[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
                if let value, value != "null", !value.isEmpty { result[currentPackage]?.name = value }
            }
            if let range = text.range(of: "versionCode=") {
                let digits = text[range.upperBound...].prefix(while: \.isNumber)
                if let code = Int64(digits) { result[currentPackage]?.code = code }
            }
        }
        return result
    }

    private static func parsePackageStorage(_ output: String) -> [String: Int64] {
        func array(after label: String) -> [String]? {
            guard let labelRange = output.range(of: label),
                  let open = output[labelRange.upperBound...].firstIndex(of: "["),
                  let close = output[output.index(after: open)...].firstIndex(of: "]") else { return nil }
            return output[output.index(after: open)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\\\"")) }
        }
        guard let names = array(after: "Package Names:"),
              let code = array(after: "App Sizes:"),
              let data = array(after: "App Data Sizes:"),
              let cache = array(after: "Cache Sizes:") else { return [:] }
        var sizes: [String: Int64] = [:]
        for index in 0..<min(names.count, code.count, data.count, cache.count) {
            guard let codeBytes = Int64(code[index]), let dataBytes = Int64(data[index]), let cacheBytes = Int64(cache[index]) else { continue }
            sizes[names[index]] = codeBytes + dataBytes + cacheBytes
        }
        return sizes
    }

    func packageDetails(serial: String, packageName: String) async throws -> InstalledPackage? {
        guard packageName.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return nil }
        let output = try await adb.shell(serial: serial, "dumpsys package \(RemotePath.shellQuote(packageName))")
        var versionName: String?
        var versionCode: Int64?
        for line in output.standardOutput.split(whereSeparator: \.isNewline) {
            if versionName == nil, let range = line.range(of: "versionName=") {
                let value = line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
                if let value, value != "null", !value.isEmpty { versionName = value }
            }
            if versionCode == nil, let range = line.range(of: "versionCode=") {
                let digits = line[range.upperBound...].prefix(while: \.isNumber)
                versionCode = Int64(digits)
            }
            if versionName != nil && versionCode != nil { break }
        }
        guard versionName != nil || versionCode != nil else { return nil }
        return InstalledPackage(packageName: packageName, versionName: versionName, versionCode: versionCode)
    }

    func homeActivities(serial: String) async throws -> [HomeActivity] {
        let result = try await adb.shell(serial: serial, "cmd package query-activities --brief --components -a android.intent.action.MAIN -c android.intent.category.HOME")
        return parseHomeActivities(result.standardOutput)
    }

    func currentHomeActivity(serial: String) async throws -> HomeActivity? {
        let result = try await adb.shell(serial: serial, "cmd package resolve-activity --brief --components -a android.intent.action.MAIN -c android.intent.category.HOME")
        return parseHomeActivities(result.standardOutput).first
    }

    func openHomeSettings(serial: String) async throws {
        let activities = try await homeActivities(serial: serial)
        guard activities.count >= 2 else {
            throw ManagerError.launcherNotAvailable("Android meldet weniger als zwei Home-Apps. Installiere zuerst einen weiteren Launcher.")
        }
        _ = try await adb.shell(serial: serial, "am start -a android.settings.HOME_SETTINGS")
    }

    func canSetHomeActivity(serial: String) async throws -> Bool {
        // Some Android builds print help but still exit with 255. Return grep's
        // status so a supported command doesn't break the whole device refresh.
        let result = try await adb.shell(serial: serial, "cmd package help 2>&1 | grep -F 'set-home-activity' >/dev/null; echo $?")
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("0")
    }

    func setHomeActivity(serial: String, packageName: String) async throws -> HomeActivity {
        let choices = try await homeActivities(serial: serial)
        guard let target = choices.first(where: { $0.packageName == packageName }) else {
            throw ManagerError.launcherNotAvailable("Das ausgewählte Paket ist aktuell keine erkannte Home-App.")
        }
        guard try await canSetHomeActivity(serial: serial) else {
            throw ManagerError.launcherNotAvailable("Dieser Android-Build bietet cmd package set-home-activity nicht an. Öffne stattdessen die Home-Auswahl am Gerät.")
        }
        _ = try await adb.shell(serial: serial, "cmd package set-home-activity \(RemotePath.shellQuote(target.packageName))")
        guard let current = try await currentHomeActivity(serial: serial), current.packageName == target.packageName else {
            throw ManagerError.launcherNotAvailable("Android hat den Launcher nicht auf das ausgewählte Paket umgestellt.")
        }
        return current
    }

    func settingsActionAvailability(serial: String) async throws -> [SettingsActionAvailability] {
        var result: [SettingsActionAvailability] = []
        for action in SettingsAction.all {
            let output = try await adb.shell(serial: serial, "cmd package resolve-activity --brief --components -a \(RemotePath.shellQuote(action.action))")
            let component = parseHomeActivities(output.standardOutput).first?.componentName
            result.append(SettingsActionAvailability(actionID: action.id, resolvedComponent: component))
        }
        return result
    }

    func openSettingsAction(serial: String, actionID: String) async throws -> Bool {
        guard let action = SettingsAction.all.first(where: { $0.id == actionID }) else {
            throw ManagerError.commandFailed("Diese Systemeinstellungsaktion ist nicht freigegeben.")
        }
        let output = try await adb.shell(serial: serial, "cmd package resolve-activity --brief --components -a \(RemotePath.shellQuote(action.action))")
        let supported = parseHomeActivities(output.standardOutput).first != nil
        if supported {
            _ = try await adb.shell(serial: serial, "am start -a \(RemotePath.shellQuote(action.action))")
            return true
        }
        if actionID != "general" {
            _ = try await adb.shell(serial: serial, "am start -a android.settings.SETTINGS")
        }
        return false
    }

    private func parseHomeActivities(_ output: String) -> [HomeActivity] {
        var result: [HomeActivity] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let component = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let slash = component.firstIndex(of: "/") else { continue }
            let packageName = String(component[..<slash])
            guard packageName.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { continue }
            guard !result.contains(where: { $0.componentName == component }) else { continue }
            result.append(HomeActivity(packageName: packageName, componentName: component))
        }
        return result.sorted { $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending }
    }

    private func makeReports(_ descriptor: DeviceDescriptor) -> [CapabilityReport] {
        let canReadSharedStorage = descriptor.volumes.contains(where: \.readable)
        var reports = [
            CapabilityReport(id: "usb-adb", title: "USB-ADB", state: .supported, detail: "Gerät ist autorisiert und an eine konkrete ADB-Seriennummer gebunden."),
            CapabilityReport(id: "packages", title: "Installierte Apps inventarisieren", state: .supported, detail: "\(descriptor.packages.count) Apps gemeldet; Speicherwerte für \(descriptor.packages.filter { $0.storageBytes != nil }.count) Apps ermittelt."),
            CapabilityReport(id: "profiles", title: "Emulatorprofile", state: canReadSharedStorage ? .supported : .unavailable, detail: "Die App sucht Config-Dateien direkt in den lesbaren Emulatorordnern auf dem Gerät und sichert sie auf dem Mac. Nur Androids private /data/data-Sandbox bleibt für ADB gesperrt; dafür ist kein In-App-Export nötig."),
            CapabilityReport(id: "wireless", title: "Wireless Debugging", state: .unknown, detail: "Wird in dieser MVP-Version nicht automatisch eingerichtet.")
        ]
        reports.append(CapabilityReport(
            id: "launcher", title: "Home-Launcher",
            state: descriptor.homeActivities.count >= 2 ? .supported : .requiresOnDeviceAction,
            detail: descriptor.canSetHomeActivity
                ? "\(descriptor.homeActivities.count) Home-Aktivitäten erkannt; dieser Build meldet cmd package set-home-activity."
                : (descriptor.homeActivities.count >= 2 ? "\(descriptor.homeActivities.count) Home-Aktivitäten gefunden; Auswahl erfolgt sichtbar am Gerät." : "Installiere einen weiteren Home-Launcher, bevor Android eine Auswahl anzeigen kann.")
        ))
        let settingsAvailable = descriptor.settingsActions.filter(\.isAvailable).count
        reports.append(CapabilityReport(
            id: "settings", title: "Android-Einstellungsseiten",
            state: settingsAvailable > 0 ? .supported : .unknown,
            detail: "\(settingsAvailable) von \(SettingsAction.all.count) dokumentierten Aktionen auf diesem Build auflösbar; nicht verfügbare Seiten fallen auf Einstellungen zurück."
        ))
        let internalVolume = descriptor.volumes.first(where: { $0.kind == .internalStorage })
        reports.append(CapabilityReport(
            id: "internal-files", title: "Interne gemeinsame Dateien",
            state: internalVolume?.readable == true ? .supported : .unavailable,
            detail: internalVolume?.writable == true ? "Lesen und Schreiben am Gerät erreichbar." : "Lesen erreichbar; Schreibzugriff nicht bestätigt."
        ))
        let sd = descriptor.volumes.first(where: { $0.kind == .removable })
        reports.append(CapabilityReport(
            id: "sd-files", title: "microSD",
            state: sd == nil ? .unavailable : (sd?.readable == true ? .supported : .unknown),
            detail: sd?.writable == true ? "Gemountet; Lesen und Schreiben am Gerät erreichbar." : (sd == nil ? "Keine gemountete microSD erkannt." : "Gemountet; Schreibzugriff nicht bestätigt.")
        ))
        return reports
    }

    private static func formatCapacity(_ output: String) -> String? {
        let rows = output.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let row = rows.last, row.count >= 5,
              let used = Int64(row[2]), let free = Int64(row[3]) else { return nil }
        return "\((used * 1024).humanBytes) belegt · \((free * 1024).humanBytes) frei"
    }
}

final class DeviceFileService {
    private let adb: ADBClient
    private let fileManager = FileManager.default
    private let backupsDirectory: URL
    private(set) var lastReplacementBackup: FileReplacementBackup?

    init(adb: ADBClient) throws {
        self.adb = adb
        let support = try Self.supportDirectory()
        backupsDirectory = support.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        lastReplacementBackup = loadLatestReplacementBackup()
    }

    func previewUpload(serial: String, local: URL, destination: String, volume: StorageVolume) async throws -> FileTransferPreview {
        let target = try RemotePath.normalized(destination, within: volume)
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ManagerError.commandFailed("Bitte wähle eine einzelne Datei aus.") }
        let hash = try Hash.sha256(file: local)
        let exists = try await adb.remoteExists(serial: serial, path: target)
        return FileTransferPreview(source: local.path, destination: target, size: Int64(values.fileSize ?? 0), sha256: hash, destinationExists: exists)
    }

    func list(serial: String, path: String, volume: StorageVolume) async throws -> [DeviceFileEntry] {
        let normalized = try RemotePath.normalized(path, within: volume)
        let output = try await adb.shell(serial: serial, "ls -lan \(RemotePath.shellQuote(normalized))")
        return output.standardOutput.split(whereSeparator: \.isNewline).compactMap { Self.parseLSLine(String($0), directory: normalized) }
            .sorted { left, right in left.isDirectory != right.isDirectory ? left.isDirectory : left.name.localizedStandardCompare(right.name) == .orderedAscending }
    }

    func rename(serial: String, entry: DeviceFileEntry, to newName: String, volume: StorageVolume) async throws -> String {
        let source = try RemotePath.normalized(entry.path, within: volume)
        let trashRoot = volume.path + "/.HandheldManagerTrash"
        guard source != volume.path, source != trashRoot, !source.hasPrefix(trashRoot + "/") else {
            throw ManagerError.invalidRemotePath(source)
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ManagerError.commandFailed("Der Name darf nicht leer sein und keinen Schrägstrich oder Steuerzeichen enthalten.")
        }
        let parent = (source as NSString).deletingLastPathComponent
        let destination = parent + "/" + name
        guard destination != source else { return source }
        let siblingEntries = try await list(serial: serial, path: parent, volume: volume)
        guard let current = siblingEntries.first(where: { $0.path == source }),
              current.isDirectory == entry.isDirectory, abs(current.size - entry.size) <= 1024 else {
            throw ManagerError.stalePreview
        }
        guard !siblingEntries.contains(where: { $0.path == destination }) else {
            throw ManagerError.destinationExists(destination)
        }
        let sourceQuote = RemotePath.shellQuote(source)
        let destinationQuote = RemotePath.shellQuote(destination)
        _ = try await adb.shell(serial: serial, "mv -n \(sourceQuote) \(destinationQuote) && test ! -e \(sourceQuote) && test -e \(destinationQuote)")
        guard try await !adb.remoteExists(serial: serial, path: source),
              try await adb.remoteExists(serial: serial, path: destination) else {
            throw ManagerError.commandFailed("Android hat die Umbenennung nicht bestätigt.")
        }
        return destination
    }

    func upload(serial: String, local: URL, destination: String, volume: StorageVolume, replaceExisting: Bool, expectedPreview: FileTransferPreview? = nil) async throws -> FileOperationResult {
        let target = try RemotePath.normalized(destination, within: volume)
        let localValues = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard localValues.isRegularFile == true else { throw ManagerError.commandFailed("Bitte wähle eine einzelne Datei aus.") }
        let sourceHash = try Hash.sha256(file: local)
        let exists = try await adb.remoteExists(serial: serial, path: target)
        if let expectedPreview,
           (expectedPreview.destination != target || expectedPreview.destinationExists != exists || expectedPreview.sha256 != sourceHash || expectedPreview.size != Int64(localValues.fileSize ?? 0)) {
            throw ManagerError.stalePreview
        }
        guard !exists || replaceExisting else { throw ManagerError.destinationExists(target) }

        var backupPath: URL?
        var replacementRecord: FileReplacementBackup?
        var manifestURL: URL?
        if exists {
            let backup = backupsDirectory.appendingPathComponent("\(UUID().uuidString)-\(local.lastPathComponent)")
            let remoteHash = try await adb.remoteSHA256(serial: serial, path: target)
            try await adb.pull(serial: serial, remote: target, local: backup)
            guard try Hash.sha256(file: backup) == remoteHash else {
                try? fileManager.removeItem(at: backup)
                throw ManagerError.commandFailed("Das vorhandene Ziel konnte nicht verlustfrei gesichert werden; es wurde nicht ersetzt.")
            }
            backupPath = backup
            let record = FileReplacementBackup(id: UUID(), deviceSerial: serial, remotePath: target, localBackupPath: backup.path, originalSHA256: remoteHash, createdAt: Date())
            let manifest = backupsDirectory.appendingPathComponent("\(record.id.uuidString).file-backup.json")
            try JSONEncoder.profileEncoder.encode(record).write(to: manifest, options: .atomic)
            replacementRecord = record
            manifestURL = manifest
        }

        let stage = (target as NSString).deletingLastPathComponent + "/.handheld-manager-\(UUID().uuidString).tmp"
        var commitAttempted = false
        do {
            try await adb.push(serial: serial, local: local, remote: stage)
            let stagedHash = try await adb.remoteSHA256(serial: serial, path: stage)
            guard stagedHash == sourceHash else { throw ManagerError.commandFailed("Hashprüfung nach Upload fehlgeschlagen; das Ziel wurde nicht ersetzt.") }
            commitAttempted = true
            if let replacementRecord { lastReplacementBackup = replacementRecord }
            _ = try await adb.shell(serial: serial, "mv -f \(RemotePath.shellQuote(stage)) \(RemotePath.shellQuote(target))")
            if let replacementRecord { lastReplacementBackup = replacementRecord }
            return FileOperationResult(summary: "\(local.lastPathComponent) übertragen (\(Int64(localValues.fileSize ?? 0).humanBytes)).", sha256: sourceHash, recoverableAt: backupPath?.path)
        } catch {
            _ = try? await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(stage))")
            if !commitAttempted {
                if let backupPath { try? fileManager.removeItem(at: backupPath) }
                if let manifestURL { try? fileManager.removeItem(at: manifestURL) }
            }
            throw error
        }
    }

    func download(serial: String, source: String, volume: StorageVolume, localDestination: URL, replaceExisting: Bool) async throws -> FileOperationResult {
        let remote = try RemotePath.normalized(source, within: volume)
        let exists = fileManager.fileExists(atPath: localDestination.path)
        guard !exists || replaceExisting else { throw ManagerError.destinationExists(localDestination.path) }
        let temp = localDestination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
        try await adb.pull(serial: serial, remote: remote, local: temp)
        do {
            let deviceHash = try await adb.remoteSHA256(serial: serial, path: remote)
            let localHash = try Hash.sha256(file: temp)
            guard deviceHash == localHash else { throw ManagerError.commandFailed("Hashprüfung nach Download fehlgeschlagen.") }
            if exists { try fileManager.removeItem(at: localDestination) }
            try fileManager.moveItem(at: temp, to: localDestination)
            return FileOperationResult(summary: "\(localDestination.lastPathComponent) heruntergeladen.", sha256: localHash, recoverableAt: nil)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    func exportConfigurationFiles(serial: String, paths: [String], volume: StorageVolume, directory: URL) async throws -> [URL] {
        guard !paths.isEmpty, paths.count <= 100 else { throw ManagerError.commandFailed("Wähle zwischen 1 und 100 Konfigurationsdateien aus.") }
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        var normalizedPaths = try paths.map { try RemotePath.normalized($0, within: volume) }
        guard Set(normalizedPaths).count == normalizedPaths.count else { throw ManagerError.commandFailed("Die Liste enthält doppelte Gerätepfade.") }
        normalizedPaths.sort()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var exported: [URL] = []
        for remotePath in normalizedPaths {
            let relative = String(remotePath.dropFirst(volume.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { throw ManagerError.invalidRemotePath(remotePath) }
            let destination = directory.appendingPathComponent(relative)
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destination.path) else { throw ManagerError.destinationExists(destination.path) }
            let temp = parent.appendingPathComponent(".\(UUID().uuidString).config-download")
            do {
                try await adb.pull(serial: serial, remote: remotePath, local: temp)
                let expectedHash = try await adb.remoteSHA256(serial: serial, path: remotePath)
                guard try Hash.sha256(file: temp) == expectedHash else { throw ManagerError.commandFailed("Konfigurationsdatei hat die Hashprüfung nicht bestanden: \(remotePath)") }
                try fileManager.moveItem(at: temp, to: destination)
                exported.append(destination)
            } catch {
                try? fileManager.removeItem(at: temp)
                for file in exported { try? fileManager.removeItem(at: file) }
                throw error
            }
        }
        return exported
    }

    func discoverConfigurationFiles(serial: String, package: InstalledPackage, volume: StorageVolume) async throws -> [EmulatorConfigFile] {
        guard volume.readable else { throw ManagerError.commandFailed("Dieses Volume ist nicht lesbar.") }
        var roots = [
            volume.path + "/Android/data/" + package.packageName,
            volume.path + "/Android/media/" + package.packageName
        ]
        let packageLower = package.packageName.lowercased()
        if packageLower.contains("retroarch") { roots.append(volume.path + "/RetroArch") }
        if packageLower.contains("ppsspp") { roots.append(volume.path + "/PSP") }
        roots = Array(Set(roots))
        let findRoots = roots.map(RemotePath.shellQuote).joined(separator: " ")
        let command = "find \(findRoots) -maxdepth 8 \\( -type d \\( -iname 'GameSettings' -o -iname 'saves' -o -iname 'states' -o -iname 'cache' -o -iname 'logs' -o -iname 'screenshots' -o -iname 'covers' -o -iname 'thumbnails' -o -iname 'bios' \\) -prune \\) -o \\( -type f \\( -iname '*.ini' -o -iname '*.cfg' -o -iname '*.xml' -o -iname '*.json' -o -iname '*.conf' -o -iname '*.toml' -o -iname '*.yaml' -o -iname '*.yml' \\) -exec stat -c '%s %n' {} + \\) 2>/dev/null | head -n 1000"
        let output = try await adb.shell(serial: serial, command, timeout: 90)
        var results: [EmulatorConfigFile] = []
        for line in output.standardOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let separator = text.firstIndex(where: \.isWhitespace),
                  let size = Int64(text[..<separator]), size >= 0 else { continue }
            let path = String(text[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard roots.contains(where: { path.hasPrefix($0 + "/") }),
                  (try? RemotePath.normalized(path, within: volume)) != nil else { continue }
            guard let rank = Self.configurationPriority(path: path) else { continue }
            let name = (path as NSString).lastPathComponent
            results.append(EmulatorConfigFile(name: name, path: path, volumeID: volume.id, size: size, priority: rank.priority, priorityLabel: rank.label))
        }
        return results.sorted {
            $0.priority == $1.priority
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : $0.priority < $1.priority
        }
    }

    private static func configurationPriority(path: String) -> (priority: Int, label: String)? {
        let lower = path.lowercased()
        let excluded = ["/gamesettings/", "/saves/", "/states/", "/cache/", "/logs/", "/screenshots/", "/covers/", "/thumbnails/", "/bios/"]
        guard !excluded.contains(where: lower.contains) else { return nil }
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let allowed = ["ini", "cfg", "xml", "json", "conf", "toml", "yaml", "yml"]
        guard allowed.contains(ext) else { return nil }
        if ["xml", "json"].contains(ext),
           !["config", "settings", "preferences", "input", "controller", "control", "mapping"].contains(where: name.contains) {
            return nil
        }
        let mainNames = ["retroarch.cfg", "ppsspp.ini", "dolphin.ini", "settings.ini", "config.ini", "qt-config.ini", "preferences.xml", "pcsx2.ini"]
        if mainNames.contains(name) { return (0, "Hauptconfig") }
        let importantNames = ["input", "control", "hotkey", "gfx.ini", "wiimotenew.ini", "gcpadnew.ini", "gckeynew.ini", "free look.ini", "audio", "video", "system"]
        if importantNames.contains(where: name.contains) {
            return (1, "Wichtige Einstellung")
        }
        if lower.contains("/profiles/") || name.contains("profile") || name.contains("controller") || name.contains("mapping") {
            return (2, "Profil / Steuerung")
        }
        return (3, "Weitere Config")
    }

    func quarantine(serial: String, path: String, volume: StorageVolume) async throws -> QuarantineRecord {
        let source = try RemotePath.normalized(path, within: volume)
        let trashRoot = volume.path + "/.HandheldManagerTrash"
        guard source != volume.path, source != trashRoot, !source.hasPrefix(trashRoot + "/") else { throw ManagerError.invalidRemotePath(source) }
        let transaction = UUID().uuidString
        let targetDirectory = trashRoot + "/" + transaction
        let target = targetDirectory + "/" + ((source as NSString).lastPathComponent)
        _ = try await adb.shell(serial: serial, "mkdir -p \(RemotePath.shellQuote(targetDirectory))")
        _ = try await adb.shell(serial: serial, "mv \(RemotePath.shellQuote(source)) \(RemotePath.shellQuote(target))")
        return QuarantineRecord(id: UUID(), deviceSerial: serial, originalPath: source, quarantinePath: target, createdAt: Date())
    }

    func deletePermanently(serial: String, entry: DeviceFileEntry, volume: StorageVolume) async throws {
        let target = try RemotePath.normalized(entry.path, within: volume)
        let trashRoot = volume.path + "/.HandheldManagerTrash"
        guard target != volume.path, target != trashRoot, !target.hasPrefix(trashRoot + "/") else {
            throw ManagerError.invalidRemotePath(target)
        }
        let parent = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        guard let current = try await list(serial: serial, path: parent, volume: volume).first(where: { $0.name == name }),
              current.path == target, current.isDirectory == entry.isDirectory,
              abs(current.size - entry.size) <= 1024 else { throw ManagerError.stalePreview }
        _ = try await adb.shell(serial: serial, "rm -rf \(RemotePath.shellQuote(target))")
        guard try await !adb.remoteExists(serial: serial, path: target) else {
            throw ManagerError.commandFailed("Android hat den Eintrag nicht entfernt: \(target)")
        }
    }

    func deletePermanently(serial: String, entry: StorageUsageEntry, volume: StorageVolume) async throws {
        let target = try RemotePath.normalized(entry.path, within: volume)
        let trashRoot = volume.path + "/.HandheldManagerTrash"
        guard target != volume.path, target != trashRoot, !target.hasPrefix(trashRoot + "/") else {
            throw ManagerError.invalidRemotePath(target)
        }
        let parent = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        guard let current = try await list(serial: serial, path: parent, volume: volume).first(where: { $0.name == name }),
              current.path == target, current.isDirectory == entry.isDirectory else { throw ManagerError.stalePreview }
        if !entry.isDirectory {
            guard abs(current.size - entry.sizeBytes) <= 1024 else { throw ManagerError.stalePreview }
        } else if !entry.path.isEmpty, entry.sizeBytes > 0 {
            let measured = try await adb.shell(serial: serial, "du -sk \(RemotePath.shellQuote(target)) 2>/dev/null")
            let currentSize = measured.standardOutput.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) }.map { $0 * 1024 }
            guard let currentSize, abs(currentSize - entry.sizeBytes) <= 1024 else { throw ManagerError.stalePreview }
        }
        _ = try await adb.shell(serial: serial, "rm -rf \(RemotePath.shellQuote(target))")
        guard try await !adb.remoteExists(serial: serial, path: target) else {
            throw ManagerError.commandFailed("Android hat den Eintrag nicht entfernt: \(target)")
        }
    }

    func deletePermanently(serial: String, path: String, expectedSize: Int64, volume: StorageVolume) async throws {
        let target = try RemotePath.normalized(path, within: volume)
        guard target != volume.path, !target.contains("/.HandheldManagerTrash/") else { throw ManagerError.invalidRemotePath(target) }
        let parent = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        guard let current = try await list(serial: serial, path: parent, volume: volume).first(where: { $0.name == name }),
              !current.isDirectory, abs(current.size - expectedSize) <= 1024 else { throw ManagerError.stalePreview }
        _ = try await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(target))")
        guard try await !adb.remoteExists(serial: serial, path: target) else {
            throw ManagerError.commandFailed("Android hat die Datei nicht entfernt: \(target)")
        }
    }

    func restore(_ record: QuarantineRecord, volume: StorageVolume) async throws {
        let original = try RemotePath.normalized(record.originalPath, within: volume)
        let quarantined = try RemotePath.normalized(record.quarantinePath, within: volume)
        guard try await !adb.remoteExists(serial: record.deviceSerial, path: original) else { throw ManagerError.destinationExists(original) }
        _ = try await adb.shell(serial: record.deviceSerial, "mv \(RemotePath.shellQuote(quarantined)) \(RemotePath.shellQuote(original))")
    }

    func restoreLastReplacement(serial: String, volume: StorageVolume) async throws {
        guard let record = lastReplacementBackup, record.deviceSerial == serial else { throw ManagerError.noBackupAvailable }
        let target = try RemotePath.normalized(record.remotePath, within: volume)
        let backup = URL(fileURLWithPath: record.localBackupPath)
        guard fileManager.fileExists(atPath: backup.path), try Hash.sha256(file: backup) == record.originalSHA256 else {
            throw ManagerError.commandFailed("Lokales Ersatzbackup fehlt oder sein Hash stimmt nicht.")
        }
        let stage = target + ".handheld-manager-restore-\(UUID().uuidString)"
        try await adb.push(serial: serial, local: backup, remote: stage)
        do {
            let remoteHash = try await adb.remoteSHA256(serial: serial, path: stage)
            guard remoteHash == record.originalSHA256 else { throw ManagerError.commandFailed("Hashprüfung des Wiederherstellungsuploads fehlgeschlagen.") }
            _ = try await adb.shell(serial: serial, "mv -f \(RemotePath.shellQuote(stage)) \(RemotePath.shellQuote(target))")
            let manifest = backupsDirectory.appendingPathComponent("\(record.id.uuidString).file-backup.json")
            try? fileManager.removeItem(at: manifest)
            lastReplacementBackup = nil
        } catch {
            _ = try? await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(stage))")
            throw error
        }
    }

    static func parseLSLine(_ line: String, directory: String) -> DeviceFileEntry? {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 8, let size = Int64(tokens[4]) else { return nil }
        guard tokens[0].first != "l",
              let regex = try? NSRegularExpression(pattern: #"^\s*\S+(?:\s+\S+){6}\s+"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        var name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { return nil }
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        let isDirectory = tokens[0].first == "d"
        let child = directory == "/" ? "/\(name)" : "\(directory)/\(name)"
        return DeviceFileEntry(name: name, path: child, isDirectory: isDirectory, size: size, modified: "\(tokens[5]) \(tokens[6])")
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let app = base.appendingPathComponent("HandheldManager", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    private func loadLatestReplacementBackup() -> FileReplacementBackup? {
        guard let urls = try? fileManager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let manifests = urls.filter { $0.lastPathComponent.hasSuffix(".file-backup.json") }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        for manifest in manifests {
            guard let data = try? Data(contentsOf: manifest),
                  let record = try? JSONDecoder.profileDecoder.decode(FileReplacementBackup.self, from: data),
                  fileManager.fileExists(atPath: record.localBackupPath) else { continue }
            return record
        }
        return nil
    }
}

final class StorageUsageService {
    private let adb: ADBClient
    init(adb: ADBClient) { self.adb = adb }

    func scan(serial: String, volume: StorageVolume, root: String? = nil, limit: Int = 200) async throws -> [StorageUsageEntry] {
        guard volume.readable else { throw ManagerError.commandFailed("Dieses Volume ist nicht lesbar.") }
        let scanRoot = root ?? volume.path
        guard (try? RemotePath.normalized(scanRoot, within: volume)) != nil,
              scanRoot == volume.path || scanRoot.hasPrefix(volume.path + "/") else {
            throw ManagerError.commandFailed("Der Scanpfad liegt außerhalb des ausgewählten Volumes.")
        }
        // List one directory at a time. Recursively calculating every size at
        // the volume root made large SD cards appear frozen and blocked folder
        // navigation. Users can drill into directories to reach large files.
        let output = try await adb.shell(serial: serial, "ls -lan \(RemotePath.shellQuote(scanRoot))", timeout: 30)
        var entries: [StorageUsageEntry] = []
        for line in output.standardOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let columns = text.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 8, columns[0].first != "l",
                  let itemSize = Int64(columns[4]), itemSize >= 0,
                  let prefix = try? NSRegularExpression(pattern: #"^\s*\S+(?:\s+\S+){6}\s+"#),
                  let match = prefix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { continue }
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != ".", name != "..", !name.contains(" -> ") else { continue }
            let path = scanRoot == "/" ? "/\(name)" : "\(scanRoot)/\(name)"
            guard !path.contains("/.HandheldManagerTrash/"),
                  (try? RemotePath.normalized(path, within: volume)) != nil else { continue }
            let isDirectory = columns[0].first == "d"
            entries.append(StorageUsageEntry(path: path, sizeBytes: isDirectory ? 0 : itemSize, volumeID: volume.id, isDirectory: isDirectory))
        }
        let sorted = entries.sorted { left, right in
            if left.sizeBytes != right.sizeBytes { return left.sizeBytes > right.sizeBytes }
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
        return Array(sorted.prefix(max(1, min(limit, 500))))
    }

    func calculateDirectorySizes(serial: String, entries: [StorageUsageEntry]) async throws -> [String: Int64] {
        let directories = entries.filter(\.isDirectory)
        guard !directories.isEmpty else { return [:] }
        let deadline = Date().addingTimeInterval(90)
        var sizes: [String: Int64] = [:]
        for start in stride(from: 0, to: directories.count, by: 16) {
            guard !Task.isCancelled, Date() < deadline else { break }
            let batch = Array(directories[start..<min(start + 16, directories.count)])
            let measured = try await measureDirectorySizes(serial: serial, entries: batch, deadline: deadline)
            sizes.merge(measured) { _, new in new }
        }
        return sizes
    }

    private func measureDirectorySizes(
        serial: String,
        entries: [StorageUsageEntry],
        deadline: Date
    ) async throws -> [String: Int64] {
        guard !entries.isEmpty, !Task.isCancelled else { return [:] }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return [:] }
        let paths = entries.map { RemotePath.shellQuote($0.path) }.joined(separator: " ")
        let timeout = min(25, max(1, remaining))
        do {
            let output = try await adb.shell(serial: serial, "du -sk \(paths) 2>/dev/null", timeout: timeout)
            var sizes: [String: Int64] = [:]
            let acceptedPaths = Set(entries.map(\.path))
            for line in output.standardOutput.split(whereSeparator: \.isNewline) {
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let split = text.firstIndex(where: \.isWhitespace),
                      let kilobytes = Int64(text[..<split]), kilobytes >= 0 else { continue }
                let path = String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if acceptedPaths.contains(path) { sizes[path] = kilobytes * 1024 }
            }

            // Some Android builds omit inaccessible paths from `du` output.
            // Retry only those paths so one protected folder does not hide sizes
            // for the rest of the directory listing.
            let missing = entries.filter { sizes[$0.path] == nil }
            if entries.count > 1, !missing.isEmpty, Date() < deadline {
                let retried = try await measureDirectorySizes(serial: serial, entries: missing, deadline: deadline)
                sizes.merge(retried) { _, new in new }
            }
            return sizes
        } catch ManagerError.commandTimedOut {
            // Split slow batches and retain the sizes that can still be measured.
            // A single very large folder stays marked as unmeasured in the UI.
            guard entries.count > 1, Date() < deadline else { return [:] }
            let midpoint = entries.count / 2
            let first = try await measureDirectorySizes(serial: serial, entries: Array(entries[..<midpoint]), deadline: deadline)
            let second = try await measureDirectorySizes(serial: serial, entries: Array(entries[midpoint...]), deadline: deadline)
            var combined = first
            combined.merge(second) { _, new in new }
            return combined
        }
    }
}
