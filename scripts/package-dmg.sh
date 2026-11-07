#!/bin/zsh
# Package an already-built app without modifying its signature or resources.
set -euo pipefail
cd "${0:A:h}/.."
app='dist/Maschinery.app'
[[ -d "$app" ]] || { print -u2 'Build dist/Maschinery.app before packaging.'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid app release version'; exit 1; }
/usr/bin/codesign --verify --deep --strict --all-architectures "$app"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/Maschinery-DMG.XXXXXXXX")
trap 'rm -rf -- "$workspace"' EXIT
mkdir "$workspace/payload"
/usr/bin/ditto "$app" "$workspace/payload/Maschinery.app"
ln -s /Applications "$workspace/payload/Applications"
/usr/bin/hdiutil create -volname "Maschinery" -srcfolder "$workspace/payload" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$workspace/Maschinery.dmg"
/usr/bin/hdiutil verify "$workspace/Maschinery.dmg"
artifact="dist/Maschinery-v$version-macOS.dmg"
mv "$workspace/Maschinery.dmg" "$artifact"
(cd dist && /usr/bin/shasum -a 256 "${artifact:t}" > "${artifact:t}.sha256")
print -r -- "Verified DMG: $artifact"
