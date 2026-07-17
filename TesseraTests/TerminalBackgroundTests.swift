import XCTest
import CoreGraphics
import TmuxControl
@testable import Tessera

final class TerminalBackgroundTests: XCTestCase {
    // MARK: - Host override Codable (the "blur key resets every blob" trap)

    func testOverrideDecodesLegacyBlobWithoutBlurKey() throws {
        // Exactly what the pre-blur app persisted: no `blur` key. Synthesized
        // Codable would throw here and silently reset every per-host override.
        let legacy = #"{"mode":"image","imageID":"ABC.jpg","dim":0.3,"fillMode":"fit"}"#
        let decoded = try JSONDecoder().decode(
            HostTerminalBackgroundOverride.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.mode, .image)
        XCTAssertEqual(decoded.imageID, "ABC.jpg")
        XCTAssertEqual(decoded.dim, 0.3)
        XCTAssertEqual(decoded.fillMode, .fit)
        XCTAssertEqual(decoded.blur, 0)
    }

    func testOverrideRoundTripsBlur() throws {
        let override = HostTerminalBackgroundOverride(
            mode: .image, imageID: "X.jpg", dim: 0.1, fillMode: .fill, blur: 12
        )
        let data = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(HostTerminalBackgroundOverride.self, from: data)
        XCTAssertEqual(decoded, override)
    }

    // MARK: - Blur variant naming

    func testVariantIDZeroRadiusIsBaseID() {
        XCTAssertEqual(TerminalBackgroundImageStore.variantID(id: "ABC.jpg", blur: 0), "ABC.jpg")
        XCTAssertEqual(TerminalBackgroundImageStore.variantID(id: "ABC.jpg", blur: 0.4), "ABC.jpg")
    }

    func testVariantIDEncodesRoundedRadius() {
        XCTAssertEqual(
            TerminalBackgroundImageStore.variantID(id: "ABC.jpg", blur: 8),
            "ABC-b8.jpg"
        )
        XCTAssertEqual(
            TerminalBackgroundImageStore.variantID(id: "ABC.jpg", blur: 11.6),
            "ABC-b12.jpg"
        )
    }

    // MARK: - Header bar geometry

    private func frame(_ id: Int, header: CGRect) -> PaneFrame {
        PaneFrame(
            paneId: PaneId(id),
            headerFrame: header,
            surfaceFrame: CGRect(
                x: header.minX, y: header.maxY,
                width: header.width, height: 100
            )
        )
    }

    func testSideBySideHeadersBridgeAcrossTheGutter() {
        // Two panes split left/right with a 9pt (one-cell) gutter.
        let cellWidth: CGFloat = 9
        let frames = [
            frame(1, header: CGRect(x: 0, y: 0, width: 450, height: 17)),
            frame(2, header: CGRect(x: 459, y: 0, width: 450, height: 17)),
        ]
        let geometry = PaneHeaderBarGeometry(
            frames: frames,
            layoutBounds: CGRect(x: 0, y: 0, width: 909, height: 117),
            containerSize: CGSize(width: 912, height: 500),
            maxBridgeWidth: cellWidth * 1.5
        )

        XCTAssertEqual(
            geometry.bridgeRects,
            [CGRect(x: 450, y: 0, width: 9, height: 17)]
        )
        // Right edge snaps to the container so the bar reads full-width.
        XCTAssertEqual(
            geometry.segmentRects[PaneId(2)],
            CGRect(x: 459, y: 0, width: 912 - 459, height: 17)
        )
        XCTAssertEqual(
            geometry.segmentRects[PaneId(1)],
            CGRect(x: 0, y: 0, width: 450, height: 17)
        )
    }

    func testSameRowHeadersAcrossAFullHeightPaneDoNotBridge() {
        // col1 and col3 are stacked (mid-row headers align in Y); col2 spans
        // full height, so the space between the mid headers is col2's live
        // content and must stay open.
        let cellWidth: CGFloat = 9
        let frames = [
            frame(1, header: CGRect(x: 0, y: 200, width: 200, height: 17)),
            frame(2, header: CGRect(x: 500, y: 200, width: 200, height: 17)),
        ]
        let geometry = PaneHeaderBarGeometry(
            frames: frames,
            layoutBounds: CGRect(x: 0, y: 0, width: 700, height: 400),
            containerSize: CGSize(width: 700, height: 400),
            maxBridgeWidth: cellWidth * 1.5
        )
        XCTAssertTrue(geometry.bridgeRects.isEmpty)
    }

    func testZeroHeightHeadersProduceNoBar() {
        let frames = [
            frame(1, header: CGRect(x: 0, y: 0, width: 450, height: 0))
        ]
        let geometry = PaneHeaderBarGeometry(
            frames: frames,
            layoutBounds: CGRect(x: 0, y: 0, width: 450, height: 100),
            containerSize: CGSize(width: 450, height: 100),
            maxBridgeWidth: 13.5
        )
        XCTAssertTrue(geometry.segmentRects.isEmpty)
        XCTAssertTrue(geometry.bridgeRects.isEmpty)
    }
}
