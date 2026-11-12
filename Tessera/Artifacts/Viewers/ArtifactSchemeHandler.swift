import Foundation
import WebKit

/// Adapt `FileBridging.download(remotePath:to:progress:)` using a temporary
/// file and the progress cancellation pattern in MarkdownImageStaging.
/// The adapter must not connect the bridge, and must bound the download,
/// including when the server omits its size or the file grows during a read.
/// It must honor Task cancellation before buffering the complete file.
protocol ArtifactRemoteReader: Sendable {
    /// A nil root is reserved for the tab's exact page file, which may itself
    /// be a symlink. Every sibling read must stay inside the canonical root.
    func read(absolutePath: String, allowedRoot: String?, maxBytes: Int) async throws -> Data
}

/// Readers should translate missing/denied SFTP paths into these errors.
enum ArtifactRemoteReadError: Error, Equatable, LocalizedError, Sendable {
    case notFound
    case forbidden
    case fileTooLarge(maxBytes: Int)

    var errorDescription: String? {
        switch self {
        case .notFound: return String(localized: "this artifact file was not found")
        case .forbidden: return String(localized: "this artifact path is not allowed")
        case .fileTooLarge(let maxBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .binary)
            return String(localized: "this artifact file exceeds the \(limit) preview limit")
        }
    }
}

/// URL paths are relative to this root. With the default root the page is
/// `/index.html`; with an explicit build ancestor it can be `/reports/index.html`.
/// Keeping that directory in pageURL lets ordinary ../ and root-relative
/// links resolve naturally, without exposing the host's filesystem root.
struct ArtifactPathResolver: Sendable {
    let rootDirectory: String
    let pagePath: String
    let pageRelativePath: String

    init(pagePath: String, rootDirectory: String? = nil) throws {
        let page = try Self.absoluteComponents(pagePath)
        guard !page.isEmpty, !pagePath.hasSuffix("/") else { throw ArtifactRemoteReadError.forbidden }
        let root = try rootDirectory.map(Self.absoluteComponents) ?? Array(page.dropLast())
        guard page.count > root.count, Array(page.prefix(root.count)) == root else {
            throw ArtifactRemoteReadError.forbidden
        }
        self.rootDirectory = "/" + root.joined(separator: "/")
        self.pagePath = "/" + page.joined(separator: "/")
        self.pageRelativePath = page.dropFirst(root.count).joined(separator: "/")
    }

    func resolve(percentEncodedPath: String) throws -> String {
        guard let decoded = percentEncodedPath.removingPercentEncoding,
              !decoded.contains("\0"), !decoded.contains("\\") else {
            throw ArtifactRemoteReadError.forbidden
        }
        var components: [String] = []
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !components.isEmpty else { throw ArtifactRemoteReadError.forbidden }
                components.removeLast()
            default: components.append(String(part))
            }
        }
        // A directory request gets its index, rather than a directory listing.
        if components.isEmpty || decoded.hasSuffix("/") { components.append("index.html") }
        let prefix = rootDirectory == "/" ? "" : rootDirectory
        return prefix + "/" + components.joined(separator: "/")
    }

    private static func absoluteComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else {
            throw ArtifactRemoteReadError.forbidden
        }
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !result.isEmpty else { throw ArtifactRemoteReadError.forbidden }
                result.removeLast()
            } else { result.append(String(part)) }
        }
        return result
    }
}

enum ArtifactMIMEType {
    static func forPath(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs", "cjs": return "text/javascript"
        case "css": return "text/css"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "json", "map": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "xml": return "application/xml"
        case "txt", "md", "csv", "log": return "text/plain"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "eot": return "application/vnd.ms-fontobject"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }

