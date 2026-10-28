# Maschine Machine

Native macOS 14+ SwiftUI library companion. Independent utility; not affiliated with or endorsed by Native Instruments.

**Status: development foundation, not v1 or a production installer.** The supplied legacy implementation and Maschine screenshot have been reviewed. See [implementation plan](docs/PLAN.md) and [compatibility inventory](docs/COMPATIBILITY.md).

## Build and run

Requires Xcode 16+ with Swift 6 and a macOS SDK. Developed using Xcode 27.1. No third-party libraries or runtime dependencies.

Open `MaschineMachine.xcodeproj` (native app and core targets), or `Package.swift`, in Xcode and run the MaschineMachine executable scheme, or:

```sh
swift build --disable-sandbox
swift run --disable-sandbox MaschineMachine
swift test --disable-sandbox
```

`--disable-sandbox` disables SwiftPM's build subprocess sandbox, not app safety checks. It is necessary in the restricted development environment; normal machines may omit it.

## Available behavior

- Native black/charcoal sidebar UI with Install, Libraries, Logs and Settings.
- Multi-source picker and Finder file drop; asynchronous analysis and cancellation propagation.
- ISO read-only attachment with plist mount information; staged loose payloads and XML before detachment.
- pkgutil expansion, bundle fallback and logged xar fallback with member path screening.
- Batch-wide embedded XML collection; multipart normalization and grouping; explicit XML override and ambiguity detection.
- Structured XML parsing, DTD/entity rejection, ProductHints actor cache and offline network gate.
- Library root and artwork discovery; background thumbnail decoding.
- Queue selection, filtering, diagnostics, per-item conflict and destination controls.
- Extract Only: source-preserving chunked copies, SHA-256 verification, staging on destination volume and rename commit. Merge keeps unrelated files. Replace replaces the entire destination after staging. Failed staging preserves the original destination.
- Read-only existing-registration audit with missing-content/XML/artwork/resource issues and Finder actions.
- Searchable, filterable session logs with copy/save; remembered destination/offline preferences; quit guard.

## Architecture

`MaschineCore` owns models, process execution, discovery, mounts, package extraction, metadata, analysis, planning, extraction and audit. It does not import SwiftUI. `MaschineMachine` owns main-actor presentation state and views. Filesystem work uses cancellable detached workers. Analysis is serial to bound process and disk contention. Source URLs remain immutable. An analysis session owns expanded trees so queue payload URLs cannot outlive their workspace.

ProductHints: `https://api.native-instruments.com/static/phints`, 15-second request timeout, in-memory batch/session cache, automatic fallback only for unresolved metadata. Offline analysis never calls the provider. Cache is not persisted. Import XML before analysis or use Bulk XML Import afterwards. Current matching is deliberately conservative: equal normalized identity only; probable/fuzzy suggestions are still a release gate.

## Privileged architecture

Registered Install fails before copying. The `PrivilegedService` protocol is a boundary, **not an implemented helper**. No sudo, root shell, generic command executor or privileged write is used.

Production must embed a signed launch daemon managed by `SMAppService.daemon(plistName:)`. Apple reference: https://developer.apple.com/documentation/servicemanagement/smappservice . The daemon must validate peer audit-token code signatures (fixed app ID and same signing team), bound request sizes, serialize mutations and accept only typed product registration/repair operations. Use fixed destination roots and descriptor-relative `openat`/`O_NOFOLLOW` operations to prevent symlink substitution. Do not ship a path-check-only root helper. Stage data via validated handles or bounded XPC data, not caller-supplied arbitrary root paths. Implement transaction/journal and registration read-back before enabling Install.

Signing identity and administrator approval are required to validate this end to end. An unsigned development build must continue to support analysis, audit and extraction without escalation.

## Filesystem locations

Future registered installation writes only product-scoped paths:

- `/Library/Preferences/com.native-instruments.<Product>.plist`: ContentDir and authoritative ContentVersion; document `1.0.0` if a fallback is necessary.
- `/Library/Application Support/Native Instruments/Service Center/<Product>.xml`
- `/Users/Shared/NI Resources/image/<Product>/`
- User-selected library destination (initial default `/Users/Shared`).

The current audit reads these locations. No permission repair touches all of `/Library/Preferences`.

Analysis uses mode-0700 `MaschineMachine-<UUID>` system temporary directories. Sources and mounts are read-only inputs. ISO content is staged before detach; queue sessions retain staging. Normal session release removes staging. Extraction staging is a hidden UUID directory on the destination volume, permitting same-volume rename commit. Crash recovery journals and stale-mount recovery are not implemented yet. Do not use this development build on irreplaceable library destinations.

## Tests

Synthetic fixtures are generated under unique temporary directories. Tests cover normalization, matching/override/ambiguity, XML entity rejection, artwork, metadata-only and wrapped payload roots, multipart grouping, unsafe destinations, symlinks, source cleanup dependencies, copy verification, staging failure preservation and library-health states. Generated PKG integration verifies cross-package XML collection; cancellation during a staged copy preserves the old destination. All 15 tests passed locally. They contain no copyrighted library content.

## Universal 2 and distribution

Run `scripts/build-app.sh` to build arm64 and x86_64 and assemble a Universal 2 `.app` in `dist`. This is a development bundle; helper/signing/notarization are not implemented by that script. Both architectures have been built and verified with lipo. Cross-compilation does not replace testing on Intel hardware. The script uses SwiftPM native build mode because this environment denies dsymutil in the newer swiftbuild backend. Xcode also builds the application; in this restricted environment add `OTHER_SWIFT_FLAGS=-disable-sandbox` for macro subprocesses.

Production distribution: configure an owned reverse-DNS identifier and Developer ID Application signing identity; sign helper and app with hardened runtime and secure timestamp, verify with `codesign --verify --deep --strict`, submit a ZIP using `xcrun notarytool submit --keychain-profile <profile> --wait`, then `xcrun stapler staple`. Validate with `spctl --assess --type execute`. Credentials must stay in Keychain. Never distribute an ad-hoc bundle as a production installer.

## Remaining v1 release gates

- Authenticated signed helper, registration transactions/read-back, NI resource installation, permission inspection/repair.
- Repair review/execution, copy/verify relocation and registration update.
- Crash journals, stale state recovery, robust ISO attach cancellation recovery, extraction sandbox against malicious archives/symlink creation during unpack.
- ISO and fallback integration tests including fallback payload decompression; xar alone may produce compressed Payload files and is not sufficient for every package.
- Existing ContentDir correlation during analysis; duplicate registration detection, richer health checks, registration validation.
- Confidence/evidence matching UI and per-candidate explicit ambiguity resolution.
- Post-verification Trash (currently disabled), full structured report export/retry, persistent logs.
- More progress detail, artwork cache, batch conflict default and sort controls, disk budget across complete batch and extraction overhead.
- Signed helper target integration, accessibility/keyboard review and UI automation.
- Signing/notarization, real NI compatibility validation, Universal 2 runtime tests and all supplied acceptance scenarios.

These are incomplete requirements, not claims that v1 is finished. Never enable destructive cleanup or registered install merely to make UI controls appear complete.
