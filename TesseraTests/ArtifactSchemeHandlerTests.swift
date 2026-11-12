import Foundation
import os
import Testing
import WebKit
@testable import Tessera

struct ArtifactSchemeHandlerTests {
    @Test func resolvesSiblingsEncodedNamesAndBuildAncestor() throws {
        let adjacent = try ArtifactPathResolver(pagePath: "/srv/site/report.html")
        #expect(adjacent.rootDirectory == "/srv/site")
        #expect(adjacent.pageRelativePath == "report.html")
        #expect(try adjacent.resolve(percentEncodedPath: "/assets/app.mjs") == "/srv/site/assets/app.mjs")
        #expect(try adjacent.resolve(percentEncodedPath: "/images/a%20b.svg") == "/srv/site/images/a b.svg")
        #expect(try adjacent.resolve(percentEncodedPath: "/assets/../style.css") == "/srv/site/style.css")
        #expect(try adjacent.resolve(percentEncodedPath: "/assets/") == "/srv/site/assets/index.html")
        #expect(try adjacent.resolve(percentEncodedPath: "/") == "/srv/site/index.html")

        let build = try ArtifactPathResolver(pagePath: "/srv/dist/reports/test/index.html", rootDirectory: "/srv/dist")
        #expect(build.pageRelativePath == "reports/test/index.html")
        #expect(try build.resolve(percentEncodedPath: "/reports/test/../../assets/app.js") == "/srv/dist/assets/app.js")
        #expect(try build.resolve(percentEncodedPath: "/assets/app.js") == "/srv/dist/assets/app.js")
    }

    @Test func refusesTraversalEncodedSeparatorsAndInvalidRoots() throws {
        let resolver = try ArtifactPathResolver(pagePath: "/srv/site/index.html")
        for path in ["/../secret", "/a/../../secret", "/%2e%2e/secret", "/%2E%2e%2fsecret", "/a/%2e%2e/%2e%2e/secret", "/a%5c..%5csecret", "/%00secret", "/bad%XX"] {
            #expect(throws: ArtifactRemoteReadError.forbidden) { try resolver.resolve(percentEncodedPath: path) }
        }
        for (page, root) in [("relative.html", "/srv"), ("/srv/site/index.html", "/srv/sit"), ("/srv/site/index.html", "/other"), ("/srv/site/index.html", "/srv/site/index.html"), ("/../../index.html", "/")] {
            #expect(throws: ArtifactRemoteReadError.forbidden) { try ArtifactPathResolver(pagePath: page, rootDirectory: root) }
        }
        // Decode once: an actual percent-encoded filename stays a filename.
        #expect(try resolver.resolve(percentEncodedPath: "/%252e%252e/file") == "/srv/site/%2e%2e/file")
        let filesystemRoot = try ArtifactPathResolver(pagePath: "/index.html")
        #expect(try filesystemRoot.resolve(percentEncodedPath: "/image.png") == "/image.png")
    }

