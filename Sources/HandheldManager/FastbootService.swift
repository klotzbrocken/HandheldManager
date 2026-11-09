import Foundation

struct FastbootClient {
    let executable: URL

    init?(path: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)) {
        let candidates = ["/opt/homebrew/bin/fastboot", "/usr/local/bin/fastboot"] + path.map { URL(fileURLWithPath: $0).appendingPathComponent("fastboot").path }
        guard let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        executable = URL(fileURLWithPath: match)
    }

    func waitForDevice(serial expectedSerial: String, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await run(["devices"], timeout: 10)
            let serials = result.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, fields[1] == "fastboot" else { return nil }
                return String(fields[0])
            }
            if serials.contains(expectedSerial) { return }
            if !serials.isEmpty { throw ManagerError.commandFailed("Fastboot meldet ein anderes Gerät (\(serials.joined(separator: ", "))); Boot-Image wurde nicht gestartet.") }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ManagerError.commandTimedOut("fastboot devices — das ausgewählte Gerät wurde nicht mit derselben Seriennummer gefunden")
    }

    func boot(serial: String, image: URL) async throws -> String {
        let accessed = image.startAccessingSecurityScopedResource()
        defer { if accessed { image.stopAccessingSecurityScopedResource() } }
        return try await run(["-s", serial, "boot", image.path], timeout: 300)
    }

    func reboot(serial: String) async throws {
        _ = try await run(["-s", serial, "reboot"], timeout: 60)
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let r = try await ProcessRunner.run(executable, arguments, timeout: timeout, outputLimit: 256 * 1024)
        if r.timedOut { throw ManagerError.commandTimedOut("fastboot \(arguments.prefix(3).joined(separator: " "))") }
        guard r.status == 0 else {
            let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.commandFailed(message.isEmpty ? "fastboot fehlgeschlagen (\(r.status))." : message)
        }
        return r.stdout
    }
}

struct OverclockImageInspection {
    let fileName: String
    let sha256: String
    let isAndroidBootImage: Bool
}

enum OverclockImageInspector {
    static func inspect(_ url: URL) async throws -> OverclockImageInspection {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        let magic = try handle.read(upToCount: 8) ?? Data()
        try? handle.close()
        let digest = try await FirmwareChecksumService.sha256(of: url)
        return OverclockImageInspection(
            fileName: url.lastPathComponent,
            sha256: digest,
            isAndroidBootImage: size >= 16 * 1024 * 1024 && magic == Data("ANDROID!".utf8)
        )
    }
}
