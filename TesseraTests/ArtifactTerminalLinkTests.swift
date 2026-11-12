import Foundation
import XCTest
@testable import Tessera

final class ArtifactTerminalLinkTests: XCTestCase {
    func testLoopbackLinksBecomePageRequestsWithSavedHostAndLiveSession() {
        let hostID = UUID()
        let sessionID = UUID()
        let links: [(String, String, Int, String)] = [
            ("http://localhost:5173/reports/a%20b?q=one%20two#section", "http", 5173, "/reports/a%20b?q=one%20two#section"),
            ("https://127.42.0.2/dashboard", "https", 443, "/dashboard"),
            ("http://0.0.0.0:8080/", "http", 8080, "/"),
            ("https://[::1]:8443/app?mode=preview#top", "https", 8443, "/app?mode=preview#top"),
            ("http://[::]:3000", "http", 3000, "/")
        ]
        for (link, scheme, port, path) in links {
            XCTAssertEqual(ArtifactTerminalLinkRouting.request(
                for: link, hostID: hostID, sessionID: sessionID, canOpenArtifact: true
            ), ArtifactOpenRequest(
                hostID: hostID, target: .page(scheme: scheme, port: port, path: path),
                origin: .terminalLink, sessionID: sessionID
            ), link)
        }
    }

    func testExternalAndUnsupportedLinksFallThrough() {
        for link in ["https://example.com/a", "http://localhost.example.com:3000/", "mailto:test@example.com", "file:///tmp/report.html", "not a link"] {
            XCTAssertNil(ArtifactTerminalLinkRouting.request(
                for: link, hostID: UUID(), sessionID: UUID(), canOpenArtifact: true
            ), link)
        }
    }

    func testMissingArtifactHandlerFallsThrough() {
        XCTAssertNil(ArtifactTerminalLinkRouting.request(
            for: "http://localhost:3000/", hostID: UUID(), sessionID: UUID(), canOpenArtifact: false
        ))
    }

    func testSessionWithoutSavedHostFallsThrough() {
        XCTAssertNil(ArtifactTerminalLinkRouting.request(
            for: "http://localhost:3000/", hostID: nil, sessionID: UUID(), canOpenArtifact: true
        ))
    }

    func testSelectedLoopbackURLTrimsWhitespaceAndUsesTheLinkRequest() {
        let hostID = UUID()
        let sessionID = UUID()
        XCTAssertEqual(ArtifactTerminalLinkRouting.request(
            for: " \nhttps://localhost:8443/report?view=full#result\t ",
            hostID: hostID, sessionID: sessionID, canOpenArtifact: true
        ), ArtifactOpenRequest(
            hostID: hostID, target: .page(scheme: "https", port: 8443, path: "/report?view=full#result"),
            origin: .terminalLink, sessionID: sessionID
        ))
    }

    func testRefusedLoopbackLinksShowTheTerminalFailureWithoutOpeningAnything() {
        for link in ["http://viewer@127.0.0.1:3000/", "https://viewer:secret@localhost:8443/report"] {
            for artifactAvailable in [false, true] {
                var artifactAttempts = 0
                var failures: [String] = []
                var externalURLs: [URL] = []
                ArtifactTerminalLinkRouting.open(link, onOpenLink: { link in
                    let artifactOpened = ArtifactTerminalLinkRouting.handle(link, openArtifact: {
                        artifactAttempts += 1
                        return artifactAvailable
                    }, showFailure: { failures.append($0) })
                    XCTAssertFalse(artifactOpened, "a refused link must keep terminal focus")
                    return artifactOpened
                }, openExternal: { externalURLs.append($0) })
                XCTAssertEqual(artifactAttempts, 0, link)
                XCTAssertEqual(failures, [String(localized: "this link could not be opened")], link)
                XCTAssertTrue(externalURLs.isEmpty, link)
                XCTAssertNil(ArtifactTerminalLinkRouting.request(
                    for: link, hostID: UUID(), sessionID: UUID(), canOpenArtifact: artifactAvailable
                ), link)
            }
        }
    }

    func testRefusedLoopbackFallbackCannotOpenWhenCallbackIsMissingOrDeclines() {
        for hasCallback in [false, true] {
            var externalURLs: [URL] = []
            let callback: ((String) -> Bool)? = hasCallback ? { _ in false } : nil
            ArtifactTerminalLinkRouting.open(
                "http://viewer@127.0.0.1:3000/", onOpenLink: callback,
                openExternal: { externalURLs.append($0) }
            )
            XCTAssertTrue(externalURLs.isEmpty)
        }
    }

    func testNonRefusedLinksPreserveArtifactAndExternalRouting() throws {
        for link in ["http://localhost:3000/", "https://example.com/a", "mailto:test@example.com", "file:///tmp/report.html"] {
            for artifactOpened in [false, true] {
                var artifactAttempts = 0
                var failures: [String] = []
                var externalURLs: [URL] = []
                ArtifactTerminalLinkRouting.open(link, onOpenLink: { link in
                    ArtifactTerminalLinkRouting.handle(link, openArtifact: {
                        artifactAttempts += 1
                        return artifactOpened
                    }, showFailure: { failures.append($0) })
                }, openExternal: { externalURLs.append($0) })
                XCTAssertEqual(artifactAttempts, 1, link)
                XCTAssertTrue(failures.isEmpty, link)
                XCTAssertEqual(externalURLs, artifactOpened ? [] : [try XCTUnwrap(URL(string: link))], link)
            }
        }
    }

    func testRemoteLoopbackStillOpensExternallyWithoutAnArtifactCallback() throws {
        let link = "http://localhost:3000/"
        var externalURLs: [URL] = []
        ArtifactTerminalLinkRouting.open(link, onOpenLink: nil, openExternal: { externalURLs.append($0) })
        XCTAssertEqual(externalURLs, [try XCTUnwrap(URL(string: link))])
    }
}
