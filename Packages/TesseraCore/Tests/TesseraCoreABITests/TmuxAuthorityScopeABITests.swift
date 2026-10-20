import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

final class TmuxAuthorityScopeABITests: XCTestCase {
    private func bytes<T>(_ json: String, _ body: (UnsafePointer<UInt8>?, Int) throws -> T) rethrows -> T {
        try Array(json.utf8).withUnsafeBufferPointer { try body($0.baseAddress, $0.count) }
    }
    private func commands(_ json: String) throws -> [String] {
        try bytes(json) { input, count in
            let size = tesseraTmuxAuthorityCommands(requestBytes: input, requestCount: count, outputBytes: nil, outputCapacity: 0)
            XCTAssertGreaterThan(size, 0)
            var output = [UInt8](repeating: 0, count: max(0, Int(size)))
            let written = output.withUnsafeMutableBufferPointer {
                tesseraTmuxAuthorityCommands(requestBytes: input, requestCount: count, outputBytes: $0.baseAddress, outputCapacity: $0.count)
            }
            XCTAssertEqual(written, size)
            return try JSONDecoder().decode([String].self, from: Data(output))
        }
    }
    func testQueries() throws {
        XCTAssertEqual(try commands(#"{"op":"query"}"#), [TmuxGridAuthority.queryCommand(.ownSession)])
        XCTAssertEqual(try commands(#"{"op":"query","ownerSessionID":"$42"}"#), [TmuxGridAuthority.queryCommand(.owner(SessionId(42)))])
    }
    func testSubscriptionsAreTheRuntimesToRegister() {
        let input = Array(#"{"op":"subscription"}"#.utf8)
        XCTAssertEqual(input.withUnsafeBufferPointer {
            tesseraTmuxAuthorityCommands(requestBytes: $0.baseAddress, requestCount: $0.count, outputBytes: nil, outputCapacity: 0)
        }, -1, "the feed is per pane now; tessera_tmux_runtime_set_subscriptions asks for it")
    }
    func testWritesAndMirror() throws {
        let stamp = TmuxGridAuthorityStamp(identity: .init(id: "M", displayName: "iPhone"), generation: 123456789012345)
        XCTAssertEqual(try commands(#"{"op":"write","stamp":"v1 M 123456789012345 iPhone"}"#), TmuxGridAuthority.writeCommands(stamp, scope: .ownSession))
        XCTAssertEqual(try commands(#"{"op":"write","ownerSessionID":"$42","stamp":"v1 M 123456789012345 iPhone"}"#), TmuxGridAuthority.writeCommands(stamp, scope: .owner(SessionId(42))))
    }
    func testResolutionCommands() throws {
        XCTAssertEqual(try commands(#"{"name":"o'wn","op":"ownerResolution"}"#), TmuxGridAuthority.ownerResolutionCommands(ownerSessionName: "o'wn"))
    }
    private func queryReply(_ json: String) -> String? {
        bytes(json) { input, count in
            let size = tesseraTmuxAuthorityQueryReply(requestBytes: input, requestCount: count, outputBytes: nil, outputCapacity: 0)
            guard size > 0 else { return nil }
            var output = [UInt8](repeating: 0, count: Int(size))
            let written = output.withUnsafeMutableBufferPointer {
                tesseraTmuxAuthorityQueryReply(requestBytes: input, requestCount: count, outputBytes: $0.baseAddress, outputCapacity: $0.count)
            }
            XCTAssertEqual(written, size)
            return String(decoding: output, as: UTF8.self)
        }
    }
    func testQueryReplyStripsTheOwnerAndReportsAKilledOwnerAsNull() {
        XCTAssertEqual(queryReply(#"{"ownerSessionID":"$42","reply":["$42|v1 M 2 Pixel #2"]}"#), #"["v1 M 2 Pixel #2"]"#)
        XCTAssertEqual(queryReply(#"{"ownerSessionID":"$42","reply":["$42|"]}"#), "[]")
        XCTAssertEqual(queryReply(#"{"ownerSessionID":"$42","reply":[""]}"#), "null")
        XCTAssertEqual(queryReply(#"{"ownerSessionID":"$42","reply":["$4|v1 M 2 x"]}"#), "null")
        XCTAssertEqual(queryReply(#"{"reply":[]}"#), "[]")
        XCTAssertEqual(queryReply(#"{"reply":["v1 M 2 x"]}"#), #"["v1 M 2 x"]"#)
        for json in [#"{}"#, #"{"ownerSessionID":"42","reply":[]}"#, #"{"extra":1,"reply":[]}"#, #"{"ownerSessionID":null,"reply":[]}"#] {
            XCTAssertNil(queryReply(json), json)
        }
    }
    func testResolveOwnerAndAllFallbackShapes() {
        XCTAssertEqual(bytes(#"{"ownReply":["$1 own"],"ownerReply":["$0 own"]}"#) { tesseraTmuxAuthorityResolveOwner(requestBytes: $0, requestCount: $1) }, 0)
        for json in [#"{}"#, #"{"ownReply":["$1 own"]}"#, #"{"ownerReply":["$0 own"]}"#, #"{"ownReply":[],"ownerReply":["$0 own"]}"#, #"{"ownReply":["$0 own"],"ownerReply":["$0 own"]}"#, #"{"ownReply":["$1 other"],"ownerReply":["$0 own"]}"#, #"{"ownReply":["$1 "],"ownerReply":["$0 "]}"#, #"{"ownReply":["$1 own"],"ownerReply":["bad"]}"#] {
            XCTAssertEqual(bytes(json) { tesseraTmuxAuthorityResolveOwner(requestBytes: $0, requestCount: $1) }, -1, json)
        }
    }
    func testRejectMalformedAndNonCanonicalRequests() {
        for json in [#"{"op":"nope"}"#, #"{"op":"query","ownerSessionID":"-1"}"#, #"{"op":"query","ownerSessionID":"$-1"}"#, #"{"op":"write","stamp":"bad"}"#, #"{"op":"query","name":"extra"}"#, #"{"name":"bad\nname","op":"ownerResolution"}"#, #"{"extra":1,"op":"query"}"#, #"{"op":"query","op":"query"}"#, #"{"op":"query","stamp":null}"#] {
            XCTAssertEqual(bytes(json) { tesseraTmuxAuthorityCommands(requestBytes: $0, requestCount: $1, outputBytes: nil, outputCapacity: 0) }, -1, json)
        }
    }
    func testProductionHandleSeedsGenerationAndExplicitSeedRemainsDeterministic() throws {
        let before = TmuxGridAuthorityStamp.generationBase(unixMillis: Int64(Date().timeIntervalSince1970 * 1000))
        let handle = tesseraTmuxAuthorityLifecycleCreate()
        defer { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }
        var output = [UInt8](repeating: 0, count: 65536)
        let size = bytes(#"{"version":2,"event":"snapshot","nowMillis":0}"#) { input, count in
            output.withUnsafeMutableBufferPointer { tesseraTmuxAuthorityLifecycleReduce(handle: handle, requestBytes: input, requestCount: count, outputBytes: $0.baseAddress, outputCapacity: $0.count) }
        }
        XCTAssertGreaterThan(size, 0)
        let value = try JSONSerialization.jsonObject(with: Data(output.prefix(Int(size)))) as! [String: Any]
        let base = (value["nextGeneration"] as! NSNumber).uint64Value
        XCTAssertGreaterThanOrEqual(base, before)
        XCTAssertLessThan(base, 1 << 53)
        XCTAssertEqual(base & 4095, 0)
        XCTAssertNil(tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: -1))
    }
}
