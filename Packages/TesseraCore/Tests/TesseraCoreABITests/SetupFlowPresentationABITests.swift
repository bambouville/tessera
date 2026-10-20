import Foundation
import XCTest
import TesseraCrossDeviceCore
import TesseraCoreABI

final class SetupFlowPresentationABITests: XCTestCase {
    func testProjectionRoundTripsExactBufferAndMatchesNative() throws {
        let input = SetupFlowPresentationV1.Input(purpose: .setUpAndContinue, phase: .waitingForGrant,
            supportedActions: [.cancel, .approve])
        let bytes = Array(try JSONEncoder().encode(input))
        try bytes.withUnsafeBufferPointer { inputBuffer in
            func call(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: Int) -> Int32 {
                tesseraSetupFlowProjectV1(inputBytes: inputBuffer.baseAddress, inputCount: bytes.count,
                    outputBytes: pointer, outputCapacity: count)
            }
            let count = Int(call(nil, 0))
            XCTAssertGreaterThan(count, 0)
            var output = [UInt8](repeating: 0, count: count)
            XCTAssertEqual(output.withUnsafeMutableBufferPointer { call($0.baseAddress, count - 1) }, -1)
            XCTAssertEqual(output.withUnsafeMutableBufferPointer { call($0.baseAddress, count) }, Int32(count))
            XCTAssertEqual(try JSONDecoder().decode(SetupFlowPresentationV1.Output.self, from: Data(output)),
                           SetupFlowPresentationV1.project(input))
        }
    }
    func testRejectsMalformedUnknownAndOversizedInput() {
        XCTAssertEqual(tesseraSetupFlowProjectV1(inputBytes: nil, inputCount: 1, outputBytes: nil, outputCapacity: 0), -1)
        for value in ["{}", "{\"purpose\":\"future\",\"entry\":\"qr\",\"phase\":\"entry\",\"supportedActions\":[],\"hosts\":[]}", String(repeating: " ", count: 262_145)] {
            let bytes = Array(value.utf8)
            XCTAssertEqual(bytes.withUnsafeBufferPointer {
                tesseraSetupFlowProjectV1(inputBytes: $0.baseAddress, inputCount: $0.count, outputBytes: nil, outputCapacity: 0)
            }, -1)
        }
    }
}
