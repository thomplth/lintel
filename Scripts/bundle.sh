#!/bin/zsh
# Builds Lintel.app from the Swift package, signed for this Mac only, not for distribution.
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
# No LSUIElement: Launch Services then never sends the reopen event that makes a Dock click open the bar. main.swift
# starts Lintel as an accessory app, and AppController.applyDockPresence shows the Dock icon only when settings allow.
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
# An ad-hoc signature changes with every build, so the keychain treats each rebuild as a new app and asks for the
# login password again before Lintel can read its saved API keys. A certificate identity stays the same across builds.
# Only the login keychain is searched: an identity in another keychain, such as a CI keychain, makes codesign stop
# on a password prompt for that keychain.
login_identities=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db)
identity=${LINTEL_SIGN_IDENTITY:-$( {
    print -r -- "$login_identities" | sed -n 's/.*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p'
    print -r -- "$login_identities" | sed -n 's/.*) \([0-9A-F]\{40\}\) ".*/\1/p'
} | sed -n 1p)}
codesign --force --deep --sign "${identity:--}" "$app" >/dev/null
print "$app"
