#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
identity="${SIGNING_IDENTITY:-}"
keychain_args=()
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
  keychain_args=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ -z "$identity" ]]; then
  discovery_args=()
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then discovery_args=("$SIGNING_KEYCHAIN"); fi
  identities=$(/usr/bin/security find-identity -v -p codesigning "${discovery_args[@]}")
  hashes=("${(@f)$(print -r -- "$identities" | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) .*/\1/p')}")
  if (( ${#hashes} != 1 )) || [[ -z "${hashes[1]}" ]]; then
    print -u2 'Could not select one signing identity. Set SIGNING_IDENTITY to an existing certificate SHA-1 or full name.'
    print -u2 'A sandbox can hide login Keychain identities; retry outside it before concluding a certificate is missing.'
    print -u2 'For an intentional ad-hoc build only, set SIGNING_IDENTITY=- (use the Full Install package for privileged features).'
    exit 1
  fi
  identity="${hashes[1]}"
fi
print -r -- "Signing identity: $identity"
for arch in arm64 x86_64; do
  swift build --disable-sandbox --build-system native -c release --arch "$arch" --scratch-path ".build/$arch"
done
app='dist/Maschinery.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
cp Helper/local.maschinery.helper.plist "$app/Contents/Library/LaunchDaemons/"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Sources/MaschineryCore/Resources/ExpansionCatalogue.json "$app/Contents/Resources/ExpansionCatalogue.json"
armbin=$(swift build --disable-sandbox --build-system native -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)
intelbin=$(swift build --disable-sandbox --build-system native -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)
# Keep the SwiftPM resource bundle relocatable inside the app’s Resources.
if [[ -d "$armbin/Maschinery_MaschineryCore.bundle" ]]; then
  cp -R "$armbin/Maschinery_MaschineryCore.bundle" "$app/Contents/Resources/"
fi
lipo -create "$armbin/Maschinery" "$intelbin/Maschinery" -output "$app/Contents/MacOS/Maschinery"
lipo -create "$armbin/MaschineryHelper" "$intelbin/MaschineryHelper" -output "$app/Contents/Library/LaunchServices/MaschineryHelper"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.maschinery.app</string>
<key>CFBundleName</key><string>Maschinery</string>
<key>CFBundleDisplayName</key><string>Maschinery</string>
<key>CFBundleExecutable</key><string>Maschinery</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.5</string>
<key>CFBundleVersion</key><string>2</string>
<key>MaschineryReleaseVersion</key><string>1.0.5r1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ "$identity" == '-' ]]; then
  codesign --force --preserve-metadata=entitlements --options runtime --sign - --identifier local.maschinery.helper "$app/Contents/Library/LaunchServices/MaschineryHelper"
  codesign --force --preserve-metadata=entitlements --options runtime --sign - --identifier local.maschinery.app "$app"
else
  codesign --force --preserve-metadata=entitlements --options runtime --timestamp --sign "$identity" "${keychain_args[@]}" --identifier local.maschinery.helper "$app/Contents/Library/LaunchServices/MaschineryHelper"
  codesign --force --preserve-metadata=entitlements --options runtime --timestamp --sign "$identity" "${keychain_args[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 --all-architectures "$app"
lipo -archs "$app/Contents/Library/LaunchServices/MaschineryHelper"
lipo -archs "$app/Contents/MacOS/Maschinery"

# The setup executable is only run by administrator-authorized package scripts.
lipo -create "$armbin/MaschinerySetup" "$intelbin/MaschinerySetup" -output dist/MaschinerySetup
if [[ "$identity" == '-' ]]; then
  codesign --force --options runtime --sign - --identifier local.maschinery.setup dist/MaschinerySetup
else
  codesign --force --options runtime --timestamp --sign "$identity" "${keychain_args[@]}" --identifier local.maschinery.setup dist/MaschinerySetup
fi
codesign --verify --strict --all-architectures dist/MaschinerySetup
