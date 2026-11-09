import Foundation

enum FirmwareGuideCatalog {
    private static let retroidURL = URL(string: "https://www.goretroid.com/en-gb/products/retroid-pocket-flip-2")!
    private static let anbernicURL = URL(string: "https://anbernic.com/en-gb/pages/system-update")!

    static func guide(for descriptor: DeviceDescriptor?) -> FirmwareGuide? {
        guard let descriptor else { return nil }
        let identity = [descriptor.manufacturer, descriptor.model, descriptor.device, descriptor.connection.product ?? "", descriptor.connection.model ?? ""]
            .joined(separator: " ").lowercased()
        if identity.contains("retroid") && identity.contains("flip") {
            let exact = ["retroid pocket flip 2", "rp flip 2", "rp flip2", "flip 2"].contains(where: identity.contains)
            let match: FirmwareGuide.Match = exact ? .verifiedModel : .possibleModel
            return FirmwareGuide(
                id: "retroid-flip-2", title: "Retroid Pocket Flip 2", manufacturer: "Retroid", officialURL: retroidURL,
                guidance: "Retroid führt Android 13 und offiziellen OTA-Support auf der Produktseite auf. Das Update muss über die Updatefunktion am Handheld erfolgen. Für dieses Gerät wird hier kein Firmwarepaket heruntergeladen oder geflasht.",
                listedRelease: "Android 13 · OTA-Support laut offizieller Produktseite", sourceCheckedAt: "2026-11-08", match: match
            )
        }
        if identity.contains("anbernic") && (identity.contains("rotate") || identity.contains("rgrotate")) {
            let exact = identity.contains("rotate")
            return FirmwareGuide(
                id: "anbernic-rg-rotate", title: "ANBERNIC RG Rotate", manufacturer: "ANBERNIC", officialURL: anbernicURL,
                guidance: "Die offizielle Seite listet RG ROTATE -V1.44. Das Gerät und die dortige Firmwarevariante müssen auf der Herstellerseite abgeglichen werden. Der Eintrag allein belegt nicht, dass das Paket für Android statt Linux bestimmt ist.",
                listedRelease: "RG ROTATE -V1.44 laut offizieller Update-Seite", sourceCheckedAt: "2026-11-08", match: exact ? .verifiedModel : .possibleModel
            )
        }
        return nil
    }
}

enum FirmwareChecksumService {
    static func sha256(of url: URL) async throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .utility) { try Hash.sha256(file: url) }.value
    }

    static func normalized(_ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range]).lowercased()
    }
}
