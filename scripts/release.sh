#!/bin/zsh
# Build locally with the existing Keychain identity and upload a draft release.
set -euo pipefail
cd "${0:A:h}/.."
if ! command -v gh >/dev/null; then
  print -u2 'Install GitHub CLI (brew install gh), then run gh auth login.'
  exit 1
fi
gh auth status >/dev/null
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 'Commit all intended source changes before releasing; the build must match its Git tag.'
  exit 1
fi
git remote get-url origin >/dev/null
branch=$(git symbolic-ref --short HEAD)
commit=$(git rev-parse HEAD)
scripts/test-native.sh
scripts/build-app.sh
app='dist/Maschinery.app'
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid app version'; exit 1; }
tag="v$version"
if git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  print -u2 "Tag $tag already exists; increment the app version before releasing."
  exit 1
fi
# An ad-hoc signature cannot authorize the privileged helper.
app_team=""
for executable in "$app" "$app/Contents/Library/LaunchServices/MaschineryHelper"; do
  /usr/bin/codesign --verify --strict --all-architectures "$executable"
  signature=$(/usr/bin/codesign -dv "$executable" 2>&1)
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
archive="dist/Maschinery-$version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
git push origin "$branch"
git tag -a "$tag" "$commit" -m "Maschinery $version"
git push origin "refs/tags/$tag"
gh release create "$tag" "$archive" "$archive.sha256" --verify-tag --draft \
  --title "Maschinery $version" --notes 'Universal macOS build (Apple Silicon and Intel). Requires macOS 14 or later. Signed with the existing Apple identity; not notarized. Review this draft before publishing.'
