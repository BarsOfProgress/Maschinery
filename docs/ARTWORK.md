# Artwork discovery and diagnostics

Preview discovery is independent of installation/registration. It runs once a logical expansion's payload parts have been grouped and its metadata name resolved. Every part contributes its recursive PAResources/image tree. Adding another part in a later drop reruns discovery for the combined payloads. Library previews reuse the same ranking and can fall back to that product's installed NI Resources image directory.

No particular filename is mandatory. PNG, JPG/JPEG, TIFF, GIF, BMP, HEIC/HEIF, WebP and other recognized ImageIO formats are considered; formats unavailable to the OS decoder are rejected with a reason. ImageIO reads metadata without decoding full-size pixels during ranking.

Ranking uses additive relative scores (not confidence percentages):

| Evidence | Points |
|---|---:|
| Valid, useful image | +20 |
| MST_artwork stem | +65 |
| Artwork / cover stem, otherwise | +35 / +32 |
| Expansion / product / library stem, otherwise | +24 / +22 / +20 |
| Browser / tile stem, otherwise | +12 / +8 |
| Any enclosing directory matches normalized resolved product | +45 |
| Enclosing directory matches a normalized payload alias, otherwise | +30 |
| Area at least 512×512; otherwise at least 256×128 | +22 / +14 |
| Area below 128×128 | -15 |
| Landscape ratio 1.35–2.5 (browser-like); otherwise 1.1–3.0 | +22 / +10 |
| Approximately square; otherwise portrait/narrow | +4 / -15 |
| Icon, badge, logo, button, sprite, knob, toolbar or similar stem | -55 |
| UI/icons/buttons/sprites/controls/interface/toolbar directory | -35 |

Unreadable metadata, edges below 48 pixels, longest edge below 96 pixels, extreme aspect ratios (<0.2 or >6), and implausibly huge dimensions are rejected. Compact real browser artwork such as 134×66 is accepted. A useful-size icon may remain a penalized fallback when nothing better exists; tiny icons never win even if named MST_artwork. Equal scores prefer more pixels, then a stable lexical path.

ExpansionCandidate.artworkDiscovery retains the best eight plausible candidates, up to twelve rejection diagnostics, counts, dimensions, scores, reasons and search warnings. Logs identify the selection and alternate/rejected examples. Expand a queue row → **Artwork diagnostics** to see the selected full path, why it won, alternatives and rejections. Missing artwork remains a non-fatal warning and uses the dark product-name placeholder.

All artwork views share ArtworkThumbnailCache, a non-main actor that performs bounded ImageIO thumbnail decoding serially. It caches decoded CGImages with a 32 MiB cost limit and 128-entry cap. The key includes path, inode, file size, modification timestamp and requested size. Changed files invalidate naturally; missing/cancelled loads cannot leave a stale image displayed. Full-size bitmap decoding is not performed in SwiftUI body evaluation.

Synthetic tests generate actual PNG/JPEG/TIFF image files. Coverage includes competing filenames/sizes/aspects, nested product matching, metadata-resolved multipart discovery in either input order, tiny/corrupt assets, no images, low-priority icon fallback, diagnostic retention/logging, installed JPEG previews and off-main cache reuse/invalidation. Installation, registration, privileged operations and payload copying are unchanged by this artwork update.
