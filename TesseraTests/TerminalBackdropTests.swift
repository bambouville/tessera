import XCTest
import CoreGraphics
import SwiftUI
@testable import Tessera

final class TerminalBackdropTests: XCTestCase {
    func testContentFrameWithoutBleedPreservesCanvasBounds() {
        let size = CGSize(width: 1_280, height: 720)

        XCTAssertEqual(
            TerminalBackdrop.contentFrame(in: size, bleed: EdgeInsets()),
            CGRect(origin: .zero, size: size)
        )
    }

    func testContentFrameReconstructsFullSessionAroundTerminalRegion() {
        XCTAssertEqual(
            TerminalBackdrop.contentFrame(
                in: CGSize(width: 1_280, height: 720),
                bleed: EdgeInsets(top: 48, leading: 24, bottom: 52, trailing: 24)
            ),
            CGRect(x: -24, y: -48, width: 1_328, height: 820)
        )
    }

    func testContentFrameClampsNegativeBleedToZero() {
        let size = CGSize(width: 1_280, height: 720)

        XCTAssertEqual(
            TerminalBackdrop.contentFrame(
                in: size,
                bleed: EdgeInsets(top: -1, leading: -24, bottom: -1, trailing: -24)
            ),
            CGRect(origin: .zero, size: size)
        )
    }
}
