import Foundation
import Network
import Testing
import WebKit
@testable import Tessera

struct ArtifactWebPolicyTests {
    private let served = URL(string: "tessera-artifact://tab/index.html")!
    private let forwarded = URL(string: "http://127.0.0.1:5173/")!

    @Test func scriptsCannotLaunchExternalAppsOrSafari() throws {
        for initial in [served, forwarded] {
            for raw in ["tel:+15555550100", "mailto:person@example.com", "https://example.com/", "http://example.com/"] {
                let destination = try #require(URL(string: raw))
                #expect(decision(initial, destination, .other) == .cancel)
                #expect(decision(initial, destination, .other, userInitiatedForm: true) == .cancel)
                #expect(decision(initial, destination, .linkActivated) == .openExternal)
                #expect(decision(initial, destination, .formSubmitted) == .cancel)
                #expect(decision(initial, destination, .formSubmitted, userInitiatedForm: true) == .openExternal)
            }
        }
    }

    @Test func subframesAndUnsupportedSchemesCannotLaunchExternalHandlers() throws {
        for raw in ["https://example.com/", "tel:+15555550100", "mailto:person@example.com"] {
            let destination = try #require(URL(string: raw))
            #expect(ArtifactWebNavigationPolicy.decision(initialURL: served, destination: destination,
                                                        trigger: .linkActivated, targetsMainFrame: false) == .cancel)
        }
        for raw in ["file:///private/data", "javascript:alert(1)", "custom-app://open", "https://user:password@example.com/"] {
            #expect(decision(served, try #require(URL(string: raw)), .linkActivated) == .cancel)
        }
    }

    @Test func scriptsAndHistoryCanStillNavigateInsideTheTabsOrigin() throws {
        for trigger in [ArtifactWebNavigationPolicy.Trigger.linkActivated, .formSubmitted, .other] {
            #expect(decision(served, try #require(URL(string: "tessera-artifact://tab/next.html?q=1#part")), trigger) == .allow)
            #expect(decision(forwarded, try #require(URL(string: "http://127.0.0.1:5173/next")), trigger) == .allow)
            for host in ["localhost", "[::1]", "[::ffff:7f00:1]", "[::7f00:1]", "[::ffff:0:0]"] {
                let initial = try #require(URL(string: "http://\(host):5173/"))
                #expect(decision(initial, try #require(URL(string: "http://\(host):5173/next")), trigger) == .allow)
            }
        }
        let initial = try #require(URL(string: "https://example.com/"))
        #expect(decision(initial, try #require(URL(string: "https://example.com:443/next")), .other) == .allow)
        #expect(decision(initial, try #require(URL(string: "https://example.com:8443/next")), .other) == .cancel)
        #expect(decision(initial, try #require(URL(string: "http://example.com/next")), .other) == .cancel)
    }

    @Test func noPageCanHandDeviceLocalURLsToExternalHandlersEvenOnATap() throws {
        for raw in ["http://127.0.0.1:3000/", "https://127.42.0.8/", "http://localhost:80/", "http://LOCALHOST.:8080/",
                    "http://app.localhost:3000/", "http://A.B.LOCALHOST./", "http://[::1]:3000/", "http://0.0.0.0:8000/", "http://[::]:9000/",
                    "http://[::ffff:7f00:1]:8080/", "https://[::ffff:7fff:ffff]/", "http://[::7f00:1]:3000/",
                    "http://[::7fff:ffff]/", "http://[::ffff:0:0]:9000/", "http://[::FFFF:7F00:1]/",
                    "http://[::ffff:127.0.0.1]:8080/", "http://[::127.0.0.1]/", "http://[::ffff:0.0.0.0]/"] {
            let destination = try #require(URL(string: raw))
            #expect(ArtifactServedPageRules.blocks(destination))
            for initial in [served, forwarded] {
                #expect(decision(initial, destination, .linkActivated) == .cancel)
                #expect(decision(initial, destination, .formSubmitted, userInitiatedForm: true) == .cancel)
                #expect(decision(initial, destination, .other) == .cancel)
            }
        }
    }

    @Test func rulesApplyOnlyToServedPages() {
        #expect(ArtifactServedPageRules.applies(to: served))
        #expect(!ArtifactServedPageRules.applies(to: forwarded))
        #expect(!ArtifactServedPageRules.applies(to: URL(string: "https://example.com/")!))
    }

    @Test func ruleJSONHasOneUnrestrictedBlockRulePerHostPatternWithoutAlternation() throws {
        let rules = try rules()
        #expect(rules.count == 8)
        var filters: Set<String> = []
        for rule in rules {
            #expect(Set(rule.keys) == ["trigger", "action"])
            let action = try #require(rule["action"] as? [String: String])
            #expect(action == ["type": "block"])
            let trigger = try #require(rule["trigger"] as? [String: String])
            #expect(Set(trigger.keys) == ["url-filter"])
            let filter = try #require(trigger["url-filter"])
            #expect(!filter.contains("|"))
            #expect(!filter.contains("{") && !filter.contains("}"))
            #expect(filters.insert(filter).inserted)
            _ = try NSRegularExpression(pattern: filter)
        }
    }

    @Test func eachLocalHostMatchesExactlyOneRuleOnEveryScheme() throws {
        let filters = try filters()
        for scheme in ["http", "https", "ws", "wss", "custom+scheme"] {
            for host in ["127.0.0.1", "127.42.8.1", "127.1", "localhost", "localhost.", "app.localhost", "a-b.c.localhost.",
                         "127.localhost", "a..localhost", ".localhost", "a..b.localhost.", "xn--n3h.localhost", "[::1]", "0.0.0.0", "[::]",
                         "[::ffff:7f00:1]", "[::ffff:7f00:0]", "[::ffff:7f42:801]", "[::ffff:7fff:ffff]",
                         "[::7f00:1]", "[::7f00:0]", "[::7fff:ffff]", "[::ffff:0:0]"] {
                #expect(ArtifactServedPageRules.blocks(try #require(URL(string: "\(scheme)://\(host)/"))))
                for suffix in ["", ":8080", "/path", ":8080/path?query=1#part", "?query=1", "#part"] {
                    let url = "\(scheme)://\(host)\(suffix)"
                    #expect(matches(url, filters: filters) == 1, "missing or ambiguous host rule for \(url)")
                }
                #expect(matches("\(scheme)://user:password@\(host):9000/path", filters: filters) == 1)
            }
        }
    }

    @Test func remoteHostsAndLocalStringsInPathsDoNotMatchRules() throws {
        let filters = try filters()
        for raw in ["https://example.com/", "https://localhost.example.com/", "https://notlocalhost/",
                    "https://app.localhost.example.com/", "https://applocalhost/",
                    "https://0.0.0.0.example.com/", "https://127.0.0.1.example.com/", "https://[2001:db8::1]/",
                    "http://[::ffff:a00:1]/", "https://[::a00:1]/", "http://[::ffff:7e00:1]/",
                    "http://[::ffff:8000:1]/", "http://[::7e00:1]/", "http://[::8000:1]/", "http://[::ffff:0:1]/",
                    "https://example.com/127.0.0.1", "https://example.com/?next=http://localhost:3000/",
                    "https://example.com/[::ffff:7f00:1]", "https://example.com/?next=http://[::7f00:1]/",
                    "tessera-artifact://tab/index.html", "http://localhost@example.com/",
                    "https://example.com?.localhost", "https://example.com#.localhost", "https://example?.localhost/",
                    "https://example.com?@localhost/", "https://example.com#@127.0.0.1", "https://example.com?x@[::1]"] {
            #expect(matches(raw, filters: filters) == 0)
            #expect(!ArtifactServedPageRules.blocks(try #require(URL(string: raw))))
        }
    }

    @Test func userFormEvidenceExpiresAndCannotAuthorizeAnotherFrameOrEndpoint() throws {
        let action = try #require(URL(string: "https://example.com/search"))
        let submission = ArtifactWebFormSubmission(action: action, source: served, uptime: 100)
        let destination = try #require(URL(string: "https://example.com/search?q=hello#results"))
        #expect(submission.matches(destination: destination, source: served, now: 100.5))
        #expect(!submission.matches(destination: destination, source: served, now: 101.01))
        #expect(!submission.matches(destination: destination, source: served, now: 99))
        #expect(!submission.matches(destination: destination, source: nil, now: 100.5))
        #expect(!submission.matches(destination: destination, source: forwarded, now: 100.5))
        for raw in ["https://other.example.com/search", "http://example.com/search", "https://example.com/other",
                    "https://example.com:8443/search", "https://user:password@example.com/search"] {
            #expect(!submission.matches(destination: try #require(URL(string: raw)), source: served, now: 100.5))
        }
    }

    private func decision(
        _ initial: URL, _ destination: URL, _ trigger: ArtifactWebNavigationPolicy.Trigger, userInitiatedForm: Bool = false
    ) -> ArtifactWebNavigationPolicy.Decision {
        ArtifactWebNavigationPolicy.decision(initialURL: initial, destination: destination, trigger: trigger,
                                             targetsMainFrame: true, userInitiatedForm: userInitiatedForm)
    }

    private func rules() throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: Data(ArtifactServedPageRules.json.utf8)) as? [[String: Any]])
    }

    private func filters() throws -> [NSRegularExpression] {
        try rules().map { rule in
            let trigger = try #require(rule["trigger"] as? [String: String])
            return try NSRegularExpression(pattern: #require(trigger["url-filter"]), options: .caseInsensitive)
        }
    }

    private func matches(_ url: String, filters: [NSRegularExpression]) -> Int {
        filters.filter { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }.count
    }
}

