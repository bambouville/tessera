import SwiftUI
import UIKit

extension View {
    /// Also takes this control's taps through a clear UIKit control.
    ///
    /// iOS 27 gives a window that holds a scroll-to-top scroll view a top tap
    /// region (`-[UIWindow _addWindowTopTapRegion]`): a touch that starts
    /// within 16 pt of the window's top edge fails every other gesture,
    /// SwiftUI buttons included, unless it lands on a UIControl. A bar laid
    /// out flush with that edge, as Duo's pane headers are once the status bar
    /// hides, would otherwise lose the upper half of its taps. VoiceOver and
    /// keyboard activation still reach the SwiftUI control underneath.
    func windowTopTapTarget(isActive: Bool = true, _ action: @escaping () -> Void) -> some View {
        modifier(WindowTopTapTarget(isActive: isActive, action: action))
    }
}

private struct WindowTopTapTarget: ViewModifier {
    let isActive: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.overlay {
            if isActive && isEnabled {
                WindowTopTapSurface(action: action)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct WindowTopTapSurface: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIControl {
        let control = UIControl()
        control.backgroundColor = .clear
        control.isAccessibilityElement = false
        // A recognizer rather than the control's own tracking: SwiftUI's
        // recognizers on the hosting view cancel a control's touch-up, while
        // one on the control is exempt from the region just the same.
        control.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped)
        ))
        return control
    }

    func updateUIView(_ control: UIControl, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func tapped() {
            action()
        }
    }
}