    /// Preserve browser encoding detection and inheritance; infer UTF-8 only
    /// for HTML without a declaration, JSON and plain text.
    static func contentType(forPath path: String, data: Data) -> String {
        let mime = forPath(path)
        let xml = mime == "application/xml" || mime == "text/xml" || mime.hasSuffix("+xml")
        let textual = mime.hasPrefix("text/") || xml || ["application/json", "application/manifest+json"].contains(mime)
        guard textual else { return mime }
        let hasWideBOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            || data.starts(with: [0x00, 0x00, 0xfe, 0xff])
        if hasWideBOM { return mime }
        if data.starts(with: [0xef, 0xbb, 0xbf]) { return mime + "; charset=utf-8" }
        if xml || mime == "text/css" || mime == "text/javascript" { return mime }
        if mime == "text/html", hasHTMLEncodingDeclaration(data) { return mime }
        return String(data: data, encoding: .utf8) != nil ? mime + "; charset=utf-8" : mime
    }

    private static let htmlTags = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:-->|$)|<meta(?=[\t\n\f\r />])(?:[^"'<>]|"[^"]*"|'[^']*')*>"#
    )
    private static let declarationAttributes = try! NSRegularExpression(
        pattern: #"([^\t\n\f\r "'<>/=?]+)(?:[\t\n\f\r ]*=[\t\n\f\r ]*(?:"([^"]*)"|'([^']*)'|([^\t\n\f\r "'=<>\x60]+)))?"#
    )

    private static func hasHTMLEncodingDeclaration(_ data: Data) -> Bool {
        // Fold ASCII only, preserving byte positions and treating non-ASCII
        // bytes as non-whitespace rather than Unicode letters or separators.
        let bytes = data.prefix(1024).map { byte -> UInt8 in
            if (65...90).contains(byte) { return byte + 32 }
            return byte < 128 ? byte : 127
        }
        let prefix = String(decoding: bytes, as: UTF8.self)
        for match in htmlTags.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) {
            guard let range = Range(match.range, in: prefix) else { continue }
            let tag = String(prefix[range])
            if tag.hasPrefix("<!--") { continue }
            let attributes = attributes(in: String(tag.dropFirst(5)))
            if let charset = attributes["charset"], !charset.isEmpty { return true }
            if attributes["http-equiv"] == "content-type", let content = attributes["content"],
               content.range(of: #"(?:^|;)[\t\n\f\r ]*charset[\t\n\f\r ]*=[\t\n\f\r ]*["']?[\t\n\f\r ]*[a-z0-9][a-z0-9._:+-]*"#,
                             options: .regularExpression) != nil { return true }
        }
        return false
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let whitespace = CharacterSet(charactersIn: "\t\n\u{000c}\r ")
        for match in declarationAttributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = String(tag[nameRange])
            if attributes[name] != nil { continue }
            let valueRange = (2...4).compactMap { Range(match.range(at: $0), in: tag) }.first
            attributes[name] = valueRange.map { String(tag[$0]).trimmingCharacters(in: whitespace) } ?? ""
        }
        return attributes
    }
}

struct ArtifactResourceResponse: Sendable {
    let url: URL
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

@MainActor
final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "tessera-artifact"
    nonisolated static let defaultMaxBytes = 16 * 1024 * 1024
    nonisolated static let scriptMessageName = "tesseraArtifactRead"

    let tabID: String
    let resolver: ArtifactPathResolver
    let pageURL: URL
    let maxBytes: Int
    /// Escalate an oversized subresource to the containing page's error UI.
    /// An HTML error response alone would only appear in the page's console.
    var onFileLimitExceeded: ((String) -> Void)?

    private let reader: any ArtifactRemoteReader
    private var loads: [ObjectIdentifier: Load] = [:]
    private var scriptLoads: [String: ScriptLoad] = [:]

    private final class Load {
        let schemeTask: any WKURLSchemeTask
        var readTask: Task<Void, Never>?
        init(_ schemeTask: any WKURLSchemeTask) { self.schemeTask = schemeTask }
    }

    private final class ScriptLoad {
        var readTask: Task<Void, Never>?
        var reply: ((Any?, String?) -> Void)?
        init(reply: @escaping (Any?, String?) -> Void) { self.reply = reply }
    }

