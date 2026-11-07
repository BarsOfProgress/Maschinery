# Maschinery releases without a paid Apple account

Releases require no Apple certificates, signing secrets, paid membership or notarization credentials. The artifacts are:

- `Maschinery-vVERSION-Full-Install.pkg`: app plus administrator-installed root helper, for full functionality.
- `Maschinery-vVERSION-Remove-Helper.pkg`: helper removal, retaining the app, libraries, NI registrations and transaction journals.
- `Maschinery-vVERSION-macOS.dmg`: Universal 2 app with an Applications shortcut; dragging the app alone supports nonprivileged workflows.
- SHA-256 sidecars for each artifact.

The app, helper and setup executable are ad-hoc signed with hardened runtime. Packages and the DMG are unsigned and not notarized. An administrator explicitly approves installation; root-owned configuration then approves exact code hashes for both CPU architectures. See [helper design and required clean-Mac acceptance](INSTALLER-HELPER.md). Gatekeeper opening approval and administrator installation approval are separate steps.

## GitHub Actions

`.github/workflows/release.yml` runs on macos-15 for version tags or manual dispatch against an existing tag. The tag must match the checked-out commit and compiled app version. Do not move existing tags.

The workflow runs XCTest, builds arm64 and x86_64, verifies deep/strict signatures and identifiers, confirms the expected absence of Apple-team trust, and runs real XPC hash authentication probes on architectures the runner can execute. It packages both installers, creates and verifies the UDZO disk image and uploads all artifacts/checksums to a draft GitHub Release.

Published releases and existing assets are not overwritten. The automatic GITHUB_TOKEN needs contents:write; no Apple secrets or Keychain imports are used. Repository environment rules may require review. Complete the desktop acceptance in INSTALLER-HELPER.md before publishing this new implementation.

## Local build and packaging

```sh
scripts/test-native.sh
scripts/test-intel.sh
scripts/test-helper-trust.sh
SIGNING_IDENTITY=- scripts/build-app.sh
SIGNING_IDENTITY=- scripts/verify-release-signatures.sh
scripts/package-installer.sh
scripts/package-dmg.sh
```

Packaging does not install a system daemon. The package construction script uses developer Python to generate code-hash configuration and disable Installer bundle relocation. The recipient needs no Python or Xcode. All package executable components are Universal 2.

The native setup tool is embedded in Installer's scripts directory and accepts only fixed setup operations. Payload is staged beneath a validated root-owned directory before protected swaps and live helper verification. Package installation is restricted to the current startup volume. Keep the app closed during install/update/removal.

## Draft upload

With GitHub CLI authenticated, version metadata updated and intended source changes committed:

```sh
SIGNING_IDENTITY=- scripts/release.sh
```

This runs the local build/verification/package flow, pushes the branch and annotated tag, and uploads a draft. A tag push can also trigger the hosted workflow; choose one route for a release to avoid duplicate asset uploads. Existing Apple-signed development builds can still be built using SIGNING_IDENTITY and SIGNING_KEYCHAIN. No signing credentials are changed.

## Gatekeeper

Users who trust the download may need to attempt opening the package, then approve it through System Settings → Privacy & Security → Open Anyway. See [Apple's instructions](https://support.apple.com/en-us/102445). No global security changes are required. A checksum detects accidental corruption but does not establish publisher identity. Obtain the unsigned package from a trusted source.
