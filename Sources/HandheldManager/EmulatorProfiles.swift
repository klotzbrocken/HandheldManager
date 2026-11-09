import Foundation

struct EmulatorProfile: Codable, Identifiable, Hashable {
    struct File: Codable, Hashable, Identifiable {
        let relativePath: String
        let sha256: String
        let contents: Data
        var id: String { relativePath }
    }

    let schemaVersion: Int
    let id: UUID
    let name: String
    let packageName: String
    let appVersion: String?
    let createdAt: Date
    let files: [File]
}

struct ProfileChange: Identifiable {
    let path: String
    let size: Int
    let existing: Bool
    let sha256: String
    var id: String { path }
}

struct ProfileBackupItem: Codable {
    let remotePath: String
    let existed: Bool
    let localBackupPath: String?
    let originalSHA256: String?
}

struct ProfileBackupManifest: Codable, Identifiable {
    let id: UUID
    let deviceSerial: String
    let packageName: String
    let profileName: String
    let createdAt: Date
    let items: [ProfileBackupItem]
}

/// Works with any selected installed package and only touches user-selected,
/// ADB-accessible files under the chosen storage volume.
enum ProfileValidator {
    static func validate(profile: EmulatorProfile, package: InstalledPackage, root: String, volume: StorageVolume) throws -> [String] {
        guard profile.schemaVersion == 1 else { throw ManagerError.profileInvalid("nicht unterstützte Schemasversion \(profile.schemaVersion)") }
        guard profile.packageName == package.packageName else {
            throw ManagerError.profileMismatch("Profil für \(profile.packageName), ausgewählt ist \(package.packageName)")
        }
        if let requiredVersion = profile.appVersion, let installedVersion = package.versionName, requiredVersion != installedVersion {
            throw ManagerError.profileMismatch("Profil wurde für Version \(requiredVersion) erstellt, installiert ist \(installedVersion)")
        }
        guard !profile.files.isEmpty else { throw ManagerError.profileInvalid("das Profil enthält keine Dateien") }
        let normalizedRoot = try RemotePath.normalized(root, within: volume)
        var destinations: [String] = []
        for file in profile.files {
            let relative = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("\n"), !relative.contains("\r") else {
                throw ManagerError.profileInvalid("ungültiger relativer Pfad \(file.relativePath)")
            }
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(".."), !parts.contains("."), !parts.contains("") else {
                throw ManagerError.profileInvalid("Profilpfade dürfen nicht aus dem gewählten Ordner herausführen")
            }
            let target = try RemotePath.normalized("\(normalizedRoot)/\(relative)", within: volume)
            guard !destinations.contains(target) else { throw ManagerError.profileInvalid("doppelter Zielpfad \(target)") }
            let actual = Hash.hex(file.contents)
            guard actual == file.sha256.lowercased() else { throw ManagerError.profileInvalid("Hash stimmt für \(relative) nicht") }
            destinations.append(target)
        }
        return destinations
    }
}

final class EmulatorProfileService {
    private let adb: ADBClient
    private let fileManager = FileManager.default
    private let profilesDirectory: URL
    private let backupsDirectory: URL
    private(set) var lastBackup: ProfileBackupManifest?

    init(adb: ADBClient) throws {
        self.adb = adb
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HandheldManager", isDirectory: true)
        profilesDirectory = base.appendingPathComponent("Profiles", isDirectory: true)
        backupsDirectory = base.appendingPathComponent("ProfileBackups", isDirectory: true)
        try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        lastBackup = loadMostRecentBackup()
    }

    func importProfile(from url: URL) throws -> EmulatorProfile {
        let data = try Data(contentsOf: url)
        guard data.count <= 25 * 1024 * 1024 else { throw ManagerError.profileInvalid("Datei ist größer als 25 MiB") }
        let profile = try JSONDecoder.profileDecoder.decode(EmulatorProfile.self, from: data)
        guard profile.schemaVersion == 1 else { throw ManagerError.profileInvalid("nicht unterstützte Schemasversion") }
        for file in profile.files where Hash.hex(file.contents) != file.sha256.lowercased() {
            throw ManagerError.profileInvalid("Hash stimmt für \(file.relativePath) nicht")
        }
        return profile
    }

