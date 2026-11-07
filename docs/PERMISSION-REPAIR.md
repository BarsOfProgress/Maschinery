# Independent Library permission repair

## Root cause and complete workflow

The reported error originated in `SharedPermissions.scope`, formerly the guard that read exactly `com.native-instruments.<request.product>.plist` and compared its raw `ContentDir` string with the request’s POSIX path. That was inconsistent with `ExistingLibraryService.contentURL`, which already decodes Native Instruments’ legacy HFS `volume:folder:` paths when discovering installed libraries.

On this Mac, a read-only inventory found 262 system product preferences containing ContentDir: 254 used legacy HFS paths and eight used POSIX paths. For example:

- Plist: `Macintosh HD:Users:Shared:Anima Ascent Library:`
- Installed-products JSON and the Library model: `/Users/Shared/Anima Ascent Library`

They identify the same directory, but the old string comparison failed. Product identity was not the demonstrated cause in that example. Constructing a filename from display metadata and restricting repairs to a product-named direct child of `/Users/Shared` also made the old lookup needlessly restrictive for naming/path variations.

The previous workflow was Library Repair → AppModel.prepareRepair → RepairService.plan → embedded XML / ProductHints metadata lookup → RegistrationRequest(repairSharedPermissions: true) → authenticated helper → RegistrationEngine.apply → SharedPermissions.scope/snapshot/set → registration/XML/artwork writes and verification/commit. Thus even ordinary Repair bundled permission changes with registration creation or updates.

The new ordinary Repair path is Library Repair → permissionPlan (capture canonical path and root device/inode) → a permission-only review → client recovery receipt → existing authenticated helper → PermissionRepairEngine → scope/evidence validation → complete mode snapshot and durable helper journal → minimal fchmod changes → full verification → commit. It never invokes RegistrationBuilder, ProductHints or the NI registration writer. Library permission health now tests the current user’s effective read/traversal access rather than owner bits alone, so group/ACL access is correctly recognized. The helper refuses a message that mixes permission repair with registration/shared-content data. New combined legacy permission/registration requests are rejected; old journal recovery remains supported.

Explicit Locate Content, Replace XML, Relocate, installation and removal retain their existing deliberate registration workflows. They no longer silently include recursive permission changes. Permission-only Repair does not repair missing registration or artwork files; its review makes that scope explicit.

## Actual NI mechanisms investigated

NI’s current [macOS uninstall documentation](https://support.native-instruments.com/support/solutions/articles/69000879356-how-to-uninstall-native-instruments-software-from-a-mac-computer) identifies product preference plists, `/Users/Shared/Native Instruments/installed_products/<Product>.json`, and Service Center XML. Its [Repair / Relocate documentation](https://support.native-instruments.com/support/solutions/articles/69000879243-using-the-repair-relocate-function-in-native-access) describes locating/reinstalling product content; that is distinct from repairing filesystem modes.

Read-only inspection confirmed the system preferences and 264 installed-products JSON files on this Mac. Anima Ascent, Jersey Ride and Grey Forge JSON records contain POSIX ContentDir values corresponding to their legacy HFS plist values. Anima Ascent and Jersey Ride have no per-product Service Center XML here, so XML cannot be a universal prerequisite for permission repair. The user preference directory contained no ContentDir values. NTK configuration files and a Maschine browser database also exist; neither was assumed to be a required registration database or modified.

Permission verification now reads both actual system product preference records and installed-products JSON, normalizes product names to find the actual filenames, decodes ContentDir through the existing Library decoder, and compares canonical directory device/inode identity. These records are corroborating evidence, not write targets. Missing records or absent/empty ContentDir keys do not cause registration fabrication. Malformed or contradictory existing records fail closed with a diagnostic explaining the problem and paths.

## Is registration necessary?

No. Filesystem read/traversal permissions can be repaired independently of NI’s registration state, provided the target is independently verified as the selected expansion. An unregistered target must have native, nonempty `.mxgrp` / `.mxsnd` content under Groups/Sounds, a product-matching root name, and product-specific PAResources artwork evidence. A matching existing registration can corroborate a legacy product-named expansion with native content even if PAResources is absent. Empty marker directories or a matching registration alone are insufficient.

This is structural filesystem verification, not a purchase/licence check or cryptographic authentication of NI content. When strong evidence is unavailable, repair refuses to proceed rather than inventing metadata. Local discovery still uses its existing NI preference audit; this fix does not add a parallel scan of arbitrary user folders or silently import unregistered products into the catalogue.

## Scope and safety

- No NI preferences, installed-products JSON, Service Center XML, NI databases or global resource files are written by permission repair. Only Maschinery recovery journals and modes inside the verified expansion are changed.
- Paths are standardized, links are rejected before canonicalization, protected/root locations are refused, and the selected root is bound to its device and inode before review and rechecked in the helper.
- Descriptor-relative `openat` with O_NOFOLLOW pins traversal. Symlinks (including hidden entries), multiply linked regular files, special files, nested filesystems, changed file identities and content belonging to another non-root user are rejected.
- All entries are validated and snapshotted before modification. Enumeration uses a fresh directory description, checks read errors and includes hidden files; repeated walks cannot share a stale seek offset and miss content.
- Only missing read/traversal bits in the caller’s applicable owner/group/other POSIX class are added. Existing write bits, regular-file execution bits, ownership and group are preserved and checked. No chmod 777, recursive chown or ACL clearing occurs.
- Explicit read/traversal-denying ACLs, immutable/append-only flags, set-ID regular files and inaccessible targets produce diagnostics. The repair does not remove access restrictions to force success. It does not claim to fix Full Disk Access/TCC or read-only volume restrictions.
- Independent root-only helper journals live under Maschinery’s `Transactions/PermissionRepairs`. Conflicting/overlapping operations are refused. Original modes and identities support rollback, client receipt recovery and lost-commit handling; rollback does not require NI registration to remain present. A failed/unsafe rollback retains recovery data.
- The same signed helper is used for privileged access. An older running helper is detected by capability negotiation, with instructions to replace the installed app and restart its background item. No new helper identity or signing credentials are created.

## Verification

`PermissionRepairTests.swift` covers missing records and missing ContentDir keys, unchanged POSIX/HFS plists, read-only installed-products JSON, normalized filenames, contradictory paths, insufficient/arbitrary directory evidence, symlink/hardlink escapes, root replacement, selective mode changes, ownership rejection, ACL refusal, injected permission failures and rollback, restart/client receipt recovery, overlapping transactions, caller isolation, helper protocol dispatch and unchanged registration domains. The existing selective permission test now exercises the independent operation and checks registration byte identity; explicit registration repair/relocation tests remain separate.

The actual installed Anima Ascent directory and both registration representations were verified through the production scope verifier in an opt-in **read-only** probe. No actual expansion permissions or NI records were changed during investigation. Root-owned real-library mutation and macOS helper restart/approval are not claimed as exercised by the isolated user-context tests.

To repeat that read-only proof for an existing installed expansion:

```sh
MASCHINERY_PERMISSION_PROBE_PRODUCT='Anima Ascent' \
MASCHINERY_PERMISSION_PROBE_CONTENT='/Users/Shared/Anima Ascent Library' \
swift test --disable-sandbox --enable-xctest --disable-swift-testing \
  --filter PermissionRepairTests/testValidPOSIXAndLegacyHFSRegistrationsRemainByteIdentical
```

The opt-in branch only opens and verifies the real folder. Mode-changing assertions in that test run exclusively on its separately generated disposable fixture.
