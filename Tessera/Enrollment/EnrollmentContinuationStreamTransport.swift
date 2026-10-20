import Foundation
import TesseraAppleContinuity

/// iOS/iPadOS enrollment adapter over the shared Apple continuation-stream
/// transport. The app adds diagnostics; byte ordering, drain lifetime, peer
/// binding, and close behavior are shared with the macOS bridge.
@MainActor
final class EnrollmentContinuationStreamTransport:
    AppleContinuationStreamTransport,
    EnrollmentMessageTransport {
    typealias StreamError = AppleContinuationStreamTransport.StreamError

    override func didFail(_ error: Error) {
        DiagnosticLogStore.appendApp(
            "enrollment stream result=failed error='\(error.localizedDescription)'"
        )
    }
}
