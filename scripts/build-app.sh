#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
for arch in arm64 x86_64; do
  swift build --disable-sandbox --build-system native -c release --arch "$arch" --scratch-path ".build/$arch"
done
app='dist/Maschine Machine.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
armbin=$(swift build --disable-sandbox --build-system native -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)
intelbin=$(swift build --disable-sandbox --build-system native -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)
lipo -create "$armbin/MaschineMachine" "$intelbin/MaschineMachine" -output "$app/Contents/MacOS/MaschineMachine"
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
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
lipo -archs "$app/Contents/MacOS/MaschineMachine"