@MainActor
struct ArtifactWebSurfaceLifetimeTests {
    @Test func aLivePageModelCreatesOnlyOneWebView() {
        let model = makeModel()
        defer { model.stop() }
        let original = model.makeWebView(openExternalURL: { _ in })
        let next = model.makeWebView(openExternalURL: { _ in })
        #expect(next === original)
    }

    @Test func makeUIViewAfterDismantleReusesTheWebViewAndItsPrivateDataStore() throws {
        let model = makeModel()
        defer { model.discard() }
        let slot = ArtifactWebSurface(model: model, openExternalURL: { _ in }).makeCoordinator()
        let first = slot.makeUIView(openExternalURL: { _ in })
        let original = try #require(first.webView)
        let dataStore = original.configuration.websiteDataStore
        #expect(!dataStore.isPersistent)
        ArtifactWebSurface.dismantleUIView(first, coordinator: slot)
        #expect(first.webView == nil)

        let sheet = ArtifactWebSurface(model: model, openExternalURL: { _ in }).makeCoordinator()
        let next = sheet.makeUIView(openExternalURL: { _ in })
        #expect(next.webView === original)
        #expect(next.webView?.configuration.websiteDataStore === dataStore)
        #expect(model.makeWebView(openExternalURL: { _ in }) === original)
        ArtifactWebSurface.dismantleUIView(next, coordinator: sheet)
    }

