# Maschinery DMG releases without a paid Apple account

GitHub releases require **no Apple certificates, signing secrets, paid membership, Developer ID or notarization credentials**. The macOS distribution is `Maschinery-vVERSION-macOS.dmg` plus its SHA-256 checksum. It contains the Universal 2 app and an `Applications` symlink to `/Applications`, compressed read-only as UDZO with zlib level 9.

## GitHub Actions

`.github/workflows/release.yml` runs on **macos-15** when a `v*` tag is pushed, or manually from Actions with an existing release tag. Use a new tag containing these workflow/script changes; do not move older release tags. The tag must match the checked-out commit and compiled app version.

The workflow runs the existing XCTest suite and Release build for **arm64 and x86_64**. `SIGNING_IDENTITY=-` explicitly selects ad-hoc signing. The helper is signed first, then the outer app; existing entitlements are preserved when re-signing, and bundle IDs, helper plist/Mach service configuration and XPC security requirements remain unchanged. The project currently has no separate entitlement files or additional bundled executable components beyond the app and helper.

`scripts/verify-release-signatures.sh` checks deep/strict validity, both architectures, expected identifiers and ad-hoc signatures. A read-only Security-framework probe checks the helper trust limitation. The workflow then packages the DMG, verifies it with `hdiutil verify`, generates a SHA-256 sidecar and uses `gh release create` or `gh release upload` to attach both assets to a **draft** GitHub Release. Review the draft before publishing. It refuses asset overwrites and published-release modifications and does not delete other platform artifacts. Any failed test, build, signing check, packaging, verification or upload fails the job.

The automatic `GITHUB_TOKEN` has `contents: write`; no PAT or Apple GitHub Secrets are required. The **release** GitHub environment may have reviewers/deployment rules configured by the repository owner. Old certificate secrets, if present, are not accessed and may be removed manually. No certificate, Keychain import or notarization step runs.

## Local releases

Install GitHub CLI and authenticate (`gh auth login`), update version metadata/app labels/report version, and commit the intended sources. Run:

```sh
SIGNING_IDENTITY=- scripts/release.sh
```

This uses the same tests, Universal 2 build, verification, DMG packaging, checksum and draft upload, then pushes the branch and annotated version tag. Choose either this route or hosted release creation for a given tag; both refuse overwriting existing assets. A local tag push can also trigger the hosted workflow, which will refuse a duplicate asset rather than replace it. Existing Apple-signed development builds remain available by supplying the real `SIGNING_IDENTITY` and optional `SIGNING_KEYCHAIN`; no credentials are altered by these changes.

For packaging an existing ad-hoc app only:

```sh
SIGNING_IDENTITY=- scripts/verify-release-signatures.sh
swift scripts/check-adhoc-helper.swift dist/Maschinery.app
scripts/package-dmg.sh
```

The packager copies the app with `ditto` without changing its signature or resources, creates an `Applications` shortcut and UDZO image with native `hdiutil`, verifies it, then moves it into `dist/`. An EXIT trap removes staging data on success and failure. A failed creation or verification does not become a release artifact. Neither the app nor DMG is notarized; the DMG itself is not signed.

## Privileged helper limitation

The current shipped implementation cannot authorize its privileged helper with ad-hoc signing. `HelperIdentity.team()` rejects code without an Apple Team ID **before** calling `SMAppService.register()`. Both sides of XPC additionally require `anchor apple generic` and the matching certificate Team ID. The read-only `check-adhoc-helper.swift` probe on the actual ad-hoc app and helper confirms absent Team IDs and rejection of even the Apple-anchor/identifier portion of that trust requirement. The workflow runs this probe too.

Thus **Full Install and helper-dependent maintenance are unavailable**. Analysis, Extract Only, Library browsing/catalogue/artwork and nonprivileged workflows remain available. Approving Gatekeeper is separate from helper authorization. We did not weaken the privileged XPC policy, introduce root/sudo fallbacks or register a replacement system daemon. Raw operating-system acceptance of an ad-hoc SMAppService daemon has **not** been tested: this app's preflight prevents reaching that call, and no standalone SMAppService compatibility is claimed.

## Gatekeeper

Downloaded ad-hoc builds are not identified-developer distributions or notarized. After copying the app to Applications and attempting to open it, users who trust it can approve it in **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. This does not enable Full Install. See [Apple's instructions](https://support.apple.com/en-us/102445). No global security setting changes or quarantine-removal commands are required by these instructions.
