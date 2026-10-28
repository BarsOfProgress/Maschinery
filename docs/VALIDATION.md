# Validation evidence — 2026-10-28

## Automated coverage

The suite includes core matching/root/health tests, generated real PKGs and compressed bundle packages, a multipart ISO mount fixture with three real PKGs plus loose content, 40 offline multipart expansion installs, real native Trash/restore of a disposable source, registration verification and undo, permission selection and undo, malformed registrations, symlink/hardlink/traversal rejection, cancelled mounts and copies, crash recovery, lost commit replies, and cancellation after registration.

Registered installation tests inject isolated NI paths into the same RegistrationEngine compiled into the daemon. The actual XPC API has no parameter for replacing its fixed NI roots. These tests prove filesystem/transaction behavior, not macOS administrator authorization.

Commands:

```sh
scripts/test-native.sh
scripts/test-intel.sh
scripts/build-app.sh
xcodebuild -project MaschineMachine.xcodeproj -scheme MaschineMachine \
  -configuration Release -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox \
  DEBUG_INFORMATION_FORMAT=dwarf 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

The Intel script explicitly launches x86_64 XCTest under Rosetta. Plain `swift test --arch x86_64` uses an arm64 test helper with this Xcode release and cannot load the x86-only test bundle; this is why the wrapper exists.

## External acceptance required

- No Apple signing identity/private key is available here. The ad-hoc bundle's preflight test confirms it fails before content modification. Real SMAppService approval, mutual XPC signature acceptance, root-owned library swaps and root-owned permission repair must be exercised with your signed build. See SIGNING.md.
- Real ISO creation succeeds, but this host returns `hdiutil: attach failed - Device not configured`. That one integration test is skipped explicitly. Structured mount tests cover the analysis/cleanup paths; they do not prove the host's disk-image service works.
- No physical Intel Mac or real NI copyrighted library was supplied. Cross-architecture builds/Rosetta tests and synthetic fixtures are not a claim of completed hardware/NI product certification.
- Security tests cover path attacks and failure behavior; this implementation has not received an independent security audit. Unsupported package compression fails visibly rather than executing installer scripts.

## Final recorded results

| Check | Result |
|---|---|
| Apple Silicon XCTest | 43 discovered; 42 passed; 1 real-image test skipped; 0 failures |
| Intel XCTest under Rosetta | 43 discovered; 42 passed; 1 real-image test skipped; 0 failures |
| Native Xcode Release app/core/helper build | Succeeded for arm64 and x86_64 |
| Universal bundle script | Succeeded; both app and embedded helper contain x86_64 and arm64 |
| Ad-hoc bundle signature verification | `codesign --verify --deep --strict` passed |
| Available Apple signing identities | 0; system helper authorization remains an external acceptance step |

The real ISO test skip reports `hdiutil: attach failed - Device not configured`. No other test is skipped. The native Trash test restores its own uniquely named disposable file after verifying it was moved to Trash.

## Test-discovery investigation

The former trailing “Test run with 0 tests in 0 suites passed” came from Swift Testing, after XCTest had already executed the suite. The project uses XCTestCase, not Swift Testing annotations. `scripts/test-native.sh` now selects XCTest explicitly and disables the unused Swift Testing runner. Both architecture wrappers run `check-xctest-log.sh`, which rejects zero started/passed cases and verifies that started cases equal passed plus skipped cases. A synthetic zero-test log was explicitly rejected.

`swift test --disable-sandbox --enable-xctest --disable-swift-testing list` independently discovers **43 XCTest methods**. The suite also now tests ProductHints transport coalescing/cache, zero offline requests, automatic ProductHints-to-Full-Install registration, and rejection of privileged replacement without existing library evidence.

## GUI smoke-test limitation

The final bundle passes executable lookup through Foundation Bundle, executable-mode checks, architecture checks, plist lint and deep signature verification. This execution host nevertheless refuses Launch Services registration (`lsregister -f`: -10822; `open`: -10827). Direct launch aborts in Apple's `HIServices._RegisterApplication` during NSApplication initialization, before the product's UI starts. The native Xcode app behaves the same way. An independently compiled, packaged minimal AppKit program containing only NSApplication initialization reproduces the same abort. Interpreted, unbundled AppKit initialization works but logs a Launch Services notification failure when a window is created.

Consequently GUI launch and end-to-end signed-helper acceptance are **not validated on this host**. Confirm them by opening the built/signed app from an unrestricted desktop session. No private-API or process-registration bypass was added to the application to hide this limitation.
