import SwiftUI
import UIKit

extension View {
    /// Native TabView items are UIKit views, so an anchor on `.tabItem`'s
    /// SwiftUI Label does not describe the actual button. Mount this on the
    /// compact TabView to publish invisible anchors over its real items.
    func onboardingTabBarAnchors(agentCenterEnabled: Bool, isVisible: Bool = true) -> some View {
        overlay {
            if isVisible {
                OnboardingTabBarAnchors(agentCenterEnabled: agentCenterEnabled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct OnboardingTabBarAnchors: View {
    let agentCenterEnabled: Bool
    @State private var frames: [OnboardingTarget: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                OnboardingTabBarProbe(agentCenterEnabled: agentCenterEnabled) { frames = $0 }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                ForEach([OnboardingTarget.agentsNav, .artifactsNav, .settingsNav], id: \.self) { target in
                    if let frame = frames[target] {
                        Color.clear
                            .frame(width: frame.width, height: frame.height)
                            .onboardingAnchor(target)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
    }
}

private struct OnboardingTabBarProbe: UIViewRepresentable {
    let agentCenterEnabled: Bool
    let onFramesChanged: ([OnboardingTarget: CGRect]) -> Void

    func makeUIView(context: Context) -> OnboardingTabBarProbeView {
        OnboardingTabBarProbeView(frame: .zero)
    }

    func updateUIView(_ view: OnboardingTabBarProbeView, context: Context) {
        var targets: [OnboardingTarget?] = [nil, nil]
        if agentCenterEnabled { targets.append(.agentsNav) }
        targets.append(contentsOf: [.artifactsNav, .settingsNav])
        view.targets = targets
        view.onFramesChanged = onFramesChanged
        view.refreshAfterLayout()
    }
}

private final class OnboardingTabBarProbeView: UIView {
    var targets: [OnboardingTarget?] = []
    var onFramesChanged: (([OnboardingTarget: CGRect]) -> Void)?
    private var lastFrames: [OnboardingTarget: CGRect] = [:]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAfterLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshAfterLayout()
    }

    func refreshAfterLayout() {
        // Preference/state updates must happen after UIKit and SwiftUI finish
        // the current layout pass. A disappearing bar publishes no targets.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frames = self.itemFrames()
            guard frames != self.lastFrames else { return }
            self.lastFrames = frames
            self.onFramesChanged?(frames)
        }
    }

    private func itemFrames() -> [OnboardingTarget: CGRect] {
        guard let window, let bar = visibleTabBar(in: window),
              bar.items?.count == targets.count else { return [:] }
        let controls = itemControls(in: bar).sorted {
            let left = $0.convert($0.bounds, to: bar).midX
            let right = $1.convert($1.bounds, to: bar).midX
            return bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? left > right : left < right
        }
        // Unknown UIKit layouts fall back to the centered coach card rather
        // than spotlighting a guessed position or the wrong destination.
        guard controls.count == targets.count else { return [:] }
        var frames: [OnboardingTarget: CGRect] = [:]
        for (target, control) in zip(targets, controls) {
            if let target { frames[target] = control.convert(control.bounds, to: self) }
        }
        return frames
    }

    private func visibleTabBar(in view: UIView) -> UITabBar? {
        guard !view.isHidden, view.alpha > 0 else { return nil }
        if let bar = view as? UITabBar,
           !bar.convert(bar.bounds, to: self).intersection(bounds).isEmpty { return bar }
        for child in view.subviews {
            if let bar = visibleTabBar(in: child) { return bar }
        }
        return nil
    }

    private func itemControls(in view: UIView) -> [UIControl] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        let children = view.subviews.flatMap { itemControls(in: $0) }
        if children.isEmpty, let control = view as? UIControl, !control.bounds.isEmpty {
            return [control]
        }
        return children
    }
}