    @Test func overlappingSurfacesWaitForReleaseInBothHandoffDirections() throws {
        let model = makeModel()
        defer { model.discard() }
        let slot = ArtifactWebSurface.Coordinator(model: model)
        let sheet = ArtifactWebSurface.Coordinator(model: model)
        let first = slot.makeUIView(openExternalURL: { _ in })
        let original = try #require(first.webView)
        let second = sheet.makeUIView(openExternalURL: { _ in })
        #expect(second.webView == nil)
        #expect(first.webView === original)
        #expect(original.superview === first)

        ArtifactWebSurface.dismantleUIView(first, coordinator: slot)
        #expect(first.webView == nil)
        #expect(second.webView === original)
        let returning = slot.makeUIView(openExternalURL: { _ in })
        #expect(returning.webView == nil)
        ArtifactWebSurface.dismantleUIView(second, coordinator: sheet)
        #expect(returning.webView === original)
        #expect(second.webView == nil)
        // Late teardown of an outgoing copy must not detach the new owner.
        ArtifactWebSurface.dismantleUIView(first, coordinator: slot)
        #expect(returning.webView === original)
        ArtifactWebSurface.dismantleUIView(returning, coordinator: slot)
    }

    @Test func aDismantledWaitingSurfaceCannotStealTheNextMount() throws {
        let model = makeModel()
        defer { model.discard() }
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let first = coordinator.makeUIView(openExternalURL: { _ in })
        let original = try #require(first.webView)
        let cancelled = coordinator.makeUIView(openExternalURL: { _ in })
        let next = coordinator.makeUIView(openExternalURL: { _ in })
        #expect(cancelled.webView == nil)
        #expect(next.webView == nil)
        ArtifactWebSurface.dismantleUIView(cancelled, coordinator: coordinator)
        ArtifactWebSurface.dismantleUIView(first, coordinator: coordinator)
        #expect(cancelled.webView == nil)
        #expect(next.webView === original)
        ArtifactWebSurface.dismantleUIView(next, coordinator: coordinator)
    }

