// TesseraTests/SystemPresentationTests.swift
//
// System pickers and share sheets are presented by UIKit from the window
// (Design/Components/SystemPresentation.swift). Run as an iPad app on a Mac,
// a document picker hosted in a SwiftUI sheet lost the chosen file, and
// ShareLink's "Save to Files" crashed the app. UI tests cannot run on the
// Mac, so these run inside the app on iPhone, iPad and the Mac: each one
// drives a call site to the controller UIKit really presents, then plays the
// Mac's order of events back through it (the picker leaves first, then
// reports).

import AVFoundation
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Tessera

@MainActor
final class SystemPresentationTests: XCTestCase {
    private var window: UIWindow?

    // MARK: - The shared presenter

    func testChosenFileArrivesAfterThePickerAndItsOpenerAreGone() throws {
        let probe = PresentationProbe()
        try host(PickerHost(probe: probe))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        XCTAssertFalse(picker.allowsMultipleSelection)

        // The Mac's picker leaves before it reports, which used to take the
        // sheet hosting it, and the sheet's delegate, with it.
        try dismissPresented()
        window?.rootViewController = UIViewController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let file = URL(fileURLWithPath: "/tmp/tessera-picked-key")
        let delegate = try XCTUnwrap(picker.delegate, "the picker lost its delegate along with its opener")
        delegate.documentPicker?(picker, didPickDocumentsAt: [file])
        XCTAssertEqual(probe.picks, [[file]])
    }

    func testPickerReportsOnceAndOpensAgain() throws {
        let probe = PresentationProbe()
        try host(PickerHost(probe: probe, allowsMultipleSelection: true, asCopy: false))
        probe.isPresented = true
        let first = try presented(UIDocumentPickerViewController.self)
        XCTAssertTrue(first.allowsMultipleSelection)
        try dismissPresented()
        let files = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")]
        first.delegate?.documentPicker?(first, didPickDocumentsAt: files)
        XCTAssertEqual(probe.picks, [files])
        try waitUntil("the picker to release its binding") { !probe.isPresented }

        probe.isPresented = true
        let second = try presented(UIDocumentPickerViewController.self, other: first)
        second.delegate?.documentPickerWasCancelled?(second)
        try dismissPresented()
        XCTAssertEqual(probe.picks, [files, []], "a cancel reports no files")
        try waitUntil("the cancelled picker to release its binding") { !probe.isPresented }

        second.delegate?.documentPicker?(second, didPickDocumentsAt: files)
        first.delegate?.documentPicker?(first, didPickDocumentsAt: files)
        XCTAssertEqual(probe.picks.count, 2, "a picker reports once")
    }

    /// Clearing the request takes the picker down, as `.sheet` would, and
    /// whatever the picker reports afterwards belongs to nobody.
    func testWithdrawnPickerLeavesAndReportsNothing() throws {
        let probe = PresentationProbe()
        let root = try host(PickerHost(probe: probe))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        probe.isPresented = false
        try waitUntil("the withdrawn picker to leave") { root.presentedViewController == nil }
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/tmp/late.txt")])
        XCTAssertEqual(probe.picks, [], "a withdrawn picker reported")
        XCTAssertFalse(probe.isPresented)

        probe.isPresented = true
        let again = try presented(UIDocumentPickerViewController.self, other: picker)
        again.delegate?.documentPickerWasCancelled?(again)
        try dismissPresented()
        XCTAssertEqual(probe.picks, [[]])
        try waitUntil("the reopened picker to release its binding") { !probe.isPresented }
    }

    /// Cancel, then reopen at once: UIKit refuses to present over a
    /// controller that is still leaving, and a refused picker never reports.
    func testPickerWaitsForAControllerStillLeaving() throws {
        let probe = PresentationProbe()
        let root = try host(PickerHost(probe: probe))
        let leaving = UIViewController()
        root.present(leaving, animated: false)
        try waitUntil("the first controller to present") { root.presentedViewController === leaving }
        root.dismiss(animated: true)
        try waitUntil("the first controller to start leaving", timeout: 2) { leaving.isBeingDismissed }
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        // A presentation UIKit deferred behind the transition is not a
        // refusal: releasing the binding now would read as a cancel.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(probe.isPresented, "the binding dropped while the picker was up")
        XCTAssertTrue(root.presentedViewController === picker)
    }