    func exportProfile(_ profile: EmulatorProfile, to url: URL) throws {
        let encoder = JSONEncoder.profileEncoder
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    func prepare(profile: EmulatorProfile, package: InstalledPackage, root: String, volume: StorageVolume, serial: String) async throws -> [ProfileChange] {
        let destinations = try ProfileValidator.validate(profile: profile, package: package, root: root, volume: volume)
        var changes: [ProfileChange] = []
        for (index, file) in profile.files.enumerated() {
            let path = destinations[index]
            let exists = try await adb.remoteExists(serial: serial, path: path)
            changes.append(ProfileChange(path: path, size: file.contents.count, existing: exists, sha256: file.sha256))
        }
        return changes
    }

    func apply(profile: EmulatorProfile, package: InstalledPackage, root: String, volume: StorageVolume, serial: String, expectedChanges: [ProfileChange]) async throws -> ProfileBackupManifest {
        let destinations = try ProfileValidator.validate(profile: profile, package: package, root: root, volume: volume)
        guard expectedChanges.count == destinations.count else { throw ManagerError.stalePreview }
        for (index, path) in destinations.enumerated() {
            let expected = expectedChanges[index]
            guard expected.path == path,
                  expected.sha256 == profile.files[index].sha256,
                  expected.size == profile.files[index].contents.count,
                  expected.existing == (try await adb.remoteExists(serial: serial, path: path)) else { throw ManagerError.stalePreview }
        }
        let backupID = UUID()
        let backupCreatedAt = Date()
        let backupFolder = backupsDirectory.appendingPathComponent(backupID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        var items: [ProfileBackupItem] = []
        let manifestURL = backupFolder.appendingPathComponent("manifest.json")

        func currentManifest() -> ProfileBackupManifest {
            ProfileBackupManifest(id: backupID, deviceSerial: serial, packageName: package.packageName, profileName: profile.name, createdAt: backupCreatedAt, items: items)
        }

        do {
            for (index, file) in profile.files.enumerated() {
                let target = destinations[index]
                let existed = try await adb.remoteExists(serial: serial, path: target)
                var backupPath: String?
                var originalHash: String?
                if existed {
                    let backup = backupFolder.appendingPathComponent("\(index)-\((target as NSString).lastPathComponent)")
                    let deviceHash = try await adb.remoteSHA256(serial: serial, path: target)
                    try await adb.pull(serial: serial, remote: target, local: backup)
                    originalHash = Hash.hex(try Data(contentsOf: backup))
                    guard originalHash == deviceHash else { throw ManagerError.commandFailed("Backuphash für \(target) stimmt nicht mit dem Gerät überein; Datei wurde nicht ersetzt.") }
                    backupPath = backup.path
                }
                let item = ProfileBackupItem(remotePath: target, existed: existed, localBackupPath: backupPath, originalSHA256: originalHash)
                items.append(item)
                try JSONEncoder.profileEncoder.encode(currentManifest()).write(to: manifestURL, options: .atomic)

                let parent = (target as NSString).deletingLastPathComponent
                _ = try await adb.shell(serial: serial, "mkdir -p \(RemotePath.shellQuote(parent))")
                let stagingLocal = backupFolder.appendingPathComponent("stage-\(index).bin")
                try file.contents.write(to: stagingLocal, options: .atomic)
                defer { try? fileManager.removeItem(at: stagingLocal) }
                let stagingRemote = parent + "/.handheld-manager-\(UUID().uuidString).tmp"
                do {
                    try await adb.push(serial: serial, local: stagingLocal, remote: stagingRemote)
                    let remoteHash = try await adb.remoteSHA256(serial: serial, path: stagingRemote)
                    guard remoteHash == file.sha256.lowercased() else { throw ManagerError.commandFailed("Hashprüfung für \(target) fehlgeschlagen.") }
                    _ = try await adb.shell(serial: serial, "mv -f \(RemotePath.shellQuote(stagingRemote)) \(RemotePath.shellQuote(target))")
                } catch {
                    _ = try? await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(stagingRemote))")
                    throw error
                }
            }
        } catch {
            do {
                try await rollback(items: items, serial: serial)
                try? fileManager.removeItem(at: backupFolder)
            } catch {
                lastBackup = currentManifest()
                throw ManagerError.commandFailed("Profiländerung fehlgeschlagen (\(error.localizedDescription)); automatischer Rollback war nicht vollständig. Ein lokales Backup ist gespeichert.")
            }
            throw error
        }

        let manifest = currentManifest()
        try? JSONEncoder.profileEncoder.encode(manifest).write(to: manifestURL, options: .atomic)
        lastBackup = manifest
        return manifest
    }

    func rollbackLast(serial: String, volume: StorageVolume) async throws {
        guard let manifest = lastBackup, manifest.deviceSerial == serial else { throw ManagerError.noBackupAvailable }
        for item in manifest.items {
            let target = try RemotePath.normalized(item.remotePath, within: volume)
            if item.existed, let localPath = item.localBackupPath {
                let backup = URL(fileURLWithPath: localPath)
                let stage = target + ".handheld-manager-rollback-\(UUID().uuidString)"
                try await adb.push(serial: serial, local: backup, remote: stage)
                let hash = try await adb.remoteSHA256(serial: serial, path: stage)
                guard hash == item.originalSHA256 else { throw ManagerError.commandFailed("Backuphash stimmt vor Rollback nicht.") }
                _ = try await adb.shell(serial: serial, "mv -f \(RemotePath.shellQuote(stage)) \(RemotePath.shellQuote(target))")
            } else {
                _ = try await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(target))")
            }
        }
        let manifestURL = backupsDirectory.appendingPathComponent(manifest.id.uuidString, isDirectory: true).appendingPathComponent("manifest.json")
        try? fileManager.removeItem(at: manifestURL)
        lastBackup = nil
    }

    private func rollback(items: [ProfileBackupItem], serial: String) async throws {
        for item in items.reversed() {
            if item.existed, let localPath = item.localBackupPath {
                let local = URL(fileURLWithPath: localPath)
                let stage = item.remotePath + ".handheld-manager-recovery-\(UUID().uuidString)"
                try await adb.push(serial: serial, local: local, remote: stage)
                _ = try await adb.shell(serial: serial, "mv -f \(RemotePath.shellQuote(stage)) \(RemotePath.shellQuote(item.remotePath))")
            } else {
                _ = try await adb.shell(serial: serial, "rm -f \(RemotePath.shellQuote(item.remotePath))")
            }
        }
    }

    private func loadMostRecentBackup() -> ProfileBackupManifest? {
        guard let directories = try? fileManager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let manifests = directories.compactMap { $0.appendingPathComponent("manifest.json") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
        guard let manifestURL = manifests.first,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder.profileDecoder.decode(ProfileBackupManifest.self, from: data),
              manifest.items.allSatisfy({ !$0.existed || ($0.localBackupPath.map(fileManager.fileExists(atPath:)) ?? false) }) else { return nil }
        return manifest
    }
}

extension JSONEncoder {
    static var profileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var profileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
