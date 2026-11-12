import SwiftUI

enum DuoHingeStatus: Equatable, Sendable {
    case closed, partiallyOpen, fullyOpen
}

enum DuoHingeState: Equatable, Sendable {
    case none, moving, settled(DuoHingeStatus)
}

/// An active division in the reading view's local coordinates.
struct DuoFold: Equatable, Sendable {
    var frame: CGRect
    var splitsSideBySide: Bool

    /// The fold as seen from a view `lift` points below where it was drawn.
    func removingContentLift(_ lift: CGFloat) -> DuoFold {
        DuoFold(frame: frame.offsetBy(dx: 0, dy: -lift), splitsSideBySide: splitsSideBySide)
    }

    /// A hinge lies within its own display, which the window covers. As the
    /// Duo closes or turns, a reader already at the new display's size can
    /// still be handed the inner display's 669 pt hinge: across the closing
    /// outer display's 466 pt it folded that display into a laptop for up
    /// to 0.9 s, and the terminal under it resized the remote twice. A
    /// division longer than the window, or reaching past it, is another
    /// display's. `readerOrigin` is the reader's global origin; a lifted
    /// reader passes nil, and only the division's size is checked.
    static func liesWithin(_ window: CGSize?, frame: CGRect, readerOrigin: CGPoint?) -> Bool {
        guard let window else { return true }
        guard frame.width <= window.width + 0.5, frame.height <= window.height + 0.5 else { return false }
        guard let readerOrigin else { return true }
        let global = frame.offsetBy(dx: readerOrigin.x, dy: readerOrigin.y)
        return global.minX >= -0.5 && global.minY >= -0.5
            && global.maxX <= window.width + 0.5 && global.maxY <= window.height + 0.5
    }
}

/// The caller schedules a wake-up; only this clock decides whether it settled.
struct DuoSettleGate {
    static let settleInterval: TimeInterval = 0.3

    private let now: () -> TimeInterval
    private var pendingStatus: DuoHingeStatus?
    private(set) var deadline: TimeInterval?
    private(set) var state: DuoHingeState = .none

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    var timeUntilSettlement: TimeInterval? {
        deadline.map { max(0, $0 - now()) }
    }

    mutating func hingeChanged(_ status: DuoHingeStatus?) -> DuoHingeState? {
        pendingStatus = status
        guard status != nil else {
            deadline = nil
            return transition(to: .none)
        }
        deadline = now() + Self.settleInterval
        return transition(to: .moving)
    }

    mutating func settle() -> DuoHingeState? {
        guard let deadline, now() >= deadline, let pendingStatus else { return nil }
        self.deadline = nil
        return transition(to: .settled(pendingStatus))
    }

    private mutating func transition(to next: DuoHingeState) -> DuoHingeState? {
        guard state != next else { return nil }
        state = next
        return next
    }
}

/// Deduplicates observations, including the initial nil, without losing a
/// division that arrives while the hinge is still moving.
struct DuoFoldSettlement {
    private(set) var fold: DuoFold?
    private var foldWidth: CGFloat?
    private var resizedWhileMoving = false
    private var didReport = false

    /// `width` is the reader's own. A fold held while the hinge moves
    /// belongs to the width it was measured at: closing the Duo, or turning
    /// it between book and laptop, changes that width mid-motion, and the
    /// old display's fold would divide the new one. The first reading at a
    /// new width can still carry the old display's division, so until the
    /// hinge settles a division appearing or going is followed; only its
    /// movement is held, as motion moves it every frame.
    mutating func update(current: DuoFold?, hinge: DuoHingeState, width: CGFloat? = nil) -> Bool {
        let previous = fold
        let resized = width.flatMap { width in foldWidth.map { abs(width - $0) > 0.5 } } ?? false
        if resized, hinge == .moving { resizedWhileMoving = true }
        if hinge != .moving { resizedWhileMoving = false }
        let presenceChanged = resizedWhileMoving && (current == nil) != (fold == nil)
        if hinge != .moving || resized || presenceChanged {
            fold = current
            foldWidth = width
        }
        defer { didReport = true }
        return !didReport || previous != fold
    }
}

