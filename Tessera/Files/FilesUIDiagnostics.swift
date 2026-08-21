// Tessera/Files/FilesUIDiagnostics.swift
// Remote Files feature - scroll/render instrumentation for on-device reports.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// Launch-time switches, read outside the main actor so `Equatable`
/// conformances and other nonisolated code can consult them.
enum FilesDiagnosticsEnvironment {
    #if DEBUG
    /// Forces the instrumentation on and routes it to `NSLog` instead of the
    /// diagnostics file, for `scripts/uitest/run-files-context-menu.sh`.
    static let forced = ProcessInfo.processInfo.environment["TESSERA_FILES_MENU_DIAG"] == "1"
    /// Test seam — see `FileRowView.==`.
    static let rowEquatableDisabled =
        ProcessInfo.processInfo.environment["TESSERA_FILES_ROW_EQUATABLE"] == "0"
    /// Test seam — pins the context-menu backstop off, to separate what the
    /// backstop repaints from what UIKit's own menu presentation repaints.
    static let backstopDisabled =
        ProcessInfo.processInfo.environment["TESSERA_FILES_BACKSTOP"] == "0"
    /// Test seam — drops the custom lifted preview, isolating what UIKit
    /// repaints when it has to host and size a SwiftUI preview.
    static let menuPreviewDisabled =
        ProcessInfo.processInfo.environment["TESSERA_FILES_MENU_PREVIEW"] == "0"
    /// Test seam — drops `.onDrag`, isolating what the row's drag
    /// interaction does while the context menu owns the same touch.
    static let rowDragDisabled =
        ProcessInfo.processInfo.environment["TESSERA_FILES_ROW_DRAG"] == "0"
    /// Test seam — puts the row back on SwiftUI's `.contextMenu`, so the
    /// rig can record the UIKit and SwiftUI presentations from one binary.
    static let uikitMenuDisabled =
        ProcessInfo.processInfo.environment["TESSERA_FILES_UIKIT_MENU"] == "0"
    #else
    static let forced = false
    static let rowEquatableDisabled = false
    static let backstopDisabled = false
    static let menuPreviewDisabled = false
    static let rowDragDisabled = false
    static let uikitMenuDisabled = false
    #endif
}

/// Frame pacing and render-churn instrumentation for the Files surfaces.
///
/// "Scrolling is laggy" is two very different bugs — the main thread is too
/// busy to feed the scroll view, or the compositor cannot land the frames —
/// and a user-supplied log has to tell them apart. Every scroll session
/// therefore reports both the frame timeline (gaps, and how late each
/// `CADisplayLink` callback ran, which only grows when the main thread is
/// congested) and the SwiftUI work that ran inside it (panel passes, row
/// builds, context-menu builds, Quick Look updates). A hitch line pins the
/// worst individual frames to the work that happened during them.
///
/// Gated on the existing Settings → Diagnostics "scroll diagnostics" toggle,
/// so nothing is sampled and no display link runs unless the user asked for
/// it. Counters read a cached flag refreshed once per panel body pass, never
/// per row.
@MainActor
final class FilesUIDiagnostics {
    static let shared = FilesUIDiagnostics()

    enum Surface: String {
        /// The Files panel's outline list.
        case filesTree = "files-tree"
        /// The in-app Markdown renderer used for `.md` previews.
        case markdownPreview = "md-preview"
        /// `QLPreviewController` inside the preview sheet.
        case quickLook = "quick-look"
    }

    // MARK: - Gate

    private(set) var isEnabled = FilesDiagnosticsEnvironment.forced
    private var nextGateCheckAt: CFTimeInterval = 0
    private static let gateCheckInterval: CFTimeInterval = 2

    /// Re-reads the toggle at most every couple of seconds. Called from the
    /// panel body pass and at scroll start — never from a per-row path.
    private func refreshGate(now: CFTimeInterval) {
        guard now >= nextGateCheckAt else { return }
        nextGateCheckAt = now + Self.gateCheckInterval
        isEnabled = FilesDiagnosticsEnvironment.forced
            || DiagnosticLogStore.isScrollDiagnosticsEnabled
    }

    // MARK: - Counters

    private struct Counters {
        var bodyPasses = 0
        var rowBuilds = 0
        var menuBuilds = 0
        var previewBuilds = 0
        var rowsCalls = 0
        var rowsNanos: UInt64 = 0
        var blockBuilds = 0
        var quickLookUpdates = 0

