import SwiftUI
import UIKit
import UniformTypeIdentifiers

// System pickers and share services, presented by UIKit from the window that
// hosts the calling view rather than wrapped in a SwiftUI sheet or ShareLink.
//
// Running as an iPad app on a Mac, both wrappers failed. A document picker
// hosted in a sheet dismissed that sheet before calling its delegate, so the
// chosen file never arrived. "Save to Files" blocked the main thread loading
// ShareLink's item provider, timed out after 10 s, and AppKit's save panel
// threw on the missing file name (`-[NSSavePanel setNameFieldStringValue:]`).
//
// Like `.sheet(item:)`, each presentation belongs to one request: it clears
// that request when it ends, and clearing or replacing the request while it
// is up takes it down and drops whatever it reports afterwards. `fileID` and
// `line` tell call sites apart when SwiftUI rebuilds one; leave them defaulted.
extension View {
    /// Picks files; `onPick` receives no URLs when cancelled. With `asCopy`
    /// the URLs are local copies, otherwise security-scoped originals.
    func systemDocumentPicker(
        isPresented: Binding<Bool>,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        asCopy: Bool = true,
        fileID: String = #fileID,
        line: UInt = #line,
        onPick: @escaping ([URL]) -> Void
    ) -> some View {
        systemDocumentPicker(
            item: isPresented.presence,
            contentTypes: contentTypes,
            allowsMultipleSelection: allowsMultipleSelection,
            asCopy: asCopy,
            fileID: fileID,
            line: line
        ) { _, urls in
            onPick(urls)
        }
    }

    /// Picks files for `item` and reports them with the item they were for.
    func systemDocumentPicker<Item: Identifiable>(
        item: Binding<Item?>,
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        asCopy: Bool = true,
        fileID: String = #fileID,
        line: UInt = #line,
        onPick: @escaping (Item, [URL]) -> Void
    ) -> some View {
        background(SystemPresentationAnchor(item: item, caller: "\(fileID):\(line)") { item, presentation in
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: contentTypes,
                asCopy: asCopy
            )
            picker.allowsMultipleSelection = allowsMultipleSelection
            // The result lands before the request clears, so a binding that
            // treats clearing as a cancel sees it handled.
            let delegate = SystemDocumentPickerDelegate { urls in
                guard !presentation.hasEnded else { return }
                guard presentation.isCurrent else {
                    // The request moved on before the anchor caught up.
                    presentation.withdraw()
                    return
                }
                onPick(item, urls)
                presentation.end()
            }
            picker.delegate = delegate
            return (picker, delegate)
        })
    }

    /// Shares file URLs or text from a popover anchored to this view.
    func systemShareSheet(
        isPresented: Binding<Bool>,
        fileID: String = #fileID,
        line: UInt = #line,
        items: @escaping () -> [Any]
    ) -> some View {
        systemShareSheet(item: isPresented.presence, fileID: fileID, line: line) { _ in items() }
    }

    /// Shares what `item` holds; a newer item replaces the sheet showing.
    func systemShareSheet<Item: Identifiable>(
        item: Binding<Item?>,
        fileID: String = #fileID,
        line: UInt = #line,
        items: @escaping (Item) -> [Any]
    ) -> some View {
        background(SystemPresentationAnchor(
            item: item,
            caller: "\(fileID):\(line)",
            readyAt: { ShareSession.readyAt }
        ) { item, presentation in
            let controller = UIActivityViewController(
                activityItems: items(item),
                applicationActivities: nil
            )
            presentation.minimumShownTime = ShareSession.minimumShownTime
            controller.completionWithItemsHandler = { _, _, _, _ in
                ShareSession.didClose()
                presentation.end()
            }
            return (controller, nil)
        })
    }
}

/// The one request a Boolean stands for.
private struct Presence: Identifiable {
    var id: Int { 0 }
}

private extension Binding where Value == Bool {
    var presence: Binding<Presence?> {
        let base = self
        return Binding<Presence?>(
            get: { base.wrappedValue ? Presence() : nil },
            set: { base.wrappedValue = $0 != nil }
        )
    }
}

