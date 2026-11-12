import XCTest
@testable import TesseraArtifactsCore

final class ArtifactsDocumentLinksTests: XCTestCase {
    private let doc = "/work/atlas/docs/guide.md"

    func testPathsResolveAgainstTheDocumentOnItsHost() {
        let cases: [(String, ArtifactsDocumentLink)] = [
            ("setup.md", .file(path: "/work/atlas/docs/setup.md")),
            ("./setup.md", .file(path: "/work/atlas/docs/setup.md")),
            ("../README.md", .file(path: "/work/atlas/README.md")),
            ("../../../../../etc/hosts", .file(path: "/etc/hosts")),
            ("api/../api/./v1.md", .file(path: "/work/atlas/docs/api/v1.md")),
            ("/srv/notes.md", .file(path: "/srv/notes.md")),
            ("/srv//notes.md/", .file(path: "/srv/notes.md")),
            ("src/", .file(path: "/work/atlas/docs/src")),
            ("..", .file(path: "/work/atlas")),
            ("setup.md#install", .file(path: "/work/atlas/docs/setup.md")),
            ("setup.md?plain=1#L3", .file(path: "/work/atlas/docs/setup.md")),
            ("my%20notes.md", .file(path: "/work/atlas/docs/my notes.md")),
            ("100%.md", .file(path: "/work/atlas/docs/100%.md")),
            ("caf%C3%A9.md", .file(path: "/work/atlas/docs/café.md")),
            // An escaped dot is a dot, as a browser reads it; "~" is home only as written.
            ("%2E%2E/README.md", .file(path: "/work/atlas/README.md")),
            ("%7E/notes.md", .file(path: "/work/atlas/docs/~/notes.md")),
            ("  setup.md\n", .file(path: "/work/atlas/docs/setup.md")),
            ("~/notes.md", .file(path: "/home/me/notes.md")),
            ("~", .file(path: "/home/me")),
            ("~me/notes.md", .file(path: "/work/atlas/docs/~me/notes.md")),
            ("file:///srv/a.md", .file(path: "/srv/a.md")),
            ("FILE://LocalHost/srv/a%20b.md#top", .file(path: "/srv/a b.md")),
        ]
        for (link, expected) in cases {
            XCTAssertEqual(ArtifactsDocumentLinks.resolve(link, documentPath: doc, home: "/home/me"), expected, link)
        }
    }

    func testLocalhostPagesStayOnTheHostAndTheInternetGoesToTheDevice() {
        let cases: [(String, ArtifactsDocumentLink)] = [
            ("http://localhost:3000/billing?x=1#top", .page(scheme: "http", port: 3000, pathAndQuery: "/billing?x=1#top")),
            ("HTTPS://127.0.0.1/", .page(scheme: "https", port: 443, pathAndQuery: "/")),
            ("http://app.localhost:5173", .page(scheme: "http", port: 5173, pathAndQuery: "/")),
            ("https://example.com/docs", .external),
            ("mailto:team@example.com", .external),
            ("tel:+15555550100", .external),
            ("http://viewer@127.0.0.1:3000/", .refused),
            ("http://%6cocalhost:3000/", .refused),
        ]
        for (link, expected) in cases {
            XCTAssertEqual(ArtifactsDocumentLinks.resolve(link, documentPath: doc), expected, link)
        }
    }

    func testAnchorsAreIgnoredAndUnsafeLinksRefused() {
        let cases: [(String, ArtifactsDocumentLink)] = [
            ("", .ignored),
            ("   ", .ignored),
            ("#install", .ignored),
            ("?plain=1", .ignored),
            ("javascript:alert(1)", .refused),
            ("JavaScript:alert(1)", .refused),
            ("data:text/html,hi", .refused),
            ("blob:https://example.com/x", .refused),
            ("about:blank", .refused),
            ("shortcuts://run-shortcut?name=x", .refused),
            ("file://other-host/srv/a.md", .refused),
            ("file:relative.md", .refused),
            ("//example.com/a.md", .refused),
            ("C:/Windows/notes.md", .refused),
            ("a\u{0}b.md", .refused),
            ("a%00b.md", .refused),
            ("a%0Ab.md", .refused),
            // An escaped "/" never splits a path, so it names no file.
            ("%2Fetc%2Fpasswd", .refused),
            ("..%2Fsecrets.md", .refused),
            ("~/notes.md", .refused),  // home unknown
        ]
        for (link, expected) in cases {
            XCTAssertEqual(ArtifactsDocumentLinks.resolve(link, documentPath: doc), expected, link)
        }
    }

    func testARelativeLinkNeedsAnAbsoluteDocumentPath() {
        XCTAssertEqual(ArtifactsDocumentLinks.resolve("b.md", documentPath: "notes/a.md"), .refused)
        XCTAssertEqual(ArtifactsDocumentLinks.resolve("/srv/b.md", documentPath: "notes/a.md"), .file(path: "/srv/b.md"))
        XCTAssertEqual(ArtifactsDocumentLinks.resolve("b.md", documentPath: "/a.md"), .file(path: "/b.md"))
    }

    func testWireIsFlat() throws {
        let cases: [(ArtifactsDocumentLink, String)] = [
            (.file(path: "/srv/a.md"), #"{"path":"\/srv\/a.md","type":"file"}"#),
            (.page(scheme: "http", port: 3000, pathAndQuery: "/x#y"), #"{"pathAndQuery":"\/x#y","port":3000,"scheme":"http","type":"page"}"#),
            (.external, #"{"type":"external"}"#),
            (.refused, #"{"type":"refused"}"#),
            (.ignored, #"{"type":"ignored"}"#),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (link, json) in cases {
            XCTAssertEqual(String(decoding: try encoder.encode(link), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(ArtifactsDocumentLink.self, from: Data(json.utf8)), link)
        }
        for bad in [#"{"type":"file","path":"a.md"}"#, #"{"type":"page","scheme":"ftp","port":21,"pathAndQuery":"/"}"#, #"{"type":"other"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ArtifactsDocumentLink.self, from: Data(bad.utf8)), bad)
        }
    }
}