        static func - (a: Counters, b: Counters) -> Counters {
            Counters(
                bodyPasses: a.bodyPasses - b.bodyPasses,
                rowBuilds: a.rowBuilds - b.rowBuilds,
                menuBuilds: a.menuBuilds - b.menuBuilds,
                previewBuilds: a.previewBuilds - b.previewBuilds,
                rowsCalls: a.rowsCalls - b.rowsCalls,
                rowsNanos: a.rowsNanos &- b.rowsNanos,
                blockBuilds: a.blockBuilds - b.blockBuilds,
                quickLookUpdates: a.quickLookUpdates - b.quickLookUpdates
            )
        }

        var line: String {
            "bodyPasses=\(bodyPasses) rowBuilds=\(rowBuilds) menuBuilds=\(menuBuilds)"
                + " previewBuilds=\(previewBuilds) rowsCalls=\(rowsCalls)"
                + " rowsMs=\(FilesUIDiagnostics.format(Double(rowsNanos) / 1e6))"
                + " blockBuilds=\(blockBuilds) qlUpdates=\(quickLookUpdates)"
        }
    }

    private var counters = Counters()
    private var treeRowCount = 0
    private var treeFiltering = false
    private var markdownBlockCount = 0

    /// One panel body evaluation. Also the gate's refresh tick.
    func panelBodyPass() {
        refreshGate(now: CACurrentMediaTime())
        guard isEnabled else { return }
        counters.bodyPasses += 1
    }

    /// One row body evaluation — the row's context menu and lifted preview
    /// are built with it, which is why they are counted separately below.
    func rowBuild() {
        guard isEnabled else { return }
        counters.rowBuilds += 1
        if menuPresentationCount > 0 { rowBuildsSinceMenu += 1 }
    }

    func menuBuild() {
        guard isEnabled else { return }
        counters.menuBuilds += 1
    }

    func menuPreviewBuild() {
        guard isEnabled else { return }
        counters.previewBuilds += 1
    }

    /// Markdown block shapes, kept here rather than reused from the
    /// presenter so the frame sampler does not depend on the document model.
    /// The names are the keys of the `md-cost` line.
    enum MarkdownBlockKind: Int, CaseIterable {
        case paragraph, heading, code, table, rule

        var key: String {
            switch self {
            case .paragraph: return "para"
            case .heading: return "head"
            case .code: return "code"
            case .table: return "table"
            case .rule: return "rule"
            }
        }
    }

    /// Monotonic per-kind realization counts. The frame sampler diffs these
    /// to learn which block shapes a slow frame was building.
    private var blockKindTotals = [Int](repeating: 0, count: MarkdownBlockKind.allCases.count)

    func markdownBlockBuild(kind: MarkdownBlockKind) {
        guard isEnabled else { return }
        counters.blockBuilds += 1
        blockKindTotals[kind.rawValue] += 1
    }

    /// Time spent constructing one block's view value, as opposed to laying
    /// it out and rendering it. The difference between this and the block's
    /// share of the turn says whether the cost is ours or SwiftUI's.
    private var blockBodyNanos: UInt64 = 0

    func measureBlockBody<V>(kind: MarkdownBlockKind, _ make: () -> V) -> V {
        guard isEnabled else { return make() }
        counters.blockBuilds += 1
        blockKindTotals[kind.rawValue] += 1
        let started = DispatchTime.now().uptimeNanoseconds
        let value = make()
        blockBodyNanos &+= DispatchTime.now().uptimeNanoseconds &- started
        return value
    }

    /// `updateUIViewController` on the Quick Look host. It runs on every
    /// SwiftUI update of everything around the sheet, so a high count during
    /// a preview scroll means the session behind it is still redrawing.
    func quickLookUpdate() {
        guard isEnabled else { return }
        counters.quickLookUpdates += 1
    }

    /// Times the flattened-rows computation, which walks the expanded tree
    /// and allocates on every read.
    func measureRows<Value>(_ body: () -> Value) -> Value {
        guard isEnabled else { return body() }
        let started = DispatchTime.now().uptimeNanoseconds
        let value = body()
        counters.rowsNanos &+= DispatchTime.now().uptimeNanoseconds &- started
        counters.rowsCalls += 1
        return value
    }

    func noteTree(rowCount: Int, filtering: Bool) {
        guard isEnabled else { return }
        treeRowCount = rowCount
        treeFiltering = filtering
    }

