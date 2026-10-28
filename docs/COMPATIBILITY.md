# Legacy behavior inventory

Entire reference script reviewed (587 lines). The following maps every compatibility branch to its replacement and validation target. “Pending” means a release gate, not an intentionally removed feature.

| Legacy behavior | Replacement | Validation |
|---|---|---|
| Mixed folder/ISO/PKG batch, hidden entries skipped | SourceDiscovery, package boundary pruning | Synthetic discovery |
| ISO read-only/no Finder; readable volume | hdiutil attach -plist -readonly -nobrowse | Real ISO integration pending |
| Multiple PKGs on ISO | Collect every extracted tree before resolution | Synthetic multipart; ISO integration pending |
| XML in separate installer PKG | Shared metadata pool for complete batch | Matching tests |
| Loose top-level ISO Library | Same root detector on mounted volume | Synthetic loose layout |
| Service Center / Service Centre | XML tree discovery independent of spelling | XML tests |
| pkgutil --expand-full | ProcessRunner abstraction | Generated PKG integration pending |
| Bundle PKG fallback | Copy bundle to workspace | Bundle integration pending |
| xar nonzero but useful output | Log fallback, inspect resulting output | Failure injection pending |
| Name contains Library incl concatenation/parts | RootDetector + normalized grouping | Root and normalization tests |
| PAResources without Library name | RootDetector | Root tests |
| Library PKG with different payload name | Payload wrapper fallback | Wrapped fixtures |
| Multiple subfolders under Payload | Return all content roots | Wrapped fixtures |
| Scripts/Resources/Contents/PackageInfo/__MACOSX | Ignore metadata in fallback | Metadata-only fixtures |
| Installer/setup with no payload | Log metadata component, no fake candidate | Metadata-only fixtures |
| Shared XML variants spaces/underscores | Structured XML + normalized matching | Matching tests |
| Multiple parts merge | Group normalized identity, retain all payloads | Multipart test |
| PAResources/image/product/MST_artwork.png | Recursive artwork discovery | Artwork fixture |
| Embedded XML | Batch metadata collection | XML fixture |
| ProductHints fallback | Actor provider, timeout, cache, offline gate | Live endpoint validation pending |
| Explicit XML/offline | Highest-priority metadata and no network | Override tests |
| Manual payload extraction | Same analysis, Extract Only plan | Copy/rollback tests |
| Plist ContentDir/ContentVersion | Typed registration contract | Signed helper pending |
| NI resource image copy | Product-scoped registration operation | Signed helper pending |
| Service Center XML | Fixed helper destination | Signed helper pending |
| Post-copy nonempty check | Byte manifest verification | Transaction tests |

Deliberately removed: mv from sources, fixed /tmp paths, title-casing authoritative names, silent network exceptions, rm -rf conflicts, broad recursive chmod/chown, sudo heartbeat and terminal password prompts. Source cleanup must require verified success for ALL dependents (including unselected dependents).
