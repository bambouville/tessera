import Foundation
import XCTest
@testable import TesseraCoreABI

final class AgentMarkdownABITests: XCTestCase {
    func testMarkdownABIProducesCanonicalBoundedJSONWithRequiredSizeConvention() throws {
        let input = Array("# Heading\n\n[link](https://example.com)".utf8)
        let required = input.withUnsafeBytes { raw in
            tesseraAgentMarkdownParse(
                inputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                inputCount: input.count,
                outputBytes: nil,
                outputCapacity: 0
            )
        }
        XCTAssertGreaterThan(required, 0)
        var output = [UInt8](repeating: 0, count: Int(required))
        let outputCapacity = output.count
        let written = input.withUnsafeBytes { raw in output.withUnsafeMutableBytes { destination in
            tesseraAgentMarkdownParse(
                inputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                inputCount: input.count,
                outputBytes: destination.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: outputCapacity
            )
        } }
        XCTAssertEqual(written, required)
        let document = try JSONSerialization.jsonObject(with: Data(output)) as? [String: Any]
        XCTAssertEqual(document?["truncated"] as? Bool, false)
        XCTAssertEqual(((document?["blocks"] as? [[String: Any]])?.first?["kind"] as? String), "heading")
    }

    func testMarkdownABIRejectsInvalidAndOversizedInputWithoutWritingShortOutput() {
        let invalidUTF8: [UInt8] = [0xC3, 0x28]
        XCTAssertEqual(invalidUTF8.withUnsafeBytes { raw in
            tesseraAgentMarkdownParse(
                inputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                inputCount: invalidUTF8.count,
                outputBytes: nil,
                outputCapacity: 0
            )
        }, -1)

        let oversized = [UInt8](repeating: 0x61, count: 128 * 1024 + 1)
        XCTAssertEqual(oversized.withUnsafeBytes { raw in
            tesseraAgentMarkdownParse(
                inputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                inputCount: oversized.count,
                outputBytes: nil,
                outputCapacity: 0
            )
        }, -1)

        let input = Array("text".utf8)
        var output = [UInt8](repeating: 0xA5, count: 1)
        let outputCapacity = output.count
        let result = input.withUnsafeBytes { raw in output.withUnsafeMutableBytes { destination in
            tesseraAgentMarkdownParse(
                inputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                inputCount: input.count,
                outputBytes: destination.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: outputCapacity
            )
        } }
        XCTAssertEqual(result, -1)
        XCTAssertEqual(output, [0xA5])
        XCTAssertGreaterThan(tesseraAgentMarkdownParse(inputBytes: nil, inputCount: 0, outputBytes: nil, outputCapacity: 0), 0)
        XCTAssertEqual(tesseraAgentMarkdownParse(inputBytes: nil, inputCount: 1, outputBytes: nil, outputCapacity: 0), -1)
    }
}