    @Test func mimeTypesCoverBuiltPagesFontsAndImages() {
        let types = [
            "index.html": "text/html", "page.HTM": "text/html", "app.js": "text/javascript", "module.mjs": "text/javascript",
            "style.css": "text/css", "icon.SVG": "image/svg+xml", "runtime.wasm": "application/wasm", "data.json": "application/json",
            "app.js.map": "application/json", "font.woff": "font/woff", "font.woff2": "font/woff2", "font.ttf": "font/ttf",
            "font.otf": "font/otf", "font.eot": "application/vnd.ms-fontobject", "photo.png": "image/png",
            "photo.jpg": "image/jpeg", "photo.jpeg": "image/jpeg", "photo.gif": "image/gif", "photo.webp": "image/webp",
            "photo.avif": "image/avif", "photo.heic": "image/heic", "favicon.ico": "image/x-icon", "photo.tiff": "image/tiff",
            "report.pdf": "application/pdf", "unknown.bin": "application/octet-stream", "README": "application/octet-stream",
        ]
        for (path, expected) in types { #expect(ArtifactMIMEType.forPath("/root/" + path) == expected) }
    }

    @Test func htmlJSONAndPlainTextDeclareUTF8AndBinariesDoNot() {
        let utf8 = Data("café 😀".utf8)
        for path in ["/r/index.html", "/r/data.json", "/r/app.js.map", "/r/site.webmanifest", "/r/plain.txt"] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: utf8) == ArtifactMIMEType.forPath(path) + "; charset=utf-8")
        }
        #expect(ArtifactMIMEType.contentType(forPath: "/r/photo.png", data: utf8) == "image/png")
        #expect(ArtifactMIMEType.contentType(forPath: "/r/runtime.wasm", data: utf8) == "application/wasm")
    }

    @Test func stylesheetsScriptsXMLAndSVGDoNotInferUTF8() {
        for (path, source) in [
            ("/r/style.css", "p::after { content: '£'; }"),
            ("/r/classic.js", "window.price = '£';"),
            ("/r/module.mjs", "export const price = '£';"),
            ("/r/common.cjs", "module.exports = '£';"),
            ("/r/data.xml", "<root>£</root>"),
            ("/r/icon.SVG", "<svg xmlns='http://www.w3.org/2000/svg'><text>£</text></svg>"),
        ] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: Data(source.utf8)) == ArtifactMIMEType.forPath(path))
            #expect(ArtifactMIMEType.contentType(forPath: path, data: Data()) == ArtifactMIMEType.forPath(path))
        }
    }

    @Test func bomlessUTF16XMLDeclarationsAreLeftForTheXMLParser() throws {
        for (encoding, label) in [
            (String.Encoding.utf16LittleEndian, "UTF-16LE"), (.utf16BigEndian, "UTF-16BE"),
        ] {
            let source = "<?xml version=\"1.0\" encoding=\"\(label)\"?><root/>"
            let data = try #require(source.data(using: encoding))
            // ASCII plus NUL is valid UTF-8, but these bytes are UTF-16 XML.
            #expect(String(data: data, encoding: .utf8) != nil)
            for path in ["/r/data.xml", "/r/icon.svg"] {
                #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == ArtifactMIMEType.forPath(path))
            }
        }
    }

    @Test func htmlMetaCharsetOverridesBytesThatAlsoValidateAsUTF8() {
        for declaration in [
            "<meta charset=windows-1252>",
            "<MeTa CHARSET = \"Windows-1252\">",
            "<meta\ncharset\t=\t' windows-1252 ' >",
            "<meta data-note='a > b' charset = windows-1252>",
        ] {
            let data = Data((declaration + "<p>é</p>").utf8)
            #expect(String(data: data, encoding: .utf8) != nil)
            for path in ["/r/index.html", "/r/page.HTM"] {
                #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == "text/html")
            }
        }
    }

    @Test func htmlHttpEquivCharsetWorksInEitherAttributeOrder() {
        for declaration in [
            "<meta http-equiv='Content-Type' content='text/html; charset=windows-1252'>",
            "<META CONTENT=\"text/html; ChArSeT = 'windows-1252'\" HTTP-EQUIV = \" content-type \">",
            "<meta http-equiv = content-type content = 'text/html;\ncharset\t=\tWindows-1252'>",
        ] {
            let data = Data((declaration + "<p>é</p>").utf8)
            for path in ["/r/index.HTML", "/r/page.htm"] {
                #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == "text/html")
            }
        }
    }

    @Test func xmlAndSVGEncodingDeclarationsOverrideUTF8Validity() {
        for declaration in [
            "<?xml version=\"1.0\" encoding=\"windows-1252\"?>",
            "<?XmL version = '1.0'\nEnCoDiNg\t=\t'ISO-8859-1' ?>",
            "<?xml version='1.0'" + String(repeating: " ", count: 1024) + "encoding='windows-1252'?>",
        ] {
            let data = Data((declaration + "<root>é</root>").utf8)
            #expect(ArtifactMIMEType.contentType(forPath: "/r/data.xml", data: data) == "application/xml")
            #expect(ArtifactMIMEType.contentType(forPath: "/r/icon.SVG", data: data) == "image/svg+xml")
        }
    }

    @Test func cssCharsetOverridesBytesThatAlsoValidateAsUTF8() {
        for declaration in ["@charset \"windows-1252\";", "@charset \"ISO-8859-1\";"] {
            let data = Data(declaration.utf8) + Data("a::before { content: \"".utf8)
                + Data([0xc3, 0xa9]) + Data("\"; }".utf8)
            #expect(String(data: data, encoding: .utf8) != nil)
            for path in ["/r/style.css", "/r/theme.CSS"] {
                #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == "text/css")
            }
        }
    }

    @Test func cssCharsetSyntaxIsLeftForWebKit() {
        for declaration in [
            " @charset \"windows-1252\";", "\n@charset \"windows-1252\";", "/* comment */@charset \"windows-1252\";",
            "@Charset \"windows-1252\";", "@CHARSET \"windows-1252\";", "@charset 'windows-1252';",
            "@charset windows-1252;", "@charset  \"windows-1252\";", "@charset\t\"windows-1252\";",
            "@charset \"windows-1252\" ;", "@charset \"windows-1252\"", "@charset \"windows-1252",
            "@charset \"\";", "@charset \"windows-1252\"junk\";", "@char\u{017f}et \"windows-1252\";",
        ] {
            let data = Data((declaration + "a::before { content: 'é'; }").utf8)
            #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: data) == "text/css")
        }
        for data in [Data(), Data("@charset \"".utf8), Data("@charset \"x\"".utf8)] {
            #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: data) == "text/css")
        }
    }

    @Test func cssDoesNotInferACharsetBeyondTheBrowserPrescan() {
        let declaration = "@charset \"" + String(repeating: " ", count: 1000) + "windows-1252\";"
        #expect(declaration.utf8.count == 1024)
        #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: Data((declaration + "é").utf8)) == "text/css")
        let outside = "@charset \"" + String(repeating: " ", count: 1001) + "windows-1252\";é"
        #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: Data(outside.utf8)) == "text/css")
    }

    @Test func cssCharsetDeclarationDoesNotChangeOtherResourceTypes() {
        let data = Data("@charset \"windows-1252\";é".utf8)
        for path in ["/r/index.html", "/r/data.json", "/r/app.js.map", "/r/site.webmanifest", "/r/plain.txt"] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == ArtifactMIMEType.forPath(path) + "; charset=utf-8")
        }
    }

    @Test func htmlCharsetPrescanStopsAt1024Bytes() {
        let declaration = "<meta charset=windows-1252>"
        let padding = 1024 - declaration.utf8.count
        let within = Data((String(repeating: " ", count: padding) + declaration + "é").utf8)
        let outside = Data((String(repeating: " ", count: padding + 1) + declaration + "é").utf8)
        #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: within) == "text/html")
        #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: outside) == "text/html; charset=utf-8")
    }

    @Test func htmlCharsetDetectionRequiresARealASCIIEncodingDeclaration() {
        for markup in [
            "<!-- <meta charset=windows-1252> -->",
            "<metadata charset=windows-1252>",
            "<meta data-charset=windows-1252>",
            "<meta data-note='charset=windows-1252'>",
            "<meta content='text/html; charset=windows-1252'>",
            "<meta http-equiv=refresh content='text/html; charset=windows-1252'>",
            "<meta charset=''>",
            "<meta char\u{017f}et=windows-1252>",
            "<meta\u{00a0}charset=windows-1252>",
            "<meta http-equiv=content-type content='text/html; char\u{017f}et=windows-1252'>",
        ] {
            #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: Data(markup.utf8)) == "text/html; charset=utf-8")
        }
    }

    @Test func documentEncodingDeclarationsDoNotChangeOtherResourceTypes() {
        let data = Data("<meta charset=windows-1252><?xml encoding='windows-1252'?>é".utf8)
        for path in ["/r/data.json", "/r/app.js.map", "/r/site.webmanifest", "/r/plain.txt"] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == ArtifactMIMEType.forPath(path) + "; charset=utf-8")
        }
    }

    @Test func byteOrderMarksTakePrecedenceOverConflictingDeclarations() throws {
        let page = "<meta charset=windows-1252><p>é</p>"
        let utf8 = Data([0xef, 0xbb, 0xbf]) + Data(page.utf8)
        #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: utf8) == "text/html; charset=utf-8")
        #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: Data([0xef, 0xbb, 0xbf, 0xff])) == "text/html; charset=utf-8")
        for (encoding, bom) in [
            (String.Encoding.utf16LittleEndian, Data([0xff, 0xfe])),
            (.utf16BigEndian, Data([0xfe, 0xff])),
            (.utf32LittleEndian, Data([0xff, 0xfe, 0x00, 0x00])),
            (.utf32BigEndian, Data([0x00, 0x00, 0xfe, 0xff])),
        ] {
            let data = bom + (try #require(page.data(using: encoding)))
            #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: data) == "text/html")
        }
        let stylesheet = "@charset \"windows-1252\";a::before { content: 'é'; }"
        let cssUTF8 = Data([0xef, 0xbb, 0xbf]) + Data(stylesheet.utf8)
        #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: cssUTF8) == "text/css; charset=utf-8")
        for (encoding, bom) in [
            (String.Encoding.utf16LittleEndian, Data([0xff, 0xfe])),
            (.utf16BigEndian, Data([0xfe, 0xff])),
            (.utf32LittleEndian, Data([0xff, 0xfe, 0x00, 0x00])),
            (.utf32BigEndian, Data([0x00, 0x00, 0xfe, 0xff])),
        ] {
            let data = bom + (try #require(stylesheet.data(using: encoding)))
            #expect(ArtifactMIMEType.contentType(forPath: "/r/style.css", data: data) == "text/css")
        }
    }

    @Test func everyTextResourceHonorsAUTF8BOM() {
        let data = Data([0xef, 0xbb, 0xbf]) + Data("<meta charset=windows-1252><?xml encoding='UTF-16LE'?>@charset \"windows-1252\";£".utf8)
        for path in [
            "/r/index.html", "/r/style.css", "/r/classic.js", "/r/module.mjs", "/r/common.cjs", "/r/data.xml",
            "/r/icon.svg", "/r/data.json", "/r/app.js.map", "/r/site.webmanifest", "/r/plain.txt",
        ] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: data) == ArtifactMIMEType.forPath(path) + "; charset=utf-8")
        }
    }

    @Test func undeclaredInvalidUTF8IsLeftForWebKitToDecode() {
        for path in [
            "/r/index.html", "/r/data.xml", "/r/icon.svg", "/r/style.css", "/r/classic.js", "/r/module.mjs", "/r/common.cjs",
            "/r/data.json", "/r/app.js.map", "/r/site.webmanifest", "/r/plain.txt",
        ] {
            #expect(ArtifactMIMEType.contentType(forPath: path, data: Data([0xc3, 0x28])) == ArtifactMIMEType.forPath(path))
        }
    }

    @Test @MainActor func windows1252PageLeavesTheStylesheetEncodingInherited() async throws {
        let page = Data("<meta charset=windows-1252><link rel=stylesheet href=style.css>".utf8)
        #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: page) == "text/html")
        // C2 A3 must remain available as Â£ in the referring page's encoding.
        let stylesheet = Data("p::after { content: '".utf8) + Data([0xc2, 0xa3]) + Data("'; }".utf8)
        let reader = ArtifactRecordingReader(result: .success(stylesheet))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/r/index.html", reader: reader)
        let url = try #require(URL(string: "style.css", relativeTo: handler.pageURL)?.absoluteURL)
        let response = await handler.response(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "text/css")
        #expect(response.data == stylesheet)
        let reads = await reader.requests
        #expect(reads.count == 1)
        #expect(reads.first?.path == "/r/style.css")
        #expect(reads.first?.root == "/r")
    }

    @Test @MainActor func undeclaredResourceResponsesPreserveTheirEncodingSignals() async throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16LE\"?><root/>"
        let xmlBE = "<?xml version=\"1.0\" encoding=\"UTF-16BE\"?><root/>"
        for (path, data) in [
            ("/r/classic.js", Data("window.price = '£';".utf8)),
            ("/r/module.mjs", Data("export const price = '£';".utf8)),
            ("/r/common.cjs", Data("module.exports = '£';".utf8)),
            ("/r/icon.svg", Data("<svg xmlns='http://www.w3.org/2000/svg'><text>£</text></svg>".utf8)),
            ("/r/data.xml", try #require(xml.data(using: .utf16LittleEndian))),
            ("/r/data.xml", try #require(xmlBE.data(using: .utf16BigEndian))),
        ] {
            let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: path,
                                                   reader: ArtifactRecordingReader(result: .success(data)))
            let response = await handler.response(for: URLRequest(url: handler.pageURL))
            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"] == ArtifactMIMEType.forPath(path))
            #expect(response.data == data)
        }
    }

    @Test @MainActor func declaredEncodingsKeepResponseBytesAndOmitACharset() async throws {
        for (path, declaration, mime) in [
            ("/r/index.html", "<meta charset=windows-1252>", "text/html"),
            ("/r/page.htm", "<meta http-equiv=content-type content='text/html; charset=windows-1252'>", "text/html"),
            ("/r/data.xml", "<?xml encoding='windows-1252'?>", "application/xml"),
            ("/r/icon.svg", "<?xml encoding='windows-1252'?>", "image/svg+xml"),
            ("/r/style.css", "@charset \"windows-1252\";", "text/css"),
        ] {
            // C3 A9 is valid UTF-8, but a Windows-1252 declaration makes it Ã©.
            let data = Data(declaration.utf8) + Data([0xc3, 0xa9])
            let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: path,
                                                   reader: ArtifactRecordingReader(result: .success(data)))
            let response = await handler.response(for: URLRequest(url: handler.pageURL))
            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"] == mime)
            #expect(response.data == data)
        }
    }

    @Test @MainActor func windows1252AndWideBOMPagesKeepBytesWithoutAForcedCharset() async throws {
        let windows1252 = Data("<meta charset=windows-1252><p>caf".utf8) + Data([0xe9]) + Data("</p>".utf8)
        let utf16LE = Data([0xff, 0xfe, 0x3c, 0x00, 0x70, 0x00, 0x3e, 0x00])
        let utf16BE = Data([0xfe, 0xff, 0x00, 0x3c, 0x00, 0x70, 0x00, 0x3e])
        let utf32LE = Data([0xff, 0xfe, 0x00, 0x00, 0x3c, 0x00, 0x00, 0x00])
        let utf32BE = Data([0x00, 0x00, 0xfe, 0xff, 0x00, 0x00, 0x00, 0x3c])
        for data in [windows1252, utf16LE, utf16BE, utf32LE, utf32BE] {
            #expect(ArtifactMIMEType.contentType(forPath: "/r/index.html", data: data) == "text/html")
            let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/r/index.html",
                                                   reader: ArtifactRecordingReader(result: .success(data)))
            let response = await handler.response(for: URLRequest(url: handler.pageURL))
            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"] == "text/html")
            #expect(response.data == data)
        }
    }

    @Test @MainActor func base64EncodingRunsOffMainActorAndPreservesBytes() async throws {
        let data = Data([0, 1, 127, 128, 255])
        let base64 = try await ArtifactSchemeHandler.encodeBase64(data) { bytes in
            #expect(!Thread.isMainThread)
            return bytes.base64EncodedString()
        }
        #expect(Data(base64Encoded: base64) == data)
    }

    @Test @MainActor func cancellationDuringBase64EncodingReachesTheWorker() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let observedCancellation = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await ArtifactSchemeHandler.encodeBase64(Data([1])) { bytes in
                #expect(!Thread.isMainThread)
                started.withLock { $0 = true }
                #expect(release.wait(timeout: .now() + 5) == .success)
                observedCancellation.withLock { $0 = Task.isCancelled }
                return bytes.base64EncodedString()
            }
        }
        defer { release.signal(); task.cancel() }
        await artifactEventually { started.withLock { $0 } }
        task.cancel()
        release.signal()
        do { _ = try await task.value; Issue.record("cancelled encoding returned a value") }
        catch is CancellationError { }
        #expect(observedCancellation.withLock { $0 })
    }

    @Test @MainActor func pageURLUsesRootRelativePageAndForwardsBoundedRead() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("export default 1".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "TAB-1", pagePath: "/srv/dist/reports/index.html", rootDirectory: "/srv/dist", reader: reader, maxBytes: 64)
        #expect(handler.pageURL.absoluteString == "tessera-artifact://tab-1/reports/index.html")
        let url = try #require(URL(string: "../assets/main.mjs?v=2#module", relativeTo: handler.pageURL)?.absoluteURL)
        let response = await handler.response(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(response.headers["Content-Type"] == "text/javascript")
        #expect(response.headers["Access-Control-Allow-Origin"] == "*")
        #expect(response.headers["Cache-Control"] == "no-store")
        #expect(response.headers["Set-Cookie"] == nil)
        let requests = await reader.requests
        #expect(requests.map(\.path) == ["/srv/dist/assets/main.mjs"])
        #expect(requests.map(\.limit) == [64])
        #expect(requests.map(\.root) == ["/srv/dist"])
    }

    @Test @MainActor func onlyTheExactPagePathMayBeReadOutsideTheCanonicalRoot() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("page".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/site/index.html", reader: reader)
        #expect(await handler.response(for: URLRequest(url: handler.pageURL)).statusCode == 200)
        let other = try #require(URL(string: "other.html", relativeTo: handler.pageURL)?.absoluteURL)
        #expect(await handler.response(for: URLRequest(url: other)).statusCode == 200)
        let requests = await reader.requests
        #expect(requests.map(\.root) == [nil, "/srv/site"])
    }

    @Test @MainActor func escapeAndOtherTabAreForbiddenWithoutReading() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data()))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        for string in ["tessera-artifact://tab/%2e%2e/private", "tessera-artifact://other/index.html", "tessera-artifact://user@tab/index.html", "tessera-artifact://tab:42/index.html", "https://tab/index.html"] {
            let response = await handler.response(for: URLRequest(url: try #require(URL(string: string))))
            #expect(response.statusCode == 403)
        }
        #expect(await reader.requests.isEmpty)
    }

    @Test @MainActor func missingDeniedAndOversizedFilesHaveReadableErrors() async throws {
        for (result, status) in [
            (Result<Data, ArtifactRemoteReadError>.failure(.notFound), 404),
            (.failure(.forbidden), 403),
            (.failure(.fileTooLarge(maxBytes: 16 * 1024 * 1024)), 413),
            (.success(Data(repeating: 1, count: 65)), 413),
        ] {
            let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: ArtifactRecordingReader(result: result), maxBytes: 64)
            let response = await handler.response(for: URLRequest(url: handler.pageURL))
            #expect(response.statusCode == status)
            #expect(response.headers["Content-Type"] == "text/html; charset=utf-8")
            #expect(String(decoding: response.data, as: UTF8.self).contains("artifact unavailable"))
        }
    }

    @Test @MainActor func headOptionsAndMutationMethods() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("hello".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        var request = URLRequest(url: handler.pageURL)
        request.httpMethod = "HEAD"
        let head = await handler.response(for: request)
        #expect(head.statusCode == 200)
        #expect(head.data.isEmpty)
        #expect(head.headers["Content-Length"] == "5")
        request.httpMethod = "OPTIONS"
        let options = await handler.response(for: request)
        #expect(options.statusCode == 204)
        #expect(options.data.isEmpty)
        request.httpMethod = "POST"
        #expect(await handler.response(for: request).statusCode == 405)
        #expect(await reader.requests.count == 1)
    }

    @Test @MainActor func oversizedAssetAlsoReportsAPageLevelFailure() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data(repeating: 1, count: 65)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader, maxBytes: 64)
        var failure: String?
        handler.onFileLimitExceeded = { failure = $0 }
        let asset = try #require(URL(string: "large.wasm", relativeTo: handler.pageURL)?.absoluteURL)
        #expect(await handler.response(for: URLRequest(url: asset)).statusCode == 413)
        #expect(failure?.isEmpty == false)
    }

    @Test @MainActor func stopBeforeReadCompletesCancelsAndNeverCallsSchemeTask() async throws {
        let reader = ArtifactSuspendedReader()
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        let readTask = handler.start(schemeTask)
        await reader.waitUntilStarted()
        handler.stop(schemeTask)
        // Deliberately return bytes despite cancellation to exercise the
        // handler's own stop guard, rather than relying on a polite reader.
        await reader.complete(with: Data("late page".utf8))
        await readTask.value
        #expect(await reader.observedCancellation)
        #expect(schemeTask.callbacks.isEmpty)
    }

    @Test @MainActor func teardownCancelsAllOutstandingReads() async throws {
        let reader = ArtifactSuspendedReader()
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        let readTask = handler.start(schemeTask)
        await reader.waitUntilStarted()
        handler.cancelAll()
        await reader.complete(with: Data("late page".utf8))
        await readTask.value
        #expect(await reader.observedCancellation)
        #expect(schemeTask.callbacks.isEmpty)
    }

    @Test @MainActor func stopBeforeTheReadStartsNeverCallsTheReader() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("page".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        let task = handler.start(schemeTask)
        handler.stop(schemeTask)
        await task.value
        #expect(await reader.requests.isEmpty)
        #expect(schemeTask.callbacks.isEmpty)
    }

    @Test @MainActor func reentrantStopAfterResponsePreventsDataAndFinish() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("page".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        schemeTask.onResponse = { handler.stop(schemeTask) }
        await handler.start(schemeTask).value
        #expect(schemeTask.callbacks == ["response"])
        schemeTask.onResponse = nil
    }

    @Test @MainActor func reentrantStopAfterDataPreventsFinish() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("page".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        schemeTask.onData = { handler.stop(schemeTask) }
        await handler.start(schemeTask).value
        #expect(schemeTask.callbacks == ["response", "data"])
        schemeTask.onData = nil
    }

    @Test @MainActor func completedTaskReceivesResponseDataAndFinishOnce() async throws {
        let reader = ArtifactRecordingReader(result: .success(Data("page".utf8)))
        let handler = try ArtifactSchemeHandler(tabID: "tab", pagePath: "/srv/index.html", reader: reader)
        let schemeTask = ArtifactSchemeTaskStub(url: handler.pageURL)
        await handler.start(schemeTask).value
        handler.stop(schemeTask)
        #expect(schemeTask.callbacks == ["response", "data", "finish"])
        #expect((schemeTask.response as? HTTPURLResponse)?.statusCode == 200)
        #expect(schemeTask.data == Data("page".utf8))
    }

    @Test @MainActor func webOriginIncludesSchemeHostAndEffectivePort() throws {
        let model = ArtifactWebViewModel(url: try #require(URL(string: "http://127.0.0.1:5173/index")))
        #expect(model.containsInOrigin(try #require(URL(string: "http://127.0.0.1:5173/path?q=1#x"))))
        for string in ["http://127.0.0.1:5174", "https://127.0.0.1:5173", "http://localhost:5173", "http://example.com", "http://user@127.0.0.1:5173"] {
            #expect(!model.containsInOrigin(try #require(URL(string: string))))
        }
        let defaultPort = ArtifactWebViewModel(url: try #require(URL(string: "https://example.com/a")))
        #expect(defaultPort.containsInOrigin(try #require(URL(string: "https://EXAMPLE.com:443/b"))))
    }
}

private actor ArtifactRecordingReader: ArtifactRemoteReader {
    struct Read: Sendable { let path: String; let root: String?; let limit: Int }
    let result: Result<Data, ArtifactRemoteReadError>
    private(set) var requests: [Read] = []
    init(result: Result<Data, ArtifactRemoteReadError>) { self.result = result }
    func read(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data {
        requests.append(Read(path: absolutePath, root: allowedRoot, limit: maxBytes))
        return try result.get()
    }
}

private actor ArtifactSuspendedReader: ArtifactRemoteReader {
    private var continuation: CheckedContinuation<Data, Error>?
    private var started = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var observedCancellation = false

    func read(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true
            for waiter in waiting { waiter.resume() }
            waiting.removeAll()
        }
        observedCancellation = Task.isCancelled
        return data
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func complete(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private final class ArtifactSchemeTaskStub: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var callbacks: [String] = []
    private(set) var response: URLResponse?
    private(set) var data = Data()
    var onResponse: (() -> Void)?
    var onData: (() -> Void)?
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) {
        self.response = response
        callbacks.append("response")
        onResponse?()
    }
    func didReceive(_ data: Data) { self.data.append(data); callbacks.append("data"); onData?() }
    func didFinish() { callbacks.append("finish") }
    func didFailWithError(_ error: Error) { callbacks.append("failure") }
}
