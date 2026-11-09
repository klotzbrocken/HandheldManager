# Handheld Manager

> **Early version.** Developed and tested on a Retroid Pocket Flip 2 only. Expect rough edges on other devices and Android builds. Feedback and issues are welcome.

Beyond the list below, the app now has a ROM library (covers from Libretro Thumbnails, drag-and-drop import into the matching console folder, rename/delete/cover search via context menu), one-click update download from official GitHub releases with signature checks, and a task-oriented sidebar.

SwiftUI macOS application for managing Android handhelds over explicitly authorized USB-ADB.

## MVP scope implemented

- Runtime device discovery and selection; every device command is pinned to its ADB serial.
- Read-only build, Android version, package inventory, storage-volume and capability discovery.
- File browser for mounted shared storage, one-file upload/download with SHA-256 verification, explicit replacement confirmation, local backup of replaced files, and same-volume quarantine for individual file deletion.
- Versioned emulator profile bundles with a generic file adapter. Any installed third-party package can be selected; profiles are bound to package ID and, when available, app version. Profile apply includes preview, local backup, staged transfer, hash verification and rollback.
- APK installation and updates with manifest/package/version inspection, APK SHA-256, `apksigner` certificate SHA-256 verification, installed-app signer matching, downgrade blocking, split-APK installation, and post-install version/signature verification.
- Device-wide Android Home launcher discovery. On builds that expose AOSP `cmd package set-home-activity`, a selected launcher can be set remotely after confirmation; otherwise the app opens Android's visible Home selection.
- Local package-ID catalog for common emulator apps, with readable names in the overview and profile selector. Unknown packages retain their package ID.
- Emulator config export from explicitly entered, ADB-reachable device paths to a local folder with SHA-256 verification. Imported local files can be bundled as profiles and previewed/applied back to the device.
- Shared-storage scan that ranks up to 250 reachable files by size, plus individual quarantine and undo for selected files.
- A whitelist of documented Android Settings intents, probed against the connected build before launch, with fallback to the general Settings screen.
- A firmware guide for recognized Retroid Pocket Flip 2 and ANBERNIC RG Rotate devices. It opens official manufacturer pages, shows device-reported version/build context, calculates a local firmware SHA-256 and compares it with an optional manufacturer-published digest. It never flashes or sideloads firmware.
- Optional Flip 2 Snapdragon temporary boot-image flow, guarded to build 1.0.0.130, the exact local image name/format, a rechecked SHA-256 and matching ADB/Fastboot serial. It invokes only `fastboot boot`, never `fastboot flash`.

The profile mechanism is emulator-neutral. It does not assume that every emulator uses the same file format or path. The user chooses the config files and a reachable destination directory. App-private data and Android SAF grants are not bypassed; use the emulator's own export/import workflow when its config is private.

## Run

Requires macOS 14 or later, Swift 5.9+, Android Platform Tools, and Android SDK Build Tools for APK handling. The app looks for `adb` in its bundled `platform-tools` resource folder, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, then the current `PATH`. APK handling locates `aapt` and `apksigner` under `ANDROID_SDK_ROOT`, `ANDROID_HOME`, `~/Library/Android/sdk`, or `/usr/local/share/android-sdk`.

```sh
swift run HandheldManager
```

Enable Developer Options and USB Debugging on the handheld, connect it by USB, unlock it, and approve the RSA fingerprint. Wireless debugging is not set up automatically.

In **Apps & Launcher**, select a single APK or all APK files from one split set. The app stages selected files locally, checks that package name, version and signer match across the set, and displays hashes before explicit install confirmation. Updates must use the installed signing certificate and cannot downgrade. Android receives `install -r` for one APK or `install-multiple -r` for a split set; afterward the app confirms the installed version and signer. No app is uninstalled to work around a signature mismatch. If SDK Build Tools are missing, install them with Android Studio's SDK Manager and set `ANDROID_SDK_ROOT` or `ANDROID_HOME` before launching the app.

The launcher panel lists Home activities and the resolved current activity. It probes the package-manager help output for `set-home-activity`; when supported, a selected installed Home app can be set remotely after a confirmation dialog. Other builds fall back to Android's Home settings. Android documents this command in AOSP's package-manager shell reference.