/// The Mac cancels a share sheet opened while the last one's share session
/// is still closing, which it finishes up to a second after the sheet left;
/// a session closed before it finished opening cancels the next sheet even
/// later. A sheet closed by any means reports there, as it does not on iPad.
private enum ShareSession {
    private static var closedAt: Date?

    static var minimumShownTime: TimeInterval {
        ProcessInfo.processInfo.isiOSAppOnMac ? 1 : 0
    }

    static func didClose() {
        closedAt = Date()
    }

    static var readyAt: Date? {
        guard ProcessInfo.processInfo.isiOSAppOnMac, let closedAt else { return nil }
        return closedAt.addingTimeInterval(1.5)
    }
}

private final class SystemDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private var onFinish: (([URL]) -> Void)?

    init(onFinish: @escaping ([URL]) -> Void) {
        self.onFinish = onFinish
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish([])
    }

    private func finish(_ urls: [URL]) {
        let onFinish = onFinish
        self.onFinish = nil
        onFinish?(urls)
    }
}

/// Ties a delegate's lifetime to the controller that holds it weakly, so a
/// picker still reports back if the view that opened it is rebuilt meanwhile.
private var retainedDelegateKey: UInt8 = 0

private var presentationKey: UInt8 = 0

/// The anchor a presentation answers to. SwiftUI can replace it while the
/// controller is up; the replacement then takes the presentation over.
private class SystemPresentationOwner {
    var isDismantled = false
}

/// One controller for one request from one call site. It ends once: by
/// reporting, or by never arriving, which releases the request if the binding
/// still holds it; or by being withdrawn when its request goes away, which
/// takes it down without a report.
private final class SystemPresentation {
    private static let all = NSHashTable<SystemPresentation>.weakObjects()

    let caller: String
    let requestID: AnyHashable
    weak var owner: SystemPresentationOwner?
    private(set) weak var controller: UIViewController?
    private weak var window: UIWindow?
    private let currentRequest: () -> AnyHashable?
    private let clearRequest: () -> Void
    private var waiters: [() -> Void] = []
    private(set) var hasArrived = false
    private(set) var hasEnded = false
    /// How long it stays up before it may be taken down.
    var minimumShownTime: TimeInterval = 0
    private var arrivedAt: Date?

    init(
        caller: String,
        requestID: AnyHashable,
        owner: SystemPresentationOwner,
        window: UIWindow,
        currentRequest: @escaping () -> AnyHashable?,
        clearRequest: @escaping () -> Void
    ) {
        self.caller = caller
        self.requestID = requestID
        self.owner = owner
        self.window = window
        self.currentRequest = currentRequest
        self.clearRequest = clearRequest
    }

    /// Whoever asked still wants this request shown.
    var isCurrent: Bool { currentRequest() == requestID }

    /// Not ended, and its controller can still report: one gone without
    /// reporting (its presenter left first) never will.
    var isLive: Bool { !hasEnded && controller != nil }

