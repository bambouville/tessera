import XCTest
import TesseraArtifactsCore
import TesseraDomainCore
@testable import TesseraCoreABI

final class ArtifactsABITests: XCTestCase {
    private typealias Entry = (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int) -> Int32
    private struct GoldenFile: Decodable {
        var version: Int
        var cases: [Golden]
    }
    private struct Golden: Decodable {
        var name: String
        var symbol: String
        var requestJSON: String?
        var responseJSON: String
        var repeatedDiffBytes: Int?

        func expanded(_ text: String) -> String {
            guard let count = repeatedDiffBytes else { return text }
            return text.replacingOccurrences(of: "__artifacts_diff_256k__", with: String(repeating: "x", count: count))
        }
    }

    func testEveryEntryMatchesGoldenReplayAndRejectsInvalidJSON() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "artifacts-abi-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.cases.count, 42)
        XCTAssertEqual(Set(fixture.cases.map(\.symbol)).count, 19)
        for golden in fixture.cases {
            if golden.symbol == "tessera_artifacts_listening_ports_command" {
                XCTAssertNil(golden.requestJSON)
                let count = tesseraArtifactsListeningPortsCommand(outputBytes: nil, outputCapacity: 0)
                XCTAssertGreaterThan(count, 0)
                var output = [UInt8](repeating: 0, count: Int(count))
                let copied = output.withUnsafeMutableBufferPointer {
                    tesseraArtifactsListeningPortsCommand(outputBytes: $0.baseAddress, outputCapacity: $0.count)
                }
                XCTAssertEqual(copied, count)
                XCTAssertEqual(String(decoding: output, as: UTF8.self), golden.responseJSON, golden.name)
                var tiny: UInt8 = 0xa5
                XCTAssertEqual(tesseraArtifactsListeningPortsCommand(outputBytes: &tiny, outputCapacity: 1), -1)
                XCTAssertEqual(tiny, 0xa5)
                continue
            }
            let function = try XCTUnwrap(entries[golden.symbol], golden.symbol)
            let input = Array(golden.expanded(try XCTUnwrap(golden.requestJSON)).utf8)
            let response = try invoke(function, input)
            XCTAssertEqual(response, golden.expanded(golden.responseJSON), golden.name)
            // All responses are valid canonical JSON; no terminator byte is
            // counted or written, and a short copy leaves the buffer intact.
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(response.utf8)))
            var short = [UInt8](repeating: 0xa5, count: response.utf8.count)
            let result = input.withUnsafeBufferPointer { request in
                short.withUnsafeMutableBufferPointer { output in
                    function(request.baseAddress, request.count, output.baseAddress, output.count - 1)
                }
            }
            XCTAssertEqual(result, -1, golden.name)
            XCTAssertTrue(short.allSatisfy { $0 == 0xa5 }, golden.name)
            for invalid: [UInt8] in [Array("{".utf8), Array("[]".utf8), [0xff, 0xfe]] {
                XCTAssertEqual(invalid.withUnsafeBufferPointer { function($0.baseAddress, $0.count, nil, 0) }, -1, golden.name)
            }
            XCTAssertEqual(function(nil, 0, nil, 0), -1, golden.name)
        }
    }

    func testWireResponsesPinOptionalOmissionAndLowerCamelTags() throws {
        XCTAssertEqual(try invoke(tesseraArtifactsClassifyLink, Array(#"{"urlString":"https://example.com/"}"#.utf8)),
                       #"{"type":"external"}"#)
        XCTAssertEqual(try invoke(tesseraArtifactsQuickOpenParse, Array(#"{"input":"missing:/a","context":{"hosts":[],"listeningPorts":[]}}"#.utf8)),
                       #"{"reason":"unknownHost","type":"invalid"}"#)
        XCTAssertEqual(try invoke(tesseraArtifactsDecodeState, Array(#"{"version":1,"tabs":[null,4,"bad",{}],"selectedID":"gone"}"#.utf8)),
                       #"{"filter":"all","tabCap":64,"tabs":[],"version":1}"#)
        XCTAssertEqual(try invoke(tesseraArtifactsKind, Array(#"{"path":"index.html"}"#.utf8)),
                       #"{"kind":"pages","viewer":"html"}"#)
    }

    func testRefusedLinkJSONRoundTripsThroughTheABI() throws {
        let response = try invoke(tesseraArtifactsClassifyLink, Array(#"{"urlString":"http://viewer@127.0.0.1:3000/"}"#.utf8))
        XCTAssertEqual(response, #"{"type":"refused"}"#)
        let value = try JSONDecoder().decode(ArtifactsLinkClass.self, from: Data(response.utf8))
        XCTAssertEqual(value, .refused)
        XCTAssertEqual(try JSONEncoder().encode(value), Data(response.utf8))
    }

    func testStrictUTF8AndOutOfRangePortsAndUnknownAction() {
        let invalidRequests: [(Entry, String)] = [
            (tesseraArtifactsForwardPlan, #"{"remotePort":0,"hostRules":[]}"#),
            (tesseraArtifactsForwardPlan, #"{"remotePort":65536,"hostRules":[]}"#),
            (tesseraArtifactsReduce, #"{"state":{"tabs":[]},"action":{"type":"futureAction","nowMillis":1}}"#),
            (tesseraArtifactsKind, #"{"path":3}"#),
            (tesseraArtifactsJoinState, #"{"stateJSON":"[]","blobs":{}}"#),
            (tesseraArtifactsJoinState, #"{"stateJSON":"{","blobs":{}}"#),
            (tesseraArtifactsSplitState, #"{"tabs":[{}]}"#),
            (tesseraArtifactsEncodeState, #"{"tabs":[{}]}"#),
        ]
        for (function, string) in invalidRequests {
            let input = Array(string.utf8)
            XCTAssertEqual(input.withUnsafeBufferPointer { function($0.baseAddress, $0.count, nil, 0) }, -1)
        }
        // JSONDecoder accepts some other Unicode encodings; the ABI accepts
        // UTF-8 only, even when the JSON text would otherwise be valid.
        let utf16 = [UInt8](#"{"path":"a.md"}"#.data(using: .utf16)!)
        XCTAssertEqual(utf16.withUnsafeBufferPointer { tesseraArtifactsKind(requestBytes: $0.baseAddress, requestCount: $0.count,
                                                                         outputBytes: nil, outputCapacity: 0) }, -1)
    }

    func testKeepAsRuleRejectsUnassignedPortAndCollision() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var rule = PortForwardRule.localForward(id: id, autoStart: false, localPort: 0, remotePort: 80)
        let encoder = JSONEncoder()
        let noPort = try encoder.encode(ArtifactsKeepAsRuleABIRequest(ephemeral: rule, label: "app", ruleID: id))
        XCTAssertEqual(noPort.withUnsafeBytes { raw in
            tesseraArtifactsKeepAsRule(requestBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), requestCount: raw.count,
                                       outputBytes: nil, outputCapacity: 0)
        }, -1)
        rule.bind.port = 8080
        let conflicting = PortForwardRule.localForward(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                                                       localPort: 8080, remotePort: 9000)
        let collision = try encoder.encode(ArtifactsKeepAsRuleABIRequest(ephemeral: rule, label: "app", ruleID: id, hostRules: [conflicting]))
        XCTAssertEqual(collision.withUnsafeBytes { raw in
            tesseraArtifactsKeepAsRule(requestBytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), requestCount: raw.count,
                                       outputBytes: nil, outputCapacity: 0)
        }, -1)
    }

    func testEveryJSONEntryRejectsBOMLessUTF16AndUTF32BeforeDecoding() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "artifacts-abi-golden", withExtension: "json"))
        let fixture = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        for golden in fixture.cases where golden.requestJSON != nil {
            let function = try XCTUnwrap(entries[golden.symbol])
            let text = golden.expanded(try XCTUnwrap(golden.requestJSON))
            for encoding: String.Encoding in [.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
                let input = [UInt8](try XCTUnwrap(text.data(using: encoding)))
                XCTAssertTrue(input.contains(0))
                XCTAssertEqual(input.withUnsafeBufferPointer { function($0.baseAddress, $0.count, nil, 0) }, -1, golden.name)
                var output = [UInt8](repeating: 0xa5, count: 1024)
                let result = input.withUnsafeBufferPointer { request in
                    output.withUnsafeMutableBufferPointer { function(request.baseAddress, request.count, $0.baseAddress, $0.count) }
                }
                XCTAssertEqual(result, -1, "\(golden.name): \(encoding)")
                XCTAssertTrue(output.allSatisfy { $0 == 0xa5 }, golden.name)
            }
        }
        XCTAssertEqual(try invoke(tesseraArtifactsKind, Array(#"{"path":"a\u0000.md"}"#.utf8)),
                       #"{"kind":"docs","viewer":"markdown"}"#)
        XCTAssertEqual(try invoke(tesseraArtifactsDecodeState, Array(#"{"version":1,"tabs":[],"future":"\u0000"}"#.utf8)),
                       #"{"filter":"all","tabCap":64,"tabs":[],"version":1}"#)
    }

    func testWholeStateLargerThanGenericABICeilingRoundTrips() throws {
        let diff = String(repeating: "x", count: ArtifactsPersistence.maximumDiffBytes)
        let tabs = (0..<5).map { index in
            ArtifactTab(id: "t\(index)", hostID: "h1", hostLabel: "dev",
                        target: .change(path: "/\(index).swift", diff: diff, summary: "edit"),
                        title: "\(index).swift", openedAt: 1, viewedAt: 1)
        }
        let state = ArtifactsState(tabs: tabs, selectedID: "t0")
        let request = ArtifactsReduceABIRequest(state: state, action: .setFilter(.changes, nowMillis: 2))
        let bytes = [UInt8](try JSONEncoder().encode(request))
        XCTAssertGreaterThan(bytes.count, 1_048_576)
        let response = try invoke(tesseraArtifactsReduce, bytes)
        let result = try JSONDecoder().decode(ArtifactsReduction.self, from: Data(response.utf8))
        XCTAssertEqual(result.state.tabs, tabs)
        XCTAssertEqual(result.state.filter, .changes)
        var byte: UInt8 = 0
        XCTAssertEqual(tesseraArtifactsReduce(requestBytes: &byte, requestCount: 134_217_729,
                                             outputBytes: nil, outputCapacity: 0), -1)
    }

    private func invoke(_ function: Entry, _ request: [UInt8]) throws -> String {
        let count = request.withUnsafeBufferPointer { function($0.baseAddress, $0.count, nil, 0) }
        guard count >= 0 else { XCTFail("valid request returned -1"); return "" }
        var output = [UInt8](repeating: 0, count: Int(count) + 1)
        output[Int(count)] = 0xa5
        let result = request.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { function(input.baseAddress, input.count, $0.baseAddress, Int(count)) }
        }
        XCTAssertEqual(result, count)
        XCTAssertEqual(output[Int(count)], 0xa5)
        return String(decoding: output.prefix(Int(count)), as: UTF8.self)
    }

    private var entries: [String: Entry] {
        [
            "tessera_artifacts_reduce": tesseraArtifactsReduce,
            "tessera_artifacts_overview": tesseraArtifactsOverview,
            "tessera_artifacts_quick_open_parse": tesseraArtifactsQuickOpenParse,
            "tessera_artifacts_quick_open_suggestions": tesseraArtifactsQuickOpenSuggestions,
            "tessera_artifacts_classify_link": tesseraArtifactsClassifyLink,
            "tessera_artifacts_document_link": tesseraArtifactsDocumentLink,
            "tessera_artifacts_listening_ports_parse": tesseraArtifactsListeningPortsParse,
            "tessera_artifacts_forward_plan": tesseraArtifactsForwardPlan,
            "tessera_artifacts_keep_as_rule": tesseraArtifactsKeepAsRule,
            "tessera_artifacts_cache_key": tesseraArtifactsCacheKey,
            "tessera_artifacts_cache_evictions": tesseraArtifactsCacheEvictions,
            "tessera_artifacts_cache_presentation": tesseraArtifactsCachePresentation,
            "tessera_artifacts_decode_state": tesseraArtifactsDecodeState,
            "tessera_artifacts_encode_state": tesseraArtifactsEncodeState,
            "tessera_artifacts_split_state": tesseraArtifactsSplitState,
            "tessera_artifacts_state_blob_digests": tesseraArtifactsStateBlobDigests,
            "tessera_artifacts_join_state": tesseraArtifactsJoinState,
            "tessera_artifacts_kind": tesseraArtifactsKind,
        ]
    }
}