In **System & Firmware**, the app probes a fixed list of public Android Settings actions on the connected build; missing pages fall back to general Settings. The firmware guide only appears for recognized target device families. It opens the official Retroid product page (which documents OTA support) or the ANBERNIC system update page. The shown ANBERNIC RG ROTATE V1.44 listing was checked on 2026-11-08; verify the exact OS, region, and model on the live manufacturer page. A locally computed package hash is not an authenticity check unless it matches a checksum published by the manufacturer. The app does not start firmware installation.

In **Emulatorprofile**, common emulator package IDs receive readable names. To back up current configuration, enter one reachable device path per line and choose a local output folder; each file is pulled and hash-checked. To transfer new configuration, select local files, create/import a profile, choose its device target and package, preview, then apply. Emulator-private data and SAF-only paths remain unavailable to this ADB workflow.

In **Speicheranalyse**, scan a chosen shared-storage volume to list at most 250 large files (recursion depth 8). Each selected file can be moved to same-volume quarantine and restored, or permanently deleted after a second confirmation and an exact path/size recheck. A scan only includes files that ADB can reach; app-private caches and protected directories are not a complete storage report.

The Flip 2 overclock panel is an experimental community-image workflow. The supplied file at `~/Downloads/Banners-flip-2-905OC-forFW130.img` is recognized as an Android boot image; its local SHA-256 is `67d800976e98fae030918a33236b9420f0ca9eb86ac62802fae5a80ad8f59c1e`. That is not a publisher checksum. The maintainer's releases distinguish Flip 2 Snapdragon images by firmware, and their warnings mention root and warranty effects. The app requires the detected Flip 2 Snapdragon build 1.0.0.130, checks the matching device serial again in Fastboot, and requires a separate confirmation before `fastboot boot`. It does not verify image provenance or guarantee that the image is root-free or safe. Follow the [maintainer release instructions](https://github.com/The412Banner/Banners-No-PC-Retroid-Overclock/releases) and consider the manufacturer warranty before proceeding.

## Emulator profile JSON

Schema version 1 uses a package identifier, optional exact app version, relative file destinations, Base64-encoded bytes (`contents`, Foundation `Data` JSON representation), and SHA-256 per file. The target directory is selected separately in the app.

```json
{
  "schemaVersion": 1,
  "id": "00000000-0000-0000-0000-000000000000",
  "name": "Example profile",
  "packageName": "org.example.emulator",
  "appVersion": "1.2.3",
  "createdAt": "2026-11-08T12:00:00Z",
  "files": [
    {
      "relativePath": "settings.ini",
      "sha256": "<64 lowercase hex characters>",
      "contents": "<Base64 file bytes>"
    }
  ]
}
```

The profile name, package name, selected target path, file list, size, existing-file status and hashes are shown before applying. Existing files are backed up in `~/Library/Application Support/HandheldManager/ProfileBackups`; backups remain local and are not cloud-synced. The most recent valid backup can be rolled back from the app.

## Safety boundaries

- No `su` or free-form shell UI, persistent firmware flashing, package uninstall or silent target deletion. The separate experimental Flip 2 feature can execute a user-selected boot image once with `fastboot boot` after two explicit confirmations.
- The file browser is scoped to mounted shared-storage roots. Directories are navigable; quarantine is offered for individual files only.
- Upload replacement needs explicit confirmation and saves a verified local backup first. Downloads do not overwrite an existing local file silently.
- Profile paths must be relative to the selected storage root; `..`, absolute paths and duplicate destinations are rejected.
- The generic adapter can only edit files reachable through ADB. It reports errors when a user-selected path is private or unavailable.
- Diagnostic output is not uploaded. Device serials are used for command targeting and are not written to an audit export.

## Current technical limits

- File sync is intentionally file-by-file in this MVP; it does not mirror directories or remove unmatched files.
- Emulator package discovery lists third-party packages; the user chooses which package is an emulator. There are no hard-coded per-emulator path assumptions.
- The app does not install ADB; Platform Tools must be installed or bundled by a future signed distribution build.
- APK installation is limited to APK files supplied by the user; there is no catalog or automatic download. Android controls the visible launcher selection, and devices with only one Home handler cannot present a choice.
- The settings whitelist only opens pages. It does not change protected/global settings. Firmware lookup is manufacturer-guidance only and does not validate package compatibility beyond a user-entered SHA-256 comparison.
- Wireless pairing and SAF companion workflows are outside these implemented phases.
