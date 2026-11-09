#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build

APP="$ROOT/.build/HandheldManager.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/debug/HandheldManager" "$APP/Contents/MacOS/HandheldManager"
cp "$ROOT/Resources/HandheldManager.icns" "$APP/Contents/Resources/HandheldManager.icns"
cp -R "$ROOT/Resources/de.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"

PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HandheldManager</string>
  <key>CFBundleIdentifier</key><string>local.handheldmanager.dev</string>
  <key>CFBundleName</key><string>Handheld Manager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile HandheldManager' "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string HandheldManager' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion de' "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string de' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconName HandheldManager' "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string HandheldManager' "$PLIST"
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations' "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleLocalizations array' "$PLIST"
fi
for locale in de en; do
  if ! /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations:$( [ "$locale" = de ] && echo 0 || echo 1 )" "$PLIST" 2>/dev/null | grep -q "^$locale$"; then
    if [ "$locale" = de ]; then index=0; else index=1; fi
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:$index string $locale" "$PLIST" 2>/dev/null || true
  fi
done
xattr -cr "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
if ! codesign --force --deep --sign - "$APP"; then
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
  codesign --force --deep --sign - "$APP" || true
fi
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
if ! codesign --verify --deep --strict "$APP"; then
  print "Note: this workspace adds Finder/file-provider metadata that prevents strict bundle signature verification." >&2
fi
print "Packaged: $APP"
