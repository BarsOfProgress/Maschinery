# Maschinery


<img width="1112" height="800" alt="image" src="https://github.com/user-attachments/assets/6790f362-c716-41eb-88eb-e79b82025ec6" />

<img width="1112" height="800" alt="image" src="https://github.com/user-attachments/assets/371a49f0-0826-4590-9c6e-c1fb49d2cbc6" />

<img width="1112" height="800" alt="image" src="https://github.com/user-attachments/assets/5fe760f3-e111-485c-a897-8e848783a26b" />


Version 1.0.5r1 (build 2).


Native SwiftUI companion for bulk Maschine library installation, extraction, auditing, repair and relocation. macOS 14+, Universal 2. Independent utility; not affiliated with or endorsed by Native Instruments.

## Install the macOS release

For full functionality, download and open **Maschinery-vVERSION-Full-Install.pkg** from [GitHub Releases](https://github.com/BarsOfProgress/Maschinery/releases). Quit Maschinery first, including in other login sessions. The installer asks for administrator approval, installs the app in Applications and sets up elevated installation privileges automatically. Open Maschinery normally afterwards. Your Mac needs no developer certificate or developer account.

The installed components use ad-hoc signatures with hardened runtime. The package is unsigned and not notarized, so macOS may require an explicit exception in **System Settings → Privacy & Security → Open Anyway** after the first opening attempt. See [Apple's instructions](https://support.apple.com/en-us/102445). A checksum helps verify the downloaded artifact, but does not identify its publisher; obtain the package from a source you trust.

Use the same full installer for updates. Finish or recover library operations and quit Maschinery before updating. No separate component setup is required. Settings shows **Elevated privileges for installation enabled** when installation and maintenance are available. App-only DMGs from earlier releases do not set up these privileges.

The installer implementation is new. Automated isolated installation/rollback tests and live ad-hoc XPC authentication probes do not replace a clean-Mac administrator installation and real-library acceptance pass. See [the helper design and acceptance checklist](docs/INSTALLER-HELPER.md).

## Development build

Builds require no paid Apple Developer account. Use `SIGNING_IDENTITY=- scripts/build-app.sh`, then `scripts/package-installer.sh` to produce the full installer and helper uninstaller. Python is used only during package construction, not on the recipient's Mac. The app never runs as root. The root setup tool accepts only fixed install/recover/remove operations, and the root daemon accepts only its existing typed library operations.

An existing Apple-signed development build can still use the original SMAppService path. Before migrating an enabled legacy helper, unregister it using the earlier development build that provides **Settings → Remove Helper…**, then quit and run the new installer. The current interface leaves component management to the installer. See [signing details](docs/SIGNING.md).

The development bundle is `dist/Maschinery.app`. The package build does not install it or alter this Mac's system helper. See [release instructions](docs/RELEASING.md).

## Build and test

Requires current Xcode and Swift 6. No Python, Homebrew or downloadable runtime is required by the application. The archive fallback links Apple's system libarchive. `scripts/sync-xcode.py` is an optional developer-only project generator; the generated project is committed.

```sh
swift build --disable-sandbox
scripts/test-native.sh      # XCTest only; rejects zero-test runs
scripts/test-intel.sh       # x86_64 XCTest under Rosetta on Apple Silicon
SIGNING_IDENTITY=- scripts/build-app.sh  # Universal 2 app, helper and setup tool
scripts/package-installer.sh # Full Install and Remove Helper packages
scripts/test-helper-trust.sh # Real XPC hash acceptance/rejection probes
open 'dist/Maschinery.app'
```

Open `Maschinery.xcodeproj` for native app, core and helper targets. `Package.swift` also builds all executables and tests. Restricted environments may require `OTHER_SWIFT_FLAGS=-disable-sandbox` for compiler macro subprocesses. This is a build-tool setting, not a runtime security bypass. The bundle script uses the legacy SwiftPM native backend because this host denies the newer backend's dsymutil subprocess.

## Workflows

**Install:** drop ISO/PKG/library folders, or select files/folders. Analysis collects metadata across the entire batch before grouping library parts. Review artwork, sources, destinations, warnings and existing registrations. Import multiple XML files/directories or choose an explicit XML per candidate. Filter/sort/select the queue, choose batch/per-item destinations and resolve conflicts. Install the matching Full Install package for privileged features, or select Extract Only.

**Uninstall:** select a library in Libraries, then choose **Uninstall…**. Review its registered path and choose **Uninstall, Keep Files** or **Uninstall and Move to Trash**. The helper journals, removes and verifies the selected product’s registration plist and Service Center XML; cached artwork is retained. Content moves to native reversible Trash only after registration commits. Shared/overlapping registered content blocks Trash; choose Keep Files instead. A Trash failure reports the retained path. Unfinished registration removal uses the same launch recovery as repairs.

**Reinstall:** an already registered expansion shows **Overwrite Installed Library** and **Install Elsewhere…** directly in the install queue. Overwrite selects the registered path and Replace policy; press Install to execute it. Installing elsewhere updates registration to the new destination and preserves the old content. Reinstall is also available after a successful install in the current queue.

**Conflicts:** Ask blocks modification until you choose a policy. Merge/Update keeps unrelated files and replaces overlapping files in a verified staged tree. Replace swaps the entire library directory, retaining a backup until verification/commit. Skip performs no installation. Existing registered locations are shown and used by default, rather than silently creating a second registration elsewhere.

**Metadata:** explicit user XML wins over embedded XML, then ProductHints. Automatic online fallback uses `https://api.native-instruments.com/static/phints`, a 15-second timeout and a shared in-memory cache. Cancellation propagates to requests. Offline Mode makes no ProductHints request. Ambiguous records block Full Install until you explicitly choose XML. Metadata is parsed structurally; external entities and DTDs are rejected. Authoritative ContentVersion is used; absent versions use a logged `1.0.0` compatibility fallback.

**Libraries:** show Maschine content libraries (Groups/Sounds), excluding Kontakt-only instruments and NKS plug-in registrations. Native Access POSIX and legacy volume:folder: content paths are supported. Missing Service Center XML alone is not a fault; Repair appears only when the audit reports an issue. Audit registration, content, permissions, existing XML and artwork; inspect details and reveal files in Finder. Repair… now reviews an independent permission-only operation; it never creates or rewrites NI registration records. Locate Content / Replace XML retain their separate explicit registration reviews. See [permission repair investigation and safety](docs/PERMISSION-REPAIR.md). Locate Content… repairs broken paths using the selected existing library; it does not imply a move. Replace XML… uses an explicit product XML. Relocate… copies and hashes the library, updates/validates registration and offers optional post-verification Trash of the old content.

**Sources:** Keep is the default. Optional Trash runs only after selected dependents are verified. The implementation conservatively also retains a shared source if another detected dependent was unselected, failed, cancelled or skipped. Source identity/size/mtime inventories are compared before Trash; a changed source stays. Extract Only never triggers source cleanup. Trash uses FileManager's native reversible Trash API; there is no permanent-delete fallback.

**Results:** candidates retain final state and diagnostics, with Retry Failed and JSON report export. Logs have severity/search/filter/copy/save/reveal controls and persistent JSONL session files. Cancellation stops at chunk boundaries, rolls back unfinished registered installations, and preserves already committed successes. Quit offers safe cancellation before exiting.

## Expansion catalogue

Libraries now combines the official store catalogue with local detection, with **All / Installed / Missing**, search, A–Z/Z–A sorting, dynamic completion statistics, official product links and the existing local management actions. Unlisted local libraries remain visible; missing means not detected locally and says nothing about ownership. Statistics wait for a successful local scan.

A verified metadata-only baseline is bundled for offline use. A persistent catalogue is checked once at launch when its cache is older than the configured age (24 hours by default); later updates use **Refresh**. Returning to Libraries reuses the existing local scan and catalogue. The last successful catalogue date remains visible. Invalid/incomplete refreshes preserve the previous snapshot. Official product artwork is fetched on demand and cached separately; local artwork always takes priority. No official artwork is bundled, and no NI content is changed by catalogue refreshes. See [catalogue sources, matching, caching, usage limitations and verification](docs/CATALOGUE.md).

## Artwork previews

Artwork is ranked across all resolved payload parts using product folders, filenames, actual image dimensions, aspect ratio and UI-asset penalties. MST_artwork is preferred but never required. Expand a queue row’s Artwork diagnostics to see the selected path, score and reasons, alternatives and rejections. Thumbnails use a bounded shared cache and decode off the main actor. See [artwork rules and diagnostics](docs/ARTWORK.md).

## Transactions and security

- Copy streams into a private destination-volume staging directory, hashes each source stream and reads back/hash-verifies each output. Hidden payload files are preserved. Existing libraries stay intact during staging.
- A durable client journal precedes the directory swap. Registration has a separate root-only undo journal before any plist/XML/artwork/permission mutation.
- The helper verifies all changed registration bytes and modes. Full success is acknowledged only after helper commit. Lost replies query durable state; uncertainty retains recovery data instead of guessing.
- Failed registration restores registration backups and the previous content directory. Restart recovery resolves incomplete content and repair transactions and cleans stale mounts/analysis workspaces. Failed rollback retains diagnostics and backups.
- Privileged writes use fixed NI roots, validated product names, bounded typed data and fd-relative `openat`/`renameat` with `O_NOFOLLOW`; links, devices and multiply-linked registration targets are rejected. The helper never accepts executable commands or arbitrary absolute write paths.
- A separate tightly constrained helper capability swaps root-owned product-named library directories directly under `/Users/Shared`. It validates the caller's private staging ownership and derives staging/backup names from a UUID. It cannot operate on NI Resources or arbitrary destinations.
- Permission repair is independent of registration. It validates canonical root identity, native Groups/Sounds presets and product evidence, reads existing plist/installed-products JSON only as corroboration, and refuses contradictory locations. It pins descriptors, rejects links/hardlinks/nested filesystems, journals original modes and adds only missing read/traversal bits in the caller’s applicable POSIX class. Ownership, write permissions, regular-file execution bits and ACLs are preserved; explicit read-denying ACLs/locked files produce diagnostics. No recursive chown or blanket chmod is used. Generic privileged installation to arbitrary destinations remains unsupported.
- Raw fallback extraction does not execute installer scripts. System libarchive streams regular files/directories into a pinned private tree with a disk budget and rejects archive traversal, links and special files. xar inventory errors are captured in logs. Unsupported or corrupt compression fails visibly.

## Files and lifecycle

Registration changes are product-scoped:

- `/Library/Preferences/com.native-instruments.<Product>.plist` (preserves unrelated existing keys)
- `/Library/Application Support/Native Instruments/Service Center/<Product>.xml`
- `/Users/Shared/NI Resources/image/<Product>/` (preserves unrelated resource files)

Root transaction journals: `/Library/Application Support/Maschinery/Transactions` (root-owned; not group/world writable). User preferences use UserDefaults. User logs, analysis workspaces, client journals and mount receipts live below `~/Library/Application Support/Maschinery/`. ISO mounts are read-only under app-owned mount roots and detached on success, failure and cancellation. Workspace/session records support cleanup after abnormal termination. User-owned destination staging is `.maschinery-<UUID>` beside the final library.

Do not manually delete a directory named in a recovery error. Reopen Maschinery after installation privileges are available to retry automatic recovery. Committed helper receipts are retained so a lost acknowledgement cannot cause a later incorrect rollback.

## Validation and remaining external acceptance

See [validation evidence](docs/VALIDATION.md) and [legacy compatibility](docs/COMPATIBILITY.md). Synthetic tests contain no copyrighted samples. The native and Intel wrappers validate actual XCTest case counts and fail on zero-test runs; the unused Swift Testing runner is disabled for native runs.

This host also refuses packaged GUI application registration; a separate minimal AppKit app reproduces the same system abort. GUI smoke testing must be repeated from an unrestricted desktop session. See VALIDATION.md.

The agent sandbox can hide valid login Keychain signing identities; see SIGNING.md for the verified existing identity and build instructions. This host previously refused real disk-image attachment with `Device not configured`; the real ISO integration test explicitly skips on that condition. The multipart ISO analysis and cancellation tests use structured mount fixtures plus real generated PKGs. Run the real ISO test outside this execution restriction, then run a signed helper/NI acceptance test before distributing the app. Intel builds and Rosetta tests do not substitute for testing on physical Intel hardware.

Production notarization needs your Developer ID and Apple credentials. These are external inputs, not a disabled or unimplemented registration pipeline.
