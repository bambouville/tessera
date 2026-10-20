import SwiftUI
import WebKit
import PortForwarding

/// The in-app browser a tunnel opens into.
///
/// A forwarded port is a web server the user already trusts but cannot reach
/// without leaving Tessera, so the page opens here rather than in Safari: the
/// terminal stays one `done` away, and the tunnel's own chrome says which rule
/// is being browsed.
///
/// Presented as a `fullScreenCover`, not a nested sheet. A form sheet inside
/// the tunnel status sheet would give a dashboard or notebook a fraction of
/// the iPad's width, and on iPhone the two stacked sheets shrink the page to a
/// card.
struct TunnelWebBrowserView: View {
    let target: ForwardedWebTarget
    /// The rule's own label, shown beside the address so a user with several
    /// tunnels open knows which one this is. Empty for an unlabelled rule.
    var ruleLabel: String = ""

    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var model = TunnelWebBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            progressHairline
            Divider().overlay(T.border)
            content
        }
        // The cover inherits the app root's ignored safe area, so the chrome
        // would otherwise sit under the status bar. `safeAreaPadding` pads by
        // whatever inset is actually left, so it is a no-op wherever the
        // region already respects it.
        .safeAreaPadding(.top)
        .background(T.bg)
        .onAppear { model.start(url: target.url) }
    }

    // MARK: - Chrome

    private var chromeBar: some View {
        HStack(spacing: 4) {
            chromeButton("chevron.left", label: "back", enabled: model.canGoBack) {
                model.goBack()
            }
            chromeButton("chevron.right", label: "forward", enabled: model.canGoForward) {
                model.goForward()
            }
            chromeButton(
                model.isLoading ? "xmark" : "arrow.clockwise",
                label: model.isLoading ? "stop" : "reload",
                enabled: true
            ) {
                if model.isLoading { model.stop() } else { model.reload() }
            }

            address
                .frame(maxWidth: .infinity)

            chromeButton("arrow.up.forward.square", label: "open in safari", enabled: true) {
                if let url = URL(string: model.displayURL) { openURL(url) }
            }
            Btn("done", style: .primary, compact: true) { dismiss() }
                .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(T.panelBg)
    }

    private var address: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                // Insecure is the normal case for a tunnel — the SSH channel is
                // the encryption — so the lock is stated, never warned about.
                Image(systemName: target.isSecure ? "lock" : "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.fgMuted)
                Text(verbatim: model.displayURL)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !ruleLabel.isEmpty {
                Text(verbatim: ruleLabel)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.inputBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var progressHairline: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(T.accent)
                .frame(width: geo.size.width * model.progress)
                .animation(.easeOut(duration: 0.15), value: model.progress)
        }
        .frame(height: 2)
        .opacity(model.isLoading ? 1 : 0)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            TunnelWebView(model: model)
            if let failure = model.failure {
                failureCard(failure)
            }
        }
    }

    private func failureCard(_ failure: String) -> some View {
        VStack(spacing: 12) {
            Text("this tunnel did not answer")
                .font(Typography.tesseraMono(size: 13, weight: .medium))
                .foregroundStyle(T.fg)
            Text(verbatim: failure)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .multilineTextAlignment(.center)
            Text("check that the rule is listening and that the remote service is up.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .multilineTextAlignment(.center)
            Btn("retry", style: .primary, compact: true) { model.reload() }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(T.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border, lineWidth: 1)
        )
        .padding(24)
    }

    private func chromeButton(
        _ symbol: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? T.fg : T.fgFaint)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The observable half of the browser: everything the chrome reads, and the
/// handful of commands it issues. The `WKWebView` itself is owned here so a
/// SwiftUI body re-evaluation cannot rebuild it and throw the page away.
@Observable
@MainActor
final class TunnelWebBrowserModel: NSObject {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var displayURL = ""
    private(set) var failure: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    @ObservationIgnored lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Ephemeral on purpose. Every tunnel presents as `127.0.0.1:<port>`,
        // so one persistent store would hand a second host's page the first
        // host's session cookie for the same port — the origins are
        // indistinguishable to WebKit, but the servers behind them are not.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        observe(view)
        return view
    }()

    func start(url: String) {
        // `start` runs on every `onAppear`, including the one that follows a
        // backgrounding — reloading there would throw away a form the user
        // had half filled in.
        guard displayURL.isEmpty, let parsed = URL(string: url) else { return }
        displayURL = url
        webView.load(URLRequest(url: parsed))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    func reload() {
        failure = nil
        if webView.url == nil, let parsed = URL(string: displayURL) {
            // A failed first load leaves no history entry to reload.
            webView.load(URLRequest(url: parsed))
        } else {
            webView.reload()
        }
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
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let url = view.url?.absoluteString else { return }
                    self?.displayURL = url
                }
            },
        ]
    }
}

extension TunnelWebBrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failure = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(error)
    }

    private func report(_ error: Error) {
        // A cancelled load is the user pressing stop, or a redirect the page
        // itself replaced — not a failure worth a card over the content.
        if (error as NSError).code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }
}

/// Hosts the model's `WKWebView`. The representable deliberately owns nothing:
/// SwiftUI rebuilds this struct freely, and a web view built in `makeUIView`
/// would lose its page every time the chrome above it changed.
private struct TunnelWebView: UIViewRepresentable {
    let model: TunnelWebBrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
