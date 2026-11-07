import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MaschineryCore

enum SyntheticArtworkFixture {
    static func image(at url: URL, width: Int = 640, height: Int = 360, type: UTType = .png) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }
}
final class ArtworkTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func image(_ path: String, in payload: URL, width: Int = 640, height: Int = 360, type: UTType = .png) throws -> URL {
        let url = payload.appendingPathComponent("PAResources/image/" + path)
        try SyntheticArtworkFixture.image(at: url, width: width, height: height, type: type); return url
    }
    func testMSTArtworkIsPreferredButNotRequired() throws {
        let root = try fixture()
        let mst = try image("Test/MST_artwork.png", in: root)
        _ = try image("Test/cover.png", in: root)
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, mst.resolvingSymlinksInPath().path)
        XCTAssertTrue(report.selected!.reasons.contains { $0.contains("MST_artwork") })
        XCTAssertEqual(report.consideredCount, 2); XCTAssertEqual(report.rankedCandidates.count, 2)
    }
    func testDifferentlyNamedJPEGArtwork() throws {
        let root = try fixture()
        let jpeg = try image("Test/Front_Cover.JPG", in: root, type: .jpeg)
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, jpeg.resolvingSymlinksInPath().path)
        XCTAssertEqual(report.selected?.width, 640); XCTAssertEqual(report.selected?.height, 360)
        XCTAssertTrue(report.selected!.reasons.contains { $0.contains("cover filename") })
    }
    func testRanksCompetingImagesAndCorrectProductAboveOtherProduct() throws {
        let root = try fixture()
        let cover = try image("Test/cover.png", in: root)
        _ = try image("Test/logo.png", in: root, width: 1024, height: 1024)
        _ = try image("Test/texture.png", in: root, width: 2048, height: 2048)
        _ = try image("Other Product/MST_artwork.png", in: root, width: 2048, height: 1024)
        _ = try image("Test/controls/slider.png", in: root, width: 2048, height: 64)
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, cover.resolvingSymlinksInPath().path)
        XCTAssertEqual(report.consideredCount, 5); XCTAssertEqual(report.plausibleCount, 4)
        XCTAssertTrue(report.rejectedCandidates.contains { $0.rejectionReason?.contains("aspect ratio") == true })
        XCTAssertTrue(zip(report.rankedCandidates, report.rankedCandidates.dropFirst()).allSatisfy { $0.score >= $1.score })
    }
    func testTinyIconCannotBeatLargerUsefulArtworkAndLogsRejection() async throws {
        let root = try fixture()
        _ = try image("Test/icon.png", in: root, width: 64, height: 64)
        let visual = try image("Test/Visual.jpeg", in: root, width: 800, height: 450, type: .jpeg)
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, visual.resolvingSymlinksInPath().path)
        let rejected = try XCTUnwrap(report.rejectedCandidates.first)
        XCTAssertEqual(rejected.rejectionReason, "tiny dimensions")
        XCTAssertTrue(rejected.reasons.contains { $0.contains("icon") })
        let logger = LoggingService(); await ArtworkService.log(report, product: "Test", to: logger)
        let messages = await logger.snapshot().map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("Artwork: considered 2 images") })
        XCTAssertTrue(messages.contains { $0.contains("Artwork: selected") && $0.contains("score") })
        XCTAssertTrue(messages.contains { $0.contains("Artwork: rejected") && $0.contains("64x64") && $0.contains("icon") })
    }
    func testNestedNormalizedProductDirectoryBeatsGenericCoverName() throws {
        let root = try fixture()
        let actual = try image("Nested/vintage_heat-library/Assets/Unnamed.png", in: root)
        _ = try image("Generic/cover.png", in: root)
        let report = try ArtworkService.discover(payloads: [root], productName: "Vintage Heat")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, actual.resolvingSymlinksInPath().path)
        XCTAssertTrue(report.selected!.reasons.contains { $0.contains("normalized product directory match") })
    }
    func testDimensionsAndBrowserAspectRatioRankUnnamedImages() throws {
        let root = try fixture()
        _ = try image("Test/a-small.png", in: root, width: 128, height: 128)
        _ = try image("Test/b-square.png", in: root, width: 1024, height: 1024)
        let landscape = try image("Test/z-landscape.png", in: root, width: 1024, height: 576)
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, landscape.resolvingSymlinksInPath().path)
        XCTAssertTrue(report.selected!.reasons.contains { $0.contains("browser landscape aspect") })
    }
    func testMultipartResolvesArtworkInLaterPartAfterMetadataMatching() async throws {
        let root = try fixture()
        let first = root.appendingPathComponent("VintageHeat Library Part 1"), second = root.appendingPathComponent("Vintage Heat Library Part 2")
        try FileManager.default.createDirectory(at: first.appendingPathComponent("Samples"), withIntermediateDirectories: true)
        _ = try image("VintageHeat/icon.png", in: first, width: 64, height: 64)
        let actual = try image("Vintage Heat/Alternate_Title.jpeg", in: second, type: .jpeg)
        let metadata = try MetadataXML.parse(Data("<ProductHints><Product><Name>Vintage Heat</Name></Product></ProductHints>".utf8), source: .user)
        let result = try await ExpansionAnalyzer(log: LoggingService()).analyze([first, second], destination: root.appendingPathComponent("out"), explicit: metadata, offline: true)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(candidate.payloads.count, 2)
        XCTAssertEqual(candidate.name, "Vintage Heat"); XCTAssertEqual(candidate.artwork?.resolvingSymlinksInPath().path, actual.resolvingSymlinksInPath().path)
        XCTAssertEqual(candidate.artworkDiscovery?.consideredCount, 2)
        XCTAssertFalse(candidate.warnings.contains("Artwork unavailable"))
        // Input order must not decide which part supplies the logical expansion's artwork.
        let reverse = try await ExpansionAnalyzer(log: LoggingService()).analyze([second, first], destination: root.appendingPathComponent("out"), explicit: metadata, offline: true)
        XCTAssertEqual(reverse.candidates.first?.artwork?.resolvingSymlinksInPath().path, actual.resolvingSymlinksInPath().path)
    }
    func testNoArtworkRemainsNonFatalAndUsesPlaceholder() async throws {
        let root = try fixture(), library = root.appendingPathComponent("Test Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let result = try await ExpansionAnalyzer(log: LoggingService()).analyze([library], destination: root.appendingPathComponent("out"), offline: true)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertNil(candidate.artwork); XCTAssertEqual(candidate.artworkDiscovery?.consideredCount, 0)
        XCTAssertTrue(candidate.warnings.contains("Artwork unavailable")); XCTAssertNotEqual(candidate.state, .failed)
        XCTAssertTrue(candidate.artworkDiscovery!.selectionReason.contains("placeholder"))
    }
    func testCorruptMSTIsRejectedAndCoverStillWins() throws {
        let root = try fixture(), good = try image("Test/cover.png", in: root)
        try Data("not an image".utf8).write(to: root.appendingPathComponent("PAResources/image/Test/MST_artwork.png"))
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, good.resolvingSymlinksInPath().path)
        XCTAssertEqual(report.rejectedCandidates.first?.rejectionReason, "unreadable or unsupported image metadata")
    }
    func testSmallBrowserArtworkIsAcceptedAndIconsAreFallbackOnly() throws {
        let root = try fixture()
        let small = try image("Test/MST_artwork.png", in: root, width: 134, height: 66)
        XCTAssertEqual(try ArtworkService.find(in: root, productName: "Test")?.resolvingSymlinksInPath().path, small.resolvingSymlinksInPath().path)
        let icons = try fixture(), icon = try image("Test/icon.png", in: icons, width: 256, height: 256)
        XCTAssertEqual(try ArtworkService.find(in: icons, productName: "Test")?.resolvingSymlinksInPath().path, icon.resolvingSymlinksInPath().path)
    }
    func testOtherNativeFormatsAndBoundedDiagnosticRetention() throws {
        let root = try fixture()
        let tiff = try image("Test/product.tiff", in: root, type: .tiff)
        for index in 0..<10 { _ = try image("Test/unknown-\(index).png", in: root) }
        let report = try ArtworkService.discover(payloads: [root], productName: "Test")
        XCTAssertEqual(report.selected?.url.resolvingSymlinksInPath().path, tiff.resolvingSymlinksInPath().path)
        XCTAssertEqual(report.consideredCount, 11); XCTAssertEqual(report.rankedCandidates.count, 8)
    }
    func testLibraryPreviewAndResourcePresenceDoNotRequireMSTFilename() throws {
        let root = try fixture(), library = root.appendingPathComponent("Test Library"), preferences = root.appendingPathComponent("Preferences"), xml = root.appendingPathComponent("XML"), resources = root.appendingPathComponent("NI Images")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("PAResources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: xml, withIntermediateDirectories: false)
        let jpeg = resources.appendingPathComponent("Test/Browser_Cover.jpg")
        try SyntheticArtworkFixture.image(at: jpeg, type: .jpeg)
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": library.path, "ContentVersion": "1"], format: .xml, options: 0).write(to: preferences.appendingPathComponent("com.native-instruments.Test.plist"))
        try Data("<ProductHints><Product><Name>Test</Name></Product></ProductHints>".utf8).write(to: xml.appendingPathComponent("Test.xml"))
        let audited = try XCTUnwrap(ExistingLibraryService.audit(preferences: preferences, serviceCenter: xml, resources: resources).first)
        XCTAssertFalse(audited.issues.contains(.missingArtwork))
        XCTAssertEqual(audited.artwork?.resolvingSymlinksInPath().path, jpeg.resolvingSymlinksInPath().path)
    }
    @MainActor func testThumbnailsAreCachedInvalidatedAndDecodedOffMainThread() async throws {
        let root = try fixture(), url = try image("Test/cover.png", in: root, width: 1024, height: 576)
        let cache = ArtworkThumbnailCache()
        let first = await cache.thumbnail(at: url, maxPixelSize: 128)
        let second = await cache.thumbnail(at: url, maxPixelSize: 128)
        XCTAssertEqual(first?.image.width, 128); XCTAssertEqual(second?.image.width, 128)
        var count = await cache.decodeCount; XCTAssertEqual(count, 1)
        let main = await cache.lastDecodeWasOnMainThread; XCTAssertFalse(main)
        try SyntheticArtworkFixture.image(at: url, width: 640, height: 640)
        let changed = await cache.thumbnail(at: url, maxPixelSize: 128)
        XCTAssertEqual(changed?.image.height, 128)
        count = await cache.decodeCount; XCTAssertEqual(count, 2)
        await cache.clear()
        _ = await cache.thumbnail(at: url, maxPixelSize: 128)
        count = await cache.decodeCount; XCTAssertEqual(count, 3)
    }
}
