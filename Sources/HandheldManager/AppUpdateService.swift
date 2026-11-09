import Foundation

struct AppUpdateResult: Sendable {
    let version: String?
    let available: Bool?
    let sourceName: String
    let sourceURL: URL
    var downloadURL: URL? = nil
    var downloadName: String? = nil
}

private struct ReleaseAsset: Sendable {
    let name: String
    let url: URL?
}

private enum UpdateSourceKind: Sendable {
    case github(repository: String, includePrerelease: Bool)
    case forgejo(repository: String)
    case dolphin
    case retroArch
    case aetherBuilds
    case playStore(package: String)
}

private struct UpdateSource: Hashable, Sendable {
    let key: String
    let name: String
    let url: URL
    let kind: UpdateSourceKind

    static func == (lhs: UpdateSource, rhs: UpdateSource) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

private struct LatestAppRelease: Sendable {
    let version: String
    let sourceName: String
    let sourceURL: URL
    let source: UpdateSource
    let commitRef: String?
    let assets: [ReleaseAsset]
}

private struct GitHubRelease: Decodable, Sendable {
    let tag_name: String
    let name: String?
    let html_url: URL
    let target_commitish: String?
    let published_at: String?
    let prerelease: Bool?
    let assets: [Asset]?
    struct Asset: Decodable, Sendable { let name: String; let browser_download_url: URL? }
}

private struct GitHubTag: Decodable, Sendable {
    let name: String
    let commit: Commit
    struct Commit: Decodable, Sendable { let sha: String }
}

private struct GitHubCommit: Decodable, Sendable {
    let sha: String
    let commit: Commit
    struct Commit: Decodable, Sendable { let committer: Identity }
    struct Identity: Decodable, Sendable { let date: String }
}

private struct ForgejoRelease: Decodable, Sendable {
    let tag_name: String
    let name: String?
    let html_url: URL
    let target_commitish: String?
    let assets: [Asset]?
    struct Asset: Decodable, Sendable { let name: String; let browser_download_url: URL? }
}

private struct ForgejoCommit: Decodable, Sendable {
    let sha: String
    let commit: Commit
    struct Commit: Decodable, Sendable { let committer: Identity }
    struct Identity: Decodable, Sendable { let date: String }
}

actor AppUpdateService {
    private let session: URLSession
    private var cache: [String: (LatestAppRelease, Date)] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 22
        session = URLSession(configuration: configuration)
    }

