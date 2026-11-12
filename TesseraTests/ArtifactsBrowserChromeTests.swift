import SwiftUI
import TesseraArtifactsCore
import UIKit
import XCTest
@testable import Tessera

/// The browser's chrome, address field and chords, below the views: which
/// controls each layout shows, what an edited address does, which tab a
/// chord picks, and which surface a chord reaches.
@MainActor
final class ArtifactsBrowserChromeTests: XCTestCase {
    // MARK: - One set of controls

    /// A phone's tab keeps today's bottom bar, which has no +: new tabs
    /// start from its switcher or overview, or ⌘T. Every other layout shows
    /// exactly one.
    func testEveryLayoutShowsExactlyOneNewTabAndAtMostOneOverviewControl() {
        let layouts: [ArtifactsChromeLayout] = [.regular, .compactOverview, .compactTab, .laptopDesk, .laptopOverview,
                                                .railOverview, .railTab, .switcher]
        var checked = 0
        for layout in layouts {
            for showsOverview in [false, true] {
                for hasTabs in [false, true] {
                    let controls = ArtifactsChromePolicy.controls(layout, showsOverview: showsOverview, hasTabs: hasTabs)
                    XCTAssertEqual(controls.intersection(ArtifactsChromePolicy.newTabControls).count, layout == .compactTab ? 0 : 1,
                                   "\(layout) overview=\(showsOverview) tabs=\(hasTabs): \(controls)")
                    XCTAssertLessThanOrEqual(controls.intersection(ArtifactsChromePolicy.overviewControls).count, 1,
                                             "\(layout) overview=\(showsOverview)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 32)
    }

    /// Laptop pose keeps everything above the fold or on the desk: the
    /// overview lies on the desk, so no switcher sheet runs across the
    /// hinge, and the open field moves up to the title with no tab on top.
    func testLaptopPoseHasNoSwitcherSheetAndOneOpenField() {
        for layout: ArtifactsChromeLayout in [.laptopDesk, .laptopOverview] {
            for hasTabs in [false, true] {
                let controls = ArtifactsChromePolicy.controls(layout, showsOverview: false, hasTabs: hasTabs)
                XCTAssertFalse(controls.contains(.switcherGrid), "\(layout): the overview is on the desk")
            }
        }
        XCTAssertTrue(ArtifactsChromePolicy.controls(.laptopDesk, showsOverview: false, hasTabs: true).contains(.deskOpenRow))
        XCTAssertEqual(ArtifactsChromePolicy.controls(.laptopOverview, showsOverview: true, hasTabs: true), [.titleOpenField],
                       "with no tab on top the desk keeps no open row of its own")
        XCTAssertTrue(ArtifactsChromePolicy.controls(.compactTab, showsOverview: false, hasTabs: true).contains(.switcherGrid),
                      "a phone's tab keeps its switcher")
    }

    /// A Duo pane on the laptop's desk types its address under its header,
    /// trading up above the keyboard; everywhere else it keeps its sheet.
    func testADuoPaneTypesItsAddressInPlaceOnlyAcrossTheLaptopsFold() {
        XCTAssertTrue(DuoContextPane.entersAddressInPlace(arrangement: .stacked))
        for arrangement: DuoPaneArrangement? in [.sideBySide, .single, nil] {
            XCTAssertFalse(DuoContextPane.entersAddressInPlace(arrangement: arrangement), String(describing: arrangement))
        }
    }

    func testRegularToolbarDropsItsCloseAndTheStripHidesWithTheOverview() {
        let page = ArtifactsChromePolicy.controls(.regular, showsOverview: false, hasTabs: true)
        XCTAssertEqual(page, [.back, .forward, .address, .reload, .shareFile, .newTab, .overview, .tabMenu, .tabStrip])
        XCTAssertFalse(page.contains(.closeTab), "each strip tab has its own close")
        let overview = ArtifactsChromePolicy.controls(.regular, showsOverview: true, hasTabs: true)
        XCTAssertFalse(overview.contains(.tabStrip))
        XCTAssertTrue(overview.contains(.newTab))
        XCTAssertFalse(ArtifactsChromePolicy.controls(.regular, showsOverview: false, hasTabs: false).contains(.tabStrip))
    }

    func testTheOverviewHeaderOffersNewTabOnlyWhereNoToolbarDoes() {
        XCTAssertFalse(ArtifactsChromePolicy.overviewHeaderOffersNewTab(regular: true, railMode: false, onDesk: false))
        XCTAssertFalse(ArtifactsChromePolicy.overviewHeaderOffersNewTab(regular: false, railMode: true, onDesk: false))
        XCTAssertFalse(ArtifactsChromePolicy.overviewHeaderOffersNewTab(regular: false, railMode: false, onDesk: true))
        XCTAssertTrue(ArtifactsChromePolicy.overviewHeaderOffersNewTab(regular: false, railMode: false, onDesk: false))
    }

    // MARK: - The address field

    func testTheEditableAddressIsTheFullAddress() {
        let page = tab("page", .page(scheme: "http", port: 8001, path: "/"))
        XCTAssertEqual(ArtifactsBrowserPresentation.editableAddress(page), "localhost:8001/")
        let live = URL(string: "http://127.0.0.1:52011/laptop.html?view=desk#top")!
        XCTAssertEqual(ArtifactsBrowserPresentation.editableAddress(page, webURL: live), "localhost:8001/laptop.html?view=desk#top",
                       "the page the tab shows now, on the host's port")
        let secure = tab("tls", .page(scheme: "https", port: 8443, path: "/app"))
        XCTAssertEqual(ArtifactsBrowserPresentation.editableAddress(secure), "https://localhost:8443/app")
        let doc = tab("doc", .file(path: "/srv/docs/PLAN.md"))
        XCTAssertEqual(ArtifactsBrowserPresentation.editableAddress(doc), "devbox:/srv/docs/PLAN.md")
        let request = ArtifactAddressEditRequest.edit(page, webURL: live)
        XCTAssertEqual(request.placement, .navigate(tabID: "page"))
        XCTAssertEqual(request.currentHostID, "h1")
        XCTAssertEqual(ArtifactAddressEditRequest.newTab(currentHostID: "h1").initialText, "")
    }

    func testTheEditedAddressParsesBackToItsTarget() {
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h1", label: "devbox", home: "/home/me")], currentHostID: "h1",
                                                cwd: "/home/me", listeningPorts: [])
        let page = tab("page", .page(scheme: "http", port: 8001, path: "/laptop.html"))
        XCTAssertEqual(ArtifactsQuickOpen.parse(ArtifactsBrowserPresentation.editableAddress(page), context: context),
                       .page(hostID: "h1", scheme: "http", port: 8001, path: "/laptop.html"))
        let secure = tab("tls", .page(scheme: "https", port: 8443, path: "/"))
        XCTAssertEqual(ArtifactsQuickOpen.parse(ArtifactsBrowserPresentation.editableAddress(secure), context: context),
                       .page(hostID: "h1", scheme: "https", port: 8443, path: "/"))
        let doc = tab("doc", .file(path: "/srv/a b.md"))
        XCTAssertEqual(ArtifactsQuickOpen.parse(ArtifactsBrowserPresentation.editableAddress(doc), context: context),
                       .file(hostID: "h1", path: "/srv/a b.md"))
    }

    func testReturnKeepsSwitchesOrOpensWhereTheFieldSays() {
        let page = tab("page", .page(scheme: "http", port: 8001, path: "/"))
        let edit = ArtifactAddressEditRequest.edit(page, webURL: nil)
        let exists: (String) -> Bool = { $0 == "page" || $0 == "other" }
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: " localhost:8001/ ", request: edit, selected: nil,
                                                                  tabExists: exists), .keep)
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: "localhost:8001/laptop.html", request: edit, selected: nil,
                                                                  tabExists: exists),
                       .open(input: "localhost:8001/laptop.html", hostID: "h1"))
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: "   ", request: edit, selected: nil, tabExists: exists), .none)
        let snapshot = ArtifactAddressEditRequest.edit(tab("edit", .change(path: "/a.swift", diff: "+a", summary: "s")), webURL: nil)
        XCTAssertTrue(snapshot.opensBeside)
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: snapshot.initialText, request: snapshot, selected: nil,
                                                                  tabExists: exists),
                       .open(input: snapshot.initialText, hostID: "h1"), "an agent edit's own address opens its file beside it")
        let newTab = ArtifactAddressEditRequest.newTab(currentHostID: "h1")
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: "localhost:8001/", request: newTab, selected: nil,
                                                                  tabExists: exists),
                       .open(input: "localhost:8001/", hostID: "h1"), "an identical address still opens a new tab")
        let openTab = ArtifactsSuggestion(kind: .openTab, title: "other", subtitle: "devbox · /", intent:
            .page(hostID: "h1", scheme: "http", port: 8001, path: "/laptop.html"), tabID: "other")
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: "localhost:8001/laptop.html", request: newTab,
                                                                  selected: openTab, tabExists: exists),
                       .switchTo(tabID: "other"), "an open tab's row switches to it as it is")
        let port = ArtifactsSuggestion(kind: .listeningPort, title: "localhost:5173", subtitle: "node",
                                       intent: .page(hostID: "h1", scheme: "http", port: 5173, path: "/"))
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: ":5", request: edit, selected: port, tabExists: exists),
                       .open(input: "http://localhost:5173/", hostID: "h1"))
        let closed = ArtifactsSuggestion(kind: .openTab, title: "gone", subtitle: "", intent: .file(hostID: "h1", path: "/gone.md"),
                                         tabID: "gone")
        XCTAssertEqual(ArtifactsBrowserPresentation.addressAction(input: "", request: newTab, selected: closed, tabExists: exists),
                       .open(input: "/gone.md", hostID: "h1"), "a row whose tab closed meanwhile opens its address")
    }

    func testTheEditedTabsOwnRowIsLeftOut() {
        let rows = [
            ArtifactsSuggestion(kind: .openTab, title: "page", subtitle: "", intent: .file(hostID: "h1", path: "/a"), tabID: "page"),
            ArtifactsSuggestion(kind: .openTab, title: "other", subtitle: "", intent: .file(hostID: "h1", path: "/b"), tabID: "other"),
        ]
        XCTAssertEqual(ArtifactsBrowserPresentation.addressSuggestions(rows, placement: .navigate(tabID: "page")).map(\.tabID),
                       ["other"])
        XCTAssertEqual(ArtifactsBrowserPresentation.addressSuggestions(rows, placement: .newTab).count, 2)
    }

    func testAnAmbiguousHostLabelStillResolvesOnTheEditedTabsHost() {
        let hosts: [ArtifactsQuickOpenHost] = [.init(id: "h1", label: "devbox", home: nil), .init(id: "h2", label: "devbox", home: nil),
                                                .init(id: "h3", label: "api", home: nil)]
        XCTAssertTrue(ArtifactsBrowserPresentation.unambiguousAddress("devbox:/srv/x.md", hostID: "h2", hosts: hosts)
                      == ("/srv/x.md", "h2"))
        XCTAssertTrue(ArtifactsBrowserPresentation.unambiguousAddress("api:/x", hostID: "h3", hosts: hosts) == ("api:/x", "h3"))
        XCTAssertTrue(ArtifactsBrowserPresentation.unambiguousAddress("localhost:8001/", hostID: "h1", hosts: hosts)
                      == ("localhost:8001/", "h1"))
    }

    func testAFileTabRestartsItsContentForAnotherFileAndAPageKeepsItsWebView() {
        let doc = tab("doc", .file(path: "/a.md"))
        var moved = doc
        moved.target = .file(path: "/b.md")
        XCTAssertNotEqual(ArtifactsBrowserPresentation.contentIdentity(doc), ArtifactsBrowserPresentation.contentIdentity(moved))
        let page = tab("page", .page(scheme: "http", port: 8001, path: "/"))
        var navigated = page
        navigated.target = .page(scheme: "http", port: 8001, path: "/laptop.html")
        XCTAssertEqual(ArtifactsBrowserPresentation.contentIdentity(page), ArtifactsBrowserPresentation.contentIdentity(navigated))
        XCTAssertTrue(ArtifactPageSession.sameOrigin(URL(string: "http://127.0.0.1:52011/")!,
                                                     URL(string: "http://127.0.0.1:52011/laptop.html")!))
        XCTAssertFalse(ArtifactPageSession.sameOrigin(URL(string: "http://127.0.0.1:52011/")!,
                                                      URL(string: "http://127.0.0.1:52012/")!))
    }

    // MARK: - Chords

    func testDigitChordsPickTheirTabAndNinePicksTheLast() {
        let tabs = (1...3).map { tab("t\($0)", .file(path: "/\($0)")) }
        XCTAssertEqual(ArtifactsBrowserPresentation.tabID(forDigit: 1, tabs: tabs), "t1")
        XCTAssertEqual(ArtifactsBrowserPresentation.tabID(forDigit: 3, tabs: tabs), "t3")
        XCTAssertNil(ArtifactsBrowserPresentation.tabID(forDigit: 4, tabs: tabs))
        XCTAssertEqual(ArtifactsBrowserPresentation.tabID(forDigit: 9, tabs: tabs), "t3")
        XCTAssertNil(ArtifactsBrowserPresentation.tabID(forDigit: 9, tabs: []))
        XCTAssertNil(ArtifactsBrowserPresentation.tabID(forDigit: 0, tabs: tabs))
    }

    func testChordsOfferOnlyWhatTheBrowserCanDo() {
        let empty = ArtifactsShortcutPolicy.available(.init())
        XCTAssertEqual(empty, [.newTab, .editAddress])
        var page = ArtifactsShortcutContext(tabCount: 3, hasDisplayedTab: true, canRefresh: true, canGoBack: true,
                                            canGoForward: false, canReopen: true, showsPage: true, canShareFile: false)
        let onPage = ArtifactsShortcutPolicy.available(page)
        for command: ArtifactsBrowserCommand in [.newTab, .editAddress, .reload, .back, .closeTab, .reopenTab, .previousTab,
                                                 .nextTab, .selectTab(1), .selectTab(3), .selectTab(9), .overview, .find] {
            XCTAssertTrue(onPage.contains(command), "\(command)")
        }
        for command: ArtifactsBrowserCommand in [.forward, .selectTab(4), .shareFile] {
            XCTAssertFalse(onPage.contains(command), "\(command)")
        }
        page.hasOverview = false
        XCTAssertFalse(ArtifactsShortcutPolicy.available(page).contains(.overview), "a Duo pane has no overview")
        let overview = ArtifactsShortcutPolicy.available(.init(tabCount: 1, hasDisplayedTab: false))
        XCTAssertFalse(overview.contains(.closeTab))
        XCTAssertTrue(overview.contains(.nextTab), "the overview steps into its one tab")
        let file = ArtifactsShortcutPolicy.available(.init(tabCount: 1, hasDisplayedTab: true, canShareFile: true))
        XCTAssertTrue(file.contains(.shareFile))
        XCTAssertFalse(file.contains(.find))
    }

    func testEveryBrowserActionMapsToOneCommandAndBack() {
        for action in ShortcutAction.browserActions {
            let command = ArtifactsBrowserCommand(action, digit: 2)
            XCTAssertEqual(command?.action, action)
        }
        XCTAssertNil(ArtifactsBrowserCommand(.tmuxNewWindow))
        XCTAssertNil(ArtifactsBrowserCommand(.browserSelectTab))
        XCTAssertEqual(ShortcutAction.browserActions.count, 13)
    }

    func testBrowserChordsShareKeysOnlyWithTheTerminal() throws {
        var checked = 0
        for action in ShortcutAction.browserActions {
            XCTAssertEqual(action.group, .artifacts)
            XCTAssertEqual(action.surface, .browser)
            XCTAssertEqual(action.availability, .artifactsBrowser)
            XCTAssertFalse(ShortcutAction.terminalActions.contains(action))
            XCTAssertNil(TesseraTerminalContainer.shortcutSelector(for: action))
            let binding = try XCTUnwrap(action.defaultBinding, "\(action.rawValue) ships a chord")
            XCTAssertTrue(binding.modifiers.contains(.command))
            XCTAssertNil(KeyBinding.reservedBySystem[binding], "\(action.rawValue)")
            for other in ShortcutAction.allCases where other != action && other.defaultBinding == binding {
                XCTAssertFalse(other.surface.overlaps(action.surface),
                               "\(action.rawValue) and \(other.rawValue) can be live at once on \(binding.rendered(.glyph))")
            }
            checked += 1
        }
        XCTAssertEqual(checked, 13)
        let expected: [ShortcutAction: KeyBinding] = [
            .browserNewTab: .cmd("t"), .browserEditAddress: .cmd("l"), .browserReload: .cmd("r"),
            .browserBack: .cmd("["), .browserForward: .cmd("]"), .browserCloseTab: .cmdShift("w"),
            .browserReopenTab: .cmdShift("t"), .browserPreviousTab: .cmdShift("["), .browserNextTab: .cmdShift("]"),
            .browserSelectTab: KeyBinding([.command], .character("1")), .browserTabOverview: .cmdShift("\\"),
            .browserFind: .cmd("f"), .browserShareFile: .cmdShift("s"),
        ]
        for (action, binding) in expected { XCTAssertEqual(action.defaultBinding, binding, action.rawValue) }
        XCTAssertTrue(ShortcutAction.browserSelectTab.isDigitBlock)
        XCTAssertTrue(ShortcutSurface.app.overlaps(.browser))
        XCTAssertFalse(ShortcutSurface.terminal.overlaps(.browser))
    }

    // MARK: - The terminal's selection menu

    func testTheTerminalSelectionMenuOffersArtifactsAndFilesOnEveryPresentation() throws {
        let container = TesseraTerminalContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        var fired: [(TesseraTerminalSelectionPathAction, String)] = []
        container.onSelectionPathAction = { fired.append(($0, $1)) }
        let view = container.terminalView
        view.feed(text: "/var/log/syslog")
        view.selectAll()
        let selection = try XCTUnwrap(view.getSelection())
        XCTAssertTrue(RemotePathResolver.isPlausiblePath(selection), selection)

        func presented() throws -> [UICommand] {
            let menu = try XCTUnwrap(view.editMenuInteraction(
                UIEditMenuInteraction(delegate: nil),
                menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
                suggestedActions: []
            ))
            return menu.children.compactMap { $0 as? UICommand }
        }
        let first = try presented()
        let second = try presented()
        XCTAssertEqual(first.map(\.title), [String(localized: "Open in Artifacts"), String(localized: "Reveal in Files")])
        XCTAssertEqual(second.map(\.title), first.map(\.title))
        XCTAssertEqual(first.map(\.action), view.additionalMenuCommands.map(\.action))
        for command in first + second {
            XCTAssertFalse(view.additionalMenuCommands.contains { $0 === command },
                           "each menu gets its own copy of \(command.title)")
        }
        for (copy, again) in zip(first, second) { XCTAssertFalse(copy === again) }

        for command in first {
            XCTAssertTrue(container.canPerformAction(command.action, withSender: command), command.title)
            container.perform(command.action, with: command)
        }
        XCTAssertEqual(fired.map(\.0), [.quickLook, .reveal])
        XCTAssertEqual(fired.map(\.1), [selection, selection])

        view.selectNone()
        for command in first {
            XCTAssertFalse(container.canPerformAction(command.action, withSender: command),
                           "no selection, no \(command.title)")
        }
    }

    // MARK: - Which surface a chord reaches

    func testATerminalRelaysTheBrowsersChordsOnlyWhileAPaneBesideItHoldsTheKeyboard() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let other = UIWindow(windowScene: scene)
        defer { window.isHidden = true; other.isHidden = true }
        let container = TesseraTerminalContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        container.tmuxShortcutsEnabled = true
        window.addSubview(container)
        let pane = UIView(frame: CGRect(x: 200, y: 0, width: 200, height: 200))
        window.addSubview(pane)
        let elsewhere = UIView()
        other.addSubview(elsewhere)
        let relay = ArtifactsShortcutRelay()
        var fired: [ArtifactsBrowserCommand] = []
        relay.attach(available: [.newTab, .closeTab, .selectTab(2)]) { fired.append($0) }
        let browserSelector = #selector(TesseraTerminalContainer.browserShortcutFired(_:))

        func chords(_ selector: Selector) -> Set<String> {
            Set((container.keyCommands ?? []).filter { $0.action == selector }.map {
                "\($0.modifierFlags.rawValue)|\($0.input ?? "")"
            })
        }
        let tmuxNewWindow = try XCTUnwrap(TesseraTerminalContainer.shortcutSelector(for: .tmuxNewWindow))
        let palette = try XCTUnwrap(TesseraTerminalContainer.shortcutSelector(for: .quickSwitchPalette))
        let commandT = "\(UIKeyModifierFlags.command.rawValue)|t"
        XCTAssertEqual(chords(tmuxNewWindow), [commandT], "a focused terminal keeps ⌘T")
        XCTAssertTrue(chords(browserSelector).isEmpty)

        focus.claim(UUID(), anchor: elsewhere, relay: relay)
        XCTAssertTrue(chords(browserSelector).isEmpty, "a browser in another window takes nothing here")
        focus.releaseAllForTesting()

        let paneID = UUID()
        focus.claim(paneID, anchor: pane, relay: relay)
        XCTAssertTrue(chords(browserSelector).contains(commandT), "the pane the user touched takes ⌘T")
        XCTAssertTrue(chords(tmuxNewWindow).isEmpty, "tmux's ⌘T steps aside rather than racing it")
        XCTAssertEqual(chords(palette), ["\(UIKeyModifierFlags.command.rawValue)|k"], "chords the browser does not use stay")
        let relayed = try XCTUnwrap(container.keyCommands?.first { $0.action == browserSelector && $0.input == "t"
            && $0.modifierFlags == .command })
        XCTAssertEqual(relayed.title, ShortcutAction.browserNewTab.title, "listed by name while ⌘ is held")
        XCTAssertTrue(relayed.wantsPriorityOverSystemBehavior)
        XCTAssertTrue(container.canPerformAction(browserSelector, withSender: relayed))
        container.browserShortcutFired(relayed)
        let digit = try XCTUnwrap(container.keyCommands?.first { $0.action == browserSelector && $0.input == "2" })
        container.browserShortcutFired(digit)
        let reload = try XCTUnwrap(container.keyCommands?.first { $0.action == browserSelector && $0.input == "r" })
        XCTAssertFalse(container.canPerformAction(browserSelector, withSender: reload), "an unavailable chord does nothing")
        XCTAssertEqual(fired, [.newTab, .selectTab(2)])

        focus.release(paneID)
        XCTAssertEqual(chords(tmuxNewWindow), [commandT], "touching the terminal gives ⌘T back")
        XCTAssertTrue(chords(browserSelector).isEmpty)
        XCTAssertFalse(container.canPerformAction(browserSelector, withSender: relayed))
    }

    func testTheLatestClaimInAWindowWinsAndAReleaseOnlyDropsItsOwn() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let page = UIView(), pane = UIView()
        window.addSubview(page)
        window.addSubview(pane)
        let pageRelay = ArtifactsShortcutRelay(), paneRelay = ArtifactsShortcutRelay()
        let pageID = UUID(), paneID = UUID()
        focus.claim(pageID, anchor: page, relay: pageRelay)
        focus.claim(paneID, anchor: pane, relay: paneRelay)
        XCTAssertTrue(focus.relay(in: window) === paneRelay)
        focus.release(pageID)
        XCTAssertTrue(focus.relay(in: window) === paneRelay)
        XCTAssertTrue(focus.holds(paneID))
        focus.release(paneID)
        XCTAssertNil(focus.relay(in: window))
        XCTAssertNil(focus.relay(in: nil))
    }

    func testATouchInsideThePaneClaimsTheKeyboardAndATouchElsewhereGivesItBack() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        defer { window.isHidden = true }
        let anchor = ArtifactsKeyboardFocusAnchorView(frame: CGRect(x: 200, y: 0, width: 200, height: 200))
        window.addSubview(anchor)
        let relay = ArtifactsShortcutRelay()
        let id = UUID()
        anchor.configure(id: id, relay: relay, isActive: true, claimsWhileActive: false)
        XCTAssertFalse(focus.holds(id), "a pane holds nothing until it is touched")
        let recognizer = try XCTUnwrap(window.gestureRecognizers?.first { $0.delegate === anchor })
        XCTAssertFalse(anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 300, y: 50), in: window)),
                       "the watcher never takes a touch")
        XCTAssertTrue(focus.holds(id))
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 50, y: 50), in: window))
        XCTAssertFalse(focus.holds(id), "a touch on the terminal takes the chords back")
        anchor.configure(id: id, relay: relay, isActive: false, claimsWhileActive: false)
        XCTAssertNil(window.gestureRecognizers?.first { $0.delegate === anchor }, "a hidden pane stops watching")
        anchor.configure(id: id, relay: relay, isActive: true, claimsWhileActive: true)
        XCTAssertTrue(focus.holds(id), "the artifacts page claims for as long as it shows")
        anchor.tearDown()
        XCTAssertFalse(focus.holds(id))
    }

    /// ⌘L on a Duo pane raises its own sheet; Esc must leave the browser's
    /// chords with the pane, not hand them to the terminal until the next
    /// touch. The sheet pauses the claim: touches under it change nothing.
    func testThePanesOwnSheetPausesItsClaimRatherThanEndingIt() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        defer { window.isHidden = true }
        let anchor = ArtifactsKeyboardFocusAnchorView(frame: CGRect(x: 200, y: 0, width: 200, height: 200))
        window.addSubview(anchor)
        let relay = ArtifactsShortcutRelay()
        let id = UUID()
        anchor.configure(id: id, relay: relay, isActive: true, claimsWhileActive: false)
        let recognizer = try XCTUnwrap(window.gestureRecognizers?.first { $0.delegate === anchor })
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 300, y: 50), in: window))
        XCTAssertTrue(focus.holds(id))

        anchor.configure(id: id, relay: relay, isActive: true, claimsWhileActive: false, pausesTouches: true)
        XCTAssertTrue(focus.holds(id), "raising its own sheet keeps the pane's claim")
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 50, y: 50), in: window))
        XCTAssertTrue(focus.holds(id), "a touch in the sheet, over the terminal, is not a touch on the terminal")

        anchor.configure(id: id, relay: relay, isActive: true, claimsWhileActive: false)
        XCTAssertTrue(focus.holds(id), "dismissing the sheet leaves the chords with the pane")
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 50, y: 50), in: window))
        XCTAssertFalse(focus.holds(id), "a touch on the terminal still takes them back")
    }

    /// A focused page takes the keyboard's presses before SwiftUI's hidden
    /// buttons see them, so its surface carries the browser's chords as key
    /// commands on the page's responder chain, while a browser holds the
    /// keyboard in that window.
    func testAFocusedPagesSurfaceRelaysTheBrowsersChords() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let surface = ArtifactWebSurfaceContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.addSubview(surface)
        let selector = #selector(ArtifactWebSurfaceContainer.browserShortcutFired(_:))
        func command(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand? {
            surface.keyCommands?.first { $0.action == selector && $0.input == input && $0.modifierFlags == flags }
        }
        XCTAssertNil(command("t", .command), "no browser holds the keyboard, so the page keeps its keys")

        let relay = ArtifactsShortcutRelay()
        var fired: [ArtifactsBrowserCommand] = []
        relay.attach(available: [.overview, .newTab, .selectTab(3)]) { fired.append($0) }
        let id = UUID()
        focus.claim(id, anchor: surface, relay: relay)
        let overview = try XCTUnwrap(command("\\", [.command, .shift]), "⌘⇧\\ waits on the page's chain")
        let newTab = try XCTUnwrap(command("t", .command))
        let third = try XCTUnwrap(command("3", .command))
        let reload = try XCTUnwrap(command("r", .command))
        XCTAssertTrue(surface.canPerformAction(selector, withSender: overview))
        XCTAssertFalse(surface.canPerformAction(selector, withSender: reload), "an unavailable chord passes on")
        surface.browserShortcutFired(overview)
        surface.browserShortcutFired(newTab)
        surface.browserShortcutFired(third)
        XCTAssertEqual(fired, [.overview, .newTab, .selectTab(3)])

        relay.mounted(available: [.newTab]) { fired.append($0) }
        relay.mounted(available: [.newTab]) { fired.append($0) }
        relay.unmounted()
        XCTAssertTrue(relay.fire(.newTab), "a replacement that appeared before its predecessor left keeps the handler")
        relay.unmounted()
        XCTAssertFalse(relay.fire(.newTab), "the last scope to leave drops the handler, and the view it captured")
        focus.release(id)
        XCTAssertNil(command("t", .command))
        XCTAssertFalse(surface.canPerformAction(selector, withSender: newTab))
    }

    /// Mounted as a surface's background, as the page and the Duo pane
    /// mount it, the anchor spans the surface: a touch anywhere on it claims.
    func testTheKeyboardScopeSpansTheSurfaceItBacks() throws {
        let focus = ArtifactsKeyboardFocus.shared
        focus.releaseAllForTesting()
        defer { focus.releaseAllForTesting() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let relay = ArtifactsShortcutRelay()
        let id = UUID()
        let surface = Color.clear
            .frame(width: 240, height: 180)
            .background {
                ArtifactsBrowserKeyboardScope(focusID: id, relay: relay, watches: true, claimsWhileActive: false,
                                              holdsKeyboard: false, available: [], perform: { _ in })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        window.rootViewController = UIHostingController(rootView: surface)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func anchorView(in view: UIView) -> ArtifactsKeyboardFocusAnchorView? {
            if let anchor = view as? ArtifactsKeyboardFocusAnchorView { return anchor }
            return view.subviews.lazy.compactMap(anchorView(in:)).first
        }
        var found: ArtifactsKeyboardFocusAnchorView?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded()
            if let anchor = anchorView(in: window), anchor.bounds.width > 0 { found = anchor; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let anchor = try XCTUnwrap(found, "the scope mounted no anchor")
        let frame = anchor.convert(anchor.bounds, to: window)
        XCTAssertEqual(frame.size.width, 240, accuracy: 0.5)
        XCTAssertEqual(frame.size.height, 180, accuracy: 0.5)
        let recognizer = try XCTUnwrap(window.gestureRecognizers?.first { $0.delegate === anchor })
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: frame.maxX - 4, y: frame.maxY - 4), in: window))
        XCTAssertTrue(focus.holds(id), "a touch near the surface's corner is a touch on it")
        _ = anchor.gestureRecognizer(recognizer, shouldReceive: FakeTouch(at: CGPoint(x: 10, y: 290), in: window))
        XCTAssertFalse(focus.holds(id))
    }

    /// The editing address stays a row's height. A text field hugs its
    /// height only weakly, and the toolbar sits above flexible content, so
    /// without that the field took ~260 pt of a landscape iPad.
    func testTheEditingAddressKeepsTheRowsHeight() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        let row = VStack(spacing: 0) {
            ArtifactAddressField(text: .constant("localhost:8001/"), placeholder: "host:path or a port", focusToken: UUID(),
                                 onSubmit: {}, onCancel: {}, onMove: { _ in })
                .frame(maxWidth: .infinity, minHeight: 44)
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        window.rootViewController = UIHostingController(rootView: row)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func field(in view: UIView) -> ArtifactAddressTextField? {
            if let field = view as? ArtifactAddressTextField { return field }
            return view.subviews.lazy.compactMap(field(in:)).first
        }
        var found: ArtifactAddressTextField?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded()
            if let candidate = field(in: window), candidate.bounds.width > 0 { found = candidate; break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let address = try XCTUnwrap(found, "the row mounted no field")
        XCTAssertGreaterThan(address.bounds.height, 10)
        XCTAssertLessThanOrEqual(address.bounds.height, 44, "the field should hug its line, not take the content's height")
    }

    // MARK: - Reopen and share

    func testTheClosedTabStackKeepsTheLatestTwentyAndForgetsGoneHosts() {
        var stack = ArtifactClosedTabStack()
        for index in 0..<25 { stack.push(tab("t\(index)", .file(path: "/\(index)"), host: index % 2 == 0 ? "h1" : "h2")) }
        XCTAssertEqual(stack.tabs.count, ArtifactClosedTabStack.capacity)
        XCTAssertEqual(stack.tabs.first?.id, "t5")
        stack.retain { $0.hostID == "h1" }
        XCTAssertEqual(stack.pop()?.id, "t24")
        XCTAssertFalse(stack.contains { $0.hostID == "h2" })
    }

    func testSharingStagesTheCompleteFileUnderItsOwnName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache/key", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("Quarterly Report.pdf")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let first = try XCTUnwrap(ArtifactShareStaging.request(for: .ready(file), in: staging))
        XCTAssertEqual(first.fileURL.lastPathComponent, "Quarterly Report.pdf")
        XCTAssertNotEqual(first.fileURL, file, "the sheet gets its own copy")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), bytes)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), bytes, "an evicted cache entry leaves the shared copy whole")
        try bytes.write(to: file)
        let second = try XCTUnwrap(ArtifactShareStaging.request(for: .ready(file), in: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path), "an earlier share's copy goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertNil(ArtifactShareStaging.request(for: .unavailable("downloading"), in: staging), "never a partial file")
        XCTAssertNil(ArtifactShareStaging.request(for: .none, in: staging))
    }

    // MARK: - Forward banner and unavailable states

    /// The address bar already shows the tab title, so the banner's dim line
    /// names a rule only when its label says something else, and notes the
    /// tunnel only for plain http.
    func testTheForwardBannerSkipsARepeatedTitleAndNotesTheTunnelOnlyForHTTP() {
        let note = String(localized: "the SSH tunnel encrypts this connection")
        func detail(_ label: String, _ title: String, http: Bool) -> String {
            ArtifactTabContentView.forwardDetail(ruleLabel: label, tabTitle: title, isPlainHTTP: http)
        }
        XCTAssertEqual(detail("localhost:8001", "localhost:8001", http: true), note)
        XCTAssertEqual(detail("localhost:8001", "localhost:8001", http: false), "")
        XCTAssertEqual(detail("", "dev", http: false), "")
        XCTAssertEqual(detail("vite", "localhost:5173", http: true), "vite · " + note)
        XCTAssertEqual(detail("vite", "localhost:5173", http: false), "vite")
    }

    /// A failed load offers a retry while its host is reachable. The other
    /// unavailable states have their own action or none.
    func testOnlyAFailedLoadOnAReachableHostOffersARetry() {
        let store = ArtifactsBrowserPreviewStore(scene: "failed")
        XCTAssertTrue(store.canRetry("failed"))
        XCTAssertTrue(store.canRefreshOrReconnect("failed"))
        for id in ["missing", "too-large", "no-forwarding", "loading", "offline", "plan"] {
            XCTAssertNotNil(store.tab(id), id)
            XCTAssertFalse(store.canRetry(id), id)
        }
    }

    /// A page counts as refreshable only once forwarded, so its failed forward
    /// comes back through retry alone, and that retry reaches the store.
    func testAFailedPageRetriesThroughThePageSessionWhileItsHostIsLive() throws {
        let store = ArtifactsBrowserPreviewStore(scene: "retry")
        let page = try XCTUnwrap(store.tab("failed-page"))
        XCTAssertEqual(store.presentation(for: page.id).state, .live, "the badge follows the host, as its header does")
        XCTAssertFalse(store.presentation(for: page.id).canRefresh)
        XCTAssertTrue(store.canRetry(page.id))
        XCTAssertTrue(store.canRefreshOrReconnect(page.id))
        ArtifactPageSession().refresh(page, store: store)
        XCTAssertEqual(store.refreshedTabIDs, [page.id])

        let offline = try XCTUnwrap(store.tab("failed-offline"))
        XCTAssertFalse(store.isLive(hostID: offline.hostID))
        XCTAssertFalse(store.canRetry(offline.id))
        XCTAssertFalse(store.canRefreshOrReconnect(offline.id))
        ArtifactPageSession().refresh(offline, store: store)
        XCTAssertEqual(store.refreshedTabIDs, [page.id])
    }

    func testQuickOpenDraftSurvivesSheetAndInlineMigration() {
        let request = ArtifactAddressEditRequest.newTab(currentHostID: "h1")
        let sheet = ArtifactAddressEntry(request)
        sheet.input = ":35757/next.html"
        let inline = ArtifactAddressEntry(sheet.request)
        sheet.cancel()
        XCTAssertEqual(inline.input, ":35757/next.html")
        XCTAssertEqual(inline.request, request)
        XCTAssertEqual(inline.request.placement, .newTab)
        XCTAssertEqual(inline.request.currentHostID, "h1")

        inline.input += "?view=full"
        let restoredSheet = ArtifactAddressEntry(inline.request)
        inline.cancel()
        XCTAssertEqual(restoredSheet.input, ":35757/next.html?view=full")
        XCTAssertEqual(restoredSheet.request, request)
        XCTAssertEqual(request.initialText, "")
    }

    func testCancelledQuickOpenStartsWithAnEmptyDraft() {
        let cancelled = ArtifactAddressEntry(.newTab(currentHostID: "h1"))
        cancelled.input = ":35757/next.html"
        cancelled.cancel()

        let next = ArtifactAddressEntry(.newTab(currentHostID: "h1"))
        XCTAssertEqual(next.input, "")
        XCTAssertNotEqual(next.request.id, cancelled.request.id)
        XCTAssertEqual(next.request.currentHostID, "h1")
    }

    func testAddressMigrationPreservesAnEmptyDraftAndItsNavigationRequest() {
        let request = ArtifactAddressEditRequest.edit(tab("page", .page(scheme: "http", port: 35757, path: "/")), webURL: nil)
        let inline = ArtifactAddressEntry(request)
        XCTAssertFalse(inline.input.isEmpty)
        inline.input = ""

        let sheet = ArtifactAddressEntry(inline.request)
        inline.cancel()
        XCTAssertEqual(sheet.input, "")
        XCTAssertEqual(sheet.request, request)
        XCTAssertEqual(sheet.request.placement, .navigate(tabID: "page"))
        XCTAssertEqual(sheet.request.currentHostID, "h1")
    }

    private func tab(_ id: String, _ target: ArtifactsTarget, host: String = "h1") -> ArtifactTab {
        ArtifactTab(id: id, hostID: host, hostLabel: "devbox", target: target, title: id, openedAt: 1, viewedAt: 1)
    }
}

/// A touch at a point, for the window's watcher.
private final class FakeTouch: UITouch {
    private let point: CGPoint
    private weak var source: UIView?

    init(at point: CGPoint, in view: UIView) {
        self.point = point
        self.source = view
        super.init()
    }

    override func location(in view: UIView?) -> CGPoint {
        guard let source, let view else { return point }
        return source.convert(point, to: view)
    }
}