    func noteMarkdown(blockCount: Int) {
        guard isEnabled else { return }
        markdownBlockCount = blockCount
    }

    // MARK: - Context-menu churn oracle

    /// Rows rebuilt since the current context menu was presented. Must stay
    /// at zero: rebuilding a row re-publishes the live `UIMenu`, which makes
    /// UIKit crossfade the platter and cancel touch tracking on the item
    /// under the finger.
    private(set) var rowBuildsSinceMenu = 0
    private var menuPresentationCount = 0
    private var menuPresentedAt: CFTimeInterval?
    private var forcedReporter: Task<Void, Never>?

    func menuPresenceDidChange(count: Int) {
        refreshGate(now: CACurrentMediaTime())
        guard isEnabled else { return }
        let now = CACurrentMediaTime()

        if count > 0, menuPresentationCount == 0 {
            rowBuildsSinceMenu = 0
            menuPresentedAt = now
            // The press became a menu interaction, so the open scroll
            // session is over — its `onEnded` will never arrive.
            scrollEnded(.filesTree)
        }
        let wasPresented = menuPresentationCount > 0
        menuPresentationCount = count

        if FilesDiagnosticsEnvironment.forced {
            NSLog(
                "[Tessera][FilesChurnDiag] menu-presence count=%d rowBuildsSinceMenu=%d",
                count, rowBuildsSinceMenu
            )
            startForcedReporterIfNeeded()
        }

        guard count == 0, wasPresented else { return }
        let heldMs = (now - (menuPresentedAt ?? now)) * 1_000
        menuPresentedAt = nil
        if !FilesDiagnosticsEnvironment.forced {
            DiagnosticLogStore.appendScroll(
                "files-menu-churn heldMs=\(Self.format(heldMs))"
                    + " rowRebuilds=\(rowBuildsSinceMenu) rowCount=\(treeRowCount)"
            )
        }
    }

