#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app='dist/Maschinery.app'
/usr/bin/codesign --verify --deep --strict --verbose=2 --all-architectures "$app"
app_team=""
for executable identifier in "$app" local.maschinery.app "$app/Contents/Library/LaunchServices/MaschineryHelper" local.maschinery.helper; do
  arches=$(/usr/bin/lipo -archs "$executable/Contents/MacOS/Maschinery" 2>/dev/null || /usr/bin/lipo -archs "$executable")
  [[ " $arches " == *' arm64 '* && " $arches " == *' x86_64 '* ]] || { print -u2 "Not Universal 2: $executable"; exit 1; }
  for arch in arm64 x86_64; do
    /usr/bin/codesign --verify --strict --verbose=2 --arch "$arch" "$executable"
    signature=$(/usr/bin/codesign -d --verbose=4 --arch "$arch" "$executable" 2>&1)
    print -r -- "$signature" | /usr/bin/grep -Fxq "Identifier=$identifier"
    if [[ "${SIGNING_IDENTITY:-}" == '-' ]]; then
      print -r -- "$signature" | /usr/bin/grep -Fxq 'Signature=adhoc'
    else
      if ! print -r -- "$signature" | /usr/bin/grep -Eq '^Authority=(Apple Development:|Developer ID Application:)'; then
        print -u2 'Expected an Apple signing identity. For an intentional ad-hoc release set SIGNING_IDENTITY=-.'
        exit 1
      fi
      team=$(print -r -- "$signature" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
      if [[ -z "$team" || "$team" == 'not set' || ( -n "$app_team" && "$team" != "$app_team" ) ]]; then
        print -u2 'App and helper must have the same valid Apple Team ID.'
        exit 1
      fi
      app_team="$team"
    fi
  done
done
