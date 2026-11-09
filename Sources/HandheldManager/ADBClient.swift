import Foundation

struct ADBExecutableLocator {
    static func locate() throws -> URL {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb") { candidates.append(bundled) }
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/adb"), URL(fileURLWithPath: "/usr/local/bin/adb")]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("adb") }
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return match }
        throw ManagerError.adbNotFound
    }
}

final class ADBClient {
    private let executable: URL
    private let timeout: TimeInterval

    init(executable: URL? = nil, timeout: TimeInterval = 45) throws {
        self.executable = try executable ?? ADBExecutableLocator.locate()
        self.timeout = timeout
    }

    var executablePath: String { executable.path }

    func listDevices() async throws -> [DeviceConnection] {
        let result = try await run(["devices", "-l"])
        return result.standardOutput.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] != "*" else { return nil }
            func value(_ key: String) -> String? {
                fields.first(where: { $0.hasPrefix(key + ":") }).map { String($0.dropFirst(key.count + 1)) }
            }
            return DeviceConnection(serial: fields[0], state: fields[1], product: value("product"), model: value("model"), device: value("device"))
        }
    }

    func device(serial: String, arguments: [String], timeout: TimeInterval? = nil) async throws -> ADBCommandResult {
        try await run(["-s", serial] + arguments, timeout: timeout)
    }

    func shell(serial: String, _ command: String, timeout: TimeInterval? = nil) async throws -> ADBCommandResult {
        try await device(serial: serial, arguments: ["shell", command], timeout: timeout)
    }

    func property(serial: String, key: String) async throws -> String {
        let output = try await shell(serial: serial, "getprop \(RemotePath.shellQuote(key))")
        return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func push(serial: String, local: URL, remote: String, timeout: TimeInterval? = nil) async throws {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
        _ = try await device(serial: serial, arguments: ["push", local.path, remote], timeout: timeout ?? max(300, Double(bytes) / 2_000_000))  // ≥ 2 MB/s assumed
    }

    func pull(serial: String, remote: String, local: URL, timeout: TimeInterval? = nil) async throws {
        _ = try await device(serial: serial, arguments: ["pull", remote, local.path], timeout: timeout ?? 1800)
    }

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ADBCommandResult {
        let r = try await ProcessRunner.run(executable, arguments, timeout: timeout ?? self.timeout)
        let command = arguments.prefix(3).joined(separator: " ")
        if r.timedOut { throw ManagerError.commandTimedOut(command) }
        if r.truncated { throw ManagerError.commandFailed("ADB-Ausgabe überschreitet das sichere Limit von 2 MiB.") }
        guard r.status == 0 else {
            let message = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagerError.commandFailed(message.isEmpty ? "ADB-Befehl fehlgeschlagen (\(r.status)): \(command)" : message)
        }
        return ADBCommandResult(standardOutput: r.stdout, standardError: r.stderr, status: r.status)
    }
}