    /// Wall-clock reporter for the UI-test arm only: "zero rebuilds while a
    /// menu was up" cannot be printed by a pass-driven flush.
    private func startForcedReporterIfNeeded() {
        guard forcedReporter == nil else { return }
        var window = counters
        var windowStart = CACurrentMediaTime()
        forcedReporter = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let now = CACurrentMediaTime()
                let delta = self.counters - window
                NSLog(
                    "[Tessera][FilesChurnDiag] window=%.2fs passes=%d rowBuilds=%d rowsCalls=%d rowsMs=%.1f menuPresented=%d sinceMenu=%d",
                    now - windowStart, delta.bodyPasses, delta.rowBuilds, delta.rowsCalls,
                    Double(delta.rowsNanos) / 1e6, self.menuPresentationCount,
                    self.rowBuildsSinceMenu
                )
                window = self.counters
                windowStart = now
            }
        }
    }

    // MARK: - Interaction timeline

    /// Wall-clock origin for `timeline` entries: the touch that opened the
    /// current interaction. A single flicker is a state change landing at an
    /// unexpected moment, so the log has to carry *when* each one happened
    /// relative to the press, not just that it happened.
    private var timelineOrigin: CFTimeInterval?

    /// Records one interaction transition — touch, menu presentation, or a
    /// backstop swap. Cheap and bounded: a press produces a handful.
    func timeline(_ event: String, detail: String = "") {
        refreshGate(now: CACurrentMediaTime())
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        if event == "touch-down" || timelineOrigin == nil { timelineOrigin = now }
        let sincePress = (now - (timelineOrigin ?? now)) * 1_000
        emit(
            "files-ui-event name=\(event) tMs=\(Self.format(sincePress))"
                + " menuUp=\(menuPresentationCount) rowRebuilds=\(rowBuildsSinceMenu)"
                + (detail.isEmpty ? "" : " " + detail)
        )
    }

    // MARK: - Scroll sessions

    private struct ScrollSession {
        let surface: Surface
        let startedAt: CFTimeInterval
        let baseline: Counters
        var frames = 0
        var gaps: [Double] = []
        var skipped = 0
        var worstGapMs: Double = 0
        var lateMaxMs: Double = 0
        var lateTotalMs: Double = 0
        var hitchesLogged = 0
        var lastFrameAt: CFTimeInterval?
        var lastCounters: Counters
        /// Per-kind block realizations and the main-thread time the run-loop
        /// turns that realized them spent busy. Frame gaps only resolve work
        /// that overruns the display budget — on fast hardware a 5 ms block
        /// is invisible to them — so the cost is measured as CPU time.
        var kindBuilds: [Int]
        var kindBusyMs: [Double]
        var lastKindTotals: [Int]
        /// Busy time of turns that realized nothing: the per-turn baseline to
        /// subtract before reading a per-kind number as a marginal cost.
        var idleTurnBusyMs: Double = 0
        var idleTurns = 0
        var buildTurns = 0
        /// Only about one run-loop turn in three commits a frame, and a turn
        /// that realizes a block always does — so the baseline to subtract is
        /// a *committing* turn that realized nothing, not any quiet turn.
        var quietFrameTurns = 0
        var quietFrameBusyMs: Double = 0
        var baselineBodyNanos: UInt64
        /// Set when the finger lifts; sampling continues through the glide.
        var tailEndsAt: CFTimeInterval?
    }

    private var session: ScrollSession?
    private var displayLink: CADisplayLink?

    /// A frame this much slower than expected is a visible hitch and gets its
    /// own attributed line.
    private static let hitchFactor: Double = 3.5
    private static let maxHitchLinesPerSession = 8
    /// Sampling continues this long past touch-up to cover the glide.
    private static let glideTailSeconds: CFTimeInterval = 0.9
    /// Sessions shorter than this never produced a scroll worth reporting.
    private static let minimumReportedFrames = 8
    /// A gesture whose end is swallowed (a drag-out, a menu claiming the
    /// touch) must still flush rather than sample forever.
    private static let maximumSessionSeconds: CFTimeInterval = 12

    /// The surface a presented preview is showing, if any.
    ///
    /// The Files panel's probe falls back to the window's shared root when it
    /// cannot find its own scroll view, so it catches touches anywhere in the
    /// app — including inside a full-screen preview presented over it. That
    /// mislabelled Markdown scrolling as `files-tree` on device. While a
    /// preview covers the app, a scroll belongs to the preview.
    private var presentedPreviewSurface: Surface?

    func previewPresentationChanged(surface: Surface?) {
        if presentedPreviewSurface != nil, surface == nil,
           let session, session.surface != .filesTree {
            finishSession(at: CACurrentMediaTime())
        }
        presentedPreviewSurface = surface
    }

    private func resolved(_ surface: Surface) -> Surface {
        guard surface == .filesTree, let presentedPreviewSurface else { return surface }
        return presentedPreviewSurface
    }

    func scrollBegan(_ requested: Surface) {
        let surface = resolved(requested)
        let now = CACurrentMediaTime()
        refreshGate(now: now)
        guard isEnabled else { return }

        if var existing = session, existing.surface == surface {
            // Finger came back down mid-glide: keep the same session.
            existing.tailEndsAt = nil
            session = existing
            return
        }
        if session != nil { finishSession(at: now) }

        session = ScrollSession(
            surface: surface,
            startedAt: now,
            baseline: counters,
            lastCounters: counters,
            kindBuilds: [Int](repeating: 0, count: MarkdownBlockKind.allCases.count),
            kindBusyMs: [Double](repeating: 0, count: MarkdownBlockKind.allCases.count),
            lastKindTotals: blockKindTotals,
            baselineBodyNanos: blockBodyNanos
        )
        startDisplayLink()
        startTurnObserver()
    }

    func scrollEnded(_ requested: Surface) {
        let surface = resolved(requested)
        guard var current = session, current.surface == surface else { return }
        current.tailEndsAt = CACurrentMediaTime() + Self.glideTailSeconds
        session = current
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        // Tracking mode matters: the default run-loop mode stops delivering
        // while a scroll gesture is being tracked, which is exactly the
        // window being measured.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Main-thread cost per run-loop turn

    /// Fires after Core Animation's commit observer (order 2_000_000), so a
    /// turn's measured span covers SwiftUI body evaluation, layout, and the
    /// render commit — everything a newly realized block costs.
    private static let turnObserverOrder: CFIndex = 2_100_000

    private var turnObserver: CFRunLoopObserver?
    private var turnStartedAt: CFTimeInterval?
    private var turnKindTotals: [Int] = []
    private var turnStartFrames = 0

    private func startTurnObserver() {
        guard turnObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            Self.turnObserverOrder
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                self?.runLoopTurn(activity)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        turnObserver = observer
    }

    private func stopTurnObserver() {
        if let turnObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), turnObserver, .commonModes)
        }
        turnObserver = nil
        turnStartedAt = nil
    }

    private func runLoopTurn(_ activity: CFRunLoopActivity) {
        guard session != nil else { return }
        if activity.contains(.afterWaiting) {
            turnStartedAt = CACurrentMediaTime()
            turnKindTotals = blockKindTotals
            turnStartFrames = session?.frames ?? 0
            return
        }
        guard let started = turnStartedAt, var current = session else { return }
        turnStartedAt = nil
        let busyMs = (CACurrentMediaTime() - started) * 1_000

        var built = 0
        for index in turnKindTotals.indices {
            built += blockKindTotals[index] - turnKindTotals[index]
        }
        if built > 0 {
            current.buildTurns += 1
            for index in turnKindTotals.indices {
                let delta = blockKindTotals[index] - turnKindTotals[index]
                guard delta > 0 else { continue }
                current.kindBusyMs[index] += busyMs * Double(delta) / Double(built)
            }
        } else {
            current.idleTurns += 1
            current.idleTurnBusyMs += busyMs
            if current.frames > turnStartFrames {
                current.quietFrameTurns += 1
                current.quietFrameBusyMs += busyMs
            }
        }
        session = current
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard var current = session else {
            stopDisplayLink()
            return
        }
        let now = CACurrentMediaTime()
        let expected = max(0.001, link.targetTimestamp - link.timestamp)
        let lateMs = max(0, now - link.timestamp) * 1_000

        current.frames += 1
        current.lateMaxMs = max(current.lateMaxMs, lateMs)
        current.lateTotalMs += lateMs

        for index in current.lastKindTotals.indices {
            current.kindBuilds[index] += blockKindTotals[index] - current.lastKindTotals[index]
        }

        if let last = current.lastFrameAt {
            let gap = link.timestamp - last
            let gapMs = gap * 1_000
            if current.gaps.count < 4_096 { current.gaps.append(gapMs) }
            current.worstGapMs = max(current.worstGapMs, gapMs)
            current.skipped += max(0, Int((gap / expected).rounded()) - 1)

            if gap > expected * Self.hitchFactor,
               current.hitchesLogged < Self.maxHitchLinesPerSession {
                current.hitchesLogged += 1
                let delta = counters - current.lastCounters
                emit(
                    "ui-scroll-hitch surface=\(current.surface.rawValue)"
                        + " gapMs=\(Self.format(gapMs)) expectedMs=\(Self.format(expected * 1_000))"
                        + " lateMs=\(Self.format(lateMs)) \(delta.line)"
                )
            }
        }
        current.lastFrameAt = link.timestamp
        current.lastCounters = counters
        current.lastKindTotals = blockKindTotals

        let expired = now - current.startedAt >= Self.maximumSessionSeconds
        if expired || (current.tailEndsAt.map { now >= $0 } ?? false) {
            session = current
            finishSession(at: now)
            return
        }
        session = current
    }

    private func finishSession(at now: CFTimeInterval) {
        guard let current = session else { return }
        session = nil
        stopDisplayLink()
        stopTurnObserver()

        guard current.frames >= Self.minimumReportedFrames else { return }
        let elapsed = now - current.startedAt
        let delta = counters - current.baseline
        let sorted = current.gaps.sorted()
        let p95 = sorted.isEmpty
            ? 0
            : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let fps = elapsed > 0 ? Double(current.frames) / elapsed : 0
        let lateAvg = current.frames > 0 ? current.lateTotalMs / Double(current.frames) : 0
        // What one committed frame costs the main thread when it is only
        // scrolling — no new content realized. This is the number that says
        // whether a surface is expensive to *move*, as opposed to expensive
        // to fill.
        let quietFramePerTurn = current.quietFrameTurns > 0
            ? current.quietFrameBusyMs / Double(current.quietFrameTurns)
            : 0
        let idlePerTurn = current.idleTurns > 0
            ? current.idleTurnBusyMs / Double(current.idleTurns)
            : 0

        emit(
            "ui-scroll surface=\(current.surface.rawValue) ms=\(Int(elapsed * 1_000))"
                + " frames=\(current.frames) fps=\(Self.format(fps))"
                + " skipped=\(current.skipped) worstGapMs=\(Self.format(current.worstGapMs))"
                + " p95GapMs=\(Self.format(p95))"
                + " lateMaxMs=\(Self.format(current.lateMaxMs))"
                + " lateAvgMs=\(Self.format(lateAvg))"
                + " \(delta.line)"
                + " frameTurnMs=\(Self.format(quietFramePerTurn))"
                + " turnMs=\(Self.format(idlePerTurn))"
                + " rowCount=\(treeRowCount) filtering=\(treeFiltering ? 1 : 0)"
                + " blockCount=\(markdownBlockCount)"
        )

        if current.kindBuilds.contains(where: { $0 > 0 }) {
            // `eachMs` is the whole turn, so subtract `idleTurnMs` — what a
            // turn costs when it realizes nothing — to read a block's own
            // marginal cost.
            let parts = MarkdownBlockKind.allCases.map { kind -> String in
                let builds = current.kindBuilds[kind.rawValue]
                let ms = current.kindBusyMs[kind.rawValue]
                let each = builds > 0 ? ms / Double(builds) : 0
                return "\(kind.key)=\(builds)/\(Self.format(ms))/\(Self.format(each))"
            }
            let bodyMs = Double(blockBodyNanos &- current.baselineBodyNanos) / 1e6
            var line = "md-cost surface=\(current.surface.rawValue) n/busyMs/eachMs "
            line += parts.joined(separator: " ")
            line += " idleTurnMs=\(Self.format(idlePerTurn))"
            line += " frameTurnMs=\(Self.format(quietFramePerTurn))"
            line += " frameTurns=\(current.quietFrameTurns)"
            line += " turns=\(current.idleTurns)/\(current.buildTurns)"
            line += " bodyMs=\(Self.format(bodyMs))"
            emit(line)
        }
    }

    private func emit(_ line: String) {
        if FilesDiagnosticsEnvironment.forced {
            NSLog("[Tessera][FilesChurnDiag] %@", line)
        } else {
            DiagnosticLogStore.appendScroll(line)
        }
    }

    nonisolated static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: - Probes

    /// Installs a non-interfering pan observer on `view`, so any scroll in
    /// its subtree opens and closes a session. Used for the two surfaces
    /// whose scroll views belong to UIKit (`QLPreviewController`) or to
    /// SwiftUI internals (the Markdown renderer).
    func attachProbe(to view: UIView, surface: Surface) {
        guard isEnabled || DiagnosticLogStore.isScrollDiagnosticsEnabled else { return }
        guard view.gestureRecognizers?.contains(where: { $0 is ScrollProbeRecognizer }) != true
        else { return }
        let recognizer = ScrollProbeRecognizer(surface: surface)
        view.addGestureRecognizer(recognizer)
    }
}

