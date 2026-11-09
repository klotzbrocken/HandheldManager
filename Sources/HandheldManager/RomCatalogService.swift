import Foundation

private struct RomProjectRecord: Hashable, Sendable {
    let gameTitle: String
    let projectTitle: String
    let method: RomProjectMethod
    let status: String
    let sourceTitle: String
    let url: URL
}

private struct RomProjectDetails: Sendable {
    let platform: String?
    let status: String?
    let runsOn: String?
}

final class RomCatalogService {
    private let session: URLSession
    private var cachedIndex: [RomProjectRecord] = []
    private var cachedAt: Date?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration)
    }

    func lookup(games: [RomGame], forceRefresh: Bool = false) async throws -> [String: [RomProjectMatch]] {
        guard !games.isEmpty else { return [:] }
        let now = Date()
        let records: [RomProjectRecord]
        if !forceRefresh, let cachedAt, now.timeIntervalSince(cachedAt) < 6 * 60 * 60, !cachedIndex.isEmpty {
            records = cachedIndex
        } else {
            records = try await loadIndexes(for: games)
            cachedIndex = records
            cachedAt = now
        }

        var candidates: [String: [RomProjectRecord]] = [:]
        for game in games {
            let matching = records.filter { record in titlesMatch(game.title, record.gameTitle) }
            candidates[game.path] = Array(matching.prefix(6))
        }
        let uniqueRecords = Dictionary(candidates.values.flatMap { $0 }.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        let details = await loadDetails(Array(uniqueRecords.values))
        let gamePlatforms = Dictionary(games.map { ($0.path, $0.platform) }, uniquingKeysWith: { first, _ in first })
        var result: [String: [RomProjectMatch]] = [:]
        for (path, matches) in candidates {
            result[path] = matches.filter { record in
                platformsMatch(for: gamePlatforms[path] ?? "Unbekannt", record: record, detail: details[record.url.absoluteString])
            }.map { record in
                let detail = details[record.url.absoluteString]
                let support: AndroidProjectStatus
                if let runsOn = detail?.runsOn {
                    support = runsOn.localizedCaseInsensitiveContains("android") ? .supported : .notListed
                } else {
                    support = .notVerified
                }
                return RomProjectMatch(
                    gameTitle: record.gameTitle,
                    projectTitle: record.projectTitle,
                    method: record.method,
                    projectStatus: detail?.status ?? record.status,
                    androidStatus: support,
                    platform: detail?.platform,
                    sourceTitle: record.sourceTitle,
                    sourceURL: record.url
                )
            }
        }
        return result
    }

    private func loadIndexes(for games: [RomGame]) async throws -> [RomProjectRecord] {
        var results: [RomProjectRecord] = []
        let recompediaHTML = try await fetchHTML("https://recompedia.com/")
        results += parseRecompediaIndex(recompediaHTML)
        if games.contains(where: { $0.platform.localizedCaseInsensitiveContains("playstation 2") || $0.platform == "Unbekannt (ISO/Disc)" }) {
            if let html = try? await fetchHTML("https://recompsoftware.com/platforms/playstation-2/") {
                results += parseRecompSoftwarePS2(html)
            }
        }
        guard !results.isEmpty else { throw ManagerError.commandFailed("Die Recompedia-Kataloge enthalten keine auswertbaren Einträge.") }
        return results
    }

    private func loadDetails(_ records: [RomProjectRecord]) async -> [String: RomProjectDetails] {
        var values: [String: RomProjectDetails] = [:]
        for start in stride(from: 0, to: records.count, by: 6) {
            let batch = Array(records[start..<min(start + 6, records.count)])
            let chunk = await withTaskGroup(of: (String, RomProjectDetails?).self) { group in
                for record in batch {
                    group.addTask { [session] in
                        let key = record.url.absoluteString
                        guard let html = try? await Self.fetchHTML(session: session, url: record.url) else { return (key, nil) }
                        return (key, Self.parseDetails(html))
                    }
                }
                var batchValues: [String: RomProjectDetails] = [:]
                for await (key, details) in group {
                    if let details { batchValues[key] = details }
                }
                return batchValues
            }
            values.merge(chunk) { _, new in new }
        }
        return values
    }

    private func fetchHTML(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw ManagerError.commandFailed("Ungültige Katalogadresse.") }
        return try await Self.fetchHTML(session: session, url: url)
    }

    private static func fetchHTML(session: URLSession, url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("HandheldManager/1.0 (ROM project catalog)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw ManagerError.commandFailed("Projektkatalog antwortete nicht erfolgreich.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func parseRecompediaIndex(_ html: String) -> [RomProjectRecord] {
        let scripts = captureAll(#"(?is)<script\s+type=["']application/ld\+json["'][^>]*>(.*?)</script>"#, in: html)
        var records: [RomProjectRecord] = []
        for script in scripts {
            guard let data = script.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["@type"] as? String == "ItemList",
                  let items = json["itemListElement"] as? [[String: Any]] else { continue }
            for item in items {
                guard let name = item["name"] as? String, let address = item["url"] as? String,
                      let url = URL(string: address) else { continue }
                let pieces = name.components(separatedBy: " — ")
                let title = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
                let project = pieces.dropFirst().joined(separator: " — ")
                let method: RomProjectMethod = url.path.contains("/decomp/") ? .decompilation : .recompilation
                records.append(RomProjectRecord(gameTitle: title, projectTitle: project.isEmpty ? title : project, method: method, status: "", sourceTitle: "Recompedia", url: url))
            }
        }
        return records
    }

    private func parseRecompSoftwarePS2(_ html: String) -> [RomProjectRecord] {
        let headings = captureMatches(#"(?is)<h2\b[^>]*>(.*?)</h2>"#, in: html)
        var records: [RomProjectRecord] = []
        for index in headings.indices {
            let heading = Self.plainText(headings[index].group(1))
            let method: RomProjectMethod
            if heading.localizedCaseInsensitiveContains("static recomp") { method = .recompilation }
            else if heading.localizedCaseInsensitiveContains("decomp") { method = .decompilation }
            else if heading.localizedCaseInsensitiveContains("ports, rewrites") { method = .port }
            else { continue }
            let start = headings[index].range.upperBound
            let end = index + 1 < headings.count ? headings[index + 1].range.lowerBound : html.endIndex
            let section = String(html[start..<end])
            for row in captureAll(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, in: section) {
                let cells = captureAll(#"(?is)<td\b[^>]*>(.*?)</td>"#, in: row)
                guard cells.count >= 3,
                      let href = captureFirst(#"(?is)<a\b[^>]*href=["']([^"']+)["']"#, in: cells[0]),
                      let url = URL(string: href, relativeTo: URL(string: "https://recompsoftware.com"))?.absoluteURL else { continue }
                let project = Self.plainText(cells[0])
                let gameTitle = Self.plainText(cells[1]).replacingOccurrences(of: #"\s+\d{4}$"#, with: "", options: .regularExpression)
                let status = Self.plainText(cells[2])
                guard !project.isEmpty, !gameTitle.isEmpty else { continue }
                records.append(RomProjectRecord(gameTitle: gameTitle, projectTitle: project, method: method, status: status, sourceTitle: "Recomp Software", url: url))
            }
        }
        return records
    }

    private static func parseDetails(_ html: String) -> RomProjectDetails {
        RomProjectDetails(
            platform: definitionValue("Platform", html: html),
            status: definitionValue("Status", html: html),
            runsOn: definitionValue("Runs on", html: html)
        )
    }

    private static func definitionValue(_ label: String, html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        guard let value = captureFirst("(?is)<dt\\b[^>]*>\\s*\(escaped)\\s*</dt>\\s*<dd\\b[^>]*>(.*?)</dd>", in: html) else { return nil }
        let text = plainText(value)
        return text.isEmpty ? nil : text
    }

    private func titlesMatch(_ left: String, _ right: String) -> Bool {
        let a = normalizedTitle(left)
        let b = normalizedTitle(right)
        guard a.count >= 7, b.count >= 7 else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    private func platformsMatch(for gamePlatform: String, record: RomProjectRecord, detail: RomProjectDetails?) -> Bool {
        let isPS2 = gamePlatform.localizedCaseInsensitiveContains("playstation 2")
        let ambiguousDisc = gamePlatform == "Unbekannt (ISO/Disc)"
        if record.sourceTitle == "Recomp Software" { return isPS2 || ambiguousDisc }
        guard let listedPlatform = detail?.platform else { return ambiguousDisc }
        if ambiguousDisc { return true }
        let game = normalizedPlatform(gamePlatform)
        let listed = normalizedPlatform(listedPlatform)
        return game == listed || game.contains(listed) || listed.contains(game)
    }

    private func normalizedPlatform(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("playstation 2") || lower == "ps2" { return "ps2" }
        if lower.contains("playstation") && (lower.contains("portable") || lower.contains("psp")) { return "psp" }
        if lower.contains("playstation") && (lower.contains("1") || lower.contains("psx")) { return "ps1" }
        if lower.contains("nintendo 64") || lower == "n64" { return "n64" }
        if lower.contains("gamecube") || lower == "gc" { return "gamecube" }
        if lower.contains("dreamcast") { return "dreamcast" }
        return lower.filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedTitle(_ value: String) -> String {
        let noRegion = value.replacingOccurrences(of: #"\s*[\[(][^\])]*[\])\s]*"#, with: " ", options: [.regularExpression, .caseInsensitive])
        return noRegion.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func captureAll(_ pattern: String, in text: String) -> [String] {
        captureMatches(pattern, in: text).map { $0.group(1) }
    }

    private func captureFirst(_ pattern: String, in text: String) -> String? {
        captureMatches(pattern, in: text).first?.group(1)
    }

    private func captureMatches(_ pattern: String, in text: String) -> [(range: Range<String.Index>, group: (Int) -> String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (range, { index in
                guard index < match.numberOfRanges, let r = Range(match.range(at: index), in: text) else { return "" }
                return String(text[r])
            })
        }
    }

    private static func captureFirst(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func plainText(_ value: String) -> String {
        var result = value.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