extension View {
    func onDuoRailEdgeChange(_ action: @escaping (HorizontalEdge?) -> Void) -> some View {
        modifier(DuoRailEdgeModifier(action: action))
    }

    func onDuoHingeChange(_ action: @escaping (DuoHingeState) -> Void) -> some View {
        modifier(DuoHingeModifier(action: action))
    }

    /// `contentLift` is how far an offset has moved this view up from its
    /// laid-out place; the fold is reported as if it had not.
    func onDuoFoldChange(contentLift: CGFloat = 0, _ action: @escaping (DuoFold?) -> Void) -> some View {
        modifier(DuoFoldModifier(contentLift: contentLift, action: action))
    }

    /// A session or an agent's conversation is a task, so while one is on
    /// screen the rail keeps its actions and squeezes the tab group first.
    /// Otherwise the system's default keeps the tabs whole.
    func duoRailPrefersActions(_ prefersActions: Bool) -> some View {
        modifier(DuoRailCompressionModifier(prefersActions: prefersActions))
    }
}

private struct DuoRailCompressionModifier: ViewModifier {
    var prefersActions: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            content.toolbarVerticalCompressionBehavior(prefersActions ? .prefersToolbarItems : .automatic)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct DuoInitialValueModifier<Value>: ViewModifier {
    var value: Value
    var action: (Value) -> Void
    @State private var didReport = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !didReport else { return }
            didReport = true
            action(value)
        }
    }
}

private struct DuoRailEdgeModifier: ViewModifier {
    var action: (HorizontalEdge?) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            content.background { DuoRailEdgeReader(action: action) }
        } else {
            content.modifier(DuoInitialValueModifier(value: nil as HorizontalEdge?, action: action))
        }
        #else
        content.modifier(DuoInitialValueModifier(value: nil as HorizontalEdge?, action: action))
        #endif
    }
}

private struct DuoHingeModifier: ViewModifier {
    var action: (DuoHingeState) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            content.modifier(DuoHingeReader(action: action))
        } else {
            content.modifier(DuoInitialValueModifier(value: DuoHingeState.none, action: action))
        }
        #else
        content.modifier(DuoInitialValueModifier(value: DuoHingeState.none, action: action))
        #endif
    }
}

private struct DuoFoldModifier: ViewModifier {
    var contentLift: CGFloat
    var action: (DuoFold?) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if DuoSyntheticLaptopFold.isEnabled {
            content.modifier(DuoSyntheticLaptopFoldReader(contentLift: contentLift, action: action))
        } else {
            hingeFold(content)
        }
        #else
        hingeFold(content)
        #endif
    }

    @ViewBuilder private func hingeFold(_ content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            content.modifier(DuoFoldReader(contentLift: contentLift, action: action))
        } else {
            content.modifier(DuoInitialValueModifier(value: nil as DuoFold?, action: action))
        }
        #else
        content.modifier(DuoInitialValueModifier(value: nil as DuoFold?, action: action))
        #endif
    }
}

#if DEBUG
/// `TESSERA_DUO_LAPTOP_FOLD=1`, host-free: every fold reader sees a settled
/// laptop fold where the iPhone Duo's inner display has one (455.5–495.5 of
/// 951 pt), scaled to this window's height. Laptop layouts can then be shot on
/// any simulator, where no hinge can be posed.
enum DuoSyntheticLaptopFold {
    static let isEnabled = ProcessInfo.processInfo.environment["TESSERA_DUO_LAPTOP_FOLD"] == "1"

    static func frame(window: CGSize) -> CGRect {
        CGRect(x: 0, y: window.height * 455.5 / 951, width: window.width, height: 40)
    }

    @MainActor static var windowSize: CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.coordinateSpace.bounds.size
    }
}