    @Test func endingAPageDetachesItsViewAndRefusesOldSurfaces() throws {
        let model = makeModel()
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let active = coordinator.makeUIView(openExternalURL: { _ in })
        let original = try #require(active.webView)
        let waiting = coordinator.makeUIView(openExternalURL: { _ in })
        model.discard()
        #expect(original.superview == nil)
        #expect(original.navigationDelegate == nil)
        #expect(original.uiDelegate == nil)
        #expect(active.webView == nil)
        #expect(waiting.webView == nil)
        ArtifactWebSurface.dismantleUIView(active, coordinator: coordinator)
        #expect(waiting.webView == nil)
        #expect(coordinator.makeUIView(openExternalURL: { _ in }).webView == nil)
    }

    @Test func anUnmountedWebViewLivesOnlyAsLongAsItsPageModel() async {
        var model: ArtifactWebViewModel? = makeModel()
        weak var view: WKWebView?
        autoreleasepool {
            let coordinator = ArtifactWebSurface.Coordinator(model: model!)
            let surface = coordinator.makeUIView(openExternalURL: { _ in })
            view = surface.webView
            ArtifactWebSurface.dismantleUIView(surface, coordinator: coordinator)
        }
        #expect(view != nil)
        autoreleasepool { model?.discard(); model = nil }
        // WebKit lets go of a stopped view on a later run-loop turn.
        #expect(await webViewReleased { view == nil })
    }

    @Test func aWebViewCannotRetainItsPageModelThroughTheScriptHandler() throws {
        var model: ArtifactWebViewModel? = makeModel()
        weak var released: ArtifactWebViewModel?
        released = model
        let view = try #require(model?.makeWebView(openExternalURL: { _ in }))
        model = nil
        #expect(released == nil)
        view.stopLoading()
    }

    /// A pose change shows the page on another surface. Handed straight
    /// across within one window it keeps first responder, so a form's
    /// keyboard stays up; one that left its window first takes it back.
    @Test func aPageHandedToItsNextSurfaceKeepsTheKeyboard() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        let root = try #require(window.rootViewController?.view)
        let model = makeModel()
        defer { model.discard() }
        // A loaded simulator must not run the hand-over out of time.
        model.focusHandoverWindow = 60
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let first = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(first)
        let view = try #require(first.webView)
        #expect(view.becomeFirstResponder())
        #expect(ArtifactWebSurfaceContainer.holdsFirstResponder(view))

        // SwiftUI makes the next surface before it dismantles the old one.
        let next = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(next)
        ArtifactWebSurface.dismantleUIView(first, coordinator: coordinator)
        #expect(next.webView === view)
        #expect(ArtifactWebSurfaceContainer.holdsFirstResponder(view), "the page lost first responder moving across")

        next.removeFromSuperview()
        #expect(!ArtifactWebSurfaceContainer.holdsFirstResponder(view))
        let third = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(third)
        ArtifactWebSurface.dismantleUIView(next, coordinator: coordinator)
        #expect(third.webView === view)
        #expect(ArtifactWebSurfaceContainer.holdsFirstResponder(view), "the page did not take the keyboard back")