    init(
        tabID: String,
        pagePath: String,
        rootDirectory: String? = nil,
        reader: any ArtifactRemoteReader,
        maxBytes: Int = ArtifactSchemeHandler.defaultMaxBytes
    ) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !tabID.isEmpty, tabID.unicodeScalars.allSatisfy(allowed.contains), maxBytes > 0 else {
            throw ArtifactRemoteReadError.forbidden
        }
        let resolver = try ArtifactPathResolver(pagePath: pagePath, rootDirectory: rootDirectory)
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = tabID.lowercased()
        components.path = "/" + resolver.pageRelativePath
        guard let pageURL = components.url else { throw ArtifactRemoteReadError.forbidden }
        self.tabID = tabID.lowercased()
        self.resolver = resolver
        self.pageURL = pageURL
        self.reader = reader
        self.maxBytes = maxBytes
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        start(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stop(urlSchemeTask)
    }

    // Separate entry points keep the stop race testable without constructing
    // a WKWebView. WebKit and all callbacks are serialized on the main actor.
    @discardableResult
    func start(_ schemeTask: any WKURLSchemeTask) -> Task<Void, Never> {
        let key = ObjectIdentifier(schemeTask)
        stop(schemeTask)
        let load = Load(schemeTask)
        loads[key] = load
        let request = schemeTask.request
        let task = Task { [weak self, weak load] in
            guard let self else { return }
            let response = await self.response(for: request)
            guard !Task.isCancelled, let load, self.loads[key] === load else { return }
            self.deliver(response, to: load, key: key)
        }
        load.readTask = task
        return task
    }

    func stop(_ schemeTask: any WKURLSchemeTask) {
        let load = loads.removeValue(forKey: ObjectIdentifier(schemeTask))
        load?.readTask?.cancel()
    }

    func cancelAll() {
        let active = Array(loads.values)
        loads.removeAll()
        for load in active { load.readTask?.cancel() }
        let scripts = Array(scriptLoads.values)
        scriptLoads.removeAll()
        for load in scripts {
            load.readTask?.cancel()
            load.reply = nil
        }
    }

    func response(for request: URLRequest) async -> ArtifactResourceResponse {
        let url = request.url ?? pageURL
        do {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == Self.scheme,
                  parts.host?.lowercased() == tabID,
                  parts.user == nil, parts.password == nil, parts.port == nil else {
                throw ArtifactRemoteReadError.forbidden
            }
            let path = try resolver.resolve(percentEncodedPath: parts.percentEncodedPath)
            let method = (request.httpMethod ?? "GET").uppercased()
            if method == "OPTIONS" { return makeResponse(url: url, status: 204, mime: "text/plain", data: Data()) }
            guard method == "GET" || method == "HEAD" else {
                return errorResponse(url: url, status: 405, message: String(localized: "artifact files are read-only"))
            }
            try Task.checkCancellation()
            let data = try await reader.read(absolutePath: path,
                                             allowedRoot: path.utf8.elementsEqual(resolver.pagePath.utf8) ? nil : resolver.rootDirectory,
                                             maxBytes: maxBytes)
            try Task.checkCancellation()
            guard data.count <= maxBytes else { throw ArtifactRemoteReadError.fileTooLarge(maxBytes: maxBytes) }
            let contentType = await Task.detached(priority: .userInitiated) {
                ArtifactMIMEType.contentType(forPath: path, data: data)
            }.value
            try Task.checkCancellation()
            var response = makeResponse(url: url, status: 200, mime: contentType, data: data)
            if method == "HEAD" {
                response = ArtifactResourceResponse(url: url, statusCode: 200, headers: response.headers, data: Data())
            }
            return response
        } catch {
            let status: Int
            switch error {
            case ArtifactRemoteReadError.forbidden: status = 403
            case ArtifactRemoteReadError.notFound: status = 404
            case ArtifactRemoteReadError.fileTooLarge:
                status = 413
                if !Task.isCancelled { onFileLimitExceeded?(error.localizedDescription) }
            default:
                let underlying = error as NSError
                status = (underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileReadNoSuchFileError)
                    || (underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorFileDoesNotExist) ? 404 : 503
            }
            return errorResponse(url: url, status: status, message: error.localizedDescription)
        }
    }