private struct DuoSyntheticLaptopFoldReader: ViewModifier {
    var contentLift: CGFloat
    var action: (DuoFold?) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let fold = DuoSyntheticLaptopFold.windowSize.map {
                    DuoFold(frame: DuoSyntheticLaptopFold.frame(window: $0).offsetBy(dx: -origin.x, dy: -origin.y),
                            splitsSideBySide: false)
                        .removingContentLift(contentLift)
                }
                Color.clear.onChange(of: fold, initial: true) { _, next in
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { action(next) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif

#if compiler(>=6.4)
@available(iOS 27.1, *)
private struct DuoRailEdgeReader: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    var action: (HorizontalEdge?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: edge, initial: true) { _, edge in action(edge) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@available(iOS 27.1, *)
private struct DuoHingeReader: ViewModifier {
    var action: (DuoHingeState) -> Void
    @State private var gate = DuoSettleGate()
    @State private var settleTask: Task<Void, Never>?
    @State private var didReport = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !didReport {
                    didReport = true
                    action(gate.state)
                }
                scheduleSettlement()
            }
            .onHingeChange { _, context in
                settleTask?.cancel()
                let status = context.hinge.map { hinge -> DuoHingeStatus in
                    switch hinge.status {
                    case .closed: return .closed
                    case .fullyOpen: return .fullyOpen
                    default: return .partiallyOpen
                    }
                }
                if let change = gate.hingeChanged(status) {
                    didReport = true
                    action(change)
                }
                scheduleSettlement()
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
    }

    private func scheduleSettlement() {
        settleTask?.cancel()
        settleTask = nil
        guard let interval = gate.timeUntilSettlement else { return }
        settleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if let change = gate.settle() {
                action(change)
            } else {
                scheduleSettlement()
            }
        }
    }
}

@available(iOS 27.1, *)
private struct DuoFoldReader: ViewModifier {
    var contentLift: CGFloat
    var action: (DuoFold?) -> Void
    @State private var currentFold: DuoFold?
    @State private var currentWidth: CGFloat?
    @State private var hinge: DuoHingeState = .none
    @State private var settlement = DuoFoldSettlement()

    private struct Reading: Equatable {
        let fold: DuoFold?
        let width: CGFloat
        /// Another display's division, left out of `fold`.
        var stale: CGRect?
    }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    let region = proxy.reservedRegions(kind: .division).first { $0.isActive }
                    let fits = region.map {
                        DuoFold.liesWithin(Self.windowSize, frame: $0.frame,
                                           readerOrigin: contentLift == 0 ? proxy.frame(in: .global).origin : nil)
                    } ?? true
                    // Read with the region in one layout pass, so a lift
                    // and the move it causes cancel instead of reporting twice.
                    let fold = fits ? region.map {
                        DuoFold(frame: $0.frame, splitsSideBySide: $0.frame.height > $0.frame.width)
                            .removingContentLift(contentLift)
                    } : nil
                    let reading = Reading(fold: fold, width: proxy.size.width, stale: fits ? nil : region?.frame)
                    Color.clear.onChange(of: reading, initial: true) { previous, next in
                        if let stale = next.stale, previous.stale == nil || previous == next {
                            noteStaleDivision(stale, width: next.width)
                        }
                        currentFold = next.fold
                        currentWidth = next.width
                        report()
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onDuoHingeChange { state in
                hinge = state
                report()
            }
            .onAppear { report() }
    }

    private func report() {
        guard settlement.update(current: currentFold, hinge: hinge, width: currentWidth) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { action(settlement.fold) }
    }

    @MainActor private static var windowSize: CGSize? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.bounds.size
    }

    private func noteStaleDivision(_ frame: CGRect, width: CGFloat) {
        guard DiagnosticLogStore.isVerboseEnabled else { return }
        let window = Self.windowSize.map { "\($0.width)x\($0.height)" } ?? "none"
        DiagnosticLogStore.append(.app, "duo-fold stale-division frame=\(frame) readerWidth=\(width) window=\(window) hinge=\(hinge)")
    }
}
#endif
