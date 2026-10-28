# Maschine Machine

Native SwiftUI companion for bulk Maschine library installation, extraction, auditing, repair and relocation. macOS 14+, Universal 2. Independent utility; not affiliated with or endorsed by Native Instruments.

## Development build

The Full Install implementation is enabled. The app embeds an SMAppService launch daemon and uses authenticated XPC for NI system registration. **The supplied ad-hoc build cannot authorize that daemon.** Sign both executables with your Apple team and approve the helper in System Settings to perform system installation or maintenance. No root GUI, Terminal password prompt or sudo fallback exists. See [exact signing instructions](docs/SIGNING.md).

Analysis, Extract Only, artwork, XML import, offline mode, audit and logs work without helper authorization. Registered installs and maintenance are tested against isolated filesystem roots using exactly the registration engine linked into the daemon. System authorization and root-owned filesystem behavior still require acceptance on a signed build; they are not claimed as tested here.

Final development bundle: `dist/Maschine Machine.app`.

## Build and test

Requires current Xcode and Swift 6. No Python, Homebrew or downloadable runtime is required by the application. The archive fallback links Apple's system libarchive. `scripts/sync-xcode.py` is an optional developer-only project generator; the generated project is committed.

```sh
swift build --disable-sandbox
scripts/test-native.sh      # XCTest only; rejects zero-test runs
scripts/test-intel.sh       # x86_64 XCTest under Rosetta on Apple Silicon
scripts/build-app.sh        # arm64 + x86_64 app AND helper, ad-hoc signing by default
open 'dist/Maschine Machine.app'
```

Open `MaschineMachine.xcodeproj` for native app, core and helper targets. `Package.swift` also builds all executables and tests. Restricted environments may require `OTHER_SWIFT_FLAGS=-disable-sandbox` for compiler macro subprocesses. This is a build-tool setting, not a runtime security bypass. The bundle script uses the legacy SwiftPM native backend because this host denies the newer backend's dsymutil subprocess.

## Workflows

**Install:** drop ISO/PKG/library folders, or select files/folders. Analysis collects metadata across the entire batch before grouping library parts. Review artwork, sources, destinations, warnings and existing registrations. Import multiple XML files/directories or choose an explicit XML per candidate. Filter/sort/select the queue, choose batch/per-item destinations and resolve conflicts. Enable the helper in Settings for Full Install, or select Extract Only.

**Conflicts:** Ask blocks modification until you choose a policy. Merge/Update keeps unrelated files and replaces overlapping files in a verified staged tree. Replace swaps the entire library directory, retaining a backup until verification/commit. Skip performs no installation. Existing registered locations are shown and used by default, rather than silently creating a second registration elsewhere.

**Metadata:** explicit user XML wins over embedded XML, then ProductHints. Automatic online fallback uses `https://api.native-instruments.com/static/phints`, a 15-second timeout and a shared in-memory cache. Cancellation propagates to requests. Offline Mode makes no ProductHints request. Ambiguous records block Full Install until you explicitly choose XML. Metadata is parsed structurally; external entities and DTDs are rejected. Authoritative ContentVersion is used; absent versions use a logged `1.0.0` compatibility fallback.

**Libraries:** audit registration, content, permissions, XML and artwork; inspect details and reveal files in Finder. Repair… builds a review before any mutation. Locate Content… repairs broken paths using the selected existing library; it does not imply a move. Replace XML… uses an explicit product XML. Relocate… copies and hashes the library, updates/validates registration and offers optional post-verification Trash of the old content.

**Sources:** Keep is the default. Optional Trash runs only after selected dependents are verified. The implementation conservatively also retains a shared source if another detected dependent was unselected, failed, cancelled or skipped. Source identity/size/mtime inventories are compared before Trash; a changed source stays. Extract Only never triggers source cleanup. Trash uses FileManager's native reversible Trash API; there is no permanent-delete fallback.

**Results:** candidates retain final state and diagnostics, with Retry Failed and JSON report export. Logs have severity/search/filter/copy/save/reveal controls and persistent JSONL session files. Cancellation stops at chunk boundaries, rolls back unfinished registered installations, and preserves already committed successes. Quit offers safe cancellation before exiting.

## Artwork previews

