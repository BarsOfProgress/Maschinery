# Expansion catalogue

Maschinery’s existing Libraries view combines the local `ExistingLibraryService.audit` results with metadata from the official [Maschine Expansions collection](https://www.native-instruments.com/collections/maschine-expansions). It retains the existing dark grid/list styles, artwork decoder, search, and local management actions. Installer, privileged-helper and NI registration mutations do not use the store catalogue.

## Inspection and architecture

Before implementation, the complete source/test/build structure was inspected. `SecondaryViews.swift` contained the local grid/list, search and management controls; `InstalledLibrary` and `ExistingLibraryService` supplied local registration/content/artwork health. `ArtworkService` ranks local payload and installed resource images. `ArtworkThumbnailCache` already performs bounded off-main decoding. `ProductHintsService` handles registration metadata and is separate from store listings. `background` propagates cancellation; Application Support journals/logs and AppStorage preferences provide persistence. These components remain in use.

New core files are `ExpansionCatalogue.swift` (store metadata, parser, validation, transport, persistence), `LibraryCatalogue.swift` (a projection over existing InstalledLibrary records, matching/filtering/statistics), and `OfficialArtworkCache.swift` (download cache feeding the existing thumbnail decoder). There is no second local library discovery mechanism or installer.

## Actual source and completeness

Verified on 2026-11-04: five unfiltered HTML pages, with 24 / 24 / 24 / 24 / 18 records. The page’s declared `numberOfItems` and the combined **114 unique products** agreed. Every included record had an NI vendor and an `Expansion - …` variant classification, including Maschine Central. This is a snapshot of current store listings, not a complete history of every expansion ever released.

The source embeds public Schema.org `CollectionPage` / `ItemList` JSON-LD with product name, official product link, primary featured artwork URL and stock availability. The public JSON-valued `var meta` theme block supplies Shopify product IDs and variant classification. Only these literal JSON values are decoded; JavaScript is never evaluated. Product-card description spans supply descriptions, available for all baseline entries. Genre and original release date were not supplied by this collection metadata; they remain absent rather than guessing from marketing prose or treating a store migration date as a release date.

No documented NI public collection API was found. Shopify’s documented Ajax API is intended for hosted themes; no undocumented `/products.json` endpoint, Storefront token or Admin API is used. The implementation follows ordinary `?page=N` links. ItemList positions restart at 1 on each page. Refresh validates each page and requires unique IDs/names and a total equal to `numberOfItems`. A missing page, inconsistent total, repeated page, unexpected product, invalid URL, empty response or suspicious reduction rejects the entire update. Large legitimate catalogue removals require review/update of the baseline rather than silently shrinking a collection.

The metadata-only baseline is `Sources/MaschineryCore/Resources/ExpansionCatalogue.json`. SwiftPM, the Xcode app and the bundle build all include it. Test fixtures retain only the relevant structured JSON blocks, pagination links, and description spans from the five recorded pages, without analytics tokens, cookies or page scripts.

## Matching and installation state

Matching uses namespaced NI UPID/RegKey mappings where explicitly maintained, then exact `ProductName.key` normalization, then explicit aliases. It does not fuzzy-match. Shopify product IDs and store SKUs are not NI product identifiers. Current baseline aliases/NI-ID overrides are empty because no semantic differences were verified; casing, spaces, punctuation and Library suffixes already normalize. Future verified mappings can be added to the baseline and survive refreshes by stable store ID. Conflicting or ambiguous identifier/alias matches stay unlisted rather than being guessed.

The view projects store metadata and existing InstalledLibrary registrations into one stable row per matched expansion. Multiple local registrations remain available in its details. A registered but missing/offline content directory remains available for Locate Content and Uninstall, but does not count as installed. Pure catalogue rows have no installation/maintenance actions. Unlisted local libraries remain visible and do not affect completion. The app does not check ownership, licensing or purchase history. “Missing” means not detected locally.

Statistics are withheld until a local scan succeeds and a complete catalogue is available. They are calculated against the dated snapshot; stale/offline snapshots are labelled. Search/filter changes preserve the search string, sort independently of installation state and do not initiate catalogue requests.

## Refresh, offline operation and storage

`~/Library/Application Support/Maschinery/Catalogue/catalogue.json` is validated and loaded before networking. The bundled baseline is used if the cache is absent/corrupt. A due background refresh is checked once on launch; Settings defaults to a 24-hour cache age for that startup check. Later catalogue updates are manual. Switching tabs and returning online do not refresh the catalogue. Manual Refresh bypasses the age check. Offline Mode makes no new catalogue/artwork requests and cancels active artwork tasks. Failed automatic attempts back off for an hour in the current session. Failed refreshes retain both the previous snapshot and last successful date. Only a fully validated replacement is atomically persisted. Catalogue work is separate from the model’s installer task/busy state.

Requests are anonymous, read-only, timed out, host/path validated, response-size bounded and paginated sequentially with a pause. There are no cookies, purchases, authentication, anti-bot bypasses or requests to sorted/filtered collections prohibited by [robots.txt](https://www.native-instruments.com/robots.txt). An HTTP failure or changed markup preserves the baseline/cache.

## Artwork and usage limitations

Local artwork always takes priority and is never overwritten. For a missing/corrupt local image, official collection featured artwork is retrieved on demand at the published 800px URL and shown with its full aspect ratio. These are the store’s primary product-card images, not arbitrary gallery or promotional banner selections. No store image bytes are bundled or redistributed in the app or fixtures.

`~/Library/Caches/Maschinery/OfficialArtwork/` contains a versioned-URL SHA-256 disk cache capped at 128 MiB, with three concurrent downloads, shared in-flight tasks, one-hour negative-result backoff, image validation and LRU eviction. Subsequent views and offline restarts reuse disk files. The existing 32 MiB / 128-thumbnail memory cache handles decoding. Obsolete view results are ignored and offline changes cancel downloads. Invalid/missing images use the same existing placeholder.

NI’s [terms of service](https://www.native-instruments.com/policies/terms-of-service), §11 for NI and §9 for inMusic, restrict downloading/reuse of demonstration content labelled not for sale without agreement. Public access and inclusion of an image URL in structured metadata do not establish a redistribution licence. No permission to bundle or redistribute official artwork has been established. The implementation only displays store product artwork through runtime retrieval and private local caching, with attribution/product links. A public distributor should obtain NI confirmation for that use; this project does not claim a licence or download demonstration media/audio. The source may change or restrict access in future, in which case cached data/placeholders remain usable.

## Verification

Run the normal offline regression suite with `scripts/test-native.sh`; recorded fixtures are used for catalogue parsing, matching, caching, failure and persistence tests. Existing installer/registration/repair/relocation/uninstall tests stay in the suite.

To explicitly verify the live transport and an official artwork sample:

```sh
MASCHINERY_LIVE_CATALOGUE=1 swift test --disable-sandbox --enable-xctest \
  --disable-swift-testing --filter CatalogueTests/testLiveCatalogueAndOfficialArtworkWhenRequested
```

The live check on 2026-11-04 retrieved 114 unique products, downloaded and decoded the first listing’s artwork, then reused it offline. It does not assert that every artwork URL will remain reachable. Normal offline test runs explicitly skip this one network-only test.

## Files in this enhancement

Added:
- `Sources/MaschineryCore/ExpansionCatalogue.swift`
- `Sources/MaschineryCore/LibraryCatalogue.swift`
- `Sources/MaschineryCore/OfficialArtworkCache.swift`
- `Sources/MaschineryCore/Resources/ExpansionCatalogue.json`
- `Tests/MaschineryCoreTests/CatalogueTests.swift`
- Five `Tests/MaschineryCoreTests/Fixtures/collection-page-*.html` fixtures
- `docs/CATALOGUE.md`

Updated:
- `Sources/Maschinery/SecondaryViews.swift` — existing Libraries view and catalogue settings
- `Sources/Maschinery/AppModel.swift` — independent catalogue lifecycle and local scan completion state
- `Sources/Maschinery/MaschineryApp.swift` — existing ArtworkView fallback and offline change handling
- `Sources/MaschineryCore/Libraries.swift` — scoped NI identifier extraction
- `Package.swift`, `Maschinery.xcodeproj/project.pbxproj`, `scripts/build-app.sh`, `scripts/sync-xcode.py` — source/resource integration
- `README.md`, `docs/VALIDATION.md` — workflow and evidence

## Expansion-only filtering and session loading

The local expansion filter requires actual nonempty native Maschine group/sound presets (including legacy formats), or product-scoped metadata declaring native Maschine content. A folder named Groups/Sounds alone is insufficient: Kontakt 8 has a groups folder containing Kontakt .nkg files. Host applications and their base factory libraries are excluded explicitly. Known catalogue products or matching native metadata keep missing/offline expansions visible. Unrelated XML cannot provide that evidence.

The app model owns the first local scan state, so recreating Libraries on a sidebar change does not start another audit. Catalogue loading is also guarded once per app session; no hourly timer remains. Refresh and Refresh / Audit remain explicit actions. Actual installs invalidate local results, and maintenance/removal update their local snapshot; navigation alone does not refresh anything.