/// A pan recognizer that never claims the gesture — it only reports when a
/// drag starts and ends. `cancelsTouchesInView` stays false and the delegate
/// allows every other recognizer to run, so the observed scroll view behaves
/// exactly as it does without the probe.
private final class ScrollProbeRecognizer: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    private let surface: FilesUIDiagnostics.Surface

    init(surface: FilesUIDiagnostics.Surface) {
        self.surface = surface
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handle))
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    @objc private func handle() {
        switch state {
        case .began, .changed:
            FilesUIDiagnostics.shared.scrollBegan(surface)
        case .ended, .cancelled, .failed:
            FilesUIDiagnostics.shared.scrollEnded(surface)
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

/// Drop into a SwiftUI hierarchy to attach the probe to the enclosing view
/// controller's root view. Renders nothing and installs nothing while the
/// scroll-diagnostics toggle is off.
struct FilesScrollProbe: UIViewRepresentable {
    let surface: FilesUIDiagnostics.Surface

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(surface: surface)
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private let surface: FilesUIDiagnostics.Surface
        private var attached = false

        init(surface: FilesUIDiagnostics.Surface) {
            self.surface = surface
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !attached else { return }
            attached = true
            // The hierarchy is still settling on the first pass, and
            // QuickLook's own content arrives later still.
            attach()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.attach()
            }
        }

        private func attach() {
            guard let host = hostRootView() else { return }
            FilesUIDiagnostics.shared.attachProbe(to: host, surface: surface)
        }

        /// Prefers the nearest enclosing scroll view; falls back to the
        /// owning controller's root, which still sees every touch in the
        /// subtree because recognizers fire along the hit-test chain.
        private func hostRootView() -> UIView? {
            var node: UIView? = superview
            while let current = node {
                if let scrollView = current as? UIScrollView { return scrollView }
                node = current.superview
            }
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.viewIfLoaded
                }
                responder = current.next
            }
            return nil
        }
    }
}
