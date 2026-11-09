import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var connections: [DeviceConnection] = []
    @Published var selectedSerial: String?
    @Published var descriptor: DeviceDescriptor?
    @Published var selectedVolumeID: String?
    @Published var currentPath: String = ""
    @Published var files: [DeviceFileEntry] = []
    @Published var selectedFilePath: String?
    @Published var uploadPreview: FileTransferPreview?
    @Published var selectedPackageName: String?
    @Published var selectedHomePackageName: String?
    @Published var profile: EmulatorProfile?
    @Published var profileName = "Neues Emulatorprofil"
    @Published var profileRoot = ""
    @Published var profileChanges: [ProfileChange] = []
    @Published var apkPlan: APKInstallPlan?
    @Published var directAPKPreview: APKDirectInstallPreview?
    @Published var storageUsageEntries: [StorageUsageEntry] = []
    @Published var storageSizingPaths: Set<String> = []
    @Published var storageUnmeasuredPaths: Set<String> = []
    @Published var storageScanPath: String?
    @Published var storageScanVolumeID: String?
    @Published var discoveredConfigFiles: [EmulatorConfigFile] = []
    @Published var configUploadPreview: ConfigUploadPreview?
    @Published var firmwareFileName: String?
    @Published var firmwareFileSHA256: String?
    @Published var officialFirmwareSHA256 = ""
    @Published var overclockImageURL: URL?
    @Published var overclockImageInspection: OverclockImageInspection?
    @Published var loadedBootImage: LoadedBootImageState?
    @Published var overclockRuntimeStatus: GPUClockStatus?
    @Published var overclockFastbootReady = false
    @Published var overclockFastbootSerial: String?
    private var overclockValidatedSerial: String?
    private var overclockValidatedBuild: String?
    @Published var lastQuarantine: QuarantineRecord?
    var fileBackupAvailable: Bool { fileService?.lastReplacementBackup?.deviceSerial == selectedSerial }
    var profileBackupAvailable: Bool { profileService?.lastBackup?.deviceSerial == selectedSerial }
    @Published var busyLabel: String?
    @Published var statusMessage = "Gerät verbinden und ADB autorisieren."
    @Published var errorMessage: String?
    @Published var appUpdatesBusy = false
    @Published var romFolderPath = ""
    @Published var romVolumeID: String?
    @Published var romGames: [RomGame] = []
    @Published var romProjectMatches: [String: [RomProjectMatch]] = [:]
    @Published var romCatalogMessage: String?
    @Published var romCatalogBusy = false
    @Published var romImport: [ROMImportItem]?
    @Published var signatureMismatchPackages: Set<String> = []
    private var romConsoleFolders: [String: String] = [:]
    private var pendingUpdatePackage: String?

    private var adb: ADBClient?
    private var discovery: DeviceDiscoveryService?
    private var fileService: DeviceFileService?
    private var profileService: EmulatorProfileService?
    private var apkService: APKUpdateService?
    private var storageUsageService: StorageUsageService?
    private var romLibraryService: RomLibraryService?
    private let romCatalogService = RomCatalogService()
    private let appUpdateService = AppUpdateService()
    private var fastboot: FastbootClient?
    private var lastDeviceIdentity: String?
    private var configRemoteMappings: [String: ConfigRemoteMapping] = [:]
    private var storageSizingTask: Task<Void, Never>?

    var isBusy: Bool { busyLabel != nil }
    var apkToolsAvailable: Bool { apkService?.toolsAvailable == true }
    var firmwareGuide: FirmwareGuide? { FirmwareGuideCatalog.guide(for: descriptor) }
    var fastbootAvailable: Bool { fastboot != nil }
    var flip2OverclockBuildMatches: Bool {
        guard let descriptor else { return false }
        let identity = "\(descriptor.manufacturer) \(descriptor.model) \(descriptor.device) \(descriptor.connection.model ?? "")".lowercased().filter { $0.isLetter || $0.isNumber }
        let isFlip2 = identity.contains("retroidpocketflip2") || identity.contains("rpflip2")
        let buildIs130 = descriptor.build.range(of: #"(?i)1\.0\.0\.130(?:\D|$)"#, options: .regularExpression) != nil
        let isSnapdragon865 = descriptor.fingerprint.localizedCaseInsensitiveContains("kona")
        return isFlip2 && buildIs130 && isSnapdragon865
    }
    var canEnterOverclockFastboot: Bool {
        canWorkWithDevice && flip2OverclockBuildMatches && fastbootAvailable && overclockImageInspection?.isAndroidBootImage == true && overclockImageInspection?.fileName == "Banners-flip-2-905OC-forFW130.img"
    }
    var canBootOverclockImage: Bool {
        overclockFastbootReady && overclockFastbootSerial != nil && overclockFastbootSerial == overclockValidatedSerial && overclockValidatedBuild?.range(of: #"(?i)1\.0\.0\.130(?:\D|$)"#, options: .regularExpression) != nil && fastbootAvailable && overclockImageInspection?.isAndroidBootImage == true && overclockImageInspection?.fileName == "Banners-flip-2-905OC-forFW130.img"
    }
    var selectedConnection: DeviceConnection? { connections.first(where: { $0.serial == selectedSerial }) }
    var selectedVolume: StorageVolume? { descriptor?.volumes.first(where: { $0.id == selectedVolumeID }) }
    var selectedPackage: InstalledPackage? { descriptor?.packages.first(where: { $0.packageName == selectedPackageName }) }
    var canWorkWithDevice: Bool { selectedConnection?.state == "device" && adb != nil }
    var hasConfigRemoteMappings: Bool { !configRemoteMappings.isEmpty }

    private static let loadedBootImageDefaultsKey = "HandheldManager.loadedBootImage.v1"
    private static let configRemoteMappingsDefaultsKey = "HandheldManager.configRemoteMappings.v1"

    init() {
        if let saved = UserDefaults.standard.data(forKey: Self.loadedBootImageDefaultsKey) {
            loadedBootImage = try? JSONDecoder().decode(LoadedBootImageState.self, from: saved)
        }
        if let saved = UserDefaults.standard.data(forKey: Self.configRemoteMappingsDefaultsKey),
           let mappings = try? JSONDecoder().decode([ConfigRemoteMapping].self, from: saved) {
            for mapping in mappings { configRemoteMappings[mapping.localPath] = mapping }
        }
        do {
            let client = try ADBClient()
            adb = client
            discovery = DeviceDiscoveryService(adb: client)
            fileService = try DeviceFileService(adb: client)
            profileService = try EmulatorProfileService(adb: client)
            apkService = APKUpdateService(adb: client)
            storageUsageService = StorageUsageService(adb: client)
            romLibraryService = RomLibraryService(adb: client)
            fastboot = FastbootClient()
            let suggestedImage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Banners-flip-2-905OC-forFW130.img")
            if FileManager.default.fileExists(atPath: suggestedImage.path) { overclockImageURL = suggestedImage }
            statusMessage = "ADB: \(client.executablePath)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "ADB ist nicht verfügbar."
        }
    }

    func refresh() async {
        guard let discovery else { return }
        await perform("Geräte werden erkannt…") {
            let found = try await discovery.connections()
            let oldSelection = self.selectedSerial
            self.connections = found
            if let oldSelection, found.contains(where: { $0.serial == oldSelection }) {
                self.selectedSerial = oldSelection
            } else {
                self.selectedSerial = found.first(where: { $0.state == "device" })?.serial ?? found.first?.serial
            }
            if let selected = self.selectedConnection, selected.state == "device" {
                try await self.loadDescriptor(selected)
                try await self.loadFilesThrowing()
            } else {
                self.descriptor = nil
                self.files = []
                self.statusMessage = found.isEmpty ? "Kein ADB-Gerät verbunden." : "Gerät muss am Handheld autorisiert werden (\(self.selectedConnection?.state ?? "unbekannt"))."
            }
        }
    }

    func chooseDevice(_ serial: String?) async {
        selectedSerial = serial
        guard let connection = selectedConnection, connection.state == "device" else {
            descriptor = nil
            files = []
            return
        }
        await perform("Geräteinformationen werden gelesen…") {
            try await self.loadDescriptor(connection)
            try await self.loadFilesThrowing()
        }
    }

    func chooseVolume(_ id: String?) async {
        let changed = selectedVolumeID != id
        selectedVolumeID = id
        if changed {
            storageSizingTask?.cancel()
            storageUsageEntries = []
            storageSizingPaths = []
            storageUnmeasuredPaths = []
            storageScanPath = nil
            storageScanVolumeID = nil
        }
        guard let volume = selectedVolume else { return }
        currentPath = volume.path
        selectedFilePath = nil
        await loadFiles()
    }

    // MARK: ROM import — files go straight into the folder of their console

    private var romVolume: StorageVolume? { descriptor?.volumes.first(where: { $0.id == romVolumeID }) }

    /// Works out which device folder belongs to which console (from scanned games and from folder names),
    /// then opens the import sheet so the user can confirm or fix the console per file.
    func prepareROMImport(_ urls: [URL]) async {
        guard let connection = selectedConnection, connection.state == "device", let volume = romVolume,
              let fileService, !romFolderPath.isEmpty else {
            errorMessage = "Wähle zuerst Speicher und ROM-Ordner auf dem Gerät."
            return
        }
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        guard !files.isEmpty else { statusMessage = "Nur einzelne Dateien können hinzugefügt werden, keine Ordner."; return }
        var folders: [String: String] = [:]
        for (platform, games) in Dictionary(grouping: romGames, by: \.platform) where !platform.hasPrefix("Unbekannt") {
            let parents = games.map { ($0.path as NSString).deletingLastPathComponent }
            if let common = Dictionary(grouping: parents, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key { folders[platform] = common }
        }
        if let entries = try? await fileService.list(serial: connection.serial, path: romFolderPath, volume: volume) {
            for entry in entries where entry.isDirectory {
                if let platform = RomLibraryService.folderPlatform(entry.name), folders[platform] == nil { folders[platform] = entry.path }
            }
        }
        romConsoleFolders = folders
        romImport = files.map { ROMImportItem(url: $0, platform: RomLibraryService.importPlatform(for: $0)) }
    }

    func setImportPlatform(_ id: UUID, _ platform: String) {
        guard let index = romImport?.firstIndex(where: { $0.id == id }) else { return }
        romImport?[index].platform = platform
    }

    func importTarget(for platform: String) -> String {
        romConsoleFolders[platform] ?? (romFolderPath.hasSuffix("/") ? romFolderPath : romFolderPath + "/") + RomLibraryService.defaultFolderName(platform)
    }

    func confirmROMImport() async {
        guard let items = romImport, items.allSatisfy({ !$0.platform.isEmpty }),
              let connection = selectedConnection, let volume = romVolume, let fileService, let adb else { return }
        romImport = nil
        var added = 0
        var notes: [String] = []
        await perform("ROMs werden übertragen…") {
            for item in items {
                let url = item.url
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let folder = self.importTarget(for: item.platform)
                let destination = folder + "/" + url.lastPathComponent
                do {
                    _ = try await adb.shell(serial: connection.serial, "mkdir -p \(RemotePath.shellQuote(try RemotePath.normalized(folder, within: volume)))")
                    let preview = try await fileService.previewUpload(serial: connection.serial, local: url, destination: destination, volume: volume)
                    if preview.destinationExists { notes.append("\(url.lastPathComponent) existiert bereits"); continue }
                    self.busyLabel = "\(url.lastPathComponent) → \(item.platform)…"
                    _ = try await fileService.upload(serial: connection.serial, local: url, destination: destination, volume: volume, replaceExisting: false, expectedPreview: preview)
                    added += 1
                } catch {
                    notes.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.statusMessage = "\(added) ROM(s) hinzugefügt" + (notes.isEmpty ? "." : " · " + notes.joined(separator: "; "))
        }
        if added > 0 { await scanROMs() }
    }

    // MARK: ROM context actions

    private func remoteSize(_ path: String, serial: String) async throws -> Int64 {
        guard let adb else { throw ManagerError.adbNotFound }
        let out = try await adb.shell(serial: serial, "stat -c %s \(RemotePath.shellQuote(path))")
        guard let size = Int64(out.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ManagerError.stalePreview }
        return size
    }

    /// Tracks a CUE/GDI points to; they belong to the game and must go with it.
    private func companionFiles(of game: RomGame, serial: String) async -> [String] {
        guard ["cue", "gdi"].contains(game.fileExtension), let adb,
              let text = try? await adb.shell(serial: serial, "cat \(RemotePath.shellQuote(game.path))", timeout: 20).standardOutput,
              let regex = try? NSRegularExpression(pattern: #"(?i)"?([^\s"/]+\.(?:bin|raw|img|iso|wav|ogg|mp3))"?"#) else { return [] }
        let directory = (game.path as NSString).deletingLastPathComponent
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let path = directory + "/" + text[range]
            if !found.contains(path), (try? await adb.remoteExists(serial: serial, path: path)) == true { found.append(path) }
        }
        return found
    }

    func deleteROM(_ game: RomGame, permanently: Bool) async {
        guard let connection = selectedConnection, connection.state == "device", let fileService,
              let volume = descriptor?.volumes.first(where: { game.path.hasPrefix($0.path + "/") }) else { return }
        await perform(permanently ? "ROM wird gelöscht…" : "ROM wird in den Papierkorb verschoben…") {
            var paths = game.groupedPaths.isEmpty ? [game.path] : game.groupedPaths
            for extra in await self.companionFiles(of: game, serial: connection.serial) where !paths.contains(extra) { paths.append(extra) }
            for path in paths {
                if permanently {
                    let size = try await self.remoteSize(path, serial: connection.serial)
                    try await fileService.deletePermanently(serial: connection.serial, path: path, expectedSize: size, volume: volume)
                } else {
                    self.lastQuarantine = try await fileService.quarantine(serial: connection.serial, path: path, volume: volume)
                }
            }
            self.romGames.removeAll { $0.id == game.id }
            self.statusMessage = permanently
                ? "\(game.title) gelöscht (\(paths.count) Datei(en))."
                : "\(game.title) in den Papierkorb verschoben (\(paths.count) Datei(en)). Letzte Datei lässt sich im Dateien-Tab zurückholen."
        }
    }

    func renameROM(_ game: RomGame, to baseName: String) async {
        guard let connection = selectedConnection, connection.state == "device", let fileService,
              let volume = descriptor?.volumes.first(where: { game.path.hasPrefix($0.path + "/") }) else { return }
        let ext = (game.fileName as NSString).pathExtension
        let newName = ext.isEmpty ? baseName : baseName.trimmingCharacters(in: .whitespaces) + "." + ext
        await perform("ROM wird umbenannt…") {
            let size = try await self.remoteSize(game.path, serial: connection.serial)
            let entry = DeviceFileEntry(name: game.fileName, path: game.path, isDirectory: false, size: size, modified: "")
            let newPath = try await fileService.rename(serial: connection.serial, entry: entry, to: newName, volume: volume)
            if let index = self.romGames.firstIndex(where: { $0.id == game.id }) {
                self.romGames[index] = RomGame(path: newPath, sizeBytes: game.sizeBytes, platform: game.platform, fileExtension: game.fileExtension)
            }
            RomCoverStore.move(from: game.path, to: newPath)
            self.statusMessage = "Umbenannt in \((newPath as NSString).lastPathComponent)."
        }
    }

    func scanROMs() async {
        guard let connection = selectedConnection, let volume = descriptor?.volumes.first(where: { $0.id == romVolumeID }), let romLibraryService else { return }
        await perform("ROMs werden gesucht…") {
            let result = try await romLibraryService.scan(serial: connection.serial, folder: self.romFolderPath, volume: volume)
            self.romGames = result.games
            self.romProjectMatches = [:]
            self.romCatalogMessage = result.reachedLimit ? "Maximale Trefferzahl erreicht; Pfad bei Bedarf enger wählen." : nil
            UserDefaults.standard.set(self.romFolderPath, forKey: "HandheldManager.romPath.\(connection.serial)")
            UserDefaults.standard.set(volume.id, forKey: "HandheldManager.romVolume.\(connection.serial)")
        }
        if errorMessage == nil, !romGames.isEmpty { await refreshROMProjects() }
    }

    func refreshROMProjects(forceRefresh: Bool = false) async {
        guard !romGames.isEmpty else { return }
        romCatalogBusy = true
        defer { romCatalogBusy = false }
        do {
            romProjectMatches = try await romCatalogService.lookup(games: romGames, forceRefresh: forceRefresh)
            romCatalogMessage = nil
        } catch {
            romCatalogMessage = "Kataloge konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }

    func checkAppUpdates() async {
        guard let packages = descriptor?.packages else { return }
        let candidates = packages.filter { $0.isSystemApp != true }
        await checkUpdates(candidates)
    }

    func checkEmulatorUpdates() async {
        guard let packages = descriptor?.packages else { return }
        await checkUpdates(packages.filter { $0.isEmulator == true })
    }

    private func checkUpdates(_ candidates: [InstalledPackage]) async {
        guard !candidates.isEmpty, !appUpdatesBusy else { return }
        appUpdatesBusy = true
        defer { appUpdatesBusy = false }
        let updates = await appUpdateService.check(candidates)
        let checkedPackages = Set(candidates.map(\.packageName))
        descriptor?.packages = (descriptor?.packages ?? []).map { package in
            guard checkedPackages.contains(package.packageName) else { return package }
            var changed = package
            changed.updateChecked = true
            if let update = updates[package.packageName] {
                changed.updateVersionName = update.version
                changed.updateAvailable = update.available
                changed.updateSourceName = update.sourceName
                changed.updateSourceURL = update.sourceURL
                changed.updateDownloadURL = update.downloadURL
                changed.updateAssetName = update.downloadName
            } else {
                changed.updateVersionName = nil
                changed.updateAvailable = nil
                changed.updateSourceName = nil
                changed.updateSourceURL = nil
                changed.updateDownloadURL = nil
                changed.updateAssetName = nil
            }
            return changed
        }
    }

    func loadFiles() async {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService else { return }
        await perform("Dateiliste wird gelesen…") {
            self.currentPath = try RemotePath.normalized(self.currentPath, within: volume)
            self.files = try await fileService.list(serial: connection.serial, path: self.currentPath, volume: volume)
            self.selectedFilePath = nil
        }
    }

    func open(_ entry: DeviceFileEntry) async {
        guard entry.isDirectory else { selectedFilePath = entry.path; return }
        currentPath = entry.path
        await loadFiles()
    }

    func renameFile(_ entry: DeviceFileEntry, to name: String) async {
        guard let connection = selectedConnection, connection.state == "device",
              let volume = descriptor?.volumes.first(where: { entry.path == $0.path || entry.path.hasPrefix($0.path + "/") }),
              let fileService else { return }
        await perform("Eintrag wird umbenannt…") {
            let newPath = try await fileService.rename(serial: connection.serial, entry: entry, to: name, volume: volume)
            self.files = try await fileService.list(serial: connection.serial, path: self.currentPath, volume: volume)
            self.selectedFilePath = newPath
            self.statusMessage = String.localizedStringWithFormat(
                NSLocalizedString("Eintrag umbenannt: %@", comment: "Rename status"),
                (newPath as NSString).lastPathComponent
            )
        }
    }

    func goToParent() async {
        guard let volume = selectedVolume else { return }
        if currentPath != volume.path {
            let parent = (currentPath as NSString).deletingLastPathComponent
            currentPath = parent.count < volume.path.count ? volume.path : parent
            await loadFiles()
        }
    }

    func upload(_ localURL: URL, replaceExisting: Bool = false) async {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService, let preview = uploadPreview else { return }
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        let destination = currentPath + "/" + localURL.lastPathComponent
        await perform("Datei wird übertragen und verifiziert…") {
            let result = try await fileService.upload(serial: connection.serial, local: localURL, destination: destination, volume: volume, replaceExisting: replaceExisting, expectedPreview: preview)
            self.statusMessage = result.summary + " SHA-256: " + (result.sha256 ?? "unbekannt") + (result.recoverableAt == nil ? "" : " · vorherige Datei gesichert")
            self.uploadPreview = nil
            try await self.reloadFilesAndDescriptor()
        }
    }

    func prepareUpload(_ localURL: URL) async {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService else { return }
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        await perform("Uploadvorschau wird erstellt…") {
            let destination = self.currentPath + "/" + localURL.lastPathComponent
            self.uploadPreview = try await fileService.previewUpload(serial: connection.serial, local: localURL, destination: destination, volume: volume)
        }
    }

    func downloadSelected(to destination: URL, replaceExisting: Bool = false) async {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService, let selectedFilePath else { return }
        await perform("Datei wird heruntergeladen und verifiziert…") {
            let result = try await fileService.download(serial: connection.serial, source: selectedFilePath, volume: volume, localDestination: destination, replaceExisting: replaceExisting)
            self.statusMessage = result.summary + " SHA-256: " + (result.sha256 ?? "unbekannt")
        }
    }

    func scanStorageUsage() async {
        guard let connection = selectedConnection, connection.state == "device",
              let volume = selectedVolume, storageUsageService != nil else { return }
        storageScanPath = volume.path
        await scanStorageFolder(volume.path, volumeID: volume.id)
    }

    func scanStorageFolder(_ path: String, volumeID: String? = nil) async {
        guard let connection = selectedConnection, connection.state == "device",
              let volume = descriptor?.volumes.first(where: { $0.id == (volumeID ?? storageScanVolumeID ?? selectedVolumeID) }),
              let storageUsageService else { return }
        await perform("Speicherordner wird analysiert…") {
            self.storageSizingTask?.cancel()
            let entries = try await storageUsageService.scan(serial: connection.serial, volume: volume, root: path)
            self.storageScanPath = path
            self.storageScanVolumeID = volume.id
            self.storageUsageEntries = entries
            self.storageSizingPaths = Set(entries.filter(\.isDirectory).map(\.path))
            self.storageUnmeasuredPaths = self.storageSizingPaths
            self.statusMessage = "\(self.storageUsageEntries.count) Datei- und Ordnerwerte gefunden. Die Analyse zeigt nur über ADB erreichbaren gemeinsamen Speicher."
            let serial = connection.serial
            let entrySnapshot = entries
            self.storageSizingTask = Task { [weak self] in
                do {
                    let sizes = try await storageUsageService.calculateDirectorySizes(serial: serial, entries: entrySnapshot)
                    guard let self, !Task.isCancelled,
                          self.selectedSerial == serial,
                          self.storageScanPath == path,
                          self.storageScanVolumeID == volume.id else { return }
                    self.storageUsageEntries = self.storageUsageEntries.map { entry in
                        guard entry.isDirectory, let size = sizes[entry.path] else { return entry }
                        return StorageUsageEntry(path: entry.path, sizeBytes: size, volumeID: entry.volumeID, isDirectory: true)
                    }
                    self.storageSizingPaths = []
                    self.storageUnmeasuredPaths = Set(self.storageUsageEntries.filter { $0.isDirectory && sizes[$0.path] == nil }.map(\.path))
                } catch {
                    guard let self, !Task.isCancelled,
                          self.selectedSerial == serial,
                          self.storageScanPath == path,
                          self.storageScanVolumeID == volume.id else { return }
                    self.storageSizingPaths = []
                    self.storageUnmeasuredPaths = Set(self.storageUsageEntries.filter(\.isDirectory).map(\.path))
                    self.errorMessage = "Ordnergrößen konnten nicht berechnet werden: \(error.localizedDescription)"
                }
            }
        }
    }

    func goToStorageParent() async {
        guard let path = storageScanPath,
              let volume = descriptor?.volumes.first(where: { $0.id == (storageScanVolumeID ?? selectedVolumeID) }),
              path != volume.path else { return }
        let parent = (path as NSString).deletingLastPathComponent
        let boundedParent = parent == volume.path || parent.hasPrefix(volume.path + "/") ? parent : volume.path
        await scanStorageFolder(boundedParent, volumeID: volume.id)
    }

    func quarantineStorageFile(_ entry: StorageUsageEntry) async {
        guard let connection = selectedConnection, connection.state == "device",
              let volume = descriptor?.volumes.first(where: { $0.id == entry.volumeID }),
              let fileService else { return }
        await perform("Datei wird in Quarantäne verschoben…") {
            self.lastQuarantine = try await fileService.quarantine(serial: connection.serial, path: entry.path, volume: volume)
            self.storageUsageEntries.removeAll { $0.path == entry.path }
            self.statusMessage = "Datei in Quarantäne verschoben; die letzte Verschiebung kann rückgängig gemacht werden."
        }
    }

    func deleteStorageFilePermanently(_ entry: StorageUsageEntry) async {
        guard let connection = selectedConnection, connection.state == "device",
              let volume = descriptor?.volumes.first(where: { $0.id == entry.volumeID }),
              let fileService else { return }
        await perform(entry.isDirectory ? "Ordner samt Inhalt wird endgültig gelöscht…" : "Datei wird endgültig gelöscht…") {
            try await fileService.deletePermanently(serial: connection.serial, entry: entry, volume: volume)
            self.storageUsageEntries.removeAll { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
            self.storageSizingPaths.remove(entry.path)
            self.storageUnmeasuredPaths.remove(entry.path)
            self.statusMessage = entry.isDirectory ? "Ordner samt Inhalt endgültig gelöscht." : "Datei endgültig gelöscht. Sie ist nicht wiederherstellbar."
            try await self.loadDescriptor(connection)
        }
    }

    func discoverEmulatorConfigFiles() async {
        guard let connection = selectedConnection, connection.state == "device",
              let package = selectedPackage, let fileService else { return }
        let volumes = descriptor?.volumes.filter(\.readable) ?? []
        guard !volumes.isEmpty else { return }
        await perform("Emulatorkonfigurationen werden auf dem Gerät gesucht…") {
            self.discoveredConfigFiles = []
            var found: [EmulatorConfigFile] = []
            for volume in volumes {
                found += try await fileService.discoverConfigurationFiles(serial: connection.serial, package: package, volume: volume)
            }
            found.sort {
                $0.priority == $1.priority
                    ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    : $0.priority < $1.priority
            }
            self.discoveredConfigFiles = found
            self.statusMessage = self.discoveredConfigFiles.isEmpty
                ? "Keine passenden Config-Dateien auf den erreichbaren Volumes gefunden (Android/data, Android/media und bekannte gemeinsame Emulatorordner)."
                : "\(self.discoveredConfigFiles.count) Config-Datei(en) für \(package.displayTitle) auf \(volumes.count) Speicherort(en) gefunden."
        }
    }

    func exportCurrentConfigFiles(_ paths: [String], to directory: URL) async -> [URL] {
        guard let connection = selectedConnection, connection.state == "device",
              let fileService else { return [] }
        let matchingVolumes = descriptor?.volumes.filter { volume in
            paths.contains(where: { $0 == volume.path || $0.hasPrefix(volume.path + "/") })
        } ?? []
        guard matchingVolumes.count == 1, let volume = matchingVolumes.first else {
            errorMessage = "Wähle Config-Dateien von genau einem Speicherort aus. Die Auswahl auf mehrere Speicherorte aufteilen."
            return []
        }
        selectedVolumeID = volume.id
        var exportedFiles: [URL] = []
        await perform("Konfigurationsdateien werden lokal gesichert…") {
            exportedFiles = try await fileService.exportConfigurationFiles(serial: connection.serial, paths: paths, volume: volume, directory: directory)
            for (remotePath, localURL) in zip(paths.sorted(), exportedFiles) {
                let mapping = ConfigRemoteMapping(localPath: localURL.standardizedFileURL.path, remotePath: remotePath, volumeID: volume.id)
                self.configRemoteMappings[mapping.localPath] = mapping
            }
            self.persistConfigRemoteMappings()
            if let commonDirectory = Self.commonParent(of: paths),
               (try? RemotePath.normalized(commonDirectory, within: volume)) != nil {
                self.profileRoot = commonDirectory
            }
            self.statusMessage = "\(exportedFiles.count) Konfigurationsdatei(en) lokal gespeichert und per SHA-256 geprüft."
        }
        return exportedFiles
    }

    /// Finds the device file an edited local config belongs to. Exact path first; then symlink-resolved path
    /// (the file picker may return /private/var vs /var), then the saved copy with the same name and the most
    /// matching folder tail, finally a unique device config with the same name from the last search.
    private func configMapping(for localURL: URL) -> ConfigRemoteMapping? {
        let standardized = localURL.standardizedFileURL.path
        if let exact = configRemoteMappings[standardized] { return exact }
        let resolved = localURL.resolvingSymlinksInPath().path
        if let match = configRemoteMappings.values.first(where: { URL(fileURLWithPath: $0.localPath).resolvingSymlinksInPath().path == resolved }) { return match }
        let name = localURL.lastPathComponent
        let sameName = configRemoteMappings.values.filter { ($0.localPath as NSString).lastPathComponent == name }
        func tail(_ a: String, _ b: String) -> Int {
            zip(a.split(separator: "/").reversed(), b.split(separator: "/").reversed()).prefix { $0 == $1 }.count
        }
        if let best = sameName.map({ (mapping: $0, score: tail($0.localPath, resolved)) }).sorted(by: { $0.score > $1.score }).first,
           sameName.filter({ tail($0.localPath, resolved) == best.score }).count == 1 { return best.mapping }
        let onDevice = discoveredConfigFiles.filter { $0.name == name }
        if onDevice.count == 1, let file = onDevice.first {
            return ConfigRemoteMapping(localPath: standardized, remotePath: file.path, volumeID: file.volumeID)
        }
        return nil
    }

    func prepareEditedEmulatorConfig(_ localURL: URL) async {
        guard let connection = selectedConnection, connection.state == "device", let fileService else { return }
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        discardEditedEmulatorConfigPreview()
        guard let mapping = configMapping(for: localURL),
              let volume = descriptor?.volumes.first(where: { $0.id == mapping.volumeID }) else {
            errorMessage = "Zu „\(localURL.lastPathComponent)“ gibt es keinen eindeutigen Gerätepfad. Sichere die Config zuerst mit „Auf dem Mac sichern“, oder wähle den Emulator und suche die Configs erneut, damit die Datei zugeordnet werden kann."
            return
        }
        let stagingFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HandheldManager/ConfigUploadStaging/\(UUID().uuidString)", isDirectory: true)
        let stagedURL = stagingFolder.appendingPathComponent(localURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: localURL, to: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingFolder)
            errorMessage = "Geänderte Config kann nicht lokal vorbereitet werden: \(error.localizedDescription)"
            return
        }
        await perform("Geänderte Config wird geprüft…") {
            let preview = try await fileService.previewUpload(serial: connection.serial, local: stagedURL, destination: mapping.remotePath, volume: volume)
            guard preview.destinationExists else { throw ManagerError.commandFailed("Die ursprüngliche Config ist am Gerät nicht mehr vorhanden; sie wird nicht automatisch neu angelegt.") }
            self.configUploadPreview = ConfigUploadPreview(mapping: mapping, preview: preview)
        }
        if configUploadPreview?.preview.source != stagedURL.path {
            try? FileManager.default.removeItem(at: stagingFolder)
        }
    }

    func uploadEditedEmulatorConfig() async {
        guard let connection = selectedConnection, connection.state == "device",
              let fileService, let configUploadPreview,
              let volume = descriptor?.volumes.first(where: { $0.id == configUploadPreview.mapping.volumeID }) else { return }
        let localURL = URL(fileURLWithPath: configUploadPreview.preview.source)
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        await perform("Geänderte Config wird mit Backup übertragen…") {
            let result = try await fileService.upload(
                serial: connection.serial,
                local: localURL,
                destination: configUploadPreview.mapping.remotePath,
                volume: volume,
                replaceExisting: true,
                expectedPreview: configUploadPreview.preview
            )
            self.configUploadPreview = nil
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
            self.statusMessage = result.summary + " · Originaldatei wurde lokal gesichert. SHA-256: " + (result.sha256 ?? "unbekannt")
        }
    }

    func discardEditedEmulatorConfigPreview() {
        if let path = configUploadPreview?.preview.source {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        configUploadPreview = nil
    }

    private func persistConfigRemoteMappings() {
        let values = Array(configRemoteMappings.values)
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: Self.configRemoteMappingsDefaultsKey)
    }

    func quarantineSelected() async {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService, let selectedFilePath else { return }
        await perform("Datei wird in Quarantäne verschoben…") {
            self.lastQuarantine = try await fileService.quarantine(serial: connection.serial, path: selectedFilePath, volume: volume)
            self.statusMessage = "Eintrag in .HandheldManagerTrash verschoben. Du kannst ihn wiederherstellen."
            try await self.loadFilesAndDescriptor()
        }
    }

    func deleteSelectedPermanently(_ entry: DeviceFileEntry) async {
        await deleteSelectedPermanently([entry])
    }

    func deleteSelectedPermanently(_ entries: [DeviceFileEntry]) async {
        guard !entries.isEmpty,
              let connection = selectedConnection, connection.state == "device",
              let volume = selectedVolume,
              let fileService else { return }
        await perform("Einträge werden endgültig gelöscht…") {
            do {
                for entry in entries {
                    try await fileService.deletePermanently(serial: connection.serial, entry: entry, volume: volume)
                }
            } catch {
                self.files = (try? await fileService.list(serial: connection.serial, path: self.currentPath, volume: volume)) ?? self.files
                self.selectedFilePath = nil
                throw error
            }
            self.files = try await fileService.list(serial: connection.serial, path: self.currentPath, volume: volume)
            self.selectedFilePath = nil
            self.statusMessage = NSLocalizedString(
                entries.count == 1 ? "Eintrag endgültig gelöscht." : "Ausgewählte Einträge endgültig gelöscht.",
                comment: "Delete status"
            )
        }
    }

    func undoQuarantine() async {
        guard let record = lastQuarantine, record.deviceSerial == selectedSerial,
              let volume = descriptor?.volumes.first(where: { record.originalPath == $0.path || record.originalPath.hasPrefix($0.path + "/") }), let fileService else { return }
        await perform("Quarantäne wird wiederhergestellt…") {
            try await fileService.restore(record, volume: volume)
            self.lastQuarantine = nil
            self.statusMessage = "Datei wurde am ursprünglichen Ort wiederhergestellt."
            try await self.loadFilesAndDescriptor()
        }
    }

    func rollbackFileReplacement() async {
        guard let connection = selectedConnection,
              let fileService,
              let record = fileService.lastReplacementBackup,
              let volume = descriptor?.volumes.first(where: { record.remotePath == $0.path || record.remotePath.hasPrefix($0.path + "/") }) else { return }
        await perform("Vorherige Dateiversion wird wiederhergestellt…") {
            try await fileService.restoreLastReplacement(serial: connection.serial, volume: volume)
            self.statusMessage = "Vorherige Version wurde mit Hashprüfung wiederhergestellt."
            try await self.loadFilesAndDescriptor()
        }
    }

    func selectProfileFile(_ url: URL) {
        guard let profileService else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            profile = try profileService.importProfile(from: url)
            profileName = profile?.name ?? ""
            selectedPackageName = profile?.packageName
            profileChanges = []
            statusMessage = "Profil \(profile?.name ?? "") geladen. Wähle Zielgerät, App und Ordner für die Vorschau."
        } catch { errorMessage = error.localizedDescription }
    }

    func createProfile(name: String, packageName: String, files localFiles: [URL]) throws -> EmulatorProfile {
        guard !localFiles.isEmpty else { throw ManagerError.profileInvalid("wähle mindestens eine Konfigurationsdatei aus") }
        guard localFiles.count <= 100 else { throw ManagerError.profileInvalid("maximal 100 Dateien pro Profil") }
        var payloadFiles: [EmulatorProfile.File] = []
        var total = 0
        let standardizedPaths = localFiles.map { $0.standardizedFileURL.path }
        guard var localBase = standardizedPaths.first.map({ ($0 as NSString).deletingLastPathComponent }) else {
            throw ManagerError.profileInvalid("keine lokale Config-Datei ausgewählt")
        }
        while standardizedPaths.contains(where: { $0 != localBase && !$0.hasPrefix(localBase.hasSuffix("/") ? localBase : localBase + "/") }) {
            let parent = (localBase as NSString).deletingLastPathComponent
            if parent == localBase || parent.isEmpty { localBase = "/"; break }
            localBase = parent
        }
        for url in localFiles {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ManagerError.profileInvalid("\(url.lastPathComponent) ist keine reguläre Datei") }
            total += values.fileSize ?? 0
            guard total <= 25 * 1024 * 1024 else { throw ManagerError.profileInvalid("Profil darf höchstens 25 MiB umfassen") }
            let data = try Data(contentsOf: url)
            let localPath = url.standardizedFileURL.path
            let relativePath = localPath == localBase ? url.lastPathComponent : String(localPath.dropFirst(localBase.hasSuffix("/") ? localBase.count : localBase.count + 1))
            payloadFiles.append(.init(relativePath: relativePath, sha256: Hash.hex(data), contents: data))
        }
        let profile = EmulatorProfile(schemaVersion: 1, id: UUID(), name: name, packageName: packageName, appVersion: selectedPackage?.versionName, createdAt: Date(), files: payloadFiles)
        self.profile = profile
        if let volume = selectedVolume,
           profileRoot.isEmpty || (try? RemotePath.normalized(profileRoot, within: volume)) == nil {
            self.profileRoot = volume.path
        }
        return profile
    }

    func previewProfile() async {
        guard let connection = selectedConnection, let volume = selectedVolume, let package = selectedPackage, let profile, let profileService else { return }
        await perform("Profiländerungen werden vorbereitet…") {
            self.profileChanges = try await profileService.prepare(profile: profile, package: package, root: self.profileRoot, volume: volume, serial: connection.serial)
            self.statusMessage = "Vorschau bereit: \(self.profileChanges.count) Datei(en), \(self.profileChanges.filter(\.existing).count) werden ersetzt."
        }
    }

    func applyProfile() async {
        guard let connection = selectedConnection, let volume = selectedVolume, let package = selectedPackage, let profile, let profileService else { return }
        await perform("Profil wird gesichert und angewendet…") {
            let manifest = try await profileService.apply(profile: profile, package: package, root: self.profileRoot, volume: volume, serial: connection.serial, expectedChanges: self.profileChanges)
            self.statusMessage = "Profil angewendet. Backup \(manifest.id.uuidString.prefix(8)) ist lokal für den Rollback gespeichert."
        }
    }

    func rollbackProfile() async {
        guard let connection = selectedConnection, let volume = selectedVolume, let profileService else { return }
        await perform("Vorherige Profilkonfiguration wird wiederhergestellt…") {
            try await profileService.rollbackLast(serial: connection.serial, volume: volume)
            self.statusMessage = "Profil-Rollback abgeschlossen."
        }
    }

    func exportCurrentProfile(to url: URL) throws {
        guard let profile, let profileService else { throw ManagerError.profileInvalid("kein Profil geladen") }
        try profileService.exportProfile(profile, to: url)
        statusMessage = "Profil als versionierte JSON-Datei exportiert."
    }

    func choosePackage(_ packageName: String?) async {
        selectedPackageName = packageName
        guard let packageName, let connection = selectedConnection, let discovery, var descriptor,
              let index = descriptor.packages.firstIndex(where: { $0.packageName == packageName }) else { return }
        do {
            if var details = try await discovery.packageDetails(serial: connection.serial, packageName: packageName) {
                details.displayName = descriptor.packages[index].displayName
                details.isEmulator = descriptor.packages[index].isEmulator
                descriptor.packages[index] = details
                self.descriptor = descriptor
            }
        } catch {
            statusMessage = "Paketversion konnte nicht gelesen werden; Profilprüfung bindet das Paket weiterhin über seine Paket-ID."
        }
    }

    func openHomeSettings() async {
        guard let connection = selectedConnection, connection.state == "device", let discovery else { return }
        await perform("Android-Launcherauswahl wird geöffnet…") {
            try await discovery.openHomeSettings(serial: connection.serial)
            self.statusMessage = "Launcher-Auswahl ist am Handheld geöffnet. Wähle dort den Home-Launcher und aktualisiere danach den Status."
        }
    }

    func setHomeLauncher(_ packageName: String) async {
        guard let connection = selectedConnection, connection.state == "device", let discovery,
              descriptor?.canSetHomeActivity == true,
              descriptor?.homeActivities.contains(where: { $0.packageName == packageName }) == true else {
            errorMessage = "Remote-Auswahl ist auf diesem Build nicht verfügbar oder das Paket ist keine erkannte Home-App."
            return
        }
        await perform("Standard-Launcher wird geändert…") {
            let current = try await discovery.setHomeActivity(serial: connection.serial, packageName: packageName)
            if var descriptor = self.descriptor {
                descriptor.currentHomeActivity = current
                self.descriptor = descriptor
            }
            self.statusMessage = "\(current.packageName) ist jetzt als Home-Launcher gesetzt."
        }
    }

    func refreshLauncherInfo() async {
        guard let connection = selectedConnection, connection.state == "device", let discovery, var descriptor else { return }
        await perform("Home-Launcher werden gelesen…") {
            descriptor.homeActivities = try await discovery.homeActivities(serial: connection.serial)
            descriptor.currentHomeActivity = try await discovery.currentHomeActivity(serial: connection.serial)
            descriptor.canSetHomeActivity = try await discovery.canSetHomeActivity(serial: connection.serial)
            if self.selectedHomePackageName == nil || !descriptor.homeActivities.contains(where: { $0.packageName == self.selectedHomePackageName }) {
                self.selectedHomePackageName = descriptor.currentHomeActivity?.packageName ?? descriptor.homeActivities.first?.packageName
            }
            descriptor.reports = self.updatedLauncherReport(descriptor)
            self.descriptor = descriptor
            self.statusMessage = "Home-Launcherstatus aktualisiert."
        }
    }

    func removeInstalledApp(_ package: InstalledPackage) async {
        guard let connection = selectedConnection, connection.state == "device", let adb else { return }
        guard package.packageName.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else { return }
        await perform(package.isSystemApp == true ? "App wird für diesen Benutzer entfernt…" : "App wird deinstalliert…") {
            let command = package.isSystemApp == true
                ? "pm uninstall --user 0 \(RemotePath.shellQuote(package.packageName))"
                : "pm uninstall \(RemotePath.shellQuote(package.packageName))"
            let result = try await adb.shell(serial: connection.serial, command, timeout: 60)
            let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.localizedCaseInsensitiveContains("success") else {
                throw ManagerError.commandFailed(output.isEmpty ? "Android hat die Deinstallation nicht bestätigt." : output)
            }
            try await self.loadDescriptor(connection)
            self.statusMessage = package.isSystemApp == true
                ? "\(package.displayTitle) wurde für Benutzer 0 entfernt. Das Systemabbild bleibt unverändert."
                : "\(package.displayTitle) wurde deinstalliert."
        }
    }

    func openSystemSettings(_ actionID: String) async {
        guard let connection = selectedConnection, connection.state == "device", let discovery else { return }
        await perform("Systemeinstellung wird geprüft und geöffnet…") {
            let openedSpecific = try await discovery.openSettingsAction(serial: connection.serial, actionID: actionID)
            self.statusMessage = openedSpecific ? "Android-Einstellungsseite geöffnet." : "Diese Seite ist auf dem Build nicht verfügbar; Android-Einstellungen wurden geöffnet."
        }
    }

    func selectFirmwareFile(_ url: URL) async {
        await perform("Firmwarepaket wird gehasht…") {
            self.firmwareFileSHA256 = nil
            self.firmwareFileName = url.lastPathComponent
            self.firmwareFileSHA256 = try await FirmwareChecksumService.sha256(of: url)
            self.statusMessage = "Lokaler Firmware-Hash berechnet. Ohne Hersteller-Prüfsumme ist er kein Echtheitsnachweis."
        }
    }

    func inspectOverclockImage(_ url: URL) async {
        await perform("Overclock-Boot-Image wird geprüft…") {
            let inspection = try await OverclockImageInspector.inspect(url)
            self.overclockImageURL = url
            self.overclockImageInspection = inspection
            self.overclockFastbootReady = false
            self.overclockFastbootSerial = nil
            self.overclockValidatedSerial = nil
            self.overclockValidatedBuild = nil
            self.statusMessage = inspection.isAndroidBootImage
                ? "Android-Boot-Image erkannt. Der lokale Hash bestätigt keine Herkunft oder Unbedenklichkeit."
                : "Datei ist kein plausibles Android-Boot-Image."
        }
    }

    func enterOverclockFastboot() async {
        guard canEnterOverclockFastboot, let connection = selectedConnection, let adb, let fastboot else {
            errorMessage = "Overclock-Assistent gesperrt: erforderlich sind Flip 2 Snapdragon, Build 1.0.0.130, passendes Boot-Image und Platform-Tools."
            return
        }
        await perform("Handheld wird in den Bootloader gestartet…") {
            _ = try await adb.device(serial: connection.serial, arguments: ["reboot", "bootloader"])
            try await fastboot.waitForDevice(serial: connection.serial)
            self.overclockFastbootSerial = connection.serial
            self.overclockValidatedSerial = connection.serial
            self.overclockValidatedBuild = self.descriptor?.build
            self.overclockFastbootReady = true
            self.statusMessage = "Fastboot-Gerät stimmt mit der ausgewählten ADB-Seriennummer überein. Noch wurde kein Image gestartet."
        }
    }

    func bootOverclockImageForThisSession() async {
        guard canBootOverclockImage,
              let serial = overclockFastbootSerial,
              let image = overclockImageURL, let fastboot else {
            errorMessage = "Fastboot-Gerät oder Overclock-Prüfplan ist nicht mehr gültig. Prüfe Gerät und Image erneut."
            return
        }
        await perform("Temporäres Boot-Image wird übertragen…") {
            let current = try await OverclockImageInspector.inspect(image)
            guard current.isAndroidBootImage,
                  current.sha256 == self.overclockImageInspection?.sha256 else {
                throw ManagerError.invalidAPK("Boot-Image hat sich seit der Prüfung geändert.")
            }
            try await fastboot.waitForDevice(serial: serial)
            let result = try await fastboot.boot(serial: serial, image: image)
            self.overclockFastbootReady = false
            self.overclockFastbootSerial = nil
            self.overclockValidatedSerial = nil
            self.overclockValidatedBuild = nil
            let output = result.trimmingCharacters(in: .whitespacesAndNewlines)
            self.loadedBootImage = LoadedBootImageState(
                deviceSerial: serial,
                build: self.descriptor?.build ?? "",
                fileName: image.lastPathComponent,
                sha256: current.sha256,
                startedAt: Date(),
                androidBootID: nil
            )
            self.persistLoadedBootImage()
            self.statusMessage = output.isEmpty
                ? "Fastboot hat \(image.lastPathComponent) zum einmaligen Booten angenommen. Warte, bis Android wieder startet."
                : "Fastboot-Ergebnis: \(output)"
        }
    }

    func rebootFastbootDeviceToAndroid() async {
        guard overclockFastbootReady, let serial = overclockFastbootSerial, let fastboot else { return }
        await perform("Gerät wird normal neu gestartet…") {
            try await fastboot.reboot(serial: serial)
            self.loadedBootImage = nil
            self.persistLoadedBootImage()
            self.overclockFastbootReady = false
            self.overclockFastbootSerial = nil
            self.overclockValidatedSerial = nil
            self.overclockValidatedBuild = nil
            self.statusMessage = "Neustart angefordert. Android sollte mit dem unveränderten persistenten Boot-Image starten."
        }
    }

    func openFirmwareGuide() {
        guard let url = firmwareGuide?.officialURL else { return }
        NSWorkspace.shared.open(url)
    }

    var firmwareChecksumResult: String? {
        guard let local = firmwareFileSHA256 else { return nil }
        guard let expected = FirmwareChecksumService.normalized(officialFirmwareSHA256) else {
            return "Lokaler SHA-256: \(local) · kein gültiger Hersteller-Hash eingetragen; Integritätswert, kein Echtheitsnachweis."
        }
        return local == expected
            ? "SHA-256 stimmt mit dem eingetragenen Herstellerwert überein: \(local)"
            : "SHA-256 stimmt NICHT überein. Dieses Paket nicht verwenden. Lokal: \(local) · Hersteller: \(expected)"
    }

    private func updatedLauncherReport(_ descriptor: DeviceDescriptor) -> [CapabilityReport] {
        let launcherReport = CapabilityReport(
            id: "launcher", title: "Home-Launcher",
            state: descriptor.homeActivities.count >= 2 ? .supported : .requiresOnDeviceAction,
            detail: descriptor.canSetHomeActivity
                ? "\(descriptor.homeActivities.count) Home-Aktivitäten erkannt; dieser Build meldet cmd package set-home-activity."
                : (descriptor.homeActivities.count >= 2
                    ? "\(descriptor.homeActivities.count) Home-Aktivitäten gefunden; Auswahl erfolgt über Androids sichtbare Auswahlseite."
                    : "Installiere einen weiteren Home-Launcher, bevor Android eine Auswahl anzeigen kann.")
        )
        var reports = descriptor.reports.filter { $0.id != "launcher" }
        reports.append(launcherReport)
        return reports
    }

    func prepareAPKUpdate(_ urls: [URL]) async {
        guard let connection = selectedConnection, connection.state == "device", let discovery, let apkService else { return }
        await perform("APK-Paket, Version, Hash und Signatur werden geprüft…") {
            if let oldPlan = self.apkPlan { apkService.discard(oldPlan) }
            self.apkPlan = nil
            self.apkPlan = try await apkService.prepare(urls: urls, serial: connection.serial, discovery: discovery)
        }
    }

    /// Downloads the update APK from its official release, then runs it through the normal
    /// check (package, version, signature vs. installed app) so the user only has to confirm.
    func downloadUpdate(_ package: InstalledPackage) async {
        guard canWorkWithDevice, let source = package.updateDownloadURL else { return }
        var downloaded: URL?
        await perform("\(package.displayTitle) wird geladen…") {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HandheldManager/Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var request = URLRequest(url: source)
            request.setValue("HandheldManager/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw ManagerError.commandFailed("Download fehlgeschlagen. Öffne die Quelle im Browser.")
            }
            let name = (package.updateAssetName ?? source.lastPathComponent).replacingOccurrences(of: "/", with: "_")
            let destination = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            downloaded = destination
        }
        guard errorMessage == nil, let downloaded else { return }
        if apkToolsAvailable { await prepareAPKUpdate([downloaded]) } else { prepareDirectAPKInstall([downloaded]); pendingUpdatePackage = package.packageName }
        if errorMessage == nil { statusMessage = "\(package.displayTitle) geladen und geprüft. Bitte Installation bestätigen." }
    }

    func prepareDirectAPKInstall(_ urls: [URL]) {
        guard let apkService else { return }
        pendingUpdatePackage = nil
        if let oldPreview = directAPKPreview { apkService.discardDirect(oldPreview) }
        do { directAPKPreview = try apkService.prepareDirectInstall(urls: urls) }
        catch { errorMessage = error.localizedDescription }
    }

    func installDirectAPK() async {
        guard let connection = selectedConnection, connection.state == "device",
              let apkService, let preview = directAPKPreview else { return }
        await perform("APK wird per ADB installiert; Android prüft das Paket…") {
            do { try await apkService.installDirect(preview, serial: connection.serial) }
            catch { self.noteInstallFailure(error, package: self.pendingUpdatePackage); throw error }
            self.directAPKPreview = nil
            self.pendingUpdatePackage = nil
            self.statusMessage = "\(preview.fileName) wurde von Android angenommen und installiert."
        }
    }

    private func noteInstallFailure(_ error: Error, package: String?) {
        if let package, error.localizedDescription.contains(InstallFailure.signatureMismatch) { signatureMismatchPackages.insert(package) }
    }

    func discardDirectAPKPreview() {
        if let preview = directAPKPreview { apkService?.discardDirect(preview) }
        directAPKPreview = nil
    }

    func installAPKPlan() async {
        guard let connection = selectedConnection, let discovery, let apkService, let plan = apkPlan else { return }
        guard plan.deviceSerial == connection.serial else {
            errorMessage = "Dieser APK-Prüfplan gehört zu einem anderen Gerät. Prüfe die APK erneut für das ausgewählte Handheld."
            return
        }
        await perform("APK wird installiert oder aktualisiert…") {
            do { try await apkService.install(plan, serial: connection.serial) }
            catch { self.noteInstallFailure(error, package: plan.packageName); throw error }
            guard let installed = try await discovery.packageDetails(serial: connection.serial, packageName: plan.packageName),
                  installed.versionCode == plan.versionCode else {
                throw ManagerError.invalidAPK("Nachinstallation meldet nicht den ausgewählten versionCode.")
            }
            let signers = try await apkService.installedSignerDigests(serial: connection.serial, packageName: plan.packageName)
            guard signers == plan.signerSHA256 else { throw ManagerError.invalidAPK("Nachinstallation hat nicht den erwarteten Signaturfingerabdruck.") }
            apkService.discard(plan)
            try await self.loadDescriptor(connection)
            if var current = self.descriptor, let index = current.packages.firstIndex(where: { $0.packageName == plan.packageName }) {
                current.packages[index] = installed
                self.descriptor = current
            }
            self.apkPlan = nil
            self.statusMessage = "\(plan.packageName) · Version \(plan.versionCode) installiert und Signatur verifiziert."
        }
    }

    func discardAPKPlan() {
        if let plan = apkPlan { apkService?.discard(plan) }
        apkPlan = nil
    }

    private func loadDescriptor(_ connection: DeviceConnection) async throws {
        let loaded = try await discovery!.descriptor(for: connection)
        descriptor = loaded
        let savedRomPath = UserDefaults.standard.string(forKey: "HandheldManager.romPath.\(connection.serial)")
        let savedRomVolume = UserDefaults.standard.string(forKey: "HandheldManager.romVolume.\(connection.serial)")
        if let savedRomVolume, loaded.volumes.contains(where: { $0.id == savedRomVolume }) {
            romVolumeID = savedRomVolume
        } else if romVolumeID == nil || !loaded.volumes.contains(where: { $0.id == romVolumeID }) {
            romVolumeID = loaded.volumes.first?.id
        }
        if let savedRomPath, let volume = loaded.volumes.first(where: { $0.id == romVolumeID }), savedRomPath == volume.path || savedRomPath.hasPrefix(volume.path + "/") {
            romFolderPath = savedRomPath
        } else if let volume = loaded.volumes.first(where: { $0.id == romVolumeID }), romFolderPath.isEmpty || !romFolderPath.hasPrefix(volume.path) {
            romFolderPath = volume.path + "/roms"
        }
        overclockRuntimeStatus = nil
        if let adb {
            let maximumOutput = try? await adb.shell(serial: connection.serial, "cat /sys/class/kgsl/kgsl-3d0/devfreq/max_freq", timeout: 10)
            let currentOutput = try? await adb.shell(serial: connection.serial, "cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq", timeout: 10)
            let maximum = maximumOutput.flatMap { Int64($0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let current = currentOutput.flatMap { Int64($0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let maximum {
                overclockRuntimeStatus = GPUClockStatus(deviceSerial: connection.serial, maximumHz: maximum, currentHz: current)
            }
        }
        if let adb, var imageState = loadedBootImage, imageState.deviceSerial == connection.serial {
            let bootOutput = try? await adb.shell(serial: connection.serial, "cat /proc/sys/kernel/random/boot_id")
            let currentBootID = bootOutput?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if let currentBootID, !currentBootID.isEmpty {
                if let previousBootID = imageState.androidBootID, previousBootID != currentBootID {
                    loadedBootImage = nil
                    persistLoadedBootImage()
                } else if imageState.androidBootID == nil {
                    imageState.androidBootID = currentBootID
                    loadedBootImage = imageState
                    persistLoadedBootImage()
                }
            }
        }
        if selectedHomePackageName == nil || !loaded.homeActivities.contains(where: { $0.packageName == selectedHomePackageName }) {
            selectedHomePackageName = loaded.currentHomeActivity?.packageName ?? loaded.homeActivities.first?.packageName
        }
        if selectedVolumeID == nil || !loaded.volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = loaded.volumes.first?.id
        }
        if selectedPackageName == nil || !loaded.packages.contains(where: { $0.packageName == selectedPackageName }) {
            selectedPackageName = loaded.packages.first?.packageName
        }
        let identity = "\(loaded.model)|\(loaded.build)|\(loaded.androidVersion)|\(loaded.securityPatch)"
        if lastDeviceIdentity != identity {
            profileChanges = []
            lastDeviceIdentity = identity
        }
        if let volume = selectedVolume, currentPath.isEmpty || !currentPath.hasPrefix(volume.path) {
            currentPath = volume.path
        }
        if let volume = selectedVolume, profileRoot.isEmpty || !profileRoot.hasPrefix(volume.path) { profileRoot = volume.path }
        statusMessage = "\(loaded.title) · Android \(loaded.androidVersion), API \(loaded.apiLevel)"
    }

    private func persistLoadedBootImage() {
        guard let loadedBootImage, let data = try? JSONEncoder().encode(loadedBootImage) else {
            UserDefaults.standard.removeObject(forKey: Self.loadedBootImageDefaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.loadedBootImageDefaultsKey)
    }

    private func reloadFilesAndDescriptor() async throws {
        guard let connection = selectedConnection else { return }
        try await loadDescriptor(connection)
        if let volume = selectedVolume, !currentPath.hasPrefix(volume.path) { currentPath = volume.path }
        try await loadFilesThrowing()
    }

    private func loadFilesAndDescriptor() async throws {
        try await reloadFilesAndDescriptor()
    }

    private func loadFilesThrowing() async throws {
        guard let connection = selectedConnection, let volume = selectedVolume, let fileService else { return }
        currentPath = try RemotePath.normalized(currentPath, within: volume)
        files = try await fileService.list(serial: connection.serial, path: currentPath, volume: volume)
        selectedFilePath = nil
    }

    private static func commonParent(of paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        var candidate = (first as NSString).deletingLastPathComponent
        while paths.contains(where: { $0 != candidate && !$0.hasPrefix(candidate.hasSuffix("/") ? candidate : candidate + "/") }) {
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { return nil }
            candidate = parent
        }
        return candidate
    }

    private func perform(_ label: String, operation: () async throws -> Void) async {
        guard !isBusy else { return }
        busyLabel = NSLocalizedString(label, comment: "Progress status")
        errorMessage = nil
        defer { busyLabel = nil }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }
}
