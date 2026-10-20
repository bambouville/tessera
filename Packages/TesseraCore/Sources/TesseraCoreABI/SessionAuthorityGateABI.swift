import Foundation
import TesseraSessionCore

/// The S5′ grid-authority gate of every backend operation, by `kindCode`.
/// Android's `perform()` classifies with a Kotlin copy so a keystroke costs
/// no JNI call; a JVM test compares that copy with this table.
enum SessionAuthorityGateTable {
    /// One operation of each kind. `CoreABICommand.Kind` lists the kinds;
    /// a test fails when a kind has no sample here.
    static let samples: [SessionBackendOperation] = [
        .connect(ConnectionIntent(hostID: UUID(), policyGeneration: 1)),
        .cancelConnect(attemptID: UUID()),
        .disconnect,
        .sendInput(Data([0x61])),
        .resize(columns: 80, rows: 24),
        .selectTmuxWindow("@1"),
        .selectTmuxPane("%1"),
        .sendTmuxPaneInput(data: Data([0x61]), paneID: "%1", receipt: nil),
        .sendTmuxPaneKey(.enter, paneID: "%1", receipt: nil),
        .createTmuxWindow,
        .closeTmuxWindow("@1"),
        .closeTmuxPane("%1"),
        .splitTmuxPane("%1", axis: .horizontal, before: false),
        .cycleTmuxPane(forward: true),
        .setTmuxPaneZoomed("%1", zoomed: true),
        .renameTmuxWindow("@1", name: "w"),
        .moveTmuxWindow("@1", move: .position(0)),
        .renumberTmuxWindows,
        .setTmuxGridPresentation(.singlePane),
        .claimTmuxGridAuthority(reason: .forceRefresh, repaintEvenIfSame: true),
        .reclaimTmuxGridAuthority(reason: .user),
        .completeTmuxGridAuthorityRepaint(generation: 1),
        .setFocused(true),
        .setApplicationVisibility(.active),
        .requestFullRepaint,
        .submitChallengeResponse(ChallengeResponse(
            challengeID: UUID(),
            attemptID: UUID(),
            policyGeneration: 1,
            decision: .approve
        )),
        .destroy,
    ]

    static var byKindCode: [String: String] {
        Dictionary(uniqueKeysWithValues: samples.map { ($0.kindCode, $0.authorityGate.rawValue) })
    }
}

/// A JSON object from each backend operation's `kindCode` to its gate:
/// `typing`, `mutation` or `ungated`.
@_cdecl("tessera_session_authority_gates")
public func tesseraSessionAuthorityGates(
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    SharedABI.copyOutJSON(SessionAuthorityGateTable.byKindCode, outputBytes, outputCapacity)
}
