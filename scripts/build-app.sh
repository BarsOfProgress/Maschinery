#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
for arch in arm64 x86_64; do
  swift build --disable-sandbox --build-system native -c release --arch "$arch" --scratch-path ".build/$arch"
done
app='dist/Maschine Machine.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
cp Helper/local.maschinemachine.helper.plist "$app/Contents/Library/LaunchDaemons/"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
armbin=$(swift build --disable-sandbox --build-system native -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)
intelbin=$(swift build --disable-sandbox --build-system native -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)
lipo -create "$armbin/MaschineMachine" "$intelbin/MaschineMachine" -output "$app/Contents/MacOS/MaschineMachine"
lipo -create "$armbin/MaschineHelper" "$intelbin/MaschineHelper" -output "$app/Contents/Library/LaunchServices/MaschineHelper"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.maschinemachine.app</string>
<key>CFBundleName</key><string>Maschine Machine</string>
<key>CFBundleDisplayName</key><string>Maschine Machine</string>
<key>CFBundleExecutable</key><string>MaschineMachine</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
  codesign --force --sign - --identifier local.maschinemachine.helper "$app/Contents/Library/LaunchServices/MaschineHelper"
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" --identifier local.maschinemachine.helper "$app/Contents/Library/LaunchServices/MaschineHelper"
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
lipo -archs "$app/Contents/Library/LaunchServices/MaschineHelper"
lipo -archs "$app/Contents/MacOS/MaschineMachine"