    private func deliver(_ response: ArtifactResourceResponse, to load: Load, key: ObjectIdentifier) {
        guard loads[key] === load else { return }
        guard let http = HTTPURLResponse(url: response.url, statusCode: response.statusCode,
                                         httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            loads.removeValue(forKey: key)
            load.schemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }
        load.schemeTask.didReceive(http)
        // A callback can synchronously reenter stop (also exercised by tests).
        guard loads[key] === load else { return }
        if !response.data.isEmpty { load.schemeTask.didReceive(response.data) }
        guard loads[key] === load else { return }
        loads.removeValue(forKey: key)
        load.schemeTask.didFinish()
    }

    private func makeResponse(url: URL, status: Int, mime: String, data: Data) -> ArtifactResourceResponse {
        ArtifactResourceResponse(url: url, statusCode: status, headers: [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "Accept, Content-Type, Range",
            "X-Content-Type-Options": "nosniff",
        ], data: data)
    }

    private func errorResponse(url: URL, status: Int, message: String) -> ArtifactResourceResponse {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let title = String(localized: "artifact unavailable")
        let body = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>\(title)</title><style>:root{color-scheme:light dark}body{font:14px ui-monospace,monospace;padding:24px;overflow-wrap:anywhere}</style><h1>\(status) · \(title)</h1><p>\(escaped)</p>"
        return makeResponse(url: url, status: status, mime: "text/html; charset=utf-8", data: Data(body.utf8))
    }
}