        // A return after the hand-over window is not a hand-over.
        model.focusHandoverWindow = 0
        third.removeFromSuperview()
        let fourth = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(fourth)
        ArtifactWebSurface.dismantleUIView(third, coordinator: coordinator)
        #expect(fourth.webView === view)
        #expect(!ArtifactWebSurfaceContainer.holdsFirstResponder(view), "a late return took the keyboard")
        ArtifactWebSurface.dismantleUIView(fourth, coordinator: coordinator)
        #expect(!ArtifactWebSurfaceContainer.holdsFirstResponder(view))
    }

    @Test func aPageDoesNotReclaimTheKeyboardFromAnotherResponderOnRemount() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        let root = try #require(window.rootViewController?.view)
        let model = makeModel()
        defer { model.discard() }
        // Only the other responder may keep the page from reclaiming.
        model.focusHandoverWindow = 60
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let first = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(first)
        let view = try #require(first.webView)
        #expect(view.becomeFirstResponder())
        #expect(ArtifactWebSurfaceContainer.holdsFirstResponder(view))

        first.removeFromSuperview()
        ArtifactWebSurface.dismantleUIView(first, coordinator: coordinator)
        #expect(!ArtifactWebSurfaceContainer.holdsFirstResponder(view))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(field)
        #expect(field.becomeFirstResponder())

        let next = coordinator.makeUIView(openExternalURL: { _ in })
        root.addSubview(next)
        #expect(next.webView === view)
        #expect(field.isFirstResponder)
        #expect(!ArtifactWebSurfaceContainer.holdsFirstResponder(view))
        ArtifactWebSurface.dismantleUIView(next, coordinator: coordinator)
    }

    private func makeModel() -> ArtifactWebViewModel {
        // An unregistered private scheme creates a view without any request.
        ArtifactWebViewModel(url: URL(string: "tessera-lifetime://fixture/index.html")!)
    }
}

