import CryptoKit
import Foundation

enum Hash {
    static func hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file, so multi-GB ROMs never sit in memory.
    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class CappedBuffer {
    private let lock = NSLock()
    private var data = Data()
    private(set) var truncated = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func drain(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            lock.lock()
            let room = max(0, limit - data.count)
            data.append(chunk.prefix(room))
            if chunk.count > room { truncated = true }
            lock.unlock()
        }
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct ProcessResult {
    let stdout: String
    let stderr: String
    let status: Int32
    let timedOut: Bool
    let truncated: Bool
}

/// One subprocess runner for adb, fastboot, aapt and apksigner. Callers map the result to their own errors.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int = 2 * 1024 * 1024) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            try runBlocking(executable, arguments, timeout: timeout, outputLimit: outputLimit)
        }.value
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int) throws -> ProcessResult {
        let process = Process()
        let outPipe = Pipe(), errPipe = Pipe()
        let out = CappedBuffer(limit: outputLimit), err = CappedBuffer(limit: outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let readers = DispatchGroup()
        for (pipe, buffer) in [(outPipe, out), (errPipe, err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { buffer.drain(pipe.fileHandleForReading); readers.leave() }
        }
        do { try process.run() }
        catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw ManagerError.commandFailed("\(executable.lastPathComponent) konnte nicht gestartet werden: \(error.localizedDescription)")
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        _ = readers.wait(timeout: .now() + 3)
        return ProcessResult(stdout: out.text, stderr: err.text, status: process.terminationStatus, timedOut: timedOut, truncated: out.truncated || err.truncated)
    }
}

extension ADBClient {
    func remoteExists(serial: String, path: String) async throws -> Bool {
        let result = try await shell(serial: serial, "if [ -e \(RemotePath.shellQuote(path)) ]; then echo EXISTS; else echo MISSING; fi")
        return result.standardOutput.contains("EXISTS")
    }

    /// Prefers on-device sha256sum; falls back to pulling the file into a temp copy.
    func remoteSHA256(serial: String, path: String) async throws -> String {
        if let result = try? await shell(serial: serial, "sha256sum \(RemotePath.shellQuote(path))"),
           let hash = result.standardOutput.split(whereSeparator: \.isWhitespace).first, hash.count == 64 {
            return String(hash).lowercased()
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await pull(serial: serial, remote: path, local: copy)
        return try Hash.sha256(file: copy)
    }
}

struct TreeStats: Equatable { var files = 0; var bytes: Int64 = 0 }

enum LocalTree {
    static func stats(_ url: URL) -> TreeStats {
        var result = TreeStats()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return result }
        if !isDirectory.boolValue {
            result.files = 1
            result.bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return result
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return result }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { result.files += 1; result.bytes += Int64(values?.fileSize ?? 0) }
        }
        return result
    }
}

extension ADBClient {
    /// File count and total bytes below a remote path (or of the single file).
    func remoteTreeStats(serial: String, path: String) async throws -> TreeStats {
        let out = try await shell(serial: serial, "find \(RemotePath.shellQuote(path)) -type f -exec stat -c %s {} + 2>/dev/null | awk '{s+=$1;n++} END{print n+0, s+0}'", timeout: 300)
        let parts = out.standardOutput.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let files = Int(parts[0]), let bytes = Int64(parts[1]) else { throw ManagerError.commandFailed("Dateistatistik von \(path) nicht lesbar.") }
        return TreeStats(files: files, bytes: bytes)
    }
}
