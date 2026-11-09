import XCTest
@testable import HandheldManager

final class RemotePathTests: XCTestCase {
    let volume = StorageVolume(id: "v", name: "Intern", path: "/storage/emulated/0", kind: .internalStorage, readable: true, writable: true, capacity: nil)

    func testNormalizesInsideVolume() throws {
        XCTAssertEqual(try RemotePath.normalized("/storage/emulated/0//ROMs/", within: volume), "/storage/emulated/0/ROMs")
        XCTAssertEqual(try RemotePath.normalized("/storage/emulated/0", within: volume), "/storage/emulated/0")
    }

    func testRejectsEscapesAndGarbage() {
        for bad in ["relative/path", "/storage/emulated/0/../x", "/storage/emulated/0/./x", "/storage/emulated/01/x",
                    "/sdcard/x", "/storage/emulated/0/a\nb", "/storage/emulated/0/a\0b"] {
            XCTAssertThrowsError(try RemotePath.normalized(bad, within: volume), bad)
        }
    }

    func testChildRejectsBadNames() throws {
        XCTAssertEqual(try RemotePath.child("a.sfc", of: "/storage/emulated/0/ROMs", within: volume), "/storage/emulated/0/ROMs/a.sfc")
        for bad in ["", ".", "..", "a/b"] { XCTAssertThrowsError(try RemotePath.child(bad, of: "/storage/emulated/0", within: volume), bad) }
    }

    func testShellQuote() {
        XCTAssertEqual(RemotePath.shellQuote("it's"), "'it'\\''s'")
    }
}

final class ParseLSLineTests: XCTestCase {
    func testFileWithSpaces() {
        let e = DeviceFileService.parseLSLine("-rw-rw---- 1 0 1015 12345 2024-05-01 10:22 My Game (USA).sfc", directory: "/sdcard/ROMs")
        XCTAssertEqual(e?.name, "My Game (USA).sfc")
        XCTAssertEqual(e?.path, "/sdcard/ROMs/My Game (USA).sfc")
        XCTAssertEqual(e?.size, 12345)
        XCTAssertEqual(e?.isDirectory, false)
    }

    func testDirectoryAtRoot() {
        let e = DeviceFileService.parseLSLine("drwxrws--- 2 0 1015 4096 2024-05-01 10:22 Roms", directory: "/")
        XCTAssertEqual(e?.path, "/Roms")
        XCTAssertEqual(e?.isDirectory, true)
    }

    func testSkipsDotsSymlinksAndHeaders() {
        XCTAssertNil(DeviceFileService.parseLSLine("drwxrws--- 2 0 1015 4096 2024-05-01 10:22 .", directory: "/x"))
        XCTAssertNil(DeviceFileService.parseLSLine("drwxrws--- 2 0 1015 4096 2024-05-01 10:22 ..", directory: "/x"))
        XCTAssertNil(DeviceFileService.parseLSLine("lrwxrwxrwx 1 0 0 11 2024-05-01 10:22 sdcard -> /x/y", directory: "/x"))
        XCTAssertNil(DeviceFileService.parseLSLine("total 12", directory: "/x"))
    }
}

final class VersionCompareTests: XCTestCase {
    func testNumericOrdering() {
        XCTAssertTrue(AppUpdateService.compareVersionStrings("1.10", "1.9"))
        XCTAssertFalse(AppUpdateService.compareVersionStrings("1.9", "1.10"))
        XCTAssertFalse(AppUpdateService.compareVersionStrings("2.0", "2.0"))
    }

    func testLongerVersionIsNewer() {
        XCTAssertTrue(AppUpdateService.compareVersionStrings("1.2.1", "1.2"))
        XCTAssertFalse(AppUpdateService.compareVersionStrings("1.2", "1.2.1"))
    }

    func testBaseVersionExtraction() {
        XCTAssertEqual(AppUpdateService.baseVersion("v1.2.3-beta"), "1.2.3")
        XCTAssertNil(AppUpdateService.baseVersion("nightly"))
    }
}

final class RomTitleTests: XCTestCase {
    func testStripsStackedTags() {
        let game = RomGame(path: "/x/Crazy Taxi (USA) (Disc 1) [SLUS-12345].gdi", sizeBytes: 1, platform: "Dreamcast", fileExtension: "gdi")
        XCTAssertEqual(game.title, "Crazy Taxi")
    }
}

final class RomImportTests: XCTestCase {
    func testPlatformFromExtensionAndFolder() {
        XCTAssertEqual(RomLibraryService.importPlatform(for: URL(fileURLWithPath: "/a/Game.gdi")), "Dreamcast")
        XCTAssertEqual(RomLibraryService.importPlatform(for: URL(fileURLWithPath: "/a/Game.iso")), "")   // ambiguous: user must choose
        XCTAssertEqual(RomLibraryService.folderPlatform("dreamcast"), "Dreamcast")
        XCTAssertEqual(RomLibraryService.folderPlatform("PS2"), "PlayStation 2")
        XCTAssertNil(RomLibraryService.folderPlatform("Backups"))
    }

    func testSignatureMismatchMessage() {
        let error = InstallFailure.friendly(ManagerError.commandFailed("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: x]"))
        XCTAssertTrue(error.localizedDescription.contains(InstallFailure.signatureMismatch))
    }
}
