import XCTest
@testable import TmuxControlCore

final class WindowSizeReplayTests: XCTestCase {
    func testDecisionWireValuesAreStable() {
        XCTAssertEqual(TmuxWindowSizeReplay.Decision.fitting.rawValue, 0)
        XCTAssertEqual(TmuxWindowSizeReplay.Decision.waiting.rawValue, 1)
        XCTAssertEqual(TmuxWindowSizeReplay.Decision.replay.rawValue, 2)
    }

    func testExactObservedGridFitsEvenWhileAnAttemptIsPending() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let otherAttempt = try TmuxClientGeometry(columns: 80, rows: 24)

        for lastAttempt in [nil, requested, otherAttempt] {
            XCTAssertEqual(
                TmuxWindowSizeReplay.decision(
                    requested: requested, observed: requested, lastAttempt: lastAttempt
                ),
                .fitting,
                "a matching observed grid is not evidence that an outstanding reply completed"
            )
        }
    }

    func testUnknownObservedGridReplaysUnlessThatGridAlreadyHasAnAttempt() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let oldAttempt = try TmuxClientGeometry(columns: 56, rows: 47)

        XCTAssertEqual(
            TmuxWindowSizeReplay.decision(requested: requested, observed: nil, lastAttempt: nil),
            .replay
        )
        XCTAssertEqual(
            TmuxWindowSizeReplay.decision(requested: requested, observed: nil, lastAttempt: requested),
            .waiting
        )
        XCTAssertEqual(
            TmuxWindowSizeReplay.decision(requested: requested, observed: nil, lastAttempt: oldAttempt),
            .replay
        )
    }

    func testEitherMismatchedAxisReplaysOnceThenWaitsForTheSameAttempt() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let mismatches = [
            try TmuxClientGeometry(columns: 55, rows: 48),
            try TmuxClientGeometry(columns: 56, rows: 47),
            try TmuxClientGeometry(columns: 55, rows: 47),
        ]

        for observed in mismatches {
            XCTAssertEqual(
                TmuxWindowSizeReplay.decision(requested: requested, observed: observed, lastAttempt: nil),
                .replay
            )
            XCTAssertEqual(
                TmuxWindowSizeReplay.decision(
                    requested: requested, observed: observed, lastAttempt: requested
                ),
                .waiting
            )
        }
    }

    func testTransientFitAndRejectedPostUnsetConfirmationNeverRearmTheSameAttempt() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let smaller = try TmuxClientGeometry(columns: 56, rows: 46)
        var pending: TmuxClientGeometry?
        XCTAssertEqual(TmuxWindowSizeReplay.decision(
            requested: requested, observed: smaller, lastAttempt: pending
        ), .replay)
        pending = requested

        // resize-window emits a temporary fitting layout before unset restores
        // the smaller native policy. Neither observation clears the attempt.
        XCTAssertEqual(TmuxWindowSizeReplay.decision(
            requested: requested, observed: requested, lastAttempt: pending
        ), .fitting)
        XCTAssertEqual(TmuxWindowSizeReplay.decision(
            requested: requested, observed: smaller, lastAttempt: pending
        ), .waiting)
        let confirmed = TmuxWindowSizeReplay.confirms(
            windowID: WindowId(5), requested: requested,
            reply: "tessera-window-size\t@5\t56\t46"
        )
        if confirmed { pending = nil }
        XCTAssertFalse(confirmed)
        for _ in 0..<20 {
            XCTAssertEqual(TmuxWindowSizeReplay.decision(
                requested: requested, observed: requested, lastAttempt: pending
            ), .fitting)
            XCTAssertEqual(TmuxWindowSizeReplay.decision(
                requested: requested, observed: smaller, lastAttempt: pending
            ), .waiting)
        }
    }

    func testChangedRequestedGridSupersedesThePriorAttemptOnEitherAxis() throws {
        let previous = try TmuxClientGeometry(columns: 56, rows: 48)
        let newerGrids = [
            try TmuxClientGeometry(columns: 57, rows: 48),
            try TmuxClientGeometry(columns: 56, rows: 49),
            try TmuxClientGeometry(columns: 57, rows: 49),
        ]

        for requested in newerGrids {
            XCTAssertEqual(
                TmuxWindowSizeReplay.decision(
                    requested: requested, observed: previous, lastAttempt: previous
                ),
                .replay
            )
            XCTAssertEqual(
                TmuxWindowSizeReplay.decision(
                    requested: requested, observed: nil, lastAttempt: previous
                ),
                .replay
            )
        }
    }

    func testCommandsForceThenFenceOwnCurrentWindowThenRestorePolicyThenConfirm() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)

        XCTAssertEqual(
            TmuxWindowSizeReplay.commands(windowID: WindowId(5), requested: requested),
            [
                "resize-window -x 56 -y 48 -t @5",
                "select-window",
                "set-option -w -u -t @5 window-size",
                "display-message -p -t @5 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'",
            ]
        )
        XCTAssertEqual(
            TmuxWindowSizeReplay.commands(windowID: WindowId(0), requested: requested).last,
            "display-message -p -t @0 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'"
        )
    }

    func testValidatedGeometrySupportsItsBoundsAndRejectsInvalidDimensions() throws {
        let maximum = TmuxClientGeometry.maximumDimension
        let requested = try TmuxClientGeometry(columns: maximum, rows: maximum)
        let minimum = try TmuxClientGeometry(columns: 1, rows: 1)

        XCTAssertEqual(
            TmuxWindowSizeReplay.commands(windowID: WindowId(0), requested: requested).first,
            "resize-window -x \(maximum) -y \(maximum) -t @0"
        )
        XCTAssertTrue(TmuxWindowSizeReplay.confirms(
            windowID: WindowId(0), requested: requested,
            reply: "tessera-window-size\t@0\t\(maximum)\t\(maximum)"
        ))
        XCTAssertTrue(TmuxWindowSizeReplay.confirms(
            windowID: WindowId(0), requested: minimum, reply: "tessera-window-size\t@0\t1\t1"
        ))
        for dimensions in [(0, 48), (56, 0), (-1, 48), (56, -1)] {
            XCTAssertThrowsError(try TmuxClientGeometry(columns: dimensions.0, rows: dimensions.1)) {
                XCTAssertEqual($0 as? TmuxGeometryValidationError, .nonPositiveDimension)
            }
        }
        for dimensions in [(maximum + 1, 48), (56, maximum + 1)] {
            XCTAssertThrowsError(try TmuxClientGeometry(columns: dimensions.0, rows: dimensions.1)) {
                XCTAssertEqual($0 as? TmuxGeometryValidationError, .dimensionTooLarge)
            }
        }
    }

    func testConfirmationAcceptsExactReplyWithAtMostOneTerminalLineEnding() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let reply = "tessera-window-size\t@5\t56\t48"

        for ending in ["", "\n", "\r\n"] {
            XCTAssertTrue(TmuxWindowSizeReplay.confirms(
                windowID: WindowId(5), requested: requested, reply: reply + ending
            ))
        }
    }

    func testConfirmationRejectsForeignTargetsAndMismatchedDimensions() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let replies = [
            "tessera-window-size\t@6\t56\t48",
            "tessera-window-size\t@5\t55\t48",
            "tessera-window-size\t@5\t56\t47",
            "tessera-window-size\t@5\t55\t47",
            "other-window-size\t@5\t56\t48",
            "tessera-window-size\t\t56\t48",
            "tessera-window-size\t@\t56\t48",
            "tessera-window-size\t%5\t56\t48",
            "tessera-window-size\t$5\t56\t48",
            "tessera-window-size\t@-5\t56\t48",
            "tessera-window-size\t@+5\t56\t48",
            "tessera-window-size\t@05\t56\t48",
            "tessera-window-size\t@999999999999999999999999\t56\t48",
        ]

        for reply in replies {
            XCTAssertFalse(TmuxWindowSizeReplay.confirms(
                windowID: WindowId(5), requested: requested, reply: reply
            ), reply.debugDescription)
        }
    }

    func testConfirmationRejectsExtraFieldsLinesAndNoncanonicalNumbers() throws {
        let requested = try TmuxClientGeometry(columns: 56, rows: 48)
        let exact = "tessera-window-size\t@5\t56\t48"
        var replies = [
            "", "\n", " " + exact, exact + " ", exact + "\t", exact + "\textra",
            exact + "\r", exact + "\n\n", exact + "\r\n\r\n", "\n" + exact,
            exact + "\n" + exact, exact + "\nother", "other\n" + exact,
            "tessera-window-size\t@5\t56", "tessera-window-size @5 56 48",
            "tessera-window-size\\t@5\\t56\\t48",
        ]
        for numeric in ["", "0", "-56", "+56", "056", "56.0", " 56", "56 ",
                        "65536", "999999999999999999999999", "NaN", "５６"] {
            replies.append("tessera-window-size\t@5\t\(numeric)\t48")
        }
        for numeric in ["", "0", "-48", "+48", "048", "48.0", " 48", "48 ",
                        "65536", "999999999999999999999999", "NaN", "４８"] {
            replies.append("tessera-window-size\t@5\t56\t\(numeric)")
        }

        for reply in replies {
            XCTAssertFalse(TmuxWindowSizeReplay.confirms(
                windowID: WindowId(5), requested: requested, reply: reply
            ), reply.debugDescription)
        }
    }

    func testOwnershipProofAcceptsExactlyOurDistinctClientsAndValidOtherWindows() {
        let rows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        for ending in ["", "\n", "\r\n"] {
            XCTAssertTrue(ownershipProof(inventory: rows + ending))
        }
        XCTAssertTrue(ownershipProof(inventory: rows.replacingOccurrences(of: "\n", with: "\r\n")))
        XCTAssertTrue(ownershipProof(inventory: "@6\tforeign\t13\t103\n" + rows))
        XCTAssertTrue(ownershipProof(
            windowID: 0, inventory: rows.replacingOccurrences(of: "@5", with: "@0")
        ))
        XCTAssertTrue(ownershipProof(
            control: "客户端|11|101", inventory: rows.replacingOccurrences(of: "control", with: "客户端")
        ))
        XCTAssertTrue(ownershipProof(
            control: "visible|11|101", inventory: rows.replacingOccurrences(of: "control", with: "visible")
        ), "client names alone are not an identity")
    }

    func testOwnershipProofRejectsForeignMissingAndDuplicateClients() {
        let rows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        for inventory in [
            "", "@5\tcontrol\t11\t101", "@5\tvisible\t12\t102",
            rows + "\n@5\tforeign\t13\t103",
            rows.replacingOccurrences(of: "@5\tvisible", with: "@6\tvisible"),
            rows + "\n@5\tcontrol\t11\t101",
            rows + "\n@6\tcontrol\t11\t101",
            rows + "\n@6\tforeign\t13\t103\n@6\tforeign\t13\t103",
        ] {
            XCTAssertFalse(ownershipProof(inventory: inventory), inventory.debugDescription)
        }
        XCTAssertFalse(ownershipProof(control: "visible|12|102"))
        XCTAssertFalse(ownershipProof(windowID: -1))
    }

    func testOwnershipProofComparesClientNamesAsExactUTF8() {
        let composed = "é"
        let decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality normalizes these names")
        XCTAssertFalse(ownershipProof(
            control: composed + "|11|101",
            inventory: "@5\t\(decomposed)\t11\t101\n@5\tvisible\t12\t102"
        ))
        XCTAssertTrue(ownershipProof(
            control: composed + "|11|101", visible: decomposed + "|11|101",
            inventory: "@5\t\(composed)\t11\t101\n@5\t\(decomposed)\t11\t101"
        ), "distinct wire identities must not be collapsed")
    }

    func testOwnershipProofRejectsMalformedRowsEvenInUnrelatedWindows() {
        let rows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        for malformed in [
            "@6\tforeign\t13", "@6\tforeign\t13\t103\textra",
            "@6 foreign 13 103", "@6\\tforeign\\t13\\t103", "", " ",
            "@6\t\t13\t103", "@6\tbad|name\t13\t103",
            "@6\tbad\u{0}name\t13\t103", "@6\tbad\u{7F}name\t13\t103",
            "@6\tforeign\t13\t103\u{2028}",
        ] {
            XCTAssertFalse(ownershipProof(inventory: rows + "\n" + malformed + "\n"), malformed.debugDescription)
        }
        XCTAssertFalse(ownershipProof(inventory: rows + "\n\n"))
        XCTAssertFalse(ownershipProof(inventory: "\n" + rows))
        XCTAssertFalse(ownershipProof(inventory: rows + "\n@6\tforeign\t13\t103\r"))
    }

    func testOwnershipProofRequiresCanonicalPositiveIdentityNumbers() {
        for value in ["", "0", "00", "011", "+11", "-11", "11.0", " 11", "11 ", "１１", "18446744073709551616"] {
            for position in [1, 2] {
                var fields = ["control", "11", "101"]
                fields[position] = value
                XCTAssertFalse(ownershipProof(control: fields.joined(separator: "|")), fields.description)
                XCTAssertFalse(ownershipProof(inventory:
                    "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102\n@6\tforeign\t" +
                    (position == 1 ? value + "\t103" : "13\t" + value)
                ), fields.description)
            }
        }
        let maximum = String(UInt64.max)
        XCTAssertTrue(ownershipProof(
            control: "control|\(maximum)|\(maximum)",
            inventory: "@5\tcontrol\t\(maximum)\t\(maximum)\n@5\tvisible\t12\t102"
        ))
    }

    func testOwnershipProofRequiresCanonicalWindowIDsOnEveryRecord() {
        let rows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        for malformed in ["", "@", "@-6", "@+6", "@06", "%6", "$6", "6", "@６", " @6", "@6 ", "@999999999999999999999999"] {
            XCTAssertFalse(ownershipProof(inventory: rows + "\n\(malformed)\tforeign\t13\t103"), malformed)
        }
    }

    func testOwnershipProofRejectsMalformedOwnIdentityNamesAndFields() {
        for identity in [
            "", "control", "control|11", "control|11|101|extra", "|11|101",
            "bad|name|11|101", "bad\tname|11|101", "bad\nname|11|101",
            "bad\rname|11|101", "bad\u{0}name|11|101", "bad\u{7F}name|11|101",
        ] {
            XCTAssertFalse(ownershipProof(control: identity), identity.debugDescription)
            XCTAssertFalse(ownershipProof(visible: identity), identity.debugDescription)
        }
    }

    func testOwnershipProofBoundsIdentityAndInventoryUTF8Bytes() {
        let name = String(repeating: "x", count: TmuxWindowSizeReplay.maximumIdentityBytes - 4)
        let rows = "@5\t\(name)\t1\t1\n@5\tvisible\t12\t102"
        XCTAssertTrue(ownershipProof(control: name + "|1|1", inventory: rows))
        XCTAssertFalse(ownershipProof(control: name + "x|1|1", inventory: rows))
        XCTAssertFalse(ownershipProof(
            control: name + "|1|1", inventory: rows + "\n@6\t" + name + "x\t2\t2"
        ))
        let unicodeName = String(repeating: "é", count: (TmuxWindowSizeReplay.maximumIdentityBytes - 4) / 2)
        XCTAssertTrue(ownershipProof(
            control: unicodeName + "|1|1",
            inventory: "@5\t\(unicodeName)\t1\t1\n@5\tvisible\t12\t102"
        ))
        XCTAssertFalse(ownershipProof(control: unicodeName + "é|1|1"))
        var manyRows = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
        var pid = 1000
        while manyRows.utf8.count <= TmuxWindowSizeReplay.maximumInventoryBytes {
            manyRows += "\n@6\tforeign\(pid)\t\(pid)\t1"
            pid += 1
        }
        let inBounds = manyRows.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        XCTAssertTrue(ownershipProof(inventory: inBounds))
        XCTAssertFalse(ownershipProof(inventory: manyRows))
    }

    private func ownershipProof(
        windowID: Int = 5,
        control: String = "control|11|101",
        visible: String = "visible|12|102",
        inventory: String = "@5\tcontrol\t11\t101\n@5\tvisible\t12\t102"
    ) -> Bool {
        TmuxWindowSizeReplay.provesExclusiveOwnership(
            windowID: WindowId(windowID), controlIdentity: control,
            visibleIdentity: visible, inventory: inventory
        )
    }
}
