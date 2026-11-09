import Foundation

enum EmulatorCatalog {
    private static let names: [String: String] = [
        "org.ppsspp.ppsspp": "PPSSPP",
        "org.ppsspp.ppssppgold": "PPSSPP Gold",
        "com.retroarch": "RetroArch",
        "com.retroarch.aarch64": "RetroArch (64-bit)",
        "com.retroarch.ra32": "RetroArch (32-bit)",
        "org.dolphinemu.dolphinemu": "Dolphin Emulator",
        "com.dolphinemu.dolphinemu": "Dolphin Emulator",
        "com.dolphinemu.mmjr": "Dolphin MMJR",
        "com.dolphinemu.mmjr2": "Dolphin MMJR2",
        "org.mupen64plusae.v3.fzurita": "M64Plus FZ Emulator",
        "org.mupen64plusae.v3.fzurita.pro": "M64Plus FZ Pro",
        "com.github.stenzek.duckstation": "DuckStation",
        "com.dsemu.drastic": "DraStic DS Emulator",
        "xyz.aethersx2.android": "AetherSX2 / NetherSX2",
        "xyz.aethersx2.cturnip": "NetherSX2 Turnip",
        "org.citra.citra_emu": "Citra Emulator",
        "org.citra.emu": "Citra Emulator",
        "org.citra.citra_emu.canary": "Citra Canary",
        "io.github.lime3ds.android": "Lime3DS",
        "org.azahar_emu.azahar": "Azahar Emulator",
        "org.citron.citron_emu": "Citron NEO",
        "dev.legacy.eden_emulator.nightly": "Eden Nightly",
        "info.cemu.cemu": "Cemu",
        "org.vita3k.emulator": "Vita3K",
        "org.melonds.android": "melonDS",
        "me.magnum.melonds": "melonDS",
        "me.magnum.melonds.nightly": "melonDS Nightly",
        "org.yuzu.yuzu_emu": "yuzu Emulator",
        "org.yuzu.yuzu_emu.ea": "yuzu Early Access",
        "org.sudachi.sudachi_emu": "Sudachi Emulator",
        "org.suyu.suyu_emu": "Suyu Emulator",
        "org.skyline.emulator": "Skyline Emulator",
        "org.ryujinx.android": "Ryujinx Android",
        "org.leaf.emulator": "Yuzu Fork Emulator",
        "com.xiaoji.eggns": "Egg NS Emulator",
        "com.snes9x.explusalpha": "Snes9x EX+",
        "com.bubblezapgames.supergnes": "SuperGNES",
        "com.explusalpha.NesEmu": "NES.emu",
        "com.explusalpha.Snes9xPlus": "SNES9x EX+",
        "com.explusalpha.MdEmu": "MD.emu",
        "com.explusalpha.GbEmu": "GBA.emu",
        "com.explusalpha.NeoEmu": "NEO.emu",
        "com.explusalpha.PceEmu": "PCE.emu",
        "com.explusalpha.C64Emu": "C64.emu",
        "com.explusalpha.PsEmu": "2600.emu",
        "com.explusalpha.MsxEmu": "MSX.emu",
        "com.explusalpha.NgpEmu": "NGP.emu",
        "com.explusalpha.WsEmu": "WonderSwan.emu",
        "com.virtualapplications.play": "Lemuroid"
    ]

    static func annotate(_ packages: [InstalledPackage]) -> [InstalledPackage] {
        packages.map { package in
            var result = package
            if package.packageName.hasPrefix("org.vita3k.emulator.") {
                result.displayName = "Vita3K"
                result.isEmulator = true
            } else if package.packageName == "xyz.aethersx2.android", package.versionName?.localizedCaseInsensitiveContains("2.2n") == true {
                result.displayName = "NetherSX2 Classic"
                result.isEmulator = true
            } else if let name = names[package.packageName] {
                result.displayName = name
                result.isEmulator = true
            } else {
                result.displayName = package.packageName
                result.isEmulator = false
            }
            return result
        }
    }

    static func knownEmulators(in packages: [InstalledPackage]) -> [InstalledPackage] {
        annotate(packages).filter { $0.isEmulator == true }
    }

    static func compatiblePlatforms(packageName: String) -> Set<String> {
        switch packageName {
        case "org.ppsspp.ppsspp", "org.ppsspp.ppssppgold": return ["PSP"]
        case "com.dolphinemu.dolphinemu", "org.dolphinemu.dolphinemu", "com.dolphinemu.mmjr", "com.dolphinemu.mmjr2": return ["GameCube", "Wii"]
        case "org.mupen64plusae.v3.fzurita", "org.mupen64plusae.v3.fzurita.pro": return ["Nintendo 64"]
        case "com.github.stenzek.duckstation": return ["PlayStation"]
        case "xyz.aethersx2.android", "xyz.aethersx2.cturnip": return ["PlayStation 2"]
        case "org.azahar_emu.azahar", "io.github.lime3ds.android", "org.citra.citra_emu", "org.citra.emu", "org.citra.citra_emu.canary": return ["Nintendo 3DS"]
        case "org.vita3k.emulator", "org.vita3k.emulator.ikhoeyZX": return ["PlayStation Vita"]
        case "org.melonds.android", "me.magnum.melonds", "me.magnum.melonds.nightly": return ["Nintendo DS"]
        case "com.dsemu.drastic": return ["Nintendo DS"]
        case "org.yuzu.yuzu_emu", "org.yuzu.yuzu_emu.ea", "org.sudachi.sudachi_emu", "org.suyu.suyu_emu", "org.skyline.emulator", "org.ryujinx.android", "org.leaf.emulator", "com.xiaoji.eggns", "org.citron.citron_emu", "dev.legacy.eden_emulator.nightly": return ["Nintendo Switch"]
        case "info.cemu.cemu": return ["Wii U"]
        case "com.snes9x.explusalpha", "com.bubblezapgames.supergnes", "com.explusalpha.Snes9xPlus": return ["SNES"]
        case "com.explusalpha.NesEmu": return ["NES"]
        case "com.explusalpha.GbEmu": return ["Game Boy Advance"]
        case "com.virtualapplications.play": return ["NES", "SNES", "Game Boy", "Game Boy Color", "Game Boy Advance", "Nintendo DS", "Nintendo 64", "PlayStation"]
        case "com.retroarch", "com.retroarch.aarch64", "com.retroarch.ra32": return ["*"]
        default: return []
        }
    }
}
