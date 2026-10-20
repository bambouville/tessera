import Foundation
import XCTest
@testable import TmuxControlCore

final class ProgramStatusParserTests: XCTestCase {
    private func parse(_ body: String) -> ProgramStatusSequence? {
        ProgramStatusParser.parse(body: body.utf8)
    }

    private func report(_ body: String) -> ProgramStatusReport? {
        guard case .report(let report) = parse(body) else { return nil }
        return report
    }

    private func encoded(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    func testAllStatesAndBlockedKinds() {
        for state in ProgramStatusState.allCases {
            XCTAssertEqual(report("state=\(state.rawValue)")?.action, .set(state))
            for kind in ProgramStatusBlockedKind.allCases {
                let value = report("state=\(state.rawValue):kind=\(kind.rawValue)")
                XCTAssertEqual(value?.kind, state == .blocked ? kind : nil)
            }
        }
        XCTAssertNil(report("state=blocked:kind=other")?.kind)
        for body in ["", "app=cargo", "state=other", "state=WORKING"] { XCTAssertNil(parse(body), body) }
    }

    func testQueryMustBeFirstTrimmedPair() {
        XCTAssertEqual(parse(" \t?\t :state=unknown:bad"), .query)
        XCTAssertEqual(parse("?:\(String(repeating: "x", count: 17))=a"), .query)
        XCTAssertNil(parse("x=y:?"))
        XCTAssertNil(parse("?=yes"))
        XCTAssertEqual(report("state=done:?")?.action, .set(.done))
    }

    func testPairsWhitespaceMalformedUnknownAndLastWins() {
        let body = " \tstate \t= \tworking \t:unknown=a,b/c+=-_:.bad=x:STATE=error:=x:missing:msg=:state=done:state=bad!:title=a$:id=one"
        let value = report(body)
        XCTAssertEqual(value?.action, .set(.done))
        XCTAssertEqual(value?.idPath, ["one"])
        XCTAssertNil(value?.title)
        XCTAssertEqual(report("state=done:state=error")?.action, .set(.error))
        XCTAssertNil(parse("state=working:state=unknown"))
        XCTAssertEqual(report("state=done:app=first:app=second")?.app, "second")
        XCTAssertEqual(report("state=blocked:kind=auth:kind=question")?.kind, .question)
        XCTAssertEqual(report("state=working:progress=1:progress=2")?.progress, 2)
        XCTAssertEqual(report("state=working:id=a:id=b")?.idPath, ["b"])
        XCTAssertEqual(report("state=done:title=YQ==:title=Yg==:msg=YQ==:msg=Yw==")?.title, "b")
        XCTAssertEqual(report("state=done:msg=YQ==:msg=Yw==")?.message, "c")
    }

    func testKeyLimitsAndLowercaseAlphabet() {
        for count in [15, 16] { XCTAssertNotNil(parse("state=idle:\(String(repeating: "a", count: count))=x")) }
        XCTAssertNil(parse("state=idle:\(String(repeating: "a", count: 17))=x"))
        XCTAssertNil(parse("state=idle:\(String(repeating: "A", count: 17))=x"))
        for key in ["", "State", "a1", "a_b", "a-b", "a.b", "é"] {
            XCTAssertEqual(report("state=idle:\(key)=error")?.action, .set(.idle), key)
        }
    }

    func testEmptyLastValueReplacesEarlierValue() {
        XCTAssertNil(parse("state=done:state="))
        XCTAssertNil(parse("state=done:id=a:id="))
        let value = report("state=blocked:kind=auth:kind=:progress=50:progress=:app=cargo:app=:title=YQ==:title=:msg=YQ==:msg=")
        XCTAssertEqual(value?.action, .set(.blocked))
        XCTAssertNil(value?.kind)
        XCTAssertNil(value?.progress)
        XCTAssertNil(value?.app)
        XCTAssertNil(value?.title)
        XCTAssertNil(value?.message)
    }

    func testEveryKnownFieldOccurrenceIsValidatedBeforeLastWins() {
        let invalid: [(String, String)] = [
            ("app", String(repeating: "a", count: 33)),
            ("id", String(repeating: "a", count: 33)),
            ("id", Array(repeating: "a", count: 9).joined(separator: "/")),
            ("id", Array(repeating: String(repeating: "a", count: 32), count: 4).joined(separator: "/")),
            ("title", encoded(String(repeating: "x", count: 193))),
            ("msg", encoded(String(repeating: "x", count: 2049))),
            ("title", "Y"), ("msg", "/w=="),
            ("title", "Cg=="), ("msg", "CQ=="),
        ]
        for (key, value) in invalid {
            let valid = key == "id" || key == "app" ? "cargo" : "YQ=="
            for state in ["done", "clear"] {
                for suffix in [valid, ""] {
                    XCTAssertNil(parse("state=\(state):\(key)=\(value):\(key)=\(suffix)"), "\(state) \(key)")
                }
            }
        }
        XCTAssertEqual(report("state=blocked:app=a/b:app=cargo:kind=other:kind=auth")?.app, "cargo")
        XCTAssertEqual(report("state=blocked:app=cargo:app=a/b:kind=auth:kind=other")?.kind, nil)
        XCTAssertNil(report("state=blocked:app=cargo:app=a/b")?.app)
    }

    func testIDSegmentAndDepthLimits() {
        XCTAssertEqual(report("state=idle")?.idPath, [])
        XCTAssertEqual(report("state=idle:id=A_z.1+-/child")?.idPath, ["A_z.1+-", "child"])
        for count in [31, 32] { XCTAssertNotNil(parse("state=idle:id=\(String(repeating: "a", count: count))")) }
        XCTAssertNil(parse("state=idle:id=\(String(repeating: "a", count: 33))"))
        for count in [7, 8] { XCTAssertNotNil(parse("state=idle:id=\(Array(repeating: "a", count: count).joined(separator: "/"))")) }
        XCTAssertNil(parse("state=idle:id=\(Array(repeating: "a", count: 9).joined(separator: "/"))"))
        for path in ["/a", "a/", "a//b", "a,b", "a=b"] { XCTAssertNil(parse("state=idle:id=\(path)"), path) }
        // Explicit malformed targets must never become root operations.
        for path in ["a!", "", "a b", "é"] { XCTAssertNil(parse("state=idle:id=\(path)")) }
    }

    func testIDTotalByteLimits() {
        for length in [127, 128, 129] {
            let last = length - (32 * 3 + 3)
            let id = [String(repeating: "a", count: 32), String(repeating: "b", count: 32),
                      String(repeating: "c", count: 32), String(repeating: "d", count: last)].joined(separator: "/")
            XCTAssertEqual(id.utf8.count, length)
            XCTAssertEqual(parse("state=done:id=\(id)") != nil, length <= 128)
        }
    }

    func testProgressFormsAndApplicability() {
        for (raw, expected) in [("0", 0), ("100", 100), ("007", 7), ("099", 99)] {
            for state in ["working", "blocked"] {
                XCTAssertEqual(report("state=\(state):progress=\(raw)")?.progress, expected)
            }
        }
        for raw in ["101", "+40", "abc", "0000", "1.0", "-1", "", "1,2"] {
            XCTAssertNil(report("state=working:progress=\(raw)")?.progress, raw)
        }
        for state in ["idle", "done", "error", "clear"] { XCTAssertNil(report("state=\(state):progress=40")?.progress) }
    }

    func testAppAlphabetAndByteLimit() {
        XCTAssertEqual(report("state=done:app=A_z.1+-")?.app, "A_z.1+-")
        for length in [31, 32, 33] {
            XCTAssertEqual(parse("state=done:app=\(String(repeating: "a", count: length))") != nil, length <= 32)
        }
        for app in ["a/b", "a,b", "a=b", ""] { XCTAssertNil(report("state=done:app=\(app)")?.app) }
    }

    func testBase64PaddingAndUTF8() {
        for text in ["a", "ab", "abc", "Bonjour 世界 🚀"] {
            let padded = encoded(text)
            let bare = padded.replacingOccurrences(of: "=", with: "")
            for value in [padded, bare] {
                XCTAssertEqual(report("state=done:title=\(value):msg=\(value)")?.title, text)
                XCTAssertEqual(report("state=done:msg=\(value)")?.message, text)
            }
        }
        for invalid in ["Y", "YQ=", "YQ===", "Y=Q=", "YWJj=", "YWJj====", "_w==", "-w==", "====", "/w=="] {
            for key in ["title", "msg"] { XCTAssertNil(parse("state=done:\(key)=\(invalid)"), invalid) }
        }
        XCTAssertNil(report("state=done:title=")?.title)
        XCTAssertNil(report("state=done:msg=")?.message)
    }

    func testEncodedAndDecodedTextLimits() {
        for (key, decodedLimit, encodedLimit) in [("title", 192, 256), ("msg", 2048, 2732)] {
            for length in [decodedLimit - 1, decodedLimit, decodedLimit + 1] {
                XCTAssertEqual(parse("state=done:\(key)=\(encoded(String(repeating: "x", count: length)))") != nil,
                               length <= decodedLimit, "\(key) decoded \(length)")
            }
            for length in [encodedLimit - 1, encodedLimit, encodedLimit + 1] {
                // 255 and 2731 are valid unpadded lengths with bounded output.
                XCTAssertEqual(parse("state=done:\(key)=\(String(repeating: "A", count: length))") != nil,
                               false, "NUL-decoding input must be rejected even within \(key) limit")
            }
            let boundary = encoded(String(repeating: "x", count: decodedLimit))
            XCTAssertEqual(boundary.utf8.count, encodedLimit)
            XCTAssertNotNil(parse("state=done:\(key)=\(boundary)"))
            XCTAssertNotNil(parse("state=done:\(key)=\(String(boundary.prefix(encodedLimit - 1)))"))
            XCTAssertNil(parse("state=done:\(key)=\(boundary)A"))
        }
        // Limits are bytes, rather than grapheme or scalar counts.
        XCTAssertNotNil(parse("state=done:title=\(encoded(String(repeating: "é", count: 96)))"))
        XCTAssertNil(parse("state=done:title=\(encoded(String(repeating: "é", count: 97)))"))
    }

    func testControlScalarsAndSeparatorsRejected() {
        for value in Array(0...31) + Array(127...159) + [0x2028, 0x2029] {
            let text = "a" + String(UnicodeScalar(value)!) + "b"
            for key in ["title", "msg"] { XCTAssertNil(parse("state=done:\(key)=\(encoded(text))"), "\(key) U+\(value)") }
        }
        XCTAssertEqual(report("state=done:title=\(encoded("a\u{202E}b"))")?.title, "a\u{202E}b")
    }

    func testClearIgnoresValidatedMetadataAndValidatesTarget() {
        let value = report("state=clear:id=a/b:kind=auth:progress=100:app=cargo:title=YQ==:msg=Yg==")
        XCTAssertEqual(value, .init(action: .clear, idPath: ["a", "b"]))
        XCTAssertEqual(report("state=clear"), .init(action: .clear))
        for field in ["app=\(String(repeating: "a", count: 33))", "title=_", "msg=/w==", "msg=Cg=="] {
            XCTAssertNil(parse("state=clear:\(field)"), field)
        }
        XCTAssertNil(parse("state=clear:id=a//b"))
        XCTAssertNil(parse("state=clear:id=a!"))
        XCTAssertNil(parse("state=clear:id="))
        XCTAssertNil(parse("state=clear:\(String(repeating: "a", count: 17))=x"))
    }

    func testDisplaySanitizationAndLiteralMarkup() {
        let removed = Array(0x202A...0x202E) + Array(0x2066...0x2069) + [0x200E, 0x200F, 0x061C]
            + Array(0x200B...0x200D) + Array(0x2060...0x2064) + [0xFEFF, 0x00AD, 0x180E]
        let additional = [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0]
            + Array(0x180B...0x180F) + Array(0x206A...0x206F) + Array(0xFFF0...0xFFF8)
            + Array(0x1BCA0...0x1BCA3) + Array(0x1D173...0x1D17A) + Array(0xE0000...0xE0FFF)
        for value in removed + additional {
            XCTAssertEqual(ProgramStatusText.displaySanitized("a" + String(UnicodeScalar(value)!) + "b"), "ab")
        }
        XCTAssertEqual(ProgramStatusText.displaySanitized(" \t a \n\u{00A0}\u{2003} b  "), "a b")
        XCTAssertEqual(ProgramStatusText.displaySanitized(" \u{202E}\u{200B} "), "")
        XCTAssertEqual(ProgramStatusText.displaySanitized("<b>**literal**</b>"), "<b>**literal**</b>")
        XCTAssertEqual(ProgramStatusText.displaySanitized("☀️"), "☀️")
        XCTAssertEqual(ProgramStatusReply.query, Array("\u{1B}]7501;?\u{1B}\\".utf8))
    }
}
