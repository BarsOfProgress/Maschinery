# Validation evidence — 2026-10-28


## Certificate-free installer implementation — 2026-11-07

The new 1.0.4 implementation builds a Universal 2 app, daemon and native setup executable with ad-hoc signatures and hardened runtime. The full installer installs root-owned launchd configuration and pins app/helper/setup CodeDirectory hashes for both architectures; the helper-removal package retains the app, NI content, registrations and transaction journals. The legacy Apple-team SMAppService option remains available.

Native XCTest and Intel/Rosetta XCTest each ran 130 cases: 129 passed, one existing opt-in live catalogue test skipped, zero failures. Nineteen new cases cover protected trust-file ownership/modes/ACLs, symlink/hardlink/FIFO/size rejection, malformed identities, role separation, isolated install/update/uninstall, failure at each replacement, failed startup rollback, interrupted recovery, committed cleanup interruption, running-app/pending-journal refusal, payload links and real codesign requirement parsing. The setup fixtures replace system service management and peer signature verification; a separate case invokes the production codesign verification function against a system executable.

A real hardened, ad-hoc signed NSXPC probe passed natively and under Intel/Rosetta: matching peer hashes were accepted; wrong helper and wrong client hashes were rejected. This is an anonymous XPC fixture, not a root launch daemon installation.

The native Xcode Release app/core/helper build succeeded for arm64 and x86_64. The Universal bundle/setup build and deep/strict signature verification passed. Full Install and Remove Helper packages were generated without signing credentials. Read-only package expansion verified root:wheel payload ownership, protected modes, disabled bundle relocation, matching script/setup binaries, expected daemon configuration, Universal architectures and every pinned app/helper/setup signature. Both SHA-256 sidecars validated.

No system helper was installed, unregistered or replaced on this Mac, and no real NI content or records were modified. Administrator installation, system launchd/XPC health checks, Gatekeeper/background-item behavior and real-library operations remain pending on a disposable clean Mac. See INSTALLER-HELPER.md. These are acceptance limits, not claimed successes.

## Ad-hoc release distribution — 2026-11-07

A full Universal 2 Release build completed using `SIGNING_IDENTITY=-`, with helper signed before app and entitlements retained on re-signing. Deep strict verification and per-architecture checks passed for both binaries, including expected identifiers and ad-hoc signature type. Native XCTest: 111 started, 110 passed, one live-store test skipped, zero failures. UDZO creation, `hdiutil verify` and checksum generation passed.

A read-only Security-framework probe of the actual app and embedded helper confirmed both lack Team IDs and both fail the Apple-anchor/identifier trust requirement with `errSecCSReqFailed` (-67050). The unchanged production helper preflight rejects that missing Team ID before invoking SMAppService registration, so no helper compatibility is claimed. Raw ad-hoc daemon registration and privileged operations were not attempted. No certificate or provisioning credentials were modified. Hosted release secrets/imports were removed; release notes and README now identify ad-hoc signatures, no notarization, Gatekeeper approval and unavailable privileged features.

## DMG release packaging — 2026-11-07

The shared native hdiutil packager produced `Maschinery-v1.0.1-macOS.dmg` with UDZO/zlib compression and passed `hdiutil verify`. Read-only mounting confirmed the app and exact `Applications -> /Applications` symlink; deep strict all-architecture signature verification passed inside the mounted app, and both app/helper contained x86_64 and arm64. The SHA-256 sidecar validated. The temporary packaging directory was removed, and the verification mount was detached. Existing signing configuration remains unchanged; no certificates were exported or altered and no notarization was performed. The hosted release path requires user-configured signing secrets and has not been exercised with those credentials.

## Library scan progress — 2026-11-04

The Library audit previously left the shared operation fraction at zero. It now emits checked/total NI registration counts, including filtered-out records, and the interface advances the bar from those counts. Preparation uses an indeterminate indicator until the total is known. Cancellation propagates rather than completing successfully; cleanup resets progress for subsequent operations.

