# GitHub builds and releases

Source pushes and pull requests run `.github/workflows/ci.yml` on a GitHub-hosted Mac: native XCTest followed by a Universal 2 app/helper build. CI uses ad-hoc signing solely to check compilation and packaging; it does not publish a downloadable app or enable Full Install.

Run production releases on the development Mac so the existing signing identity remains in its Keychain. No certificate export or GitHub signing secret is needed. The script uses the existing `SIGNING_IDENTITY` and optional `SIGNING_KEYCHAIN` settings from `build-app.sh`.

## One-time setup

Install GitHub CLI with `brew install gh`, then authenticate interactively with `gh auth login`. Create the chosen repository, configure it as `origin`, and commit the intended source files. Keep the repository private unless public source distribution is intended. Build outputs, Keychain exports and credentials must not be committed.

## Create a release

Update the app version in the build script, Xcode project/generator, app labels and report metadata. Commit those changes, then run:

```sh
scripts/release.sh
```

The command requires a clean working tree, runs tests, builds and verifies signatures, creates `dist/Maschinery-VERSION.zip` and its SHA-256 checksum, pushes the current branch and an annotated `vVERSION` tag, and uploads a **draft** GitHub Release. Review the draft on GitHub and publish it when ready. It refuses existing local version tags and ad-hoc release signatures. It never force-pushes or overwrites release assets. If an upload fails after the tag is pushed, finish the draft manually with `gh release create` for that existing tag; do not delete or replace published tags.

These builds retain the project's current signing approach. An Apple Development signature is not Developer ID distribution or notarization, and a successful CI run does not establish privileged helper approval on another Mac.

GitHub CLI reference: https://cli.github.com/manual/gh_release_create