Artwork is ranked across all resolved payload parts using product folders, filenames, actual image dimensions, aspect ratio and UI-asset penalties. MST_artwork is preferred but never required. Expand a queue row’s Artwork diagnostics to see the selected path, score and reasons, alternatives and rejections. Thumbnails use a bounded shared cache and decode off the main actor. See [artwork rules and diagnostics](docs/ARTWORK.md).

## Transactions and security

- Copy streams into a private destination-volume staging directory, hashes each source stream and reads back/hash-verifies each output. Hidden payload files are preserved. Existing libraries stay intact during staging.
- A durable client journal precedes the directory swap. Registration has a separate root-only undo journal before any plist/XML/artwork/permission mutation.
- The helper verifies all changed registration bytes and modes. Full success is acknowledged only after helper commit. Lost replies query durable state; uncertainty retains recovery data instead of guessing.
- Failed registration restores registration backups and the previous content directory. Restart recovery resolves incomplete content and repair transactions and cleans stale mounts/analysis workspaces. Failed rollback retains diagnostics and backups.
- Privileged writes use fixed NI roots, validated product names, bounded typed data and fd-relative `openat`/`renameat` with `O_NOFOLLOW`; links, devices and multiply-linked registration targets are rejected. The helper never accepts executable commands or arbitrary absolute write paths.
- A separate tightly constrained helper capability swaps root-owned product-named library directories directly under `/Users/Shared`. It validates the caller's private staging ownership and derives staging/backup names from a UUID. It cannot operate on NI Resources or arbitrary destinations.
- Permission repair is scoped to the selected product. Registered shared-library permission repair requires a matching existing ContentDir and PAResources, pins descriptors, rejects links/hardlinks, journals original modes and adds only missing read/traversal bits. Ordinary user-library repairs touch only paths owned by the current user. Arbitrary root-owned custom destinations remain subject to filesystem permissions; select a writable destination rather than granting a generic root filesystem capability.
- Raw fallback extraction does not execute installer scripts. System libarchive streams regular files/directories into a pinned private tree with a disk budget and rejects archive traversal, links and special files. xar inventory errors are captured in logs. Unsupported or corrupt compression fails visibly.

## Files and lifecycle

Registration changes are product-scoped:

- `/Library/Preferences/com.native-instruments.<Product>.plist` (preserves unrelated existing keys)
- `/Library/Application Support/Native Instruments/Service Center/<Product>.xml`
- `/Users/Shared/NI Resources/image/<Product>/` (preserves unrelated resource files)

Root transaction journals: `/Library/Application Support/Maschine Machine/Transactions` (root-owned; not group/world writable). User preferences use UserDefaults. User logs, analysis workspaces, client journals and mount receipts live below `~/Library/Application Support/Maschine Machine/`. ISO mounts are read-only under app-owned mount roots and detached on success, failure and cancellation. Workspace/session records support cleanup after abnormal termination. User-owned destination staging is `.maschine-<UUID>` beside the final library.

Do not manually delete a directory named in a recovery error. Restore/recover through Settings after helper authorization is available. Committed helper receipts are retained so a lost acknowledgement cannot cause a later incorrect rollback.

## Validation and remaining external acceptance

See [validation evidence](docs/VALIDATION.md) and [legacy compatibility](docs/COMPATIBILITY.md). Synthetic tests contain no copyrighted samples. The native and Intel wrappers validate actual XCTest case counts and fail on zero-test runs; the unused Swift Testing runner is disabled for native runs.

This host also refuses packaged GUI application registration; a separate minimal AppKit app reproduces the same system abort. GUI smoke testing must be repeated from an unrestricted desktop session. See VALIDATION.md.

This host has zero valid code-signing identities. It also refuses real disk-image attachment with `Device not configured`; the real ISO integration test explicitly skips on that condition. The multipart ISO analysis and cancellation tests use structured mount fixtures plus real generated PKGs. Run the real ISO test outside this execution restriction, then run a signed helper/NI acceptance test before distributing the app. Intel builds and Rosetta tests do not substitute for testing on physical Intel hardware.

Production notarization needs your Developer ID and Apple credentials. These are external inputs, not a disabled or unimplemented registration pipeline.
