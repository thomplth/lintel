#!/bin/zsh
# Builds Lintel.app from the Swift package. Ad-hoc signed: enough to run on this Mac, not to distribute.
set -euo pipefail
root=${0:A:h:h}
configuration=${1:-release}
cd "$root"
xcrun --sdk macosx swift build -c "$configuration"
products="$root/.build/$configuration"
app="$root/build/Lintel.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/Lintel" "$app/Contents/MacOS/Lintel"
cp -R "$products/Lintel_Lintel.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.lintel.Lintel</string>
  <key>CFBundleName</key><string>Lintel</string>
  <key>CFBundleDisplayName</key><string>Lintel</string>
  <key>CFBundleExecutable</key><string>Lintel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>macOS shares the Wi-Fi network name only with apps allowed to use your location.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Lintel Module</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>app.lintel.module</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.lintel.module</string>
      <key>UTTypeDescription</key><string>Lintel Module</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>lintelmodule</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$app" >/dev/null
print "$app"
