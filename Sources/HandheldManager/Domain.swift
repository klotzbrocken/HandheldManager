import Foundation

struct DeviceConnection: Identifiable, Hashable {
    let serial: String
    let state: String
    let product: String?
    let model: String?
    let device: String?

    var id: String { serial }
    var displayName: String { model?.replacingOccurrences(of: "_", with: " ") ?? product ?? "Android-Gerät" }
}

struct GPUClockStatus: Equatable {
    let deviceSerial: String
    let maximumHz: Int64
    let currentHz: Int64?

    var isOverclocked: Bool { maximumHz >= 905_000_000 }
    var maximumMHz: Int64 { maximumHz / 1_000_000 }
    var currentMHz: Int64? { currentHz.map { $0 / 1_000_000 } }
}

struct StorageVolume: Identifiable, Hashable {
    enum Kind: String, Codable { case internalStorage, removable }
    let id: String
    let name: String
    let path: String
    let kind: Kind
    var readable: Bool
    var writable: Bool
    var capacity: String?
}

struct DeviceDescriptor: Identifiable {
    let connection: DeviceConnection
    var manufacturer: String = ""
    var model: String = ""
    var device: String = ""
    var androidVersion: String = ""
    var apiLevel: String = ""
    var securityPatch: String = ""
    var build: String = ""
    var fingerprint: String = ""
    var volumes: [StorageVolume] = []
    var packages: [InstalledPackage] = []
    var homeActivities: [HomeActivity] = []
    var currentHomeActivity: HomeActivity?
    var canSetHomeActivity = false
    var settingsActions: [SettingsActionAvailability] = []
    var reports: [CapabilityReport] = []

    var id: String { connection.id }
    var title: String { model.isEmpty ? connection.displayName : model }
}

struct SettingsAction: Identifiable, Hashable {
    let id: String
    let title: String
    let action: String
    let help: String

    static let all: [SettingsAction] = [
        .init(id: "general", title: "Einstellungen", action: "android.settings.SETTINGS", help: "Android-Systemeinstellungen öffnen."),
        .init(id: "display", title: "Anzeige", action: "android.settings.DISPLAY_SETTINGS", help: "Anzeigeeinstellungen anzeigen."),
        .init(id: "storage", title: "Interner Speicher", action: "android.settings.INTERNAL_STORAGE_SETTINGS", help: "Speichereinstellungen anzeigen."),
        .init(id: "memory-card", title: "Speicherkarte", action: "android.settings.MEMORY_CARD_SETTINGS", help: "Speicherkarteinstellungen anzeigen, sofern der OEM diese Seite bereitstellt."),
        .init(id: "wifi", title: "WLAN", action: "android.settings.WIFI_SETTINGS", help: "WLAN-Einstellungen anzeigen."),
        .init(id: "bluetooth", title: "Bluetooth", action: "android.settings.BLUETOOTH_SETTINGS", help: "Bluetooth-Einstellungen anzeigen."),
        .init(id: "device-info", title: "Geräteinformationen", action: "android.settings.DEVICE_INFO_SETTINGS", help: "Geräte- und Versionsinformationen anzeigen."),
        .init(id: "developer", title: "Entwickleroptionen", action: "android.settings.APPLICATION_DEVELOPMENT_SETTINGS", help: "Entwickleroptionen anzeigen, sofern verfügbar.")
    ]
}

struct SettingsActionAvailability: Identifiable, Hashable {
    let actionID: String
    let resolvedComponent: String?
    var id: String { actionID }
    var isAvailable: Bool { resolvedComponent != nil }
}

struct FirmwareGuide: Identifiable {
    let id: String
    let title: String
    let manufacturer: String
    let officialURL: URL
    let guidance: String
    let listedRelease: String?
    let sourceCheckedAt: String
    let match: Match

    enum Match: Equatable { case verifiedModel, possibleModel, unsupported }
}

