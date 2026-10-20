import XCTest
import TmuxControlCore

final class GridAuthorityScopeTests: XCTestCase {
    private let owner = TmuxGridAuthorityScope.owner(SessionId(42))
    private let stamp = TmuxGridAuthorityStamp(identity: .init(id: "MOSH", displayName: "iPhone"), generation: 2)

    func testQueryCommands() {
        XCTAssertEqual(TmuxGridAuthority.queryCommand(.ownSession), "show-options -qv @tessera_authority")
        XCTAssertEqual(TmuxGridAuthority.queryCommand(owner),
                       "display-message -p '#{S:#{?#{==:#{session_id},$42},#{session_id}|#{@tessera_authority},}}'")
    }

    func testOwnerReadReplyTellsAKilledOwnerFromAnUnsetStamp() {
        XCTAssertEqual(TmuxGridAuthority.queryReplyLines(["$42|v1 MOSH 2 iPhone"], scope: owner), ["v1 MOSH 2 iPhone"])
        XCTAssertEqual(TmuxGridAuthority.queryReplyLines(["$42|v1 M 2 Pixel #2, a|b  "], scope: owner), ["v1 M 2 Pixel #2, a|b  "])
        XCTAssertEqual(TmuxGridAuthority.queryReplyLines(["$42|"], scope: owner), [])
        for reply in [[""], [], ["$4|v1 M 2 x"], ["$420|"], ["v1 M 2 x"], ["$42|a", "$42|b"]] {
            XCTAssertNil(TmuxGridAuthority.queryReplyLines(reply, scope: owner), "\(reply)")
        }
        XCTAssertEqual(TmuxGridAuthority.queryReplyLines([], scope: .ownSession), [])
        XCTAssertEqual(TmuxGridAuthority.queryReplyLines(["v1 M 2 x"], scope: .ownSession), ["v1 M 2 x"])
    }

    func testWriteCommandsCommitOwnerBeforeCompatibilityMirror() {
        XCTAssertEqual(TmuxGridAuthority.writeCommands(stamp, scope: .ownSession), ["set-option @tessera_authority 'v1 MOSH 2 iPhone'"])
        XCTAssertEqual(TmuxGridAuthority.writeCommands(stamp, scope: owner), [
            "set-option -t '$42' @tessera_authority 'v1 MOSH 2 iPhone'",
            "set-option @tessera_authority 'v1 MOSH 2 iPhone'",
        ])
    }

    func testSubscriptionFormats() {
        XCTAssertEqual(TmuxGridAuthority.subscriptionFormat(.ownSession), "#{@tessera_authority}")
        XCTAssertEqual(TmuxGridAuthority.subscriptionFormat(owner), "#{S:#{?#{==:#{session_id},$42},#{@tessera_authority},}}")
    }

    func testOwnerResolutionCommandsKeepExactNameAndTrailingColonQuoted() {
        XCTAssertEqual(TmuxGridAuthority.ownerResolutionCommands(ownerSessionName: "own"), [
            "display-message -p -t '=own:' '#{session_id} #{session_group}'",
            "display-message -p '#{session_id} #{session_group}'",
        ])
        XCTAssertEqual(TmuxGridAuthority.ownerResolutionCommands(ownerSessionName: "o'wn")[0],
                       "display-message -p -t '=o'\\''wn:' '#{session_id} #{session_group}'")
    }

    func testResolveDifferentSessionsInSameGroup() {
        XCTAssertEqual(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 own"], ownReply: ["$1 own"]), SessionId(0))
        XCTAssertEqual(TmuxGridAuthority.resolveOwner(ownerReply: ["$42 group"], ownReply: ["$3 group"]), SessionId(42))
    }

    func testResolveNamedGroupContainingSpaces() {
        XCTAssertEqual(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 work group"], ownReply: ["$1 work group"]), SessionId(0))
        XCTAssertEqual(TmuxGridAuthority.resolveOwner(ownerReply: ["$0  padded "], ownReply: ["$1  padded "]), SessionId(0))
        XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 work group"], ownReply: ["$1 work"]))
        XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 work group"], ownReply: ["$1 work  group"]))
    }

    func testResolveErrorsAndMissingOrMultipleLines() {
        let replies: [[String]?] = [nil, [], [""], ["$0 own", "$1 own"]]
        for reply in replies {
            XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: reply, ownReply: ["$1 own"]))
            XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 own"], ownReply: reply))
        }
    }

    func testResolveMalformedIDOrGroup() {
        for line in ["0 own", "$ own", "$-1 own", "$1x own", "$999999999999999999999999 own", "$0", "$0 ", "$0\town", "$0 own\n", "$0 own\r"] {
            XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: [line], ownReply: ["$1 own"]), line)
            XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$1 own"], ownReply: [line]), line)
        }
    }

    func testResolveSameSessionAndDifferentGroupsFallBack() {
        XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$1 own"], ownReply: ["$1 own"]))
        XCTAssertNil(TmuxGridAuthority.resolveOwner(ownerReply: ["$0 own"], ownReply: ["$1 other"]))
    }

    func testGenerationBaseAndClamp() {
        let origin: Int64 = 1_767_225_600_000
        for now in [Int64.min, -1, 0, origin - 1, origin] {
            XCTAssertEqual(TmuxGridAuthorityStamp.generationBase(unixMillis: now), 0)
        }
        XCTAssertEqual(TmuxGridAuthorityStamp.generationBase(unixMillis: origin + 1), 4096)
        let base = TmuxGridAuthorityStamp.generationBase(unixMillis: origin + 24_000_000_000)
        XCTAssertEqual(base, 24_000_000_000 << 12)
        XCTAssertLessThan(base + 4095, 1 << 53)
        XCTAssertLessThanOrEqual(TmuxGridAuthorityStamp.generationBase(unixMillis: .max) + 4095, TmuxGridAuthorityStamp.maximumGeneration)
    }

    func testSeededSessionFirstClaimIsBasePlusOne() {
        let base = TmuxGridAuthorityStamp.generationBase(unixMillis: 1_767_225_600_123)
        var session = TmuxGridAuthoritySession(localDeviceID: "SELF", initialGeneration: base)
        _ = session.reduce(.attached, now: 0)
        _ = session.reduce(.shown(source: .show, stepAt: 1), now: 1)
        let id = session.query.current!.id
        _ = session.reduce(.queryReplied(id: id, raw: "v1 PEER 7 iPhone"), now: 2)
        XCTAssertEqual(session.reducer.claim?.generation, base + 1)
    }
}