/// WebKit, not NSRegularExpression, decides whether the rule list compiles and
/// what it blocks. A real listener proves a served page never reaches it.
@MainActor
struct ArtifactServedPageLoopbackTests {
    @Test func servedPagesNeverConnectToALoopbackListenerThatOtherPagesReach() async throws {
        let listener = try await LoopbackListener.start()
        defer { listener.cancel() }
        let images = ["http://127.0.0.1:\(listener.port)/probe.png",
                      "http://[::ffff:127.0.0.1]:\(listener.port)/mapped.png"]

        // Count each request path, so IPv4 retries cannot stand in for a
        // mapped-address control that this runtime never actually reached.
        let control = PageHandler(images: images)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(control, forURLScheme: "tessera-control")
        let controlView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        controlView.load(URLRequest(url: try #require(URL(string: "tessera-control://tab/index.html"))))
        #expect(await poll { control.paths.contains("/after.png") && !controlView.isLoading }, "the control page did not finish")
        #expect(listener.paths.contains("/probe.png"), "the IPv4 control never reached the listener")
        #expect(listener.paths.contains("/mapped.png"), "the mapped-address control never reached the listener; blocking is unproven for that address on this runtime")
        controlView.stopLoading()
        let reached = listener.connections

        let served = PageHandler(images: images)
        let model = ArtifactWebViewModel(
            url: try #require(URL(string: "tessera-artifact://tab/index.html")),
            schemeRegistration: ArtifactWebSchemeRegistration(scheme: "tessera-artifact", handler: served)
        )
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let surface = coordinator.makeUIView(openExternalURL: { _ in Issue.record("no external launch expected") })
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        defer { ArtifactWebSurface.dismantleUIView(surface, coordinator: coordinator); model.discard() }
        #expect(await poll { served.paths.contains("/after.png") && !model.isLoading }, "the served page did not finish")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(model.failure == nil)
        #expect(listener.connections == reached, "a served page reached a loopback listener")
    }

    /// A pose can hide a docked page while its rules compile. Hidden, it
    /// requests nothing; the next surface to show it starts the load.
    @Test func aPageHiddenBeforeItsRulesCompileWaitsForItsNextSurface() async throws {
        let url = try #require(URL(string: "tessera-artifact://tab/index.html"))
        // A shown page first, so the shared rules are compiled and the
        // hidden page's own wait ends on the next turn.
        let warm = PageHandler(images: [])
        let shownModel = ArtifactWebViewModel(url: url, schemeRegistration: .init(scheme: "tessera-artifact", handler: warm))
        let shownCoordinator = ArtifactWebSurface.Coordinator(model: shownModel)
        let shown = shownCoordinator.makeUIView(openExternalURL: { _ in })
        defer { ArtifactWebSurface.dismantleUIView(shown, coordinator: shownCoordinator); shownModel.discard() }
        #expect(await poll { warm.paths.contains("/index.html") }, "the shown page never loaded")

        let hidden = PageHandler(images: [])
        let model = ArtifactWebViewModel(url: url, schemeRegistration: .init(scheme: "tessera-artifact", handler: hidden))
        defer { model.discard() }
        let coordinator = ArtifactWebSurface.Coordinator(model: model)
        let first = coordinator.makeUIView(openExternalURL: { _ in })
        let view = try #require(first.webView)
        ArtifactWebSurface.dismantleUIView(first, coordinator: coordinator)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(hidden.paths.isEmpty, "a hidden page requested its document")
        #expect(view.url == nil)

        let next = coordinator.makeUIView(openExternalURL: { _ in })
        defer { ArtifactWebSurface.dismantleUIView(next, coordinator: coordinator) }
        #expect(next.webView === view)
        #expect(await poll { hidden.paths.contains("/after.png") && !model.isLoading }, "the shown page did not finish")
        #expect(hidden.paths.filter { $0 == "/index.html" }.count == 1)
        #expect(model.failure == nil)
    }

    /// The first page in a test process also launches WebKit's content and
    /// network processes, which alone took about 7 s and passed 10 s while
    /// other suites ran. The deadline only bounds a hang.
    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

/// Serves one page with loopback images and a same-scheme sentinel image.
private final class PageHandler: NSObject, WKURLSchemeHandler {
    private let images: [String]
    private(set) var paths: [String] = []

    init(images: [String]) { self.images = images }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        paths.append(url.path)
        let page = url.path == "/index.html"
        let markup = "<!doctype html>" + images.map { "<img src=\"\($0)\">" }.joined() + "<img src=\"after.png\">"
        let body = page ? Data(markup.utf8) : Data()
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: page ? "text/html" : "image/png",
                                             expectedContentLength: body.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "artifact-loopback-probe")
    private let lock = NSLock()
    private var count = 0
    private var requestPaths: Set<String> = []
    private var started = false
    private(set) var port: UInt16 = 0

    var connections: Int { lock.withLock { count } }
    var paths: Set<String> { lock.withLock { requestPaths } }

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let probe = LoopbackListener(listener: try NWListener(using: parameters))
        probe.listener.newConnectionHandler = { [probe] connection in
            probe.lock.withLock { probe.count += 1 }
            connection.start(queue: probe.queue)
            probe.receiveRequest(on: connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.listener.stateUpdateHandler = { state in
                let outcome: Result<Void, Error>
                switch state {
                case .ready: outcome = .success(())
                case let .failed(error): outcome = .failure(error)
                default: return
                }
                if probe.markStarted() { continuation.resume(with: outcome) }
            }
            probe.listener.start(queue: probe.queue)
        }
        probe.port = try #require(probe.listener.port?.rawValue)
        return probe
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            let bytes = buffered + (data ?? Data())
            let request = String(decoding: bytes, as: UTF8.self)
            if let lineEnd = request.range(of: "\r\n") {
                let parts = request[..<lineEnd.lowerBound].split(separator: " ")
                if parts.count >= 2 { _ = lock.withLock { requestPaths.insert(String(parts[1])) } }
                let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if error == nil, !complete, bytes.count < 8192 {
                receiveRequest(on: connection, buffered: bytes)
            } else { connection.cancel() }
        }
    }

    /// True only for the first terminal state, which resumes the start.
    private func markStarted() -> Bool {
        lock.withLock {
            defer { started = true }
            return !started
        }
    }

    func cancel() { listener.cancel() }
}

/// Polls across run-loop turns; a view still alive after the timeout is a leak.
@MainActor
func webViewReleased(timeout: Duration = .seconds(3), _ released: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !released() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