extension ArtifactSchemeHandler: WKScriptMessageHandlerWithReply {
    /// Fetch does not consistently accept custom schemes in WebKit. This
    /// public message bridge gives same-tab GET/HEAD fetch and async XHR the
    /// exact same bounded reader and path checks as ordinary subresources.
    func installFetchSupport(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.scriptMessageName)
        controller.addUserScript(WKUserScript(source: Self.fetchSupportScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let origin = message.frameInfo.securityOrigin
        let frameURL = message.frameInfo.request.url
        // WebKit can give a custom scheme an opaque security origin. Its
        // frame request still identifies the document we served; do not use
        // a page-supplied origin field or grant access to unrelated frames.
        let isArtifactFrame = (origin.protocol == Self.scheme && origin.host.lowercased() == tabID)
            || (frameURL?.scheme?.lowercased() == Self.scheme && frameURL?.host?.lowercased() == tabID
                && frameURL?.user == nil && frameURL?.password == nil && frameURL?.port == nil)
        guard isArtifactFrame,
              let body = message.body as? [String: String] else {
            replyHandler(nil, "artifact request origin was refused")
            return
        }
        if let cancelledID = body["cancel"] {
            let load = scriptLoads.removeValue(forKey: cancelledID)
            load?.readTask?.cancel()
            load?.reply = nil
            replyHandler(nil, nil)
            return
        }
        guard let id = body["id"], scriptLoads[id] == nil,
              let rawURL = body["url"], let url = URL(string: rawURL) else {
            replyHandler(nil, "invalid artifact request")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = body["method"] ?? "GET"
        let load = ScriptLoad(reply: replyHandler)
        scriptLoads[id] = load
        load.readTask = Task { [weak self, weak load] in
            guard let self else { return }
            let response = await self.response(for: request)
            guard !Task.isCancelled else { return }
            guard let base64 = try? await Self.encodeBase64(response.data) else { return }
            guard !Task.isCancelled, let load, self.scriptLoads[id] === load else { return }
            self.scriptLoads.removeValue(forKey: id)
            let reply = load.reply
            load.reply = nil
            reply?(["status": response.statusCode, "headers": response.headers,
                    "url": response.url.absoluteString, "base64": base64], nil)
        }
    }

    nonisolated static func encodeBase64(
        _ data: Data,
        encode: @escaping @Sendable (Data) throws -> String = { $0.base64EncodedString() }
    ) async throws -> String {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let encoded = try encode(data)
            try Task.checkCancellation()
            return encoded
        }
        return try await withTaskCancellationHandler {
            let encoded = try await task.value
            try Task.checkCancellation()
            return encoded
        } onCancel: { task.cancel() }
    }

    private static let fetchSupportScript = #"""
    (() => {
      if (location.protocol !== 'tessera-artifact:') return;
      const nativeFetch = window.fetch.bind(window), NativeXHR = window.XMLHttpRequest;
      const bridge = window.webkit.messageHandlers.tesseraArtifactRead;
      const sameTab = u => u.protocol === location.protocol && u.host === location.host;
      let serial = 0;
      const prefix = Math.random().toString(36).slice(2) + '-';
      window.fetch = function(input, options = {}) {
        const isRequest = input instanceof Request;
        const url = new URL(isRequest ? input.url : String(input), document.baseURI);
        if (!sameTab(url)) return nativeFetch(input, options);
        const method = String(options.method || (isRequest && input.method) || 'GET').toUpperCase();
        const signal = options.signal || (isRequest && input.signal);
        const id = prefix + (++serial);
        return new Promise((resolve, reject) => {
          let finished = false;
          const cleanup = () => { if (signal) signal.removeEventListener('abort', abort); };
          const abort = () => {
            if (finished) return;
            finished = true; cleanup();
            bridge.postMessage({cancel:id}).catch(() => {});
            reject(new DOMException('The request was aborted.', 'AbortError'));
          };
          if (signal && signal.aborted) { abort(); return; }
          if (signal) signal.addEventListener('abort', abort, {once:true});
          bridge.postMessage({id, url:url.href, method}).then(result => {
            if (finished) return;
            finished = true; cleanup();
            try {
              const bytes = Uint8Array.from(atob(result.base64), c => c.charCodeAt(0));
              const response = new Response(method === 'HEAD' || result.status === 204 ? null : bytes,
                {status:result.status, headers:result.headers});
              Object.defineProperty(response, 'url', {value:result.url});
              resolve(response);
            } catch (error) { reject(error); }
          }, error => { if (!finished) { finished = true; cleanup(); reject(error); } });
        });
      };
      const artifactFetch = window.fetch;
      // Delegate all other URLs to the native implementation. Same-tab XHR
      // is asynchronous and read-only, just like the underlying SFTP files.
      class ArtifactXHR extends EventTarget {
        constructor() {
          super(); this._native = new NativeXHR(); this._custom = false; this._generation = 0;
          this.readyState = 0; this.status = 0; this.statusText = ''; this.response = null;
          this.responseText = ''; this.responseURL = ''; this.responseType = ''; this.timeout = 0;
          this.withCredentials = false; this.upload = this._native.upload;
          for (const name of ['readystatechange','loadstart','progress','load','error','abort','timeout','loadend']) {
            this._native.addEventListener(name, event => {
              if (this._custom) return;
              this.readyState = this._native.readyState; this.status = this._native.status;
              this.statusText = this._native.statusText; this.responseURL = this._native.responseURL;
              this.response = this._native.response;
              if (!this.responseType || this.responseType === 'text') this.responseText = this._native.responseText;
              this._emit(name, event);
            });
          }
        }
        _emit(name, event) {
          const copy = event instanceof ProgressEvent ? new ProgressEvent(name,
            {lengthComputable:event.lengthComputable, loaded:event.loaded, total:event.total}) : new Event(name);
          this.dispatchEvent(copy);
          if (typeof this['on' + name] === 'function') this['on' + name].call(this, copy);
        }
        open(method, value, async = true, user, password) {
          if (this._controller) this._controller.abort();
          clearTimeout(this._timer);
          this._generation++; this._sent = false;
          this._inFlight = false; this._headers = null; this._mime = null;
          this._custom = true; this._native.abort();
          this._url = new URL(value, document.baseURI); this._method = String(method).toUpperCase();
          this._custom = sameTab(this._url);
          if (!this._custom) { this._native.open(method, value, async, user, password); return; }
          if (!async) throw new DOMException('artifact XHR must be asynchronous', 'NotSupportedError');
          this.status = 0; this.response = null; this.responseText = ''; this.responseURL = '';
          this.readyState = 1; this._emit('readystatechange');
        }
        setRequestHeader(name, value) { if (!this._custom) this._native.setRequestHeader(name, value); }
        overrideMimeType(value) { if (!this._custom) this._native.overrideMimeType(value); else this._mime = value; }
        getAllResponseHeaders() {
          if (!this._custom) return this._native.getAllResponseHeaders();
          return this._headers ? [...this._headers].map(([k,v]) => k + ': ' + v).join('\r\n') : '';
        }
        getResponseHeader(name) { return this._custom ? (this._headers ? this._headers.get(name) : null) : this._native.getResponseHeader(name); }
        abort() { if (this._custom) { if (this._inFlight && this._controller) this._controller.abort(); } else this._native.abort(); }
        send(body = null) {
          if (!this._custom) {
            this._native.responseType = this.responseType; this._native.timeout = this.timeout;
            this._native.withCredentials = this.withCredentials; this._native.send(body); return;
          }
          if (this.readyState !== 1 || this._sent) throw new DOMException('XHR is not open', 'InvalidStateError');
          this._sent = true; this._inFlight = true; const generation = this._generation;
          const controller = new AbortController(); this._controller = controller; let timedOut = false;
          const current = () => generation === this._generation && this._controller === controller;
          const emit = (name, event) => { if (!current()) return false; this._emit(name, event); return current(); };
          const timer = this.timeout > 0 ? setTimeout(() => { timedOut = true; controller.abort(); }, this.timeout) : null;
          this._timer = timer;
          if (!emit('loadstart')) { clearTimeout(timer); return; }
          artifactFetch(this._url.href, {method:this._method, signal:controller.signal}).then(async response => {
            if (!current()) return;
            this.status = response.status; this.statusText = response.statusText;
            this.responseURL = response.url; this._headers = response.headers;
            this.readyState = 2; if (!emit('readystatechange')) return;
            if (controller.signal.aborted) throw new DOMException('aborted', 'AbortError');
            this.readyState = 3; if (!emit('readystatechange')) return;
            const bytes = await response.arrayBuffer();
            if (controller.signal.aborted) throw new DOMException('aborted', 'AbortError');
            if (!current()) return;
            if (this.responseType === 'arraybuffer') this.response = bytes;
            else if (this.responseType === 'blob') this.response = new Blob([bytes], {type:this._mime || response.headers.get('Content-Type') || ''});
            else {
              const text = new TextDecoder().decode(bytes);
              if (this.responseType === 'json') { try { this.response = JSON.parse(text); } catch { this.response = null; } }
              else if (this.responseType === 'document') this.response = new DOMParser().parseFromString(text, 'text/html');
              else { this.response = text; this.responseText = text; }
            }
            clearTimeout(timer); this._inFlight = false;
            this.readyState = 4; if (!emit('readystatechange')) return;
            if (!emit('progress', new ProgressEvent('progress', {lengthComputable:true, loaded:bytes.byteLength, total:bytes.byteLength}))) return;
            if (!emit('load')) return;
            emit('loadend');
          }).catch(error => {
            clearTimeout(timer); if (!current()) return;
            this._inFlight = false; this.status = 0; this.readyState = 4;
            if (!emit('readystatechange')) return;
            if (!emit(timedOut ? 'timeout' : error.name === 'AbortError' ? 'abort' : 'error')) return;
            if (!emit('loadend')) return;
            if (error.name === 'AbortError' && !timedOut) this.readyState = 0;
          }).finally(() => clearTimeout(timer));
        }
      }
      for (const [key,value] of Object.entries({UNSENT:0,OPENED:1,HEADERS_RECEIVED:2,LOADING:3,DONE:4})) {
        Object.defineProperty(ArtifactXHR, key, {value}); Object.defineProperty(ArtifactXHR.prototype, key, {value});
      }
      window.XMLHttpRequest = ArtifactXHR;
      // Custom artifact pages have neither persistent storage nor cookies.
      const denied = () => { throw new DOMException('storage is disabled for artifact pages', 'SecurityError'); };
      for (const key of ['localStorage','sessionStorage','indexedDB','caches']) {
        try { Object.defineProperty(window, key, {get:denied, configurable:false}); } catch (_) {}
      }
      try { Object.defineProperty(document, 'cookie', {get:() => '', set:() => {}, configurable:false}); } catch (_) {}
    })();
    """#
}
