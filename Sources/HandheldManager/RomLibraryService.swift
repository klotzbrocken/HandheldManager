import Foundation

struct RomScanResult {
    let games: [RomGame]
    let reachedLimit: Bool
}

final class RomLibraryService {
    private let adb: ADBClient
    private let supportedExtensions: Set<String> = [
        "iso", "chd", "cso", "zso", "pbp", "rvz", "gcz", "wbfs", "wud", "wux",
        "nsp", "nsz", "xci", "3ds", "cia", "nds", "gba", "gbc", "gb", "nes", "sfc", "smc",
        "z64", "n64", "v64", "cdi", "gdi", "bin", "cue", "img", "mdf", "vpk",
        "sms", "gg", "gen", "md", "32x", "pce", "a26", "a52", "a78", "j64", "ngp", "ngc", "raw"
    ]

    /// When the folder name already identifies the console, only that console's own file types count.
    /// Everything else in the folder (cover scans, tracks, stray tiny files) is not a launchable game.
    static let validExtensions: [String: Set<String>] = [
        "PlayStation 2": ["iso", "chd", "cso", "zso", "cue"],
        "PlayStation": ["chd", "cue", "pbp", "iso", "img", "mdf"],
        "PSP": ["iso", "cso", "zso", "pbp", "chd"],
        "PlayStation Vita": ["vpk"],
        "Nintendo Switch": ["nsp", "nsz", "xci"],
        "Wii U": ["wud", "wux"],
        "GameCube": ["iso", "gcz", "rvz", "chd"],
        "Wii": ["iso", "wbfs", "rvz", "gcz", "chd"],
        "Nintendo 64": ["z64", "n64", "v64"],
        "Xbox 360": ["iso"],
        "Dreamcast": ["gdi", "cdi", "chd", "cue"],
        "Sega Mega Drive": ["gen", "md", "bin"],
        "Sega Master System": ["sms"],
        "Sega Game Gear": ["gg"],
    ]
    /// Launch descriptors are tiny text files; their real size is the tracks next to them.
    private static let descriptorExtensions: Set<String> = ["cue", "gdi"]

    init(adb: ADBClient) { self.adb = adb }

    func scan(serial: String, folder: String, volume: StorageVolume, limit: Int = 5_000) async throws -> RomScanResult {
        let root = try RemotePath.normalized(folder, within: volume)
        guard root == volume.path || root.hasPrefix(volume.path + "/") else {
            throw ManagerError.commandFailed("Der ROM-Pfad liegt außerhalb des ausgewählten Volumes.")
        }
        let filters = supportedExtensions.sorted().map { "-iname '*.\($0)'" }.joined(separator: " -o ")
        let command = "find \(RemotePath.shellQuote(root)) -type f \\( \(filters) \\) -exec stat -c '%s|%n' {} + 2>/dev/null | head -n \(limit)"
        let output = try await adb.shell(serial: serial, command, timeout: 120)
        var files: [RomGame] = []
        var trackBytes: [String: Int64] = [:]
        for line in output.standardOutput.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let separator = text.firstIndex(of: "|"),
                  let size = Int64(text[..<separator]), size >= 0 else { continue }
            let path = String(text[text.index(after: separator)...])
            guard (try? RemotePath.normalized(path, within: volume)) != nil else { continue }
            let name = (path as NSString).lastPathComponent
            let ext = ((path as NSString).pathExtension).lowercased()
            guard !name.hasPrefix("._"), name.localizedCaseInsensitiveCompare("Thumbs.db") != ComparisonResult.orderedSame else { continue }
            guard supportedExtensions.contains(ext) else { continue }
            if ext == "raw" || ext == "bin" { trackBytes[(path as NSString).deletingLastPathComponent, default: 0] += size }
            if ext == "raw" { continue }
            guard Self.descriptorExtensions.contains(ext) || size >= 128_000 else { continue }
            let platform = Self.platform(path: path, ext: ext)
            if let allowed = Self.validExtensions[platform], !allowed.contains(ext) { continue }
            files.append(RomGame(path: path, sizeBytes: size, platform: platform, fileExtension: ext))
        }