    func check(_ packages: [InstalledPackage]) async -> [String: AppUpdateResult] {
        let eligible = packages.filter { $0.versionName != nil }
        let sources = Dictionary(eligible.map { ($0.packageName, Self.source(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let stale = Array(Set(sources.values)).filter { source in
            guard let entry = cache[source.key] else { return true }
            return Date().timeIntervalSince(entry.1) > 6 * 60 * 60
        }
        for start in stride(from: 0, to: stale.count, by: 4) {
            let batch = Array(stale[start..<min(start + 4, stale.count)])
            let session = self.session
            let fetched = await withTaskGroup(of: (UpdateSource, LatestAppRelease?).self) { group in
                for source in batch {
                    group.addTask { (source, try? await Self.fetchLatest(source, session: session)) }
                }
                var values: [String: LatestAppRelease] = [:]
                for await (source, release) in group {
                    if let release { values[source.key] = release }
                }
                return values
            }
            let now = Date()
            for (key, release) in fetched { cache[key] = (release, now) }
            for source in batch where fetched[source.key] == nil { cache.removeValue(forKey: source.key) }
        }

        var result: [String: AppUpdateResult] = [:]
        for package in eligible {
            guard let source = sources[package.packageName] else { continue }
            guard let release = cache[source.key]?.0 else {
                result[package.packageName] = AppUpdateResult(version: nil, available: nil, sourceName: source.name, sourceURL: source.url)
                continue
            }
            let comparison = await Self.compare(package: package, release: release, session: session)
            let apk = Self.bestAPK(release.assets)
            result[package.packageName] = AppUpdateResult(
                version: release.version,
                available: comparison,
                sourceName: release.sourceName,
                sourceURL: release.sourceURL,
                downloadURL: apk?.url,
                downloadName: apk?.name
            )
        }
        return result
    }

    /// Picks the APK a handheld (arm64) should install; nil when the release ships none we can download.
    private static func bestAPK(_ assets: [ReleaseAsset]) -> ReleaseAsset? {
        func score(_ name: String) -> Int {
            let n = name.lowercased()
            var value = 0
            if n.contains("arm64") || n.contains("aarch64") { value += 10 }
            if n.contains("universal") { value += 4 }
            if n.contains("x86") { value -= 10 }
            if n.contains("armeabi") || n.contains("armv7") || n.contains("arm32") { value -= 5 }
            if n.contains("debug") || n.contains("symbols") { value -= 8 }
            return value
        }
        return assets.filter { $0.url != nil && $0.name.lowercased().hasSuffix(".apk") }.max { score($0.name) < score($1.name) }
    }

    private static func source(for package: InstalledPackage) -> UpdateSource {
        let id = package.packageName
        if id.hasPrefix("org.vita3k.emulator.") {
            return .init(key: "github:Vita3K/Vita3K-Android", name: "GitHub · Vita3K", url: URL(string: "https://github.com/Vita3K/Vita3K-Android/releases")!, kind: .github(repository: "Vita3K/Vita3K-Android", includePrerelease: false))
        }
        switch id {
        case "org.dolphinemu.dolphinemu", "com.dolphinemu.dolphinemu":
            return .init(key: "dolphin", name: "Dolphin", url: URL(string: "https://dolphin-emu.org/download/?ref=btn")!, kind: .dolphin)
        case "com.retroarch", "com.retroarch.aarch64", "com.retroarch.ra32":
            return .init(key: "retroarch", name: "RetroArch", url: URL(string: "https://www.retroarch.com/platforms.html")!, kind: .retroArch)
        case "xyz.aethersx2.android":
            if package.versionName?.localizedCaseInsensitiveContains("2.2n") == true {
                return .init(key: "github:Trixarian/NetherSX2-classic", name: "NetherSX2 Classic", url: URL(string: "https://github.com/Trixarian/NetherSX2-classic/releases")!, kind: .github(repository: "Trixarian/NetherSX2-classic", includePrerelease: false))
            }
            return .init(key: "aethersx2-builds", name: "AetherSX2", url: URL(string: "https://github.com/AetherSX2-backup/AetherSX2-builds")!, kind: .aetherBuilds)
        case "xyz.aethersx2.cturnip":
            return .init(key: "github:nckstwrt/NetherSX2-Turnip", name: "NetherSX2 Turnip", url: URL(string: "https://github.com/nckstwrt/NetherSX2-Turnip/releases")!, kind: .github(repository: "nckstwrt/NetherSX2-Turnip", includePrerelease: false))
        case "dev.legacy.eden_emulator.nightly":
            return .init(key: "forgejo:eden-ci/nightly", name: "Eden Nightly", url: URL(string: "https://git.eden-emu.dev/eden-ci/nightly/releases")!, kind: .forgejo(repository: "eden-ci/nightly"))
        case "org.citron.citron_emu":
            return .init(key: "github:citron-neo/emulator", name: "Citron NEO", url: URL(string: "https://github.com/citron-neo/emulator/releases")!, kind: .github(repository: "citron-neo/emulator", includePrerelease: false))
        case "info.cemu.cemu":
            return .init(key: "github:SSimco/Cemu", name: "Cemu", url: URL(string: "https://github.com/SSimco/Cemu/releases")!, kind: .github(repository: "SSimco/Cemu", includePrerelease: false))
        case "me.magnum.melonds.nightly":
            return .init(key: "github:rafaelvcaetano/melonDS-android:nightly", name: "melonDS Android Nightly", url: URL(string: "https://github.com/rafaelvcaetano/melonDS-android/releases")!, kind: .github(repository: "rafaelvcaetano/melonDS-android", includePrerelease: true))
        case "me.magnum.melonds", "org.melonds.android":
            return .init(key: "github:rafaelvcaetano/melonDS-android", name: "melonDS Android", url: URL(string: "https://github.com/rafaelvcaetano/melonDS-android/releases")!, kind: .github(repository: "rafaelvcaetano/melonDS-android", includePrerelease: false))
        case "org.azahar_emu.azahar":
            return .init(key: "github:azahar-emu/azahar", name: "Azahar", url: URL(string: "https://github.com/azahar-emu/azahar/releases")!, kind: .github(repository: "azahar-emu/azahar", includePrerelease: false))
        case "org.ppsspp.ppsspp", "org.ppsspp.ppssppgold":
            return .init(key: "github:hrydgard/ppsspp", name: "PPSSPP", url: URL(string: "https://github.com/hrydgard/ppsspp/releases")!, kind: .github(repository: "hrydgard/ppsspp", includePrerelease: false))
        case "com.github.stenzek.duckstation":
            return .init(key: "github:stenzek/duckstation", name: "DuckStation", url: URL(string: "https://github.com/stenzek/duckstation/releases")!, kind: .github(repository: "stenzek/duckstation", includePrerelease: false))
        case "org.vita3k.emulator":
            return .init(key: "github:Vita3K/Vita3K-Android", name: "GitHub · Vita3K", url: URL(string: "https://github.com/Vita3K/Vita3K-Android/releases")!, kind: .github(repository: "Vita3K/Vita3K-Android", includePrerelease: false))
        default:
            return .init(key: "play:\(id)", name: "Google Play", url: playStoreURL(package: id), kind: .playStore(package: id))
        }
    }

    private static func fetchLatest(_ source: UpdateSource, session: URLSession) async throws -> LatestAppRelease {
        switch source.kind {
        case let .github(repository, includePrerelease):
            let releases: [GitHubRelease] = try await getJSON("https://api.github.com/repos/\(repository)/releases?per_page=20", session: session)
            guard let release = releases.first(where: { ($0.prerelease == true) == includePrerelease }) ?? releases.first else { throw URLError(.cannotFindHost) }
            let resolvedName = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = release.tag_name == "latest" ? (resolvedName?.isEmpty == false ? resolvedName! : "Latest rolling release") : release.tag_name
            let comparisonRef = release.tag_name == "latest" ? release.target_commitish : release.tag_name
            return LatestAppRelease(version: version, sourceName: source.name, sourceURL: release.html_url, source: source, commitRef: comparisonRef, assets: release.assets?.map { ReleaseAsset(name: $0.name, url: $0.browser_download_url) } ?? [])
        case let .forgejo(repository):
            let release: ForgejoRelease = try await getJSON("https://git.eden-emu.dev/api/v1/repos/\(repository)/releases/latest", session: session)
            let label = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = label?.isEmpty == false ? label! : release.tag_name
            return LatestAppRelease(version: version, sourceName: source.name, sourceURL: release.html_url, source: source, commitRef: release.tag_name, assets: release.assets?.map { ReleaseAsset(name: $0.name, url: $0.browser_download_url) } ?? [])
        case .dolphin:
            do {
                let html = try await fetchHTML(source.url, session: session)
                let version = Self.captureFirst(#"(?is)\b(\d{4}[a-z]?)\b(?:(?!\b\d{4}[a-z]?\b).){0,1200}?Android"#, in: html)
                if let version {
                    return LatestAppRelease(version: version, sourceName: source.name, sourceURL: source.url, source: source, commitRef: nil, assets: [])
                }
                throw URLError(.cannotParseResponse)
            } catch {
                let tags: [GitHubTag] = try await getJSON("https://api.github.com/repos/dolphin-emu/dolphin/tags?per_page=100", session: session)
                let releases = tags.map(\.name).filter { $0.range(of: #"^\d{4}[a-z]?$"#, options: .regularExpression) != nil }
                guard let version = releases.max(by: { Self.compareVersionStrings($1, $0) }) else { throw error }
                return LatestAppRelease(version: version, sourceName: source.name, sourceURL: source.url, source: source, commitRef: nil, assets: [])
            }
        case .retroArch:
            let html = try await fetchHTML(source.url, session: session)
            guard let version = Self.captureFirst(#"(?i)current stable version is:\s*([0-9]+(?:\.[0-9]+){1,3})"#, in: html) else { throw URLError(.cannotParseResponse) }
            return LatestAppRelease(version: version, sourceName: source.name, sourceURL: source.url, source: source, commitRef: nil, assets: [])
        case .aetherBuilds:
            let readme = URL(string: "https://raw.githubusercontent.com/AetherSX2-backup/AetherSX2-builds/master/README.md")!
            let markdown = try await fetchHTML(readme, session: session)
            guard let apk = Self.captureFirst(#"(?i)\((?:https://github\.com/[^)]+/raw/[^)]+/)?([^/()]+\.apk)\)"#, in: markdown),
                  let version = Self.captureFirst(#"(?i)v?([0-9]+\.[0-9]+(?:-[0-9]+)?)"#, in: apk) else { throw URLError(.cannotParseResponse) }
            return LatestAppRelease(version: version, sourceName: source.name, sourceURL: source.url, source: source, commitRef: nil, assets: [ReleaseAsset(name: apk, url: nil)])
        case let .playStore(package):
            let url = playStoreURL(package: package)
            let html = try await fetchHTML(url, session: session)
            guard let version = Self.captureFirst(#"(?is)"softwareVersion"\s*:\s*"([^"\\]+)""#, in: html) else { throw URLError(.cannotParseResponse) }
            return LatestAppRelease(version: version, sourceName: source.name, sourceURL: source.url, source: source, commitRef: nil, assets: [])
        }
    }

    private static func compare(package: InstalledPackage, release: LatestAppRelease, session: URLSession) async -> Bool? {
        guard let installed = package.versionName else { return nil }
        if package.packageName.hasPrefix("org.vita3k.emulator."), let code = package.versionCode,
           let latest = Int(release.version.filter(\.isNumber)) {
            return latest > code
        }
        if release.source.kind.isTurnipPatch { return nil }
        if let installedHash = commitHash(in: installed), let ref = release.commitRef,
           let commitSource = commitRepository(release.source.kind) {
            async let current = commitDate(repository: commitSource.repository, host: commitSource.host, revision: installedHash, session: session)
            async let latest = commitDate(repository: commitSource.repository, host: commitSource.host, revision: ref, session: session)
            if let currentDate = await current, let latestDate = await latest {
                return latestDate > currentDate
            }
            if ref.localizedCaseInsensitiveContains(installedHash) { return false }
        }
        if let installedBase = baseVersion(installed), let latestBase = baseVersion(release.version) {
            return compareVersionStrings(latestBase, installedBase)
        }
        return nil
    }

    private static func commitRepository(_ kind: UpdateSourceKind) -> (host: String, repository: String)? {
        switch kind {
        case let .github(repository, _): return ("https://api.github.com", repository)
        case let .forgejo(repository): return ("https://git.eden-emu.dev/api/v1", repository)
        default: return nil
        }
    }

    private static func commitDate(repository: String, host: String, revision: String, session: URLSession) async -> Date? {
        let url: String
        if host.contains("api.github.com") {
            url = "\(host)/repos/\(repository)/commits/\(revision)"
        } else {
            url = "\(host)/repos/\(repository)/git/commits/\(revision)"
        }
        guard let commit: GitHubCommit = try? await getJSON(url, session: session) else { return nil }
        return ISO8601DateFormatter().date(from: commit.commit.committer.date)
    }

    private static func getJSON<T: Decodable>(_ address: String, session: URLSession) async throws -> T {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HandheldManager/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func fetchHTML(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/537.36 Chrome/124.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func playStoreURL(package: String) -> URL {
        let encoded = package.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? package
        return URL(string: "https://play.google.com/store/apps/details?id=\(encoded)&hl=en&gl=US")!
    }

    static func baseVersion(_ value: String) -> String? {
        captureFirst(#"(?i)v?(\d+(?:\.\d+){0,3}[a-z]?)"#, in: value)
    }

    static func compareVersionStrings(_ lhs: String, _ rhs: String) -> Bool {
        let pattern = #"\d+|[a-z]+"#
        func components(_ string: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: string.lowercased(), range: NSRange(string.startIndex..., in: string)).compactMap { match in
                guard let range = Range(match.range, in: string) else { return nil }
                return String(string[range]).lowercased()
            }
        }
        let left = components(lhs), right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            guard index < left.count else { return false }
            guard index < right.count else { return true }
            let a = left[index], b = right[index]
            if a == b { continue }
            if let ai = Int(a), let bi = Int(b) { return ai > bi }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a > b
        }
        return false
    }

    private static func commitHash(in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])[0-9a-f]{7,40}(?![a-z0-9])"#) else { return nil }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        return matches.last.flatMap { Range($0.range, in: value).map { String(value[$0]) } }
    }

    private static func captureFirst(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

private extension UpdateSourceKind {
    var isTurnipPatch: Bool {
        if case let .github(repository, _) = self { return repository == "nckstwrt/NetherSX2-Turnip" }
        return false
    }
}