struct InstalledPackage: Identifiable, Hashable, Codable {
    let packageName: String
    var displayName: String? = nil
    var isEmulator: Bool? = nil
    var versionName: String? = nil
    var versionCode: Int64? = nil
    var updateVersionName: String? = nil
    var updateAvailable: Bool? = nil
    var updateChecked: Bool? = nil
    var updateSourceName: String? = nil
    var updateSourceURL: URL? = nil
    var updateDownloadURL: URL? = nil
    var updateAssetName: String? = nil
    var isSystemApp: Bool? = nil
    var storageBytes: Int64? = nil
    var id: String { packageName }
    var displayTitle: String { displayName ?? packageName }
}

struct StorageUsageEntry: Identifiable, Hashable {
    let path: String
    let sizeBytes: Int64
    let volumeID: String
    let isDirectory: Bool
    var id: String { path }
}

struct HomeActivity: Identifiable, Hashable {
    let packageName: String
    let componentName: String
    var id: String { componentName }

    /// Human-readable launcher name. ADB cannot read app labels, so known launchers come from a small
    /// list and everything else gets a tidied-up package name.
    var displayName: String {
        let known = [
            "com.android.launcher3": "Launcher3 (Android Standard)",
            "com.retroidpocket.gamelauncher": "Retroid Game Launcher",
            "com.smslv.trinketos": "TrinketOS",
            "com.spocky.projengmenu": "Projectivy Launcher",
            "org.es_de.frontend": "ES-DE Frontend",
            "com.android.settings": "Einstellungen",
            "com.anbernic.launcher": "ANBERNIC Launcher",
            "com.ayaneo.launcher": "AYANEO Launcher",
            "com.odin.launcher": "ODIN Launcher",
            "com.teslacoilsw.launcher": "Nova Launcher",
            "net.kdt.pojavlaunch": "Pojav Launcher",
            "app.lawnchair": "Lawnchair",
            "com.google.android.apps.nexuslauncher": "Pixel Launcher",
            "com.android.quickstep": "Quickstep",
            "com.sec.android.app.launcher": "One UI Home",
            "com.miui.home": "MIUI Home",
            "com.retroarch": "RetroArch",
            "com.magneticchen.daijishou": "Daijishō",
            "com.explusalpha.nostalgia": "Nostalgia",
        ]
        if let name = known[packageName] { return name }
        let last = packageName.split(separator: ".").last.map(String.init) ?? packageName
        return last.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct APKArtifact: Identifiable, Hashable {
    let url: URL
    let packageName: String
    let versionName: String?
    let versionCode: Int64
    let signerSHA256: [String]
    let sha256: String
    var id: String { url.path }
}

struct APKInstallPlan: Identifiable {
    let id: UUID
    let deviceSerial: String
    let packageName: String
    let versionName: String?
    let versionCode: Int64
    let signerSHA256: [String]
    let artifacts: [APKArtifact]
    let installedVersionName: String?
    let installedVersionCode: Int64?
    let installedSignerSHA256: [String]?

    var isUpdate: Bool { installedVersionCode != nil }
}

struct APKDirectInstallPreview: Identifiable {
    let id: UUID
    let url: URL
    let sha256: String
    var fileName: String { url.lastPathComponent }
}

enum CapabilityState: String, Codable {
    case supported = "Unterstützt"
    case unavailable = "Nicht verfügbar"
    case requiresOnDeviceAction = "Aktion am Gerät nötig"
    case unknown = "Nicht geprüft"
}

struct CapabilityReport: Identifiable, Hashable {
    let id: String
    let title: String
    let state: CapabilityState
    let detail: String
}

struct DeviceFileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: String
    var id: String { path }
}

struct RomGame: Identifiable, Hashable {
    let path: String
    let sizeBytes: Int64
    let platform: String
    let fileExtension: String
    var groupedPaths: [String] = []
    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var title: String {
        var value = (fileName as NSString).deletingPathExtension
        let tag = #"\s*(?:\[[^\]]*\]|[\[(]\s*(?:USA|Europe|Japan|World|En|Fr|De|Es|It|Rev\.?\s?\d+|Disc\s?\d+|Disk\s?\d+|CD\s?\d+|Track\s?\d+)[^\])]*[\])])$"#
        for _ in 0..<6 {
            let next = value.replacingOccurrences(of: tag, with: "", options: [.regularExpression, .caseInsensitive])
            if next == value { break }
            value = next
        }
        return value.replacingOccurrences(of: "_", with: " ")
    }
}

enum RomProjectMethod: String, Codable, Hashable {
    case recompilation
    case decompilation
    case port
}

enum AndroidProjectStatus: String, Codable, Hashable {
    case supported
    case notListed
    case notVerified
}

struct RomProjectMatch: Identifiable, Hashable {
    let gameTitle: String
    let projectTitle: String
    let method: RomProjectMethod
    let projectStatus: String
    let androidStatus: AndroidProjectStatus
    let platform: String?
    let sourceTitle: String
    let sourceURL: URL
    var id: String { sourceURL.absoluteString }
}

struct EmulatorConfigFile: Identifiable, Hashable {
    let name: String
    let path: String
    let volumeID: String
    let size: Int64
    let priority: Int
    let priorityLabel: String
    var id: String { path }
}

struct LoadedBootImageState: Codable, Equatable {
    let deviceSerial: String
    let build: String
    let fileName: String
    let sha256: String
    let startedAt: Date
    var androidBootID: String?
}

struct ConfigRemoteMapping: Codable, Hashable {
    let localPath: String
    let remotePath: String
    let volumeID: String
}

struct ConfigUploadPreview {
    let mapping: ConfigRemoteMapping
    let preview: FileTransferPreview
}

struct FileReplacementBackup: Codable, Identifiable {
    let id: UUID
    let deviceSerial: String
    let remotePath: String
    let localBackupPath: String
    let originalSHA256: String
    let createdAt: Date
}

struct FileTransferPreview {
    let source: String
    let destination: String
    let size: Int64
    let sha256: String
    let destinationExists: Bool
}

struct ADBCommandResult {
    let standardOutput: String
    let standardError: String
    let status: Int32
}

enum ManagerError: LocalizedError {
    case adbNotFound
    case commandFailed(String)
    case commandTimedOut(String)
    case noSelectedDevice
    case deviceNotReady(String)
    case invalidRemotePath(String)
    case destinationExists(String)
    case noRemovableStorage
    case profileInvalid(String)
    case profileMismatch(String)
    case noBackupAvailable
    case stalePreview
    case androidBuildToolsMissing
    case invalidAPK(String)
    case launcherNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: return "ADB wurde nicht gefunden. Installiere Android Platform Tools oder lege adb in den App-Ressourcen ab."
        case .commandFailed(let message): return message
        case .commandTimedOut(let command): return "ADB-Befehl hat das Zeitlimit überschritten: \(command)"
        case .noSelectedDevice: return "Wähle zuerst ein verbundenes Android-Gerät aus."
        case .deviceNotReady(let state): return "Das Gerät ist noch nicht autorisiert oder bereit (\(state))."
        case .invalidRemotePath(let path): return "Der Gerätepfad ist ungültig oder geschützt: \(path)"
        case .destinationExists(let path): return "Am Ziel gibt es bereits eine Datei: \(path). Ersetze sie nur nach expliziter Bestätigung."
        case .noRemovableStorage: return "Es wurde kein gemounteter, erreichbarer SD-Speicher gefunden."
        case .profileInvalid(let message): return "Das Emulatorprofil ist ungültig: \(message)"
        case .profileMismatch(let message): return "Das Profil passt nicht zum ausgewählten Emulator: \(message)"
        case .noBackupAvailable: return "Für dieses Gerät ist kein lokales Profil-Backup vorhanden."
        case .stalePreview: return "Das Ziel oder die Quelldatei hat sich seit der Vorschau geändert. Erstelle eine neue Vorschau."
        case .androidBuildToolsMissing: return "Android SDK Build Tools mit aapt und apksigner wurden nicht gefunden. Installiere Build Tools oder konfiguriere ANDROID_SDK_ROOT."
        case .invalidAPK(let message): return "APK-Prüfung fehlgeschlagen: \(message)"
        case .launcherNotAvailable(let message): return message
        }
    }
}