    func attach(to controller: UIViewController) {
        self.controller = controller
        objc_setAssociatedObject(controller, &presentationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        Self.all.add(self)
    }

    /// This call site's live presentation of the request, whose anchor
    /// SwiftUI has replaced. It may already have left the window's chain:
    /// the Mac's picker leaves before it reports.
    static func orphan(caller: String, requestID: AnyHashable, in window: UIWindow) -> SystemPresentation? {
        all.allObjects.first {
            $0.caller == caller && $0.requestID == requestID && $0.window === window
                && $0.isLive && ($0.owner?.isDismantled ?? true)
        }
    }

    /// What a new presentation in this window must wait for: one shown
    /// anywhere in its chain, or one UIKit has queued behind a transition.
    static func active(in window: UIWindow) -> SystemPresentation? {
        var next = window.rootViewController?.presentedViewController
        while let controller = next {
            if let shown = objc_getAssociatedObject(controller, &presentationKey) as? SystemPresentation,
               shown.isLive {
                return shown
            }
            next = controller.presentedViewController
        }
        return all.allObjects.first { $0.window === window && $0.isLive && !$0.hasArrived }
    }

    /// Ended, but possibly still on its way out.
    static func hasEnded(_ controller: UIViewController) -> Bool {
        (objc_getAssociatedObject(controller, &presentationKey) as? SystemPresentation)?.hasEnded ?? false
    }

    /// On screen. One that ended before UIKit got round to it leaves again.
    func arrive() {
        guard !hasArrived else { return }
        hasArrived = true
        arrivedAt = Date()
        if hasEnded { dismissIfShown() }
    }

    func onEnd(_ action: @escaping () -> Void) {
        waiters.append(action)
    }

    /// Reported, or never arrived: release the request.
    func end() {
        guard finish() else { return }
        if isCurrent { clearRequest() }
    }

    /// Its request was cleared or replaced: take it down, now or when it
    /// arrives, and drop anything it reports later.
    func withdraw() {
        guard finish() else { return }
        // Out of the SwiftUI update that cleared the request.
        DispatchQueue.main.async { self.dismissIfShown() }
    }

    private func dismissIfShown() {
        guard let controller, controller.presentingViewController != nil,
              !controller.isBeingDismissed else { return }
        let tooSoon = minimumShownTime - Date().timeIntervalSince(arrivedAt ?? Date())
        guard !controller.isBeingPresented, tooSoon <= 0 else {
            // UIKit ignores a dismissal while the presentation animates, and
            // a Mac share sheet closed while opening upsets the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(tooSoon, 0.25)) { self.dismissIfShown() }
            return
        }
        controller.dismiss(animated: true)
    }

    private func finish() -> Bool {
        guard !hasEnded else { return false }
        hasEnded = true
        let waiters = waiters
        self.waiters = []
        DispatchQueue.main.async { waiters.forEach { $0() } }
        return true
    }
}

/// A zero-size view whose window presents the controller. It also anchors
/// the popover on iPad and the share menu on a Mac.
private struct SystemPresentationAnchor<Item: Identifiable>: UIViewRepresentable {
    @Binding var item: Item?
    let caller: String
    /// The earliest this kind of controller may be presented.
    var readyAt: () -> Date? = { nil }
    /// Builds the controller plus anything it holds only weakly (a delegate),
    /// which lives as long as the controller.
    let make: (Item, SystemPresentation) -> (UIViewController, AnyObject?)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.item = $item
        coordinator.caller = caller
        coordinator.readyAt = readyAt
        let requestID = item.map { AnyHashable($0.id) }
        if let shown = coordinator.presentation, !shown.hasEnded, shown.requestID != requestID {
            // Cleared or replaced by whoever asked, as `.sheet(item:)` would be.
            shown.withdraw()
        }
        guard requestID != nil, !coordinator.isScheduled else { return }
        coordinator.isScheduled = true
        // Presenting writes the binding back on failure; stay out of the
        // update pass that delivered it.
        DispatchQueue.main.async {
            coordinator.isScheduled = false
            coordinator.present(from: view, make: make)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        // Its replacement takes over; this one must neither present nor
        // release the binding the replacement now reads. A request cleared
        // in the same update is one the replacement never sees.
        coordinator.isDismantled = true
        if let shown = coordinator.presentation {
            DispatchQueue.main.async {
                if !shown.isCurrent { shown.withdraw() }
            }
        }
    }

    final class Coordinator: SystemPresentationOwner {
        var item: Binding<Item?>?
        var caller = ""
        var readyAt: () -> Date? = { nil }
        var isScheduled = false
        private(set) var presentation: SystemPresentation?

