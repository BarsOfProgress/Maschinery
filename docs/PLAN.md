# Implementation plan and release gates

1. Foundation: Swift package with independently testable core and native SwiftUI executable; typed models, settings, logging, OLED design.
2. Analysis: immutable source discovery, unique workspaces, plist ISO attachment, package extraction, batch-wide XML collection, payload grouping and matching.
3. Review: bulk queue, artwork, selection, diagnostics, destinations, XML import and offline controls.
4. Installation: staged copy, explicit conflicts, verification, rollback, cancellation; privileged registration behind a narrow service boundary.
5. Libraries: registration discovery, health audit, selective repair and copy/verify relocation.
6. Hardening: synthetic tests, process and mount cancellation, malicious fixtures, recovery journals, accessibility review.
7. Distribution: Universal 2 app bundle, Xcode integration, signed helper, notarization and real Maschine acceptance tests.

Do not mark v1 complete until all release gates in README pass. No production writes to NI registration locations until authenticated helper is implemented and tested. No legacy installer scripts are executed.

# Privilege decision

Apple recommends SMAppService.daemon(plistName:) for macOS 13+ launch daemons. Registration requires administrator approval in System Settings. The future helper must authenticate the client's audit token against the app identifier and signing team, accept typed registration data rather than arbitrary commands or destinations, and perform fd-relative/no-follow writes to fixed NI directories. Unsigned development supports analysis and Extract Only. Signing identity is a distribution input, not permission to use sudo as a substitute.

Source: https://developer.apple.com/documentation/servicemanagement/smappservice