Native and Intel/Rosetta XCTest each passed: 111 started, 110 passed, one opt-in live-store test skipped, zero failures. Three new regressions cover excluded registrations reaching completion, an empty scan and cancellation at the final progress update. Universal signed app/helper and Xcode Release builds succeeded; deep strict signature verification passed. Accessibility inspection of a fresh app instance confirmed the live scan advancing from 58/272 to 100/272, with progress value 0.367647 at 100 records. No installed files were modified.

## Expansion-only Library and first-load behavior — 2026-11-04

Kontakt 8 was admitted by its internal `groups` directory on a case-insensitive filesystem. The expansion filter now requires actual native Maschine preset files or matching native product metadata, excludes host/factory products explicitly, and keeps known offline expansions without admitting unrelated XML. Three new regressions cover Kontakt `.nkg`/unrelated instrument folders, host/factory exclusions, legacy Maschine formats, unrelated metadata and offline catalogue identities.

Native and Intel/Rosetta XCTest: 108 started, 107 passed, one unrelated live-store test skipped, zero failures. A separate read-only live audit passed and confirmed Kontakt products are excluded. The existing Xcode and signed Universal 2 builds succeeded.

Library initial-load state now belongs to AppModel. Navigation reuses the completed local scan and catalogue; automatic catalogue checks run once at launch, without an hourly timer or online-reconnection refresh. Explicit refresh controls remain available. Actual installs invalidate local results, while maintenance/removal update them directly. In a newly launched test instance, a completed Libraries → Install → Libraries round trip was verified through accessibility: the Library state, audit status and catalogue timestamp were unchanged, with no repeat scan. The user's previously running instance was not targeted by that test.

## Independent permission repair — 2026-11-04

The reported ContentDir error was traced to a raw HFS-vs-POSIX comparison in SharedPermissions.scope and a default Repair workflow that coupled mode changes to registration writes. Permission-only Repair now has its own typed helper operation and journals, with read-only plist/installed-products JSON evidence, canonical directory identity, structural expansion verification, minimal caller-class read/traversal changes, ownership checks, link/filesystem/ACL/locked-file rejection, complete enumeration and rollback. Library health now checks effective access rather than owner bits alone. See PERMISSION-REPAIR.md for the investigation, sources, exact workflow and safety boundaries.

Final native XCTest: 105 started, 104 passed, one unrelated opt-in live catalogue test skipped, zero failures. Intel/Rosetta: the same counts and result. The 19 new permission-repair tests cover missing registrations/ContentDir keys, both actual record formats unchanged byte for byte, normalized names, contradictory paths, arbitrary/insufficient evidence, symlink/hardlink/root replacement, ACL denial and allowed ACL access, permission failure/rollback, restart/client recovery, ownership/caller isolation, overlapping transactions and helper protocol behaviour. The existing selective permission test now exercises the independent operation and asserts unchanged registration bytes. All existing installer/removal/library/catalogue tests remain in those full runs.

An opt-in, read-only scope check passed against the real Anima Ascent folder and both of its existing registration representations. No real expansion modes or NI records were changed. Privileged mutation of a real root-owned library was not exercised during this investigation.

The final Xcode Release app/core/helper build succeeded for arm64 and x86_64. The final Universal 2 app/helper bundle was signed with the existing Apple Development identity. Older running helpers are detected before attempting the new operation and produce an update/restart diagnostic.

## Unified expansion catalogue — 2026-11-04

The official paginated collection was verified as 114 unique expansion listings over five pages. Public CollectionPage JSON-LD and literal theme metadata, not an undocumented API, supply the bundled metadata-only baseline. No store images are bundled. See CATALOGUE.md for the source, completeness rules, matching, refresh/cache design and artwork usage limitations.

Native and Intel/Rosetta XCTest each discovered 86 tests: 85 passed, one opt-in live-network test skipped, zero failures. The 22 catalogue cases cover recorded parsing, normalization, exact/alias/identifier matching, conflicting IDs, multi-product XML isolation, unlisted/broken locals, duplicate/empty/incomplete/hardware responses, network failure/backoff, offline baseline, cache persistence, maintained alias persistence, statistics, search/filter/sort, a 400-product stable-identity scenario, and artwork deduplication/validation/versioning/disk-budget/offline reuse. Existing installer, repair, relocation, registration and uninstall coverage remains in those runs. The separately invoked live test fetched the current catalogue and downloaded, decoded and reused an official artwork sample offline.