        // A CUE is the launch descriptor for its neighboring BIN tracks. Listing those tracks
        // as separate games creates several false entries for one PlayStation title.
        let directoriesWithCue = Set(files.filter { $0.fileExtension == "cue" }.map { ($0.path as NSString).deletingLastPathComponent })
        files.removeAll { game in
            if game.fileExtension == "bin" {
                let parent = (game.path as NSString).deletingLastPathComponent
                return directoriesWithCue.contains(parent) || Self.hasTrackSuffix(game.fileName) || game.platform == "Unbekannt (ISO/Disc)"
            }
            return false
        }

        // Show a descriptor with the size of its tracks when it is the only one in its folder.
        let descriptorsPerDirectory = Dictionary(grouping: files.filter { Self.descriptorExtensions.contains($0.fileExtension) }) { ($0.path as NSString).deletingLastPathComponent }
        files = files.map { game in
            let directory = (game.path as NSString).deletingLastPathComponent
            guard Self.descriptorExtensions.contains(game.fileExtension), descriptorsPerDirectory[directory]?.count == 1,
                  let tracks = trackBytes[directory] else { return game }
            return RomGame(path: game.path, sizeBytes: game.sizeBytes + tracks, platform: game.platform, fileExtension: game.fileExtension)
        }

        let grouped = Self.combineNumberedDiscs(files)
        let sorted = grouped.sorted { left, right in
            left.platform == right.platform
                ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                : left.platform.localizedStandardCompare(right.platform) == .orderedAscending
        }
        return RomScanResult(games: sorted, reachedLimit: files.count >= limit)
    }

    private static func combineNumberedDiscs(_ files: [RomGame]) -> [RomGame] {
        var numbered: [String: [RomGame]] = [:]
        var plain: [RomGame] = []
        for game in files {
            guard let base = numberedMediaBase(game.fileName) else { plain.append(game); continue }
            let key = "\(game.platform)|\(base)"
            numbered[key, default: []].append(game)
        }
        for group in numbered.values {
            if group.count == 1, let game = group.first { plain.append(game); continue }
            let ordered = group.sorted { preferredMediaOrder($0.fileExtension) < preferredMediaOrder($1.fileExtension) }
            guard let first = ordered.first else { continue }
            plain.append(RomGame(
                path: first.path,
                sizeBytes: group.reduce(Int64(0)) { $0 + $1.sizeBytes },
                platform: first.platform,
                fileExtension: first.fileExtension,
                groupedPaths: group.map(\.path).sorted()
            ))
        }
        return plain
    }

    private static func preferredMediaOrder(_ ext: String) -> Int {
        switch ext {
        case "chd", "iso", "cso", "zso", "rvz", "gcz", "wbfs", "wud", "wux", "nsp", "nsz", "xci", "3ds", "cia", "nds", "gba", "gbc", "gb", "nes", "sfc", "smc", "z64", "n64", "v64", "vpk", "cue": return 0
        case "bin": return 2
        default: return 1
        }
    }

    private static func hasTrackSuffix(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.range(of: #"(?i)\s*(?:[\[(]\s*)?(?:track|disc|disk|cd)\s*\d+[^\])]*(?:[\])]\s*)?$"#, options: .regularExpression) != nil
    }

    private static func numberedMediaBase(_ fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        guard hasTrackSuffix(fileName) else { return nil }
        let base = stem.replacingOccurrences(of: #"(?i)\s*(?:[\[(]\s*)?(?:track|disc|disk|cd)\s*\d+[^\])]*(?:[\])]\s*)?$"#, with: "", options: .regularExpression)
        let normalized = base.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }

    static let importConsoles = [
        "PlayStation 2", "PlayStation", "PSP", "PlayStation Vita", "Nintendo Switch", "Wii U", "GameCube", "Wii",
        "Nintendo 64", "Nintendo DS", "Nintendo 3DS", "Game Boy Advance", "Game Boy Color", "Game Boy", "NES", "SNES",
        "Dreamcast", "Sega Mega Drive", "Sega Master System", "Sega Game Gear", "Sega 32X", "PC Engine",
        "Atari 2600", "Atari 5200", "Atari 7800", "Neo Geo Pocket", "Xbox 360",
    ]

    /// Folder to create when the device has no folder for a console yet.
    static func defaultFolderName(_ platform: String) -> String {
        let names = ["PlayStation 2": "ps2", "PlayStation": "psx", "PSP": "psp", "PlayStation Vita": "psvita", "Nintendo Switch": "switch",
                     "Wii U": "wiiu", "GameCube": "gc", "Wii": "wii", "Nintendo 64": "n64", "Nintendo DS": "nds", "Nintendo 3DS": "3ds",
                     "Game Boy Advance": "gba", "Game Boy Color": "gbc", "Game Boy": "gb", "NES": "nes", "SNES": "snes", "Dreamcast": "dreamcast",
                     "Sega Mega Drive": "megadrive", "Sega Master System": "mastersystem", "Sega Game Gear": "gamegear", "Sega 32X": "sega32x",
                     "PC Engine": "pcengine", "Atari 2600": "atari2600", "Atari 5200": "atari5200", "Atari 7800": "atari7800",
                     "Neo Geo Pocket": "ngp", "Xbox 360": "xbox360"]
        return names[platform] ?? platform.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Console implied by the file type alone; empty when the type is ambiguous (ISO, BIN, CHD …).
    static func importPlatform(for url: URL) -> String {
        let value = platform(path: "", ext: url.pathExtension.lowercased())
        return value.hasPrefix("Unbekannt") || value.contains(" / ") ? "" : value
    }

    /// Console a folder name stands for ("dreamcast", "PS2", "Sega Mega Drive" …), nil if unknown.
    static func folderPlatform(_ name: String) -> String? {
        let value = platform(path: "/\(name)/x", ext: "")
        return value.hasPrefix("Unbekannt") ? nil : value
    }

    static func platform(path: String, ext: String) -> String {
        let value = path.lowercased()
        if value.contains("playstation 2") || value.contains("playstation2") || value.contains("/ps2/") { return "PlayStation 2" }
        if value.contains("playstation 1") || value.contains("playstation1") || value.contains("/ps1/") || value.contains("/psx/") { return "PlayStation" }
        if value.contains("playstation portable") || value.contains("/psp/") { return "PSP" }
        if value.contains("playstation vita") || value.contains("/psvita/") || value.contains("/vita/") { return "PlayStation Vita" }
        if value.contains("nintendo switch") || value.contains("/switch/") || value.contains("/switch roms/") { return "Nintendo Switch" }
        if value.contains("wii u") || value.contains("wiiu") || value.contains("/wiiu/") { return "Wii U" }
        if value.contains("gamecube") || value.contains("/gc/") { return "GameCube" }
        if value.contains("nintendo 64") || value.contains("/n64/") { return "Nintendo 64" }
        if value.contains("xbox 360") || value.contains("xbox360") { return "Xbox 360" }
        if value.contains("/wii/") { return "Wii" }
        if value.contains("dreamcast") || value.contains("/dc/") { return "Dreamcast" }
        if value.contains("mega drive") || value.contains("megadrive") || value.contains("genesis") { return "Sega Mega Drive" }
        if value.contains("master system") || value.contains("/sms/") { return "Sega Master System" }
        if value.contains("game gear") || value.contains("/gamegear/") { return "Sega Game Gear" }
        if value.contains("playstation") || value.contains("/psx/") { return "PlayStation" }
        switch ext {
        case "nsp", "nsz", "xci": return "Nintendo Switch"
        case "wud", "wux": return "Wii U"
        case "z64", "n64", "v64": return "Nintendo 64"
        case "gba": return "Game Boy Advance"
        case "gbc": return "Game Boy Color"
        case "gb": return "Game Boy"
        case "nes": return "NES"
        case "sfc", "smc": return "SNES"
        case "nds": return "Nintendo DS"
        case "3ds", "cia": return "Nintendo 3DS"
        case "rvz", "gcz": return "GameCube / Wii"
        case "wbfs": return "Wii"
        case "cso", "zso": return "PSP"
        case "vpk": return "PlayStation Vita"
        case "cdi", "gdi": return "Dreamcast"
        case "sms": return "Sega Master System"
        case "gg": return "Sega Game Gear"
        case "gen", "md": return "Sega Mega Drive"
        case "32x": return "Sega 32X"
        case "pce": return "PC Engine"
        case "a26": return "Atari 2600"
        case "a52": return "Atari 5200"
        case "a78": return "Atari 7800"
        case "ngp", "ngc": return "Neo Geo Pocket"
        case "iso", "chd", "bin", "cue", "img", "mdf", "pbp": return "Unbekannt (ISO/Disc)"
        default: return "Unbekannt"
        }
    }
}