        func present(
            from anchor: UIView,
            attempt: Int = 0,
            make: @escaping (Item, SystemPresentation) -> (UIViewController, AnyObject?)
        ) {
            guard !isDismantled, let binding = item, let wanted = binding.wrappedValue else { return }
            let requestID = AnyHashable(wanted.id)
            if let presentation, presentation.requestID == requestID, !presentation.hasEnded {
                guard !presentation.isLive else { return }
                presentation.end()
                return
            }
            if let window = anchor.window {
                if let orphan = SystemPresentation.orphan(caller: caller, requestID: requestID, in: window) {
                    // Up for this request from an anchor SwiftUI replaced:
                    // take it over, popover included.
                    orphan.owner = self
                    presentation = orphan
                    if let popover = orphan.controller?.popoverPresentationController,
                       popover.sourceView?.window == nil {
                        Self.anchor(popover, to: anchor)
                    }
                    return
                }
                if let active = SystemPresentation.active(in: window) {
                    active.onEnd { [weak self, weak anchor] in
                        guard let self, let anchor else { return }
                        self.present(from: anchor, make: make)
                    }
                    return
                }
            }
            if let readyAt = readyAt(), readyAt > Date() {
                // A wait the system asked for, not a refusal: no attempt spent.
                DispatchQueue.main.asyncAfter(deadline: .now() + readyAt.timeIntervalSinceNow) { [weak self, weak anchor] in
                    guard let self, let anchor else { return }
                    self.present(from: anchor, attempt: attempt, make: make)
                }
                return
            }
            let currentRequest = { binding.wrappedValue.map { AnyHashable($0.id) } }
            let clearRequest = { binding.wrappedValue = nil }
            var host = anchor.window?.rootViewController
            while let next = host?.presentedViewController,
                  !next.isBeingDismissed, !SystemPresentation.hasEnded(next) {
                host = next
            }
            // Not in a window yet, or a controller is still leaving (Cancel,
            // then an immediate reopen): UIKit would refuse to present, and a
            // refused controller never calls back to release the button.
            guard let window = anchor.window, let host, host.presentedViewController == nil else {
                // One of ours that was withdrawn leaves when it can (the Mac
                // holds a share sheet briefly first): waiting is free.
                let ownLeaving = host?.presentedViewController.map(SystemPresentation.hasEnded) ?? false
                guard attempt < 8 || ownLeaving else {
                    if currentRequest() == requestID { clearRequest() }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak anchor] in
                    guard let self, let anchor else { return }
                    self.present(from: anchor, attempt: ownLeaving ? attempt : attempt + 1, make: make)
                }
                return
            }
            let presentation = SystemPresentation(
                caller: caller,
                requestID: requestID,
                owner: self,
                window: window,
                currentRequest: currentRequest,
                clearRequest: clearRequest
            )
            let (controller, retained) = make(wanted, presentation)
            presentation.attach(to: controller)
            if let retained {
                objc_setAssociatedObject(
                    controller,
                    &retainedDelegateKey,
                    retained,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
            if let popover = controller.popoverPresentationController {
                Self.anchor(popover, to: anchor)
            }
            self.presentation = presentation
            host.present(controller, animated: true) { presentation.arrive() }
            Self.watchArrival(of: controller, for: presentation, checksLeft: 6)
        }

        private static func anchor(_ popover: UIPopoverPresentationController, to anchor: UIView) {
            popover.sourceView = anchor
            let bounds = anchor.bounds
            if bounds.width > 160 || bounds.height > 160 {
                // A whole row or panel: centre the popover over it rather
                // than squeezing it beside a rect that fills the window.
                popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            } else {
                popover.sourceRect = bounds
            }
        }

        /// A refused controller never reports, which would leave the request
        /// latched. UIKit can also defer a presentation behind a transition,
        /// so only one that has not arrived after a few seconds was refused;
        /// releasing sooner reads as a cancel while it is still coming.
        private static func watchArrival(
            of controller: UIViewController,
            for presentation: SystemPresentation,
            checksLeft: Int
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !presentation.hasArrived else { return }
                if controller.presentingViewController != nil {
                    presentation.arrive()
                } else if checksLeft > 0 {
                    watchArrival(of: controller, for: presentation, checksLeft: checksLeft - 1)
                } else {
                    presentation.end()
                }
            }
        }
    }
}