The existing Xcode Release app/core/helper build succeeded for arm64 and x86_64. The Universal 2 bundle build reused the existing Apple Development identity and passed deep/strict signature verification. Its packaged baseline matches the source manifest byte for byte.

A launched app was inspected through macOS accessibility: the local audit completed; All/Installed/Missing controls were present, Missing showed five rows on this Mac, collection statistics excluded unlisted libraries, and an inspected missing product exposed its description/product link with no local maintenance actions. Runtime official-artwork cache files were present. Screen capture failed with `could not create image from rect`; no screenshot-based visual acceptance is claimed. Filter/search/sort combinations are covered by core tests; full manual keyboard/visual acceptance and privileged NI operations remain external checks.

## Maschinery 1.0.0 rename — 2026-11-04

Renamed the app, Swift package/modules, targets, source directories, Xcode project, helper executable/Mach service, support directories, staging prefixes, exports and documentation. App metadata and report versions are 1.0.0 (build 1). Native and Intel/Rosetta XCTest each ran 64 tests, all passed with zero skips. The renamed Xcode Release project built app/core/helper for arm64 and x86_64. The signed Universal 2 bundle is `dist/Maschinery.app`; deep/strict verification and explicit Apple-anchor/identifier/team requirements passed for both executables and both architectures using the existing Apple Development identity. Interactive approval of the newly named helper remains a desktop acceptance step. See SIGNING.md for switching from earlier builds with their separate preferences and recovery data.

## Uninstall and reinstall — 2026-11-01

Native XCTest: 64 started, 64 passed, zero skipped. Added coverage for uninstall commit and restart rollback, stale-path and symlink rejection, preserving content/artwork and other products, refusing Trash for shared registered content, overwriting registered content and installing elsewhere while retaining the old files. Rebuilt the Universal 2 app and helper with the existing Apple Development identity; the build's deep/strict signature verification passed. Interactive uninstall/Trash and signed-helper approval still require desktop acceptance.

## Signing correction — 2026-11-01

The login Keychain contains an existing Apple Development identity; sandbox discovery hid it. The Universal 2 app and embedded helper were rebuilt and signed using SHA-1 `0BDE0EBF64FBA341DB98AB72EB98CD5AF40C20DB`. Both signatures report TeamIdentifier `F75CB2ST8Q` and the expected Apple Development authority. Outside the sandbox, deep/strict verification across all architectures passed, as did explicit Apple-anchor, executable-identifier and certificate-OU requirements for both executables. Automatic identity selection also successfully selected the same certificate and produced a verified bundle. No credentials were changed. This supersedes historical ad-hoc build/signing statements below; interactive helper approval and real NI acceptance remain unverified.

## Automated coverage

The suite includes core matching/root/health tests, generated real PKGs and compressed bundle packages, a multipart ISO mount fixture with three real PKGs plus loose content, 40 offline multipart expansion installs, real native Trash/restore of a disposable source, registration verification and undo, permission selection and undo, malformed registrations, symlink/hardlink/traversal rejection, cancelled mounts and copies, crash recovery, lost commit replies, and cancellation after registration.

Registered installation tests inject isolated NI paths into the same RegistrationEngine compiled into the daemon. The actual XPC API has no parameter for replacing its fixed NI roots. These tests prove filesystem/transaction behavior, not macOS administrator authorization.

Commands:

