import SwiftUI
import XCTest
@testable import Tessera

final class SessionFilesSheetTests: XCTestCase {
    func testOnlyAnActivePresentedLargeFilesSheetCoversContext() {
        for presented in [false, true] {
            for detent: PresentationDetent in [.medium, .large] {
                for isActive in [false, true] {
                    XCTAssertEqual(SessionFilesSheetPolicy.coversContext(
                        presented: presented, detent: detent, isActive: isActive
                    ), presented && detent == .large && isActive)
                }
            }
        }
    }

    func testExpandingCollapsingDismissingAndReopeningFilesUpdatesCoverage() {
        let states: [(Bool, PresentationDetent, Bool, Bool)] = [
            (false, .medium, true, false), (true, .medium, true, false),
            (true, .large, true, true), (true, .large, false, false),
            (true, .large, true, true), (true, .medium, true, false),
            (true, .large, true, true), (false, .large, true, false),
            (true, .medium, true, false)
        ]
        for (presented, detent, isActive, expected) in states {
            XCTAssertEqual(SessionFilesSheetPolicy.coversContext(
                presented: presented, detent: detent, isActive: isActive
            ), expected)
        }
    }

    func testCoveringPreferenceORsFilesForwardingAndContinuityInEveryOrder() {
        XCTAssertFalse(ArtifactCoveringSheetPreferenceKey.defaultValue)
        for files in [false, true] {
            for forwarding in [false, true] {
                for continuity in [false, true] {
                    let sources = [files, forwarding, continuity]
                    let orders = [sources, Array(sources.reversed()),
                                  [files, continuity, forwarding], [forwarding, files, continuity],
                                  [forwarding, continuity, files], [continuity, files, forwarding]]
                    for ordered in orders {
                        var value = ArtifactCoveringSheetPreferenceKey.defaultValue
                        for source in ordered {
                            ArtifactCoveringSheetPreferenceKey.reduce(value: &value) { source }
                        }
                        XCTAssertEqual(value, files || forwarding || continuity)
                    }
                }
            }
        }
    }
}
