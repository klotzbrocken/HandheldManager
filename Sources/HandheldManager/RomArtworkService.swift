import AppKit
import Combine
import Foundation

private struct RomArtworkEntry: Sendable {
    let name: String
    let url: URL
}

struct CoverCandidate: Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }
}

/// Covers the user picked by hand; they win over the automatic match.
enum RomCoverStore {
    private static let key = "HandheldManager.coverOverrides"
    private static var all: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    static func url(for path: String) -> URL? { all[path].flatMap { URL(string: $0) } }

    static func set(_ url: URL?, for path: String) {
        var values = all
        values[path] = url?.absoluteString
        UserDefaults.standard.set(values, forKey: key)
    }

    static func move(from old: String, to new: String) {
        guard let url = url(for: old) else { return }
        set(nil, for: old); set(url, for: new)
    }
}

actor RomArtworkService {
    static let shared = RomArtworkService()

    private static let thumbnailFolders: [String: String] = [
        "PlayStation 2": "Sony - PlayStation 2",
        "PlayStation": "Sony - PlayStation",
        "PSP": "Sony - PlayStation Portable",
        "PlayStation Vita": "Sony - PlayStation Vita",
        "GameCube / Wii": "Nintendo - GameCube",
        "GameCube": "Nintendo - GameCube",
        "Wii": "Nintendo - Wii",
        "Wii U": "Nintendo - Wii U",
        "Nintendo 64": "Nintendo - Nintendo 64",
        "Game Boy Advance": "Nintendo - Game Boy Advance",
        "Game Boy Color": "Nintendo - Game Boy Color",
        "Game Boy": "Nintendo - Game Boy",
        "Nintendo DS": "Nintendo - Nintendo DS",
        "Nintendo 3DS": "Nintendo - Nintendo 3DS",
        "Nintendo Switch": "Nintendo - Nintendo Switch",
        "NES": "Nintendo - Nintendo Entertainment System",
        "SNES": "Nintendo - Super Nintendo Entertainment System",
        "Dreamcast": "Sega - Dreamcast",
        "Sega Mega Drive": "Sega - Mega Drive - Genesis",
        "Sega Master System": "Sega - Master System - Mark III",
        "Sega Game Gear": "Sega - Game Gear",
        "Sega 32X": "Sega - 32X",
        "PC Engine": "NEC - PC Engine - TurboGrafx 16",
        "Atari 2600": "Atari - 2600",
        "Atari 5200": "Atari - 5200",
        "Atari 7800": "Atari - 7800",
        "Neo Geo Pocket": "SNK - Neo Geo Pocket Color"
    ]

    private let session: URLSession
    private var indexes: [String: [RomArtworkEntry]] = [:]
    private var inFlight: [String: Task<[RomArtworkEntry]?, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    func coverURL(for game: RomGame) async -> URL? {
        guard game.platform != "Nintendo Switch", let folder = Self.thumbnailFolders[game.platform] else { return nil }
        for kind in ["Named_Boxarts", "Named_Titles"] {
            if let entries = await entries(for: folder, kind: kind), let match = Self.bestMatch(for: game, in: entries) { return match }
        }
        return nil
    }

    private static func bestMatch(for game: RomGame, in entries: [RomArtworkEntry]) -> URL? {
        let stem = (game.fileName as NSString).deletingPathExtension
        let target = normalize(game.title)
        let stemTarget = normalize(stem)
        let desiredRegion = region(in: stem)
        func byRegion(_ list: [RomArtworkEntry]) -> URL? {
            list.sorted { regionScore($0.name, desired: desiredRegion) > regionScore($1.name, desired: desiredRegion) }.first?.url
        }
        let exact = entries.filter { let n = normalize($0.name); return n == target || n == stemTarget }
        if let url = byRegion(exact) { return url }

        let targetTokens = Set(tokens(game.title))
        if targetTokens.count >= 2 {
            let fuzzy = entries.compactMap { entry -> (RomArtworkEntry, Double)? in
                let other = Set(tokens(entry.name))
                let ratio = Double(targetTokens.intersection(other).count) / Double(max(targetTokens.count, other.count))
                return ratio >= 0.75 ? (entry, ratio) : nil
            }
            if let best = fuzzy.map(\.1).max() { return byRegion(fuzzy.filter { $0.1 == best }.map(\.0)) }
        }
        // "Game" vs "Game - Subtitle": accept when one title starts with the other.
        guard target.count >= 6 else { return nil }
        return byRegion(entries.filter { let n = normalize($0.name); return n.count >= 6 && (n.hasPrefix(target) || target.hasPrefix(n)) })
    }

    /// Manual cover search: best matches of a free-text query (the user may correct the name).
    func search(_ query: String, platform: String, limit: Int = 12) async -> [CoverCandidate] {
        guard let folder = Self.thumbnailFolders[platform] else { return [] }
        let wanted = Set(Self.tokens(query))
        let normalizedQuery = Self.normalize(query)
        guard !wanted.isEmpty else { return [] }
        var seen = Set<String>()
        var scored: [(CoverCandidate, Double)] = []
        for kind in ["Named_Boxarts", "Named_Titles"] {
            guard let entries = await entries(for: folder, kind: kind) else { continue }
            for entry in entries where seen.insert(entry.name).inserted {
                let other = Set(Self.tokens(entry.name))
                let overlap = Double(wanted.intersection(other).count)
                guard overlap > 0 else { continue }
                var score = overlap / Double(max(wanted.count, other.count))
                if Self.normalize(entry.name).contains(normalizedQuery) { score += 0.5 }
                if kind == "Named_Boxarts" { score += 0.05 }
                scored.append((CoverCandidate(name: (entry.name as NSString).deletingPathExtension, url: entry.url), score))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private func entries(for folder: String, kind: String) async -> [RomArtworkEntry]? {
        let key = "\(folder)/\(kind)"
        if let cached = indexes[key] { return cached }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < 2 * 60 { return nil }
        // Many cards ask at once; share one download of the listing instead of racing (and timing out) N times.
        if let running = inFlight[key] { return await running.value }
        let session = self.session
        let task = Task<[RomArtworkEntry]?, Never> { await Self.downloadIndex(folder: folder, kind: kind, session: session) }
        inFlight[key] = task
        let values = await task.value
        inFlight[key] = nil
        if let values { indexes[key] = values } else { failedAt[key] = Date() }
        return values
    }

    private static func downloadIndex(folder: String, kind: String, session: URLSession) async -> [RomArtworkEntry]? {
        guard let encodedFolder = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let base = URL(string: "https://thumbnails.libretro.com/\(encodedFolder)/\(kind)/") else { return nil }
        var request = URLRequest(url: base)
        request.setValue("HandheldManager/1.0 (cover lookup)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let names = captureAll(#"(?is)<a\b[^>]*href=["']([^"']+\.png)["'][^>]*>"#, in: html)
            guard !names.isEmpty else { continue }
            return names.compactMap { value -> RomArtworkEntry? in
                let name = (value as NSString).lastPathComponent.removingPercentEncoding ?? (value as NSString).lastPathComponent
                guard let item = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
                return RomArtworkEntry(name: name, url: item)
            }
        }
        return nil
    }

    static func candidateURLs(for game: RomGame) -> [URL] {
        var results: [URL] = []
        if game.platform == "Nintendo Switch",
           let titleID = captureFirst(#"(?i)(?<![0-9a-f])01[0-9a-f]{14}(?![0-9a-f])"#, in: game.fileName),
           let icon = URL(string: "https://api.nlib.cc/nx/\(titleID)/icon") {
            results.append(icon)
        }
        if game.platform == "Nintendo Switch" { return results }
        guard let folder = thumbnailFolders[game.platform] else { return results }
        let stem = (game.fileName as NSString).deletingPathExtension
        let names = [stem, game.title, "\(game.title) (USA)", "\(game.title) (Europe)", "\(game.title) (World)"]
        results += names.compactMap { name in
            guard let folderPart = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let namePart = name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._()'!")),
                  let url = URL(string: "https://thumbnails.libretro.com/\(folderPart)/Named_Boxarts/\(namePart).png") else { return nil }
            return url
        }
        return results
    }

    private static func normalize(_ value: String) -> String {
        let noExtension = (value as NSString).deletingPathExtension
        let withoutSerialTags = noExtension.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: " ", options: .regularExpression)
        let clean = withoutSerialTags.replacingOccurrences(of: #"\s*\((?:USA|Europe|Japan|World|En|Fr|De|Es|It|Rev\.?\s?\d+|Disc\s?\d+|Disk\s?\d+|CD\s?\d+|Track\s?\d+|\d{4}-\d{2}-\d{2})[^)]*\)\s*"#, with: " ", options: [.regularExpression, .caseInsensitive])
        return clean.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber }
    }

    private static func tokens(_ value: String) -> [String] {
        let cleaned = value.replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]"#, with: " ", options: .regularExpression)
        return cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    private static func region(in value: String) -> String? {
        let patterns: [(String, String)] = [("USA", "USA"), ("Europe", "Europe"), ("Japan", "Japan"), ("World", "World")]
        return patterns.first(where: { value.localizedCaseInsensitiveContains($0.0) })?.1
    }

    private static func regionScore(_ name: String, desired: String?) -> Int {
        if let desired, name.localizedCaseInsensitiveContains(desired) { return 100 }
        if name.localizedCaseInsensitiveContains("USA") { return 30 }
        if name.localizedCaseInsensitiveContains("World") { return 25 }
        if name.localizedCaseInsensitiveContains("Europe") { return 20 }
        return 10
    }

    private static func captureAll(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func captureFirst(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }
}

@MainActor
final class RomCoverLoader: ObservableObject {
    private static var imageCache: [URL: NSImage] = [:]
    private static var resolvedCache: [String: NSImage] = [:]

    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false
    private var loadedKey: String?

    static func forget(path: String) {
        resolvedCache = resolvedCache.filter { !$0.key.hasPrefix(path + "|") }
    }

    func load(_ game: RomGame, force: Bool = false) async {
        let key = "\(game.path)|\(game.platform)"
        if force { loadedKey = nil }
        if let cached = Self.resolvedCache[key] { image = cached; loadedKey = key; return }
        guard loadedKey != key else { return }
        image = nil
        isLoading = true
        defer { isLoading = false }
        var candidates: [URL] = []
        if let chosen = RomCoverStore.url(for: game.path) { candidates.append(chosen) }
        if let matched = await RomArtworkService.shared.coverURL(for: game) { candidates.append(matched) }
        candidates += RomArtworkService.candidateURLs(for: game).filter { !candidates.contains($0) }
        for url in candidates {
            if Task.isCancelled { return }   // scrolled away: leave loadedKey unset so the next appearance retries
            if let cached = Self.imageCache[url] { finish(cached, key: key); return }
            var request = URLRequest(url: url)
            request.setValue("HandheldManager/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let loaded = NSImage(data: data) else { continue }
            Self.imageCache[url] = loaded
            finish(loaded, key: key)
            return
        }
        if !Task.isCancelled { loadedKey = key }   // genuinely no cover: don't hammer the server again
    }

    private func finish(_ loaded: NSImage, key: String) {
        Self.resolvedCache[key] = loaded
        image = loaded
        loadedKey = key
    }
}