```sh
scripts/test-native.sh
scripts/test-intel.sh
scripts/build-app.sh
xcodebuild -project Maschinery.xcodeproj -scheme Maschinery \
  -configuration Release -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox \
  DEBUG_INFORMATION_FORMAT=dwarf 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

The Intel script explicitly launches x86_64 XCTest under Rosetta. Plain `swift test --arch x86_64` uses an arm64 test helper with this Xcode release and cannot load the x86-only test bundle; this is why the wrapper exists.

## External acceptance required

- Historical 2026-10-28 sandbox discovery reported no signing identity; this was not proof of absence. On 2026-11-01, discovery outside the sandbox confirmed the existing Apple Development identity (see SIGNING.md). The ad-hoc bundle's preflight test confirms it fails before content modification. Real SMAppService approval, mutual XPC signature acceptance, root-owned library swaps and root-owned permission repair must be exercised with your signed build. See SIGNING.md.
- Real ISO creation succeeds, but this host returns `hdiutil: attach failed - Device not configured`. That one integration test is skipped explicitly. Structured mount tests cover the analysis/cleanup paths; they do not prove the host's disk-image service works.
- No physical Intel Mac or real NI copyrighted library was supplied. Cross-architecture builds/Rosetta tests and synthetic fixtures are not a claim of completed hardware/NI product certification.
- Security tests cover path attacks and failure behavior; this implementation has not received an independent security audit. Unsupported package compression fails visibly rather than executing installer scripts.

## Final recorded results

| Check | Result |
|---|---|
| Apple Silicon XCTest | 56 discovered; 55 passed; 1 real-image test skipped; 0 failures |
| Intel XCTest under Rosetta | 56 discovered; 55 passed; 1 real-image test skipped; 0 failures |
| Native Xcode Release app/core/helper build | Succeeded for arm64 and x86_64 |
| Universal bundle script | Succeeded; both app and embedded helper contain x86_64 and arm64 |
| Ad-hoc bundle signature verification | `codesign --verify --deep --strict` passed |
| Signing identity discovery | Historical sandbox result: 0; 2026-11-01 outside sandbox: 1 existing Apple Development identity; system helper authorization still requires acceptance |

The real ISO test skip reports `hdiutil: attach failed - Device not configured`. No other test is skipped. The native Trash test restores its own uniquely named disposable file after verifying it was moved to Trash.

## Test-discovery investigation

The former trailing “Test run with 0 tests in 0 suites passed” came from Swift Testing, after XCTest had already executed the suite. The project uses XCTestCase, not Swift Testing annotations. `scripts/test-native.sh` now selects XCTest explicitly and disables the unused Swift Testing runner. Both architecture wrappers run `check-xctest-log.sh`, which rejects zero started/passed cases and verifies that started cases equal passed plus skipped cases. A synthetic zero-test log was explicitly rejected.

`swift test --disable-sandbox --enable-xctest --disable-swift-testing list` independently discovers **43 XCTest methods**. The suite also now tests ProductHints transport coalescing/cache, zero offline requests, automatic ProductHints-to-Full-Install registration, and rejection of privileged replacement without existing library evidence.

## GUI smoke-test limitation

The final bundle passes executable lookup through Foundation Bundle, executable-mode checks, architecture checks, plist lint and deep signature verification. This execution host nevertheless refuses Launch Services registration (`lsregister -f`: -10822; `open`: -10827). Direct launch aborts in Apple's `HIServices._RegisterApplication` during NSApplication initialization, before the product's UI starts. The native Xcode app behaves the same way. An independently compiled, packaged minimal AppKit program containing only NSApplication initialization reproduces the same abort. Interpreted, unbundled AppKit initialization works but logs a Launch Services notification failure when a window is created.

Consequently GUI launch and end-to-end signed-helper acceptance are **not validated on this host**. Confirm them by opening the built/signed app from an unrestricted desktop session. No private-API or process-registration bypass was added to the application to hide this limitation.

## Artwork regression pass

Thirteen new synthetic-image tests exercise PNG/JPEG/TIFF metadata, MST and non-MST artwork, competing assets, product-directory evidence, dimensions/aspect, tiny/corrupt rejections, missing-art placeholders, multipart input order, installed JPEG previews and cache reuse/invalidation/off-main decoding. The complete suite now discovers 56 cases (55 passed, the same real-ISO case skipped). Existing registered-install/repair/relocation tests remain in the full suite. See ARTWORK.md for diagnostic details and weights.
