# Maschinery DMG releases

The macOS distribution is `Maschinery-vVERSION-macOS.dmg`, accompanied by a SHA-256 checksum. Open it and drag **Maschinery.app** onto **Applications**. The image contains the app and an `Applications` symlink to `/Applications`; it is compressed, read-only UDZO with zlib level 9.

`scripts/package-dmg.sh` copies the already-built app using `ditto`, preserving its bundle and signature. It creates the image with Apple's native `hdiutil`, verifies it with `hdiutil verify`, and only then moves it to `dist/`. Creation or verification errors stop the release. An EXIT trap removes temporary staging data on success and failure. It never edits the app, signs it again, or touches other operating systems' artifacts.

## Local release with the existing Keychain

The existing local signing path remains available, with no GitHub signing secrets or certificate export required:

```sh
scripts/release.sh
```

Install GitHub CLI (`brew install gh`) and authenticate (`gh auth login`) first. Commit the intended sources and version changes. The command requires a clean working tree, runs XCTest, builds Release binaries for **arm64 and x86_64**, signs the app and helper using `build-app.sh`, verifies their Apple identities and matching Team IDs, packages and verifies the DMG, pushes the branch and new annotated version tag, and creates a **draft** GitHub Release containing the DMG and checksum. It refuses existing local version tags, ad-hoc signatures, force-pushes and asset overwrites.

`SIGNING_IDENTITY` and optional `SIGNING_KEYCHAIN` retain their existing meanings. The app version is read from its Info.plist; update build metadata, Xcode project/generator, app labels and report version together before a release. The current `v1.0.1` tag already exists; do not move it to new source. Bump the version for the next release.

For packaging only, after building:

```sh
scripts/verify-release-signatures.sh
scripts/package-dmg.sh
```

## GitHub Actions release workflow

`.github/workflows/release.yml` runs on **macos-15**, when a `v*` tag is pushed, or manually via **Actions → Maschinery — macOS DMG release → Run workflow** with an existing tag. It checks that the tag matches both the checkout and compiled app version, runs XCTest, builds the same signed Universal 2 app/helper, packages and verifies the DMG, then uses the existing `gh release create` / `gh release upload` mechanism to attach it to a draft release. It does not publish automatically, overwrite assets, modify published releases or delete any existing assets, including other platforms' files. Historical ZIPs are left untouched; new macOS releases use DMGs.

For hosted signing, configure the **release** GitHub environment with:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded password-protected `.p12` containing an existing Apple Development or Developer ID Application identity **and its private key** |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |

This is optional setup performed by the certificate owner. No certificates or credentials are created, exported, changed or revoked by this repository change. If you choose to configure hosted signing, transfer the existing identity securely; never commit the `.p12`, its encoding or password. Each run imports it into a temporary runner Keychain and deletes that Keychain and import file afterwards. No signing secrets are needed for the local release path.

With no certificate secret configured, the release workflow fails with an explicit setup message and uploads nothing. With multiple signing identities in the imported file, the existing build script refuses ambiguous selection; supply a `.p12` with the intended identity. The automatic `GITHUB_TOKEN` is granted `contents: write` for release uploads; a separate GitHub PAT is not required. Configure required reviewers and restrict deployment tags in the **release** environment as appropriate. GitHub's [manual workflow instructions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow) describe dispatching releases.

A tag pushed by the local release script can also trigger the hosted workflow. Use the local route without hosted signing secrets, or the hosted route with secrets, rather than running both for the same tag: neither path overwrites an existing asset. To retry a failed upload, inspect the draft and upload the missing DMG/checksum explicitly; do not delete or replace published tags.

## CI and signing status

`.github/workflows/ci.yml` still runs on source pushes and pull requests on a GitHub-hosted Mac: XCTest, the existing Universal 2 Release build, then DMG creation and verification. CI uses **ad-hoc signing only for validation**, does not publish a downloadable release, and does not enable Full Install.

Real releases require a verified Apple Development or Developer ID Application signature on both app and helper. An Apple Development signature is not Developer ID distribution or notarization. There was no notarization step to preserve; these releases explicitly say **not notarized**. No notarization secrets, dummy credentials or claims of notarization are introduced. The disk image itself is not separately signed or notarized. Existing stapled app tickets, if supplied in a future build, are preserved by packaging. Full Install still requires approving the signed helper on the destination Mac.
