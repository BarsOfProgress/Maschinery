#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app='dist/Maschinery.app'
# An ad-hoc signature cannot authorize the privileged helper.
app_team=""
for executable in "$app" "$app/Contents/Library/LaunchServices/MaschineryHelper"; do
  /usr/bin/codesign --verify --strict --all-architectures "$executable"
  signature=$(/usr/bin/codesign -d --verbose=4 "$executable" 2>&1)
  if ! print -r -- "$signature" | /usr/bin/grep -Eq '^Authority=(Apple Development:|Developer ID Application:)'; then
    print -u2 'Releases require the existing Apple Development or Developer ID identity, not ad-hoc signing.'
    exit 1
  fi
  team=$(print -r -- "$signature" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
  if [[ -z "$team" || "$team" == 'not set' || ( -n "$app_team" && "$team" != "$app_team" ) ]]; then
    print -u2 'App and helper must have the same valid Apple Team ID.'
    exit 1
  fi
  app_team="$team"
done