    func testShareSheetPresentsAndReleasesItsBinding() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("shared.log", contents: "shared from a test\n")
        try host(ShareHost(probe: probe, items: [file]))
        probe.isPresented = true
        let sheet = try presented(UIActivityViewController.self)
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
        try waitUntil("the share sheet to release its binding") { !probe.isPresented }

        probe.isPresented = true
        let again = try presented(UIActivityViewController.self, other: sheet)
        try finishSharing(again)
    }

    /// The Mac cancels a share sheet opened while the last one's share
    /// session is still closing: reopening at once must wait that out.
    func testShareSheetReopenedAtOnceStaysOpen() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("reopened.txt", contents: "reopened at once\n")
        try host(ShareHost(probe: probe, items: [file]))
        var previous: UIActivityViewController?
        for round in 1...3 {
            probe.isPresented = true
            let sheet = try presented(UIActivityViewController.self, other: previous)
            assertChainStays([sheet], "share sheet \(round) closed by itself", for: 2.5)
            try finishSharing(sheet)
            try waitUntil("share sheet \(round) to release its binding") { !probe.isPresented }
            previous = sheet
        }
    }

    /// SwiftUI rebuilt the Markdown preview's anchor as its share sheet came
    /// up: both anchors presented, and the popover was left on the view
    /// SwiftUI threw away.
    func testRebuiltAnchorPresentsOnceAndKeepsThePopoverAnchored() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("rebuilt.txt", contents: "rebuilt anchor\n")
        try host(RebuildingShareHost(probe: probe, items: [file]))
        probe.isPresented = true
        let sheet = try presented(UIActivityViewController.self)
        assertChainStays([sheet], "a second controller was presented")

        probe.rebuilds += 1
        assertChainStays([sheet], "the rebuilt anchor presented again")
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
        try waitUntil("the share sheet to release its binding") { !probe.isPresented }
    }

    /// Clearing the request in the same update that rebuilds its anchor
    /// leaves the replacement nothing to withdraw; the outgoing one must.
    func testPickerClearedAsItsAnchorIsRebuiltLeaves() throws {
        let probe = PresentationProbe()
        let root = try host(RebuildingPickerHost(probe: probe))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        probe.isPresented = false
        try waitUntil("the cleared picker to leave") { root.presentedViewController == nil }
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/tmp/late.txt")])
        XCTAssertEqual(probe.picks, [], "a cleared picker reported")
    }

    /// The Mac's picker leaves before it reports. An anchor rebuilt in that
    /// gap takes the picker over rather than opening a second one.
    func testAnchorRebuiltWhileThePickerIsAwayWaitsForItsReport() throws {
        let probe = PresentationProbe()
        try host(RebuildingPickerHost(probe: probe))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        settleOnScreen()
        try dismissPresented()
        probe.rebuilds += 1
        assertChainStays([], "the rebuilt anchor opened a second picker")

        let file = URL(fileURLWithPath: "/tmp/tessera-picked-key")
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [file])
        XCTAssertEqual(probe.picks, [[file]])
        try waitUntil("the picker to release its binding") { !probe.isPresented }
    }

    /// Something the share sheet presents on top must not hide it: a rebuilt
    /// anchor would otherwise present a second sheet above both.
    func testRebuiltAnchorSeesItsSheetUnderAnotherController() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("nested.txt", contents: "nested presentation\n")
        try host(RebuildingShareHost(probe: probe, items: [file]))
        probe.isPresented = true
        let sheet = try presented(UIActivityViewController.self)
        settleOnScreen()
        let above = UIViewController()
        sheet.present(above, animated: false)
        try waitUntil("a controller to present over the sheet") { sheet.presentedViewController === above }

        probe.rebuilds += 1
        assertChainStays([sheet, above], "the rebuilt anchor presented again")
    }

    /// Two call sites bound to Booleans both ask for "the" request; one
    /// whose anchor is gone must not hand its picker to the other.
    func testAnotherCallSiteWaitsInsteadOfTakingThePickerOver() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("other.txt", contents: "another call site\n")
        try host(TwoCallSitesHost(probe: probe, items: [file]))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        probe.showsPicker = false
        probe.isSharing = true
        assertChainStays([picker], "the waiting share request presented or took the picker over")
        XCTAssertTrue(probe.isSharing, "the waiting share request was dropped")

        // Withdrawing the waiting request must leave the picker alone.
        probe.isSharing = false
        assertChainStays([picker], "the other call site took the picker down")

        probe.isSharing = true
        picker.delegate?.documentPickerWasCancelled?(picker)
        // The waiting share sheet can take the picker's place at once.
        picker.dismiss(animated: false)
        XCTAssertEqual(probe.picks, [[]])
        let sheet = try presented(UIActivityViewController.self)
        try finishSharing(sheet)
        try waitUntil("the share sheet to release its binding") { !probe.isSharing }
    }

    /// A controller of ours on its way out is waited for however long it
    /// takes (the Mac holds a share sheet a moment before closing it); only
    /// someone else's controller can make a request give up.
    func testRequestWaitsForOurControllerHoweverLongItTakesToLeave() throws {
        let probe = PresentationProbe()
        let file = try scratchFile("after.txt", contents: "after the picker\n")
        try host(TwoCallSitesHost(probe: probe, items: [file]))
        probe.isPresented = true
        let picker = try presented(UIDocumentPickerViewController.self)
        picker.delegate?.documentPickerWasCancelled?(picker)
        XCTAssertEqual(probe.picks, [[]])
        probe.isSharing = true
        // Longer than a request waits on a controller it does not own.
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(probe.isSharing, "the share request gave up behind the leaving picker")

        // The share sheet takes the picker's place at once.
        picker.dismiss(animated: false)
        let sheet = try presented(UIActivityViewController.self)
        try finishSharing(sheet)
        try waitUntil("the share sheet to release its binding") { !probe.isSharing }
    }

    // MARK: - Call sites

    /// The reported Mac bug: the chosen key file never reached the modal.
    func testKeyImportShowsTheChosenFile() throws {
        let key = try scratchFile("id_presentation_test", contents: "not parsed until import\n")
        let container = try TesseraModelContainer.make(inMemory: true)
        try host(
            ImportKeyModal(initialProtection: false, onClose: {}, onImported: { _ in })
                .modelContainer(container)
        )
        try activate("choose file…")
        let picker = try presented(UIDocumentPickerViewController.self)
        try dismissPresented()
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [key])
        _ = try element("the chosen file name") { $0 == key.lastPathComponent }
    }

    func testAgentAttachmentPickerHandsBackEveryFile() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let request = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        model.onPrepareAttachments = { _ in request }
        var completions: [[URL]] = []
        model.onCompleteAttachments = { completed, urls in
            XCTAssertEqual(completed.id, request.id)
            completions.append(urls)
        }
        try host(AgentCenterV2RootView(model: model) { EmptyView() })
        model.prepareAttachments(for: thread, source: .file)
        let picker = try presented(UIDocumentPickerViewController.self)
        XCTAssertTrue(picker.allowsMultipleSelection)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(completions, [], "the request was cancelled while the picker was up")
        XCTAssertNotNil(model.attachmentPickerRequest)

        try dismissPresented()
        let files = [URL(fileURLWithPath: "/tmp/notes.txt"), URL(fileURLWithPath: "/tmp/plot.png")]
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: files)
        XCTAssertEqual(completions.first, files, "the dismissal must not cancel ahead of the files")
        XCTAssertNil(model.attachmentPickerRequest)
    }

    /// The composer going away cancels its request (`cancelAll()`): the
    /// picker must leave with it rather than hand files to nobody.
    func testAgentAttachmentPickerLeavesWhenTheRequestIsCancelled() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let request = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        model.onPrepareAttachments = { _ in request }
        var completions: [[URL]] = []
        model.onCompleteAttachments = { _, urls in completions.append(urls) }
        let root = try host(AgentCenterV2RootView(model: model) { EmptyView() })
        model.prepareAttachments(for: thread, source: .file)
        let picker = try presented(UIDocumentPickerViewController.self)

        model.attachmentPickerRequest = nil
        try waitUntil("the cancelled picker to leave") { root.presentedViewController == nil }
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/tmp/late.txt")])
        XCTAssertEqual(completions, [], "a cancelled picker handed back files")
    }

    /// The composer cancels and asks again before SwiftUI catches up, and
    /// the first picker reports in that gap: its files belong to nobody, and
    /// the newer request must survive it.
    func testAgentAttachmentPickerDropsFilesForAReplacedRequest() throws {
        let model = AgentCenterV2Fixture.makeModel(scene: .outgoing)
        let thread = try XCTUnwrap(model.selectedThread)
        let first = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        let second = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        var requests = [first, second]
        model.onPrepareAttachments = { _ in requests.removeFirst() }
        var completions: [(UUID, [URL])] = []
        model.onCompleteAttachments = { request, urls in completions.append((request.id, urls)) }
        try host(AgentCenterV2RootView(model: model) { EmptyView() })
        model.prepareAttachments(for: thread, source: .file)
        let picker = try presented(UIDocumentPickerViewController.self)

        model.attachmentPickerRequest = nil
        model.prepareAttachments(for: thread, source: .file)
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/tmp/late.txt")])
        XCTAssertTrue(completions.isEmpty, "the replaced picker handed back files")
        XCTAssertEqual(model.attachmentPickerRequest?.id, second.id, "the replaced picker cancelled the newer request")

        let next = try presented(UIDocumentPickerViewController.self, other: picker)
        try dismissPresented()
        let files = [URL(fileURLWithPath: "/tmp/notes.txt")]
        next.delegate?.documentPicker?(next, didPickDocumentsAt: files)
        XCTAssertEqual(completions.first?.0, second.id)
        XCTAssertEqual(completions.first?.1, files)
    }

    func testDiagnosticsExportOpensTheShareSheet() throws {
        try host(DiagnosticsSettingsView(onUploadLog: {}))
        try activate("export log")
        let sheet = try presented(UIActivityViewController.self)
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
    }

    func testPublicKeyShareOpensTheShareSheet() throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let key = StoredKey(
            id: UUID(),
            name: "presentation test key",
            algorithm: .ed25519,
            authorizedKeysLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHByZXNlbnRhdGlvbi10ZXN0LXB1YmxpYy1rZXkt presentation-test",
            requiresBiometric: false
        )
        container.mainContext.insert(key)
        try container.mainContext.save()
        try host(
            KeysPageView()
                .modelContainer(container)
                .environment(AppearancePreferences())
                .environment(ConnectionActivityStore.shared)
        )
        if UIDevice.current.userInterfaceIdiom == .phone {
            // Phones open a key from the list; larger layouts select one.
            try activate(matching: "the key row") { $0.contains(key.name) }
        }
        try activate("share public key")
        let sheet = try presented(UIActivityViewController.self)
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
    }

    func testMarkdownPreviewSharesTheFile() throws {
        let file = try scratchFile("notes.md", contents: "# Notes\n\nShared from a test.\n")
        try host(QuickLookPresenter(fileURL: file, displayTitle: "notes.md"))
        try activate("Share notes.md")
        let sheet = try presented(UIActivityViewController.self)
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
    }

    func testFilesShareWithdrawsTheRequestWhenTheSheetCloses() throws {
        let controller = FilesPanelController()
        let file = try scratchFile("report.txt", contents: "remote file\n")
        try host(
            FilesPanelView(controller: controller, T: DesignTokens.make(mode: .dark, accent: .blue))
                .environment(AppearancePreferences())
        )
        controller.presentedShare = .init(items: [file])
        let sheet = try presented(UIActivityViewController.self)
        assertAnchoredInTestWindow(sheet)
        try finishSharing(sheet)
        try waitUntil("the share request to clear") { controller.presentedShare == nil }
    }

    /// A second download finishing while the first file's sheet is up
    /// replaces that sheet; the first one closing must not drop the second.
    func testFilesShareSwapsToTheNewerFile() throws {
        let controller = FilesPanelController()
        let first = try scratchFile("first.txt", contents: "first remote file\n")
        let second = try scratchFile("second.txt", contents: "second remote file\n")
        try host(
            FilesPanelView(controller: controller, T: DesignTokens.make(mode: .dark, accent: .blue))
                .environment(AppearancePreferences())
        )
        controller.presentedShare = .init(items: [first])
        let firstSheet = try presented(UIActivityViewController.self)
        let newer = FilesPanelController.ShareRequest(items: [second])
        controller.presentedShare = newer
        let secondSheet = try presented(UIActivityViewController.self, other: firstSheet)
        assertChainStays([secondSheet], "the newer file's sheet closed by itself", for: 2.5)
        assertAnchoredInTestWindow(secondSheet)

        firstSheet.completionWithItemsHandler?(nil, false, nil, nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(controller.presentedShare?.id, newer.id, "the replaced sheet withdrew the newer request")
        try finishSharing(secondSheet)
        try waitUntil("the share request to clear") { controller.presentedShare == nil }
    }

    /// Requesting QR codes from an output that cannot report them raised an
    /// Objective-C exception; an output with no camera reports nothing.
    func testScannerDeclinesQRCodesTheCameraCannotReport() {
        let output = AVCaptureMetadataOutput()
        XCTAssertFalse(output.availableMetadataObjectTypes.contains(.qr))
        XCTAssertFalse(PairingQRCodeScannerModel.requestQRCodes(from: output))
        XCTAssertTrue(output.metadataObjectTypes.isEmpty)
    }

    // MARK: - Helpers

    /// SwiftUI builds its accessibility tree only for an attached assistive
    /// client; XCUITest turns on the same automation switch. Without it the
    /// hosted buttons below cannot be found or pressed.
    override func invokeTest() {
        let previous = AccessibilityAutomation.isEnabled
        AccessibilityAutomation.setEnabled(true)
        defer { AccessibilityAutomation.setEnabled(previous) }
        super.invokeTest()
    }

    /// A window above whatever the app shows, so presentation starts here.
    @discardableResult
    private func host<Content: View>(_ content: Content) throws -> UIViewController {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let controller = AnchorRecordingController(rootView: content)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        addTeardownBlock { @MainActor in
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        return controller
    }

    private func presented<Controller: UIViewController>(
        _ type: Controller.Type,
        other previous: UIViewController? = nil
    ) throws -> Controller {
        var found: Controller?
        try waitUntil("a \(Controller.self) to present") {
            guard let top = window?.rootViewController?.presentedViewController as? Controller,
                  top !== previous, !top.isBeingPresented else { return false }
            found = top
            return true
        }
        return try XCTUnwrap(found)
    }

    /// Long enough on screen that the presenter counts the controller as
    /// shown rather than still arriving, which would hide a duplicate anyway.
    private func settleOnScreen() {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    /// UIKit puts a system controller on screen only once its remote view
    /// is ready, seconds later on a busy machine; a duplicate shows up late.
    private func assertChainStays(
        _ expected: [UIViewController],
        _ message: String,
        for seconds: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let chain = presentedChain()
            guard chain.elementsEqual(expected, by: ===) else {
                XCTFail("\(message): \(chain.map { type(of: $0) })", file: file, line: line)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Everything stacked on the test window's root, bottom first.
    private func presentedChain() -> [UIViewController] {
        var chain: [UIViewController] = []
        var next = window?.rootViewController?.presentedViewController
        while let current = next {
            chain.append(current)
            next = current.presentedViewController
        }
        return chain
    }

    private func dismissPresented() throws {
        guard let root = window?.rootViewController, root.presentedViewController != nil else { return }
        root.dismiss(animated: false)
        try waitUntil("the presented controller to leave") { root.presentedViewController == nil }
    }

    /// What the system does once the user picks a service or closes the sheet.
    private func finishSharing(_ sheet: UIActivityViewController) throws {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // A person closes the Mac's share menu once it has opened. One
            // closed while still opening leaves its share session half set
            // up, and that cancels the next sheet, in the next test too.
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        try dismissPresented()
    }

    /// iPad and the Mac present the share sheet as a popover, which must hang
    /// off a view in the window that opened it.
    private func assertAnchoredInTestWindow(
        _ controller: UIViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return }
        let anchor = objc_getAssociatedObject(controller, &anchorAtPresentationKey) as? AnchorAtPresentation
        XCTAssertNotNil(anchor, "presented without a popover source view", file: file, line: line)
        XCTAssertTrue(
            anchor?.window === window,
            "popover presented from outside the test window: \(anchor?.chain ?? "no source view")",
            file: file,
            line: line
        )
        // Once up, the Mac swaps the popover for a presentation of its own.
        // Elsewhere it stays a popover, which a rebuilt anchor must keep in
        // the window.
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let source = controller.popoverPresentationController?.sourceView
        XCTAssertNotNil(source, "popover without a source view", file: file, line: line)
        var chain: [String] = []
        var view = source
        while let current = view { chain.append(String(describing: type(of: current))); view = current.superview }
        XCTAssertTrue(
            source?.window === window,
            "popover anchored outside the test window: source window \(String(describing: source?.window)), chain \(chain.joined(separator: " < "))",
            file: file,
            line: line
        )
    }

    private func activate(_ label: String) throws {
        try activate(matching: "\"\(label)\"") { $0 == label }
    }

    private func activate(matching what: String, _ matches: @escaping (String) -> Bool) throws {
        let control = try element(what, matching: matches)
        XCTAssertTrue(control.accessibilityActivate(), "\(what) did not activate")
    }

    private func element(_ what: String, matching matches: @escaping (String) -> Bool) throws -> NSObject {
        var found: NSObject?
        try waitUntil(what) {
            found = window.flatMap { Self.accessibilityElement(in: $0, matching: matches, depth: 0) }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private static func accessibilityElement(
        in node: NSObject,
        matching matches: (String) -> Bool,
        depth: Int
    ) -> NSObject? {
        if node.isAccessibilityElement, let label = node.accessibilityLabel, matches(label) {
            return node
        }
        guard depth < 80 else { return nil }
        var children: [NSObject] = []
        if let elements = node.accessibilityElements as? [NSObject] {
            children = elements
        } else {
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = node as? UIView {
            children += view.subviews.filter { subview in !children.contains { $0 === subview } }
        }
        for child in children {
            if let hit = accessibilityElement(in: child, matching: matches, depth: depth + 1) {
                return hit
            }
        }
        return nil
    }

    private func scratchFile(_ name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw XCTestError(.timeoutWhileWaiting)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

private var anchorAtPresentationKey: UInt8 = 0

private final class AnchorAtPresentation {
    weak var window: UIWindow?
    let chain: String

    init(_ source: UIView) {
        window = source.window
        var chain: [String] = []
        var view: UIView? = source
        while let current = view { chain.append(String(describing: type(of: current))); view = current.superview }
        self.chain = chain.joined(separator: " < ")
    }
}

/// Notes where each popover hangs as it is presented: the Mac replaces the
/// popover once it is up, so its source view cannot be read afterwards.
private final class AnchorRecordingController<Content: View>: UIHostingController<Content> {
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        if let source = controller.popoverPresentationController?.sourceView {
            objc_setAssociatedObject(
                controller,
                &anchorAtPresentationKey,
                AnchorAtPresentation(source),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        super.present(controller, animated: animated, completion: completion)
    }
}

private enum AccessibilityAutomation {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void
    private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)

    static var isEnabled: Bool {
        guard let symbol = dlsym(library, "_AXSAutomationEnabled") else { return false }
        return unsafeBitCast(symbol, to: Get.self)()
    }

    static func setEnabled(_ enabled: Bool) {
        guard let symbol = dlsym(library, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(symbol, to: Set.self)(enabled)
    }
}

@MainActor
@Observable
private final class PresentationProbe {
    var isPresented = false
    var picks: [[URL]] = []
    var rebuilds = 0
    var showsPicker = true
    var isSharing = false
}

private struct PickerHost: View {
    @Bindable var probe: PresentationProbe
    var allowsMultipleSelection = false
    var asCopy = true

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .systemDocumentPicker(
                isPresented: $probe.isPresented,
                contentTypes: [.data],
                allowsMultipleSelection: allowsMultipleSelection,
                asCopy: asCopy
            ) { urls in
                probe.picks.append(urls)
            }
    }
}

private struct ShareHost: View {
    @Bindable var probe: PresentationProbe
    let items: [Any]

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .systemShareSheet(isPresented: $probe.isPresented) { items }
    }
}

/// A new anchor whenever the binding flips or the test asks for one.
private struct RebuildingPickerHost: View {
    @Bindable var probe: PresentationProbe

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .systemDocumentPicker(isPresented: $probe.isPresented, contentTypes: [.data]) { urls in
                probe.picks.append(urls)
            }
            .id("\(probe.isPresented)-\(probe.rebuilds)")
    }
}

/// A picker whose call site can go away, beside a share sheet.
private struct TwoCallSitesHost: View {
    @Bindable var probe: PresentationProbe
    let items: [Any]

    var body: some View {
        HStack {
            if probe.showsPicker {
                Color.clear
                    .frame(width: 44, height: 44)
                    .systemDocumentPicker(isPresented: $probe.isPresented, contentTypes: [.data]) { urls in
                        probe.picks.append(urls)
                    }
            }
            Color.clear
                .frame(width: 44, height: 44)
                .systemShareSheet(isPresented: $probe.isSharing) { items }
        }
    }
}

/// A new anchor whenever the binding flips or the test asks for one.
private struct RebuildingShareHost: View {
    @Bindable var probe: PresentationProbe
    let items: [Any]

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .systemShareSheet(isPresented: $probe.isPresented) { items }
            .id("\(probe.isPresented)-\(probe.rebuilds)")
    }
}
