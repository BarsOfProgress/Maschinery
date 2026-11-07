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
scripts/verify-release-signatures.sh
scripts/package-dmg.sh
archive="dist/Maschinery-v$version-macOS.dmg"
git push origin "$branch"
git tag -a "$tag" "$commit" -m "Maschinery $version"
git push origin "refs/tags/$tag"
if [[ "${SIGNING_IDENTITY:-}" == '-' ]]; then
  notes='Universal macOS DMG (Apple Silicon and Intel), macOS 14+. Ad-hoc signed, no Developer ID or notarization. Gatekeeper may require approval in Privacy & Security. Full Install and privileged maintenance are unavailable. Review this draft before publishing.'
else
  notes='Universal macOS DMG (Apple Silicon and Intel), macOS 14+. Signed with the existing Apple identity; not notarized. Review this draft before publishing.'
fi
gh release create "$tag" "$archive" "$archive.sha256" --verify-tag --draft \
  --title "Maschinery $version" --notes "$notes"