enum RemotePath {
    static func normalized(_ raw: String, within volume: StorageVolume) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n"), !trimmed.contains("\r"), !trimmed.contains("\0") else {
            throw ManagerError.invalidRemotePath(raw)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(".") else {
            throw ManagerError.invalidRemotePath(raw)
        }
        let normalized = "/" + components.joined(separator: "/")
        guard normalized == volume.path || normalized.hasPrefix(volume.path + "/") else {
            throw ManagerError.invalidRemotePath(raw)
        }
        return normalized
    }

    static func child(_ name: String, of directory: String, within volume: StorageVolume) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\n"), !name.contains("\r") else {
            throw ManagerError.invalidRemotePath(name)
        }
        return try normalized(directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == volume.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                             ? "\(volume.path)/\(name)" : "\(directory)/\(name)", within: volume)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Int64 {
    var humanBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

struct ROMImportItem: Identifiable {
    let id = UUID()
    let url: URL
    var platform: String   // empty = not assigned yet
}

/// Launchers and frontends worth installing on a handheld. GitHub entries can be downloaded in-app,
/// the others open their official page.
struct LauncherOption: Identifiable {
    let name: String
    let summary: String
    let packageName: String
    let githubRepository: String?
    let website: URL
    /// Folders (relative to a storage volume) where the frontend keeps its data; empty = private only.
    var dataFolders: [String] = []
    var id: String { packageName }

    static let recommended: [LauncherOption] = [
        .init(name: "Daijishō", summary: "Retro-Frontend mit Plattform-Playlists, Covern und Emulator-Starter. Beliebt auf Handhelds.",
              packageName: "com.magneticchen.daijishou", githubRepository: "TapiocaFox/Daijishou", website: URL(string: "https://daijishou.com")!,
              dataFolders: ["Daijishou", "Android/data/com.magneticchen.daijishou/files"]),
        .init(name: "Pegasus", summary: "Quelloffenes, anpassbares Frontend mit Themes. Konfiguration über Dateien im Speicher.",
              packageName: "org.pegasus_frontend.android", githubRepository: "mmatyas/pegasus-frontend", website: URL(string: "https://pegasus-frontend.org")!,
              dataFolders: ["pegasus-frontend", "Android/data/org.pegasus_frontend.android/files"]),
        .init(name: "ES-DE", summary: "Die bekannte EmulationStation-Oberfläche für Android. Wird über die Projektseite bezogen.",
              packageName: "org.es_de.frontend", githubRepository: nil, website: URL(string: "https://es-de.org")!,
              dataFolders: ["ES-DE"]),
        .init(name: "Projectivy Launcher", summary: "Flexibler Launcher mit Backup und Import des Layouts. Wird über Google Play bezogen.",
              packageName: "com.spocky.projengmenu", githubRepository: nil, website: URL(string: "https://play.google.com/store/apps/details?id=com.spocky.projengmenu")!),
    ]
}

struct FrontendDataEntry: Identifiable, Hashable {
    let path: String
    let sizeBytes: Int64
    let isDirectory: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct FrontendBackupManifest: Codable {
    struct Item: Codable { let relativePath: String; let isDirectory: Bool; let sizeBytes: Int64 }
    let packageName: String
    let deviceSerial: String
    let volumeKind: String
    let createdAt: Date
    let items: [Item]
}

struct FrontendRestorePlan {
    let manifest: FrontendBackupManifest
    let folder: URL
    let volume: StorageVolume
    let existing: Set<String>   // relative paths that already exist on the device
}
