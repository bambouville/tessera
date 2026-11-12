import Observation
import SwiftUI
import WebKit

enum ArtifactWebNavigationPolicy {
    enum Trigger: Equatable { case linkActivated, formSubmitted, other }
    enum Decision: Equatable { case allow, openExternal, cancel }

    static func decision(
        initialURL: URL,
        destination: URL,
        trigger: Trigger,
        targetsMainFrame: Bool,
        userInitiatedForm: Bool = false
    ) -> Decision {
        if containsInOrigin(destination, initialURL: initialURL) { return .allow }
        guard targetsMainFrame, destination.user == nil, destination.password == nil,
              ["http", "https", "mailto", "tel"].contains(destination.scheme?.lowercased() ?? ""),
              !ArtifactServedPageRules.blocks(destination) else {
            return .cancel
        }
        switch trigger {
        case .linkActivated: return .openExternal
        case .formSubmitted: return userInitiatedForm ? .openExternal : .cancel
        case .other: return .cancel
        }
    }

    static func containsInOrigin(_ candidate: URL, initialURL: URL) -> Bool {
        guard candidate.user == nil, candidate.password == nil else { return false }
        return candidate.scheme?.lowercased() == initialURL.scheme?.lowercased()
            && candidate.host?.lowercased() == initialURL.host?.lowercased()
            && effectivePort(candidate) == effectivePort(initialURL)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

struct ArtifactWebFormSubmission {
    let action: URL
    let source: URL
    let uptime: TimeInterval

    func matches(destination: URL, source: URL?, now: TimeInterval) -> Bool {
        // GET forms add their fields to the query after the submit event.
        source == self.source && now >= uptime && now - uptime <= 1
            && ArtifactWebNavigationPolicy.containsInOrigin(destination, initialURL: action)
            && destination.path == action.path
    }
}

enum ArtifactServedPageRules {
    static func applies(to url: URL) -> Bool { url.scheme?.lowercased() == "tessera-artifact" }

    static func blocks(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let embedded: String
        if address.hasPrefix("::ffff:") { embedded = String(address.dropFirst(7)) }
        else if address.hasPrefix("::") { embedded = String(address.dropFirst(2)) }
        else { embedded = "" }
        let embeddedLoopback = embedded.range(of: #"^7f[0-9a-f][0-9a-f]:[0-9a-f]+$"#, options: .regularExpression) != nil
        return isIPv4Loopback(host) || isIPv4Loopback(embedded) || embeddedLoopback
            || ["localhost", "::1", "0.0.0.0", "::", "::ffff:0:0", "::ffff:0.0.0.0"].contains(address)
            || address.hasSuffix(".localhost")
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        host.hasPrefix("127.") && host.dropFirst(4).utf8.allSatisfy { $0 == 46 || (48...57).contains($0) }
    }

    // WebKit has neither alternation nor counted repetition. Each host has
    // one rule, with no resource-type or scheme restriction (including ws and wss).
    static let json = #"""
    [
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?127\\.[0-9.]+([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?([^/:@?#]*\\.)?localhost\\.?([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?\\[::1\\]([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?0\\.0\\.0\\.0\\.?([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?\\[::\\]([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?\\[::ffff:7f[0-9a-f][0-9a-f]:[0-9a-f]+\\]([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?\\[::7f[0-9a-f][0-9a-f]:[0-9a-f]+\\]([:/?#].*)?$"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^[a-z][a-z0-9+.-]*://([^/?#@]*@)?\\[::ffff:0:0\\]([:/?#].*)?$"},"action":{"type":"block"}}
    ]
    """#
}

@MainActor
private enum ArtifactServedPageRuleList {
    private static var compilation: Task<WKContentRuleList?, Never>?

    static func compiled() async -> WKContentRuleList? {
        if let compilation { return await compilation.value }
        let task = Task<WKContentRuleList?, Never> {
            await withCheckedContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "tessera-artifact-device-local-v1", encodedContentRuleList: ArtifactServedPageRules.json
                ) { list, error in
                    if let error { NSLog("Artifacts: page rules failed: %@", error.localizedDescription) }
                    else if list == nil { NSLog("Artifacts: page rules were not compiled") }
                    continuation.resume(returning: list)
                }
            }
        }
        compilation = task
        return await task.value
    }
}

struct ArtifactWebSchemeRegistration {
    let scheme: String
    let handler: any WKURLSchemeHandler

    init(scheme: String, handler: any WKURLSchemeHandler) {
        self.scheme = scheme.lowercased()
        self.handler = handler
    }
}

/// A page inside the browser's layout. The browser may hide this small
/// toolbar and drive the same model from its own address/menu controls.
@MainActor
struct ArtifactWebView: View {
    private enum Source {
        case url(URL, ArtifactWebSchemeRegistration?)
        case model(ArtifactWebViewModel)
    }
    private struct Identity: Hashable {
        let url: URL
        let scheme: String?
        let handler: ObjectIdentifier?
    }
    private let source: Source
    private let showsControls: Bool
    private let onTitleChange: (String) -> Void

    init(
        url: URL,
        schemeRegistration: ArtifactWebSchemeRegistration? = nil,
        showsControls: Bool = true,
        onTitleChange: @escaping (String) -> Void = { _ in }
    ) {
        source = .url(url, schemeRegistration)
        self.showsControls = showsControls
        self.onTitleChange = onTitleChange
    }

    init(
        model: ArtifactWebViewModel,
        showsControls: Bool = true,
        onTitleChange: @escaping (String) -> Void = { _ in }
    ) {
        source = .model(model)
        self.showsControls = showsControls
        self.onTitleChange = onTitleChange
    }

    @ViewBuilder
    var body: some View {
        switch source {
        case .url(let url, let registration):
            ArtifactWebContent(model: ArtifactWebViewModel(url: url, schemeRegistration: registration),
                               showsControls: showsControls, onTitleChange: onTitleChange)
                .id(Identity(url: url, scheme: registration?.scheme,
                             handler: registration.map { ObjectIdentifier($0.handler) }))
        case .model(let model):
            ArtifactWebContent(model: model, showsControls: showsControls, onTitleChange: onTitleChange)
                .id(ObjectIdentifier(model))
        }
    }
}

@MainActor
private struct ArtifactWebContent: View {
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.designTokens) private var T
    @Environment(\.openURL) private var openURL
    @State private var model: ArtifactWebViewModel
    let showsControls: Bool
    let onTitleChange: (String) -> Void

    init(model: ArtifactWebViewModel, showsControls: Bool, onTitleChange: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.showsControls = showsControls
        self.onTitleChange = onTitleChange
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsControls { controls }
            GeometryReader { geometry in
                Rectangle()
                    .fill(T.accent)
                    .frame(width: geometry.size.width * model.progress)
                    .animation(.easeOut(duration: 0.15), value: model.progress)
            }
            .frame(height: 2)
            .opacity(model.isLoading ? 1 : 0)
            ZStack {
                ArtifactWebSurface(model: model) { url in
                    if !appLockController.isLocked { openURL(url) }
                }
                    .id(ObjectIdentifier(model))
                if let failure = model.failure { failureCard(failure) }
            }
        }
        .background(T.bg)
        // No ignored keyboard safe area: a page's form scrolls above the
        // software keyboard on iPhone and in a narrow iPad pane.
        .onChange(of: model.title, initial: true) { _, title in
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onTitleChange(title)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            chromeButton("chevron.left", label: "back", enabled: model.canGoBack) { model.goBack() }
            chromeButton("chevron.right", label: "forward", enabled: model.canGoForward) { model.goForward() }
            chromeButton(model.isLoading ? "xmark" : "arrow.clockwise",
                         label: model.isLoading ? "stop" : "reload") {
                if model.isLoading { model.stop() } else { model.reload() }
            }
            HStack(spacing: 5) {
                Image(systemName: addressSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.fgMuted)
                Text(verbatim: model.displayURL)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 8)
            .background(T.inputBg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, lineWidth: 1))
            .accessibilityLabel(Text(verbatim: model.displayURL))
            if model.canOpenInBrowser {
                chromeButton("arrow.up.forward.square", label: "open in safari") {
                    if !appLockController.isLocked, let url = model.url { openURL(url) }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(T.panelBg)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    private var addressSymbol: String {
        switch model.url?.scheme?.lowercased() {
        case "https": return "lock"
        case "http": return "arrow.left.arrow.right" // SSH encrypts the tunnel.
        default: return "doc.richtext"
        }
    }

    private func chromeButton(
        _ symbol: String,
        label: LocalizedStringKey,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? T.fg : T.fgFaint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("this page did not answer")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)
            Text(verbatim: message)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
            Btn(style: .primary, compact: true, action: { model.reload() }) {
                Text("retry").frame(minHeight: 32)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(T.panelBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border, lineWidth: 1))
        .padding(16)
    }
}

/// A page session retains its web view and private data store while surfaces
/// come and go. Only one surface may mount it; a transition's newcomer waits.
@Observable
@MainActor
final class ArtifactWebViewModel: NSObject {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var title: String?
    private(set) var url: URL?
    private(set) var failure: String?

    let initialURL: URL
    @ObservationIgnored private let schemeRegistration: ArtifactWebSchemeRegistration?
    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private weak var mountedSurface: ArtifactWebSurfaceContainer?
    @ObservationIgnored private var waitingSurfaces: [WaitingSurface] = []
    @ObservationIgnored private var isDiscarded = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var openExternalURL: ((URL) -> Void)?
    @ObservationIgnored private var mayLoad = false
    @ObservationIgnored private var artifactFailure: String?
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var wantsInitialLoad = false
    @ObservationIgnored private var initialLoadDeferred = false
    @ObservationIgnored private var userFormSubmission: ArtifactWebFormSubmission?
    /// When the page last left a window while it held the keyboard.
    @ObservationIgnored private var focusLeftAt: TimeInterval?
    /// Set while the main queue's turn in which the page gave up the
    /// keyboard runs: UIKit resigns a leaving subtree's first responder
    /// before any view in it hears that it is leaving.
    @ObservationIgnored private var resignedThisTurn = false

    /// A pose change moves the page to another surface within one layout
    /// pass; a later return (another section, another tab) is not one.
    var focusHandoverWindow: TimeInterval = 1

    private struct WaitingSurface {
        weak var view: ArtifactWebSurfaceContainer?
    }

    private static let formMessageName = "tesseraArtifactForm"
    private static let formWorld = WKContentWorld.world(name: "tessera-artifact-form")
    private static let formScript = """
    document.addEventListener('submit', event => {
      if (!event.isTrusted || !navigator.userActivation?.isActive) return;
      const form = event.target;
      if (!(form instanceof HTMLFormElement)) return;
      const button = event.submitter;
      const action = button?.hasAttribute('formaction') ? button.formAction : form.action;
      window.webkit.messageHandlers.tesseraArtifactForm.postMessage({action}).catch(() => {});
    }, true);
    """

    var displayURL: String { (url ?? initialURL).absoluteString }
    var canOpenInBrowser: Bool { ["http", "https"].contains((url ?? initialURL).scheme?.lowercased() ?? "") }

    init(url: URL, schemeRegistration: ArtifactWebSchemeRegistration? = nil) {
        self.initialURL = url
        self.url = url
        self.schemeRegistration = schemeRegistration
        super.init()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// ⌘F: the system's find bar over this page.
    func presentFind() {
        guard let webView, let find = webView.findInteraction else { return }
        find.presentFindNavigator(showingReplace: false)
    }
    func stop() {
        wantsInitialLoad = false
        initialLoadDeferred = false
        userFormSubmission = nil
        webView?.stopLoading()
        (schemeRegistration?.handler as? ArtifactSchemeHandler)?.cancelAll()
    }

    func reload() {
        guard let webView else { return }
        wantsInitialLoad = true
        if initialLoadTask != nil { return }
        guard mayLoad else { return }
        initialLoadDeferred = false
        artifactFailure = nil
        failure = nil
        if webView.url == nil { webView.load(URLRequest(url: url ?? initialURL)) }
        else { webView.reload() }
    }

    func load(_ url: URL) {
        guard containsInOrigin(url) else { navigationWasBlocked(); return }
        self.url = url
        wantsInitialLoad = true
        artifactFailure = nil
        failure = nil
        if mayLoad {
            initialLoadDeferred = false
            webView?.load(URLRequest(url: url))
        }
    }

    func containsInOrigin(_ candidate: URL) -> Bool {
        ArtifactWebNavigationPolicy.containsInOrigin(candidate, initialURL: initialURL)
    }

    func makeWebView(openExternalURL: @escaping (URL) -> Void) -> WKWebView {
        self.openExternalURL = openExternalURL
        if let webView { return webView }
        artifactFailure = nil
        failure = nil
        mayLoad = false
        wantsInitialLoad = true
        initialLoadDeferred = false
        userFormSubmission = nil
        let configuration = WKWebViewConfiguration()
        // Local forward ports get reused across hosts. A store belongs only
        // to this page session, and is discarded when its selected tab ends.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addScriptMessageHandler(
            ArtifactWebFormMessageHandler(model: self), contentWorld: Self.formWorld, name: Self.formMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.formScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.formWorld
        ))
        var validRegistration = false
        if let registration = schemeRegistration {
            let first = registration.scheme.unicodeScalars.first
            let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-")
            if let first, letters.contains(first), registration.scheme.unicodeScalars.allSatisfy(allowed.contains),
               !WKWebView.handlesURLScheme(registration.scheme) {
                configuration.setURLSchemeHandler(registration.handler, forURLScheme: registration.scheme)
                validRegistration = registration.scheme == initialURL.scheme?.lowercased()
                if let artifacts = registration.handler as? ArtifactSchemeHandler {
                    artifacts.onFileLimitExceeded = { [weak self] message in
                        self?.artifactFailure = message
                        self?.failure = message
                    }
                    artifacts.installFetchSupport(in: configuration.userContentController)
                }
            } else {
                failure = String(localized: "this page's URL scheme cannot be registered")
            }
        }
        let view = ArtifactPageWebView(frame: .zero, configuration: configuration)
        view.onResignFirstResponder = { [weak self] in
            guard let self, !self.resignedThisTurn else { return }
            self.resignedThisTurn = true
            DispatchQueue.main.async { [weak self] in self?.resignedThisTurn = false }
        }
        view.allowsBackForwardNavigationGestures = true
        view.isFindInteractionEnabled = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.keyboardDismissMode = .interactive
        webView = view
        observe(view)
        let scheme = initialURL.scheme?.lowercased() ?? ""
        if failure == nil, initialURL.host != nil, initialURL.user == nil, initialURL.password == nil,
           scheme == "http" || scheme == "https" || validRegistration {
            if ArtifactServedPageRules.applies(to: initialURL) {
                initialLoadTask = Task { [weak self, weak view] in
                    let rules = await ArtifactServedPageRuleList.compiled()
                    guard !Task.isCancelled, let self, let view, self.webView === view else { return }
                    self.initialLoadTask = nil
                    // A remote page must never reach this device's own listeners,
                    // so a page without its rules does not load at all.
                    guard let rules else {
                        self.failure = String(localized: "this page could not be opened safely")
                        return
                    }
                    view.configuration.userContentController.add(rules)
                    self.mayLoad = true
                    guard self.wantsInitialLoad else { return }
                    // A pane hid this page while its rules compiled. Out of
                    // sight it requests nothing until a surface shows it.
                    if self.mountedSurface == nil { self.initialLoadDeferred = true }
                    else { view.load(URLRequest(url: self.url ?? self.initialURL)) }
                }
            } else {
                mayLoad = true
                view.load(URLRequest(url: url ?? initialURL))
            }
        } else if failure == nil {
            failure = String(localized: "this page's URL cannot be opened")
        }
        return view
    }

    fileprivate func mount(_ surface: ArtifactWebSurfaceContainer) {
        guard !isDiscarded else { return }
        waitingSurfaces.removeAll { $0.view == nil || $0.view === surface }
        if let mountedSurface, mountedSurface !== surface {
            waitingSurfaces.append(WaitingSurface(view: surface))
            return
        }
        openExternalURL = surface.openExternalURL
        guard mountedSurface !== surface else { return }
        mountedSurface = surface
        let view = makeWebView(openExternalURL: surface.openExternalURL)
        view.frame = surface.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.onWillLeaveWindow = { [weak self, weak surface] in
            guard let self, self.mountedSurface === surface else { return }
            self.noteFocusIfLeaving()
        }
        surface.onDidMoveToWindow = { [weak self, weak surface] in
            guard let self, self.mountedSurface === surface else { return }
            self.restoreFocusIfHandedOver()
        }
        // Moved straight from the previous surface: within one window the
        // page never leaves it, so it keeps first responder and its keyboard.
        surface.addSubview(view)
        restoreFocusIfHandedOver()
        if initialLoadDeferred {
            initialLoadDeferred = false
            if wantsInitialLoad { view.load(URLRequest(url: url ?? initialURL)) }
        }
    }

    fileprivate func unmount(_ surface: ArtifactWebSurfaceContainer) {
        waitingSurfaces.removeAll { $0.view == nil || $0.view === surface }
        guard mountedSurface === surface else { return }
        noteFocusIfLeaving()
        mountedSurface = nil
        openExternalURL = nil
        while !waitingSurfaces.isEmpty {
            if let next = waitingSurfaces.removeFirst().view {
                mount(next)
                return
            }
        }
        webView?.removeFromSuperview()
    }

    /// The page holds the keyboard as it leaves, or gave it up in this turn
    /// because it is leaving.
    private func noteFocusIfLeaving() {
        guard let view = webView,
              resignedThisTurn || ArtifactWebSurfaceContainer.holdsFirstResponder(view) else { return }
        focusLeftAt = ProcessInfo.processInfo.systemUptime
    }

    /// A handover keeps the keyboard only if nobody else has taken input.
    private func restoreFocusIfHandedOver() {
        guard let leftAt = focusLeftAt, let view = webView, let window = view.window else { return }
        focusLeftAt = nil
        guard ProcessInfo.processInfo.systemUptime - leftAt <= focusHandoverWindow,
              !ArtifactWebSurfaceContainer.holdsFirstResponder(view) else { return }
        let activeWindows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        guard !ArtifactWebSurfaceContainer.holdsFirstResponder(window),
              !activeWindows.contains(where: { $0.isKeyWindow && ArtifactWebSurfaceContainer.holdsFirstResponder($0) }) else { return }
        view.becomeFirstResponder()
    }

    func discard() {
        isDiscarded = true
        initialLoadTask?.cancel()
        initialLoadTask = nil
        stop()
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.configuration.userContentController.removeAllUserScripts()
        if let artifacts = schemeRegistration?.handler as? ArtifactSchemeHandler {
            artifacts.onFileLimitExceeded = nil
        }
        webView = nil
        mountedSurface = nil
        waitingSurfaces.removeAll()
        mayLoad = false
        initialLoadDeferred = false
        openExternalURL = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        progress = 0
    }

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = min(1, max(0, view.estimatedProgress)) }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let url = view.url, self?.containsInOrigin(url) == true else { return }
                    self?.url = url
                }
            },
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title }
            },
        ]
    }

    private func decision(for action: WKNavigationAction, destination: URL) -> ArtifactWebNavigationPolicy.Decision {
        let trigger: ArtifactWebNavigationPolicy.Trigger
        switch action.navigationType {
        case .linkActivated: trigger = .linkActivated
        case .formSubmitted: trigger = .formSubmitted
        default: trigger = .other
        }
        let userInitiatedForm = trigger == .formSubmitted && userFormSubmission?.matches(
            destination: destination, source: action.sourceFrame.request.url, now: ProcessInfo.processInfo.systemUptime
        ) == true
        userFormSubmission = nil
        return ArtifactWebNavigationPolicy.decision(initialURL: initialURL, destination: destination, trigger: trigger,
                                                    targetsMainFrame: action.targetFrame?.isMainFrame != false,
                                                    userInitiatedForm: userInitiatedForm)
    }

    private func navigationWasBlocked() {
        let message = String(localized: "this page tried to open a link outside this tab. tap a link to open it.")
        artifactFailure = message
        failure = message
    }

    private func report(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }
}

/// WKUserContentController retains its handler. Keep that edge weak so a
/// retained web view cannot keep its page owner and data store alive forever.
@MainActor
private final class ArtifactWebFormMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var model: ArtifactWebViewModel?

    init(model: ArtifactWebViewModel) { self.model = model }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let model else { replyHandler(nil, "page session ended"); return }
        model.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

extension ArtifactWebViewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard self.webView === webView, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        switch decision(for: navigationAction, destination: url) {
        case .openExternal:
            decisionHandler(.cancel)
            openExternalURL?(url)
            return
        case .cancel:
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false { navigationWasBlocked() }
            return
        case .allow: break
        }
        if navigationAction.targetFrame == nil {
            // target=_blank and window.open keep the same tab and its origin.
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
        } else { decisionHandler(.allow) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let url = navigationResponse.response.url, containsInOrigin(url) else {
            decisionHandler(.cancel)
            // A response/redirect carries no user gesture. Only an action
            // above can hand a link to another application.
            if navigationResponse.isForMainFrame { navigationWasBlocked() }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        userFormSubmission = nil
        artifactFailure = nil
        failure = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = artifactFailure }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = String(localized: "this page was released to free memory. reload to open it again.")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard self.webView === webView, let url = navigationAction.request.url else { return nil }
        switch decision(for: navigationAction, destination: url) {
        case .allow: webView.load(navigationAction.request)
        case .openExternal: openExternalURL?(url)
        case .cancel: navigationWasBlocked()
        }
        return nil
    }
}

extension ArtifactWebViewModel: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let webView, message.name == Self.formMessageName, message.world === Self.formWorld,
              message.webView === webView, let source = message.frameInfo.request.url, containsInOrigin(source),
              let body = message.body as? [String: String], let rawAction = body["action"], let action = URL(string: rawAction) else {
            replyHandler(nil, "form origin was refused")
            return
        }
        userFormSubmission = .init(action: action, source: source, uptime: ProcessInfo.processInfo.systemUptime)
        replyHandler(nil, nil)
    }
}

@MainActor
struct ArtifactWebSurface: UIViewRepresentable {
    @Environment(ShortcutStore.self) private var shortcutStore: ShortcutStore?
    let model: ArtifactWebViewModel
    let openExternalURL: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> ArtifactWebSurfaceContainer {
        let surface = context.coordinator.makeUIView(openExternalURL: openExternalURL)
        surface.shortcutStore = shortcutStore
        return surface
    }
    func updateUIView(_ uiView: ArtifactWebSurfaceContainer, context: Context) {
        uiView.openExternalURL = openExternalURL
        uiView.shortcutStore = shortcutStore
        model.mount(uiView)
    }

    static func dismantleUIView(_ uiView: ArtifactWebSurfaceContainer, coordinator: Coordinator) {
        coordinator.model.unmount(uiView)
    }

    @MainActor
    final class Coordinator {
        let model: ArtifactWebViewModel
        init(model: ArtifactWebViewModel) { self.model = model }

        func makeUIView(openExternalURL: @escaping (URL) -> Void) -> ArtifactWebSurfaceContainer {
            let surface = ArtifactWebSurfaceContainer(frame: .zero)
            surface.openExternalURL = openExternalURL
            model.mount(surface)
            return surface
        }
    }
}

/// Hosts a page's web view, and so sits on a focused page's way up the
/// responder chain.
///
/// A press the focused page leaves alone still reaches the hidden
/// `.keyboardShortcut` buttons above it, but only after WebKit has offered
/// it to the page, whose own key handling could keep it. The browser's
/// chords wait here instead, as key commands, which UIKit matches along the
/// first responder's chain before the page gets the press, so they win as a
/// browser's do. They relay to the browser holding the keyboard in this
/// window, as a terminal beside a Duo pane does. Nothing here overrides
/// `pressesBegan`: every other press passes through.
/// WebKit sends its content view's resign through the web view, so the page
/// hears when it gives up the keyboard, before the surface hears it leave.
final class ArtifactPageWebView: WKWebView {
    var onResignFirstResponder: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let held = ArtifactWebSurfaceContainer.holdsFirstResponder(self)
        let resigned = super.resignFirstResponder()
        if held, resigned { onResignFirstResponder?() }
        return resigned
    }
}

final class ArtifactWebSurfaceContainer: UIView {
    var openExternalURL: (URL) -> Void = { _ in }
    var shortcutStore: ShortcutStore?
    var webView: WKWebView? { subviews.first as? WKWebView }
    /// The page's model notes whether its page leaves the window with the
    /// keyboard, and gives it back once this surface is in one.
    var onWillLeaveWindow: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil, window != nil { onWillLeaveWindow?() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onDidMoveToWindow?() }
    }

    /// WebKit's first responder is a view deep inside the web view.
    static func holdsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains(where: holdsFirstResponder)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard ArtifactsKeyboardFocus.shared.relay(in: window) != nil else { return super.keyCommands }
        let browser = ArtifactsBrowserKeyCommands.make(selector: #selector(browserShortcutFired(_:))) { [shortcutStore] in
            StoredShortcut.binding($0, in: shortcutStore)
        }
        return browser + (super.keyCommands ?? [])
    }

    @objc func browserShortcutFired(_ sender: UIKeyCommand) {
        guard let command = ArtifactsBrowserKeyCommands.command(for: sender) else { return }
        ArtifactsKeyboardFocus.shared.relay(in: window)?.fire(command)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(browserShortcutFired(_:)) else { return super.canPerformAction(action, withSender: sender) }
        guard let relay = ArtifactsKeyboardFocus.shared.relay(in: window) else { return false }
        guard let command = (sender as? UIKeyCommand).flatMap(ArtifactsBrowserKeyCommands.command(for:)) else { return true }
        return relay.available.contains(command)
    }
}
