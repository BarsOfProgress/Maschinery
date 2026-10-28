# Legacy compatibility inventory

The entire 587-line legacy script was reviewed before the foundation. Its installer-layout knowledge is preserved independently of its GUI and unsafe mutation behavior.

| Case | Implementation / evidence |
|---|---|
| Mixed ISO/PKG/folder sources, hidden discovery entries ignored | SourceDiscoveryService; payload copy itself preserves hidden files |
| Read-only ISO, no Finder windows, actual mount path | Plist hdiutil output, private mountroot, durable mount receipts |
| Multiple PKGs in one ISO | Multipart ISO fixture with three generated real PKGs |
| XML in another metadata-only PKG | Shared metadata collection before resolution; generated PKG and ISO tests |
| Loose library folders on ISO | Same root detector; loose library in multipart ISO test |
| Service Center / Service Centre | Structural XML collection regardless of spelling; fixtures include Centre |
| pkgutil --expand-full primary | Real generated package tests |
| Bundle packages | Directory fallback; Contents/Archive.pax.gz fixture |
| pkgutil failure / xar fallback | Logged xar inventory plus confined system-libarchive XAR/Payload extraction; injected failure test |
| Useful partial extraction despite xar nonzero | Inventory exit is logged, not treated as proof of unusability; safe extraction validates its own output. Corrupt/incomplete content is rejected visibly. Raw unsafe xar filesystem extraction was deliberately replaced. |
| Name contains Library, including concatenated/multipart names | Root and normalization tests |
| PAResources root without Library in name | Root tests and bundle fixture |
| Library PKG filename with differently named payload | Payload-wrapper fallback fixtures |
| Payload wrappers and multiple directories | Recursive wrapper fixtures |
| Scripts/Resources/Contents/PackageInfo/__MACOSX exclusions | Root detector and metadata-only fixtures |
| Installer/setup metadata-only package | Contributes XML without a fake expansion candidate |
| Space/underscore/hyphen/concatenated identity | Conservative normalized matching; ambiguous records require explicit selection |
| Multipart payloads merge into logical expansion | 40-expansion offline batch and multipart ISO fixture |
| PAResources/image/product/MST_artwork.png | Artwork discovery, async UI thumbnails, RegistrationBuilder product-scoped resource installation |
| Embedded XML | Structured parser; full registered-install tests |
| ProductHints fallback | Automatic provider, 15-second timeout, shared cache, cancellation, visible failures |
| Offline/user XML | User priority; batch and individual import; 40-expansion fully offline install test |
| Manual payload extraction | Shared planner/copy/verification pipeline without NI registration |
| NI plist ContentDir/ContentVersion | Real plist serialization/read-back; retains unrelated keys; logged 1.0.0 fallback only without an authoritative version |
| NI Resources artwork | Product-scoped fixed-root writes, verification and undo |
| Service Center XML | Fixed-root writes, structural validation and byte read-back |
| Permission repair | Selected NI registration/resource files; inode-checked selected library modes; no recursive repair of /Library/Preferences |
| Copy success verification | Chunked SHA-256 copy/read-back plus registration verification |
| Source preservation/cleanup | Copy only; source identity recheck and all-dependent success gate before native Trash |

Signing/authorization is an external validation requirement, not an unimplemented helper. The root engine, XPC client/server, embedded daemon, signing configuration and Full Install UI path are present. See VALIDATION.md for which tests require a signed app or a host with a working disk-image service.

Deliberately removed: source mv, fixed /tmp paths, guessed title-casing of product names, swallowed network exceptions, raw rm -rf conflicts, broad chmod/chown, sudo heartbeat and Terminal password prompts.
