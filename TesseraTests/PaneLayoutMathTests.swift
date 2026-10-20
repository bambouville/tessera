import XCTest
import CoreGraphics
import UIKit
import SwiftUI
import TmuxControl
@testable import Tessera

final class MoshRenderSurfaceDeclarationTests: XCTestCase {
    private func declarations(
        paneIDs: [PaneId] = [PaneId(1), PaneId(2)],
        activePaneID: PaneId? = PaneId(1),
        overlay: (windowID: WindowId, paneID: PaneId)? = nil,
        usesDetachedOverlay: Bool = true
    ) -> [SurfaceDeclaration] {
        MoshHistorySurfacePolicy.declarations(
            windowID: WindowId(7), paneIDs: paneIDs, activePaneID: activePaneID,
            overlay: overlay, usesDetachedOverlay: usesDetachedOverlay
        )
    }

    func test_unfocusedReaderAddsPinnedOverlayWithoutChangingExistingDeclarations() {
        let before = declarations()
        let reading = declarations(overlay: (WindowId(7), PaneId(2)))
        XCTAssertEqual(Array(reading.prefix(before.count)), before)
        XCTAssertEqual(reading.last, SurfaceDeclaration(
            surfaceID: SurfaceId("overlay:%2"), presentation: .overlay,
            windowID: WindowId(7), paneID: PaneId(2)
        ))
        XCTAssertEqual(reading.count, 3)
        XCTAssertNil(reading[0].windowID)
        XCTAssertNil(reading[0].paneID)
    }

    func test_onlyAReaderOfTheFocusedPaneBlocksItsClicks() {
        func covers(_ readyOverlay: (windowID: WindowId, paneID: PaneId)?, ready: Bool = true,
                    live: Bool = false, focused: PaneId? = PaneId(1)) -> Bool {
            MoshHistorySurfacePolicy.historyCoversFocusedPane(
                liveHistoryRevealed: live, overlayContentReady: ready, readyOverlay: readyOverlay,
                windowID: WindowId(7), focusedPaneID: focused
            )
        }
        XCTAssertTrue(covers((WindowId(7), PaneId(1))))
        XCTAssertFalse(covers((WindowId(7), PaneId(2))), "reading another pane leaves the focused one live")
        XCTAssertFalse(covers(nil, ready: false))
        XCTAssertTrue(covers(nil, ready: false, live: true), "compact layouts read on the live surface")
        // Unknown reader, window or focus stays blocked.
        XCTAssertTrue(covers(nil))
        XCTAssertTrue(covers((WindowId(8), PaneId(2))))
        XCTAssertTrue(covers((WindowId(7), PaneId(2)), focused: nil))
    }

    func test_focusedReaderDoesNotDuplicateOverlay() {
        XCTAssertEqual(declarations(overlay: (WindowId(7), PaneId(1))), declarations())
    }

    func test_foreignOrRemovedReaderIsNotDeclared() {
        XCTAssertEqual(declarations(overlay: (WindowId(8), PaneId(2))), declarations())
        XCTAssertEqual(declarations(overlay: (WindowId(7), PaneId(3))), declarations())
    }

    func test_readerSurvivesMissingActivePaneAndDismissalRemovesOnlyReaderDeclaration() {
        let reading = declarations(activePaneID: nil, overlay: (WindowId(7), PaneId(2)))
        XCTAssertEqual(reading.map(\.surfaceID), [.live, SurfaceId("overlay:%2")])
        let dismissed = declarations(activePaneID: nil)
        XCTAssertEqual(dismissed, [reading[0]])
    }

    func test_compactAndSinglePaneKeepOnlyLivePainter() {
        for isPhone in [false, true] {
            for rendersAsGrid in [false, true] where isPhone || !rendersAsGrid {
                let surfaces = declarations(
                    overlay: (WindowId(7), PaneId(2)),
                    usesDetachedOverlay: MoshHistorySurfacePolicy.usesDetachedOverlay(
                        isPhone: isPhone, windowRendersAsPaneGrid: rendersAsGrid
                    )
                )
                XCTAssertEqual(surfaces, [SurfaceDeclaration(surfaceID: .live, presentation: .single)])
            }
        }
    }

    func test_unhydratedPanesPreserveFocusedDeclarationWithoutRetainingUnknownReader() {
        let surfaces = declarations(paneIDs: [], overlay: (WindowId(7), PaneId(2)))
        XCTAssertEqual(surfaces, declarations(paneIDs: []))
        XCTAssertEqual(surfaces.map(\.surfaceID), [.live, SurfaceId("overlay:%1")])
    }

    func test_readerDeclarationAndRetirementPreserveLiveOwnerAndOtherCapture() throws {
        let snapshot = TmuxSnapshot(
            sessionID: SessionId(0), sessionName: "work", activeWindowID: WindowId(7),
            windows: [.init(id: WindowId(7), name: "split", activePaneID: PaneId(1),
                            panes: [.init(id: PaneId(1), isActive: true), .init(id: PaneId(2))])],
            authority: .unknown
        )
        let focusedSurface = SurfaceId("overlay:%1")
        let readerSurface = SurfaceId("overlay:%2")
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24))
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot)
        _ = ledger.reduce(.surfacesDeclared(declarations()), snapshot: snapshot)
        let liveOwner = try XCTUnwrap(ledger.owner(for: .live))

        _ = ledger.reduce(.scrollbackRequested(focusedSurface, pointsY: 1, isInertial: false))
        let reading = declarations(overlay: (WindowId(7), PaneId(2)))
        _ = ledger.reduce(.surfacesDeclared(reading))
        XCTAssertEqual(ledger.owner(for: .live), liveOwner)
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: focusedSurface))

        _ = ledger.reduce(.scrollbackRequested(readerSurface, pointsY: 1, isInertial: false))
        _ = ledger.reduce(.surfacesDeclared(reading))
        _ = ledger.reduce(.scrollbackReturnedToTail(focusedSurface))
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: focusedSurface))
        XCTAssertEqual(ledger.owner(for: .live), liveOwner)
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: readerSurface))

        _ = ledger.reduce(.surfacesDeclared(declarations()))
        XCTAssertNil(ledger.owner(for: readerSurface))
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: readerSurface))
        XCTAssertEqual(ledger.owner(for: .live), liveOwner)
        _ = ledger.reduce(.scrollbackRequested(focusedSurface, pointsY: 1, isInertial: false))
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: focusedSurface))
    }

    func test_splitInputReturnsOnlyItsFocusedPaneToTail() throws {
        let snapshot = TmuxSnapshot(
            sessionID: SessionId(0), sessionName: "work", activeWindowID: WindowId(7),
            windows: [.init(id: WindowId(7), name: "split", activePaneID: PaneId(1),
                            panes: [.init(id: PaneId(1), isActive: true), .init(id: PaneId(2))])],
            authority: .unknown
        )
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.clientSize(columns: 80, rows: 24))
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot)
        _ = ledger.reduce(.surfacesDeclared(declarations(overlay: (WindowId(7), PaneId(2)))))
        let inputSurface = try XCTUnwrap(MoshHistorySurfacePolicy.inputSurfaceID(
            focusedPaneID: PaneId(1), usesDetachedOverlay: true
        ))
        let otherReader = SurfaceId("overlay:%2")
        _ = ledger.reduce(.scrollbackRequested(inputSurface, pointsY: -20, isInertial: false))
        _ = ledger.reduce(.scrollbackRequested(otherReader, pointsY: -20, isInertial: false))
        let otherOwner = ledger.owner(for: otherReader)
        _ = ledger.reduce(.scrollbackReturnedToTail(inputSurface))
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: inputSurface))
        XCTAssertTrue(ledger.isHistoryPresentationPending(for: otherReader))
        XCTAssertEqual(ledger.owner(for: otherReader), otherOwner)
        // Typing after focusing the reader returns that pane to its tail.
        let readerInput = try XCTUnwrap(MoshHistorySurfacePolicy.inputSurfaceID(
            focusedPaneID: PaneId(2), usesDetachedOverlay: true
        ))
        _ = ledger.reduce(.scrollbackReturnedToTail(readerInput))
        XCTAssertFalse(ledger.isHistoryPresentationPending(for: otherReader))
        XCTAssertEqual(MoshHistorySurfacePolicy.inputSurfaceID(
            focusedPaneID: PaneId(1), usesDetachedOverlay: false
        ), .live)
        XCTAssertNil(MoshHistorySurfacePolicy.inputSurfaceID(
            focusedPaneID: nil, usesDetachedOverlay: true
        ))
    }
}

/// Frame-math tests for the split-pane grid: each terminal surface must compute
/// the same integer cell grid as tmux, or live escapes mis-render.
final class PaneLayoutMathTests: XCTestCase {

    func test_terminalSurfaceSizePreservesGridAfterPixelSnapping() {
        for hundredths in 1000...2400 {
            let font = TerminalFontResolver.uiFont(
                id: TerminalFontCatalog.defaultID,
                size: CGFloat(hundredths) / 100
            )
            for scale: CGFloat in [2, 3] {
                let cell = TerminalCellMetrics.cellSize(font: font, scale: scale)
                XCTAssertEqual(cell.height, cell.height.rounded(), "row lengths must stay exact")
                for count in 10...200 {
                    let grid = CGSize(width: CGFloat(count) * cell.width, height: CGFloat(count) * cell.height)
                    let surface = TerminalCellMetrics.surfaceSize(for: grid, cellSize: cell)
                    let columns = Int((surface.width * scale).rounded() / scale / cell.width)
                    let rows = Int((surface.height * scale).rounded() / scale / cell.height)
                    if (count >= 20 && columns != count) || (count <= 120 && rows != count)
                        || surface.height != grid.height {
                        XCTFail("font=\(font.pointSize) scale=\(scale) count=\(count): got \(columns)x\(rows)")
                        return
                    }
                }
            }
        }
    }

    func test_terminalSurfaceSizeRepairsFractionalCellRegression() {
        let font = TerminalFontResolver.uiFont(id: TerminalFontCatalog.defaultID, size: 15.0677)
        let cell = TerminalCellMetrics.cellSize(font: font, scale: 3)
        XCTAssertEqual(cell.width, 28.0 / 3.0)
        let grid = CGSize(width: 46 * cell.width, height: 24 * cell.height)
        let snappedExactWidth = (grid.width * 3).rounded() / 3
        XCTAssertEqual(Int(snappedExactWidth / cell.width), 45, "exact framing must reproduce the lost column")

        let surface = TerminalCellMetrics.surfaceSize(for: grid, cellSize: cell)
        XCTAssertEqual(surface.height, grid.height, "preserve the scrollback viewport height")
        XCTAssertEqual(Int((surface.width * 3).rounded() / 3 / cell.width), 46)
        XCTAssertEqual(Int((surface.height * 3).rounded() / 3 / cell.height), 24)
    }

    func test_scrollPaneUsesViewportCellsAndExcludesBorders() {
        let panes: [(PaneId, CellRect)] = [
            (PaneId(1), CellRect(width: 4, height: 4, x: 0, y: 1)),
            (PaneId(2), CellRect(width: 5, height: 4, x: 5, y: 1))
        ]
        func target(_ point: CGPoint, offset: CGPoint = .zero, inset: CGPoint = .zero) -> PaneId? {
            PaneLayoutMath.scrollPane(
                at: point, contentOffset: offset, canvasInset: inset,
                cellSize: CGSize(width: 10, height: 20), panes: panes, fallback: PaneId(1)
            )
        }
        XCTAssertEqual(target(CGPoint(x: 50, y: 20)), PaneId(2))
        XCTAssertEqual(target(CGPoint(x: 99.9, y: 99.9)), PaneId(2))
        XCTAssertEqual(target(CGPoint(x: 45, y: 40)), PaneId(1), "divider keeps focused routing")
        XCTAssertEqual(target(CGPoint(x: 60, y: 10)), PaneId(1), "title row is a border")
        XCTAssertEqual(target(CGPoint(x: 100, y: 40)), PaneId(1), "right edge is exclusive")
        XCTAssertEqual(target(CGPoint(x: -1, y: 40)), PaneId(1))
        XCTAssertEqual(target(CGPoint(x: 67, y: 1053), offset: CGPoint(x: 5, y: 1000),
                              inset: CGPoint(x: 2, y: 3)), PaneId(2))
    }

    func test_scrollPaneStackedLayoutAndInvalidGeometry() {
        let panes = [
            (PaneId(1), CellRect(width: 10, height: 2, x: 0, y: 0)),
            (PaneId(2), CellRect(width: 10, height: 2, x: 0, y: 3))
        ]
        XCTAssertEqual(PaneLayoutMath.scrollPane(
            at: CGPoint(x: 20, y: 60), contentOffset: .zero,
            cellSize: CGSize(width: 10, height: 20), panes: panes, fallback: PaneId(1)
        ), PaneId(2))
        XCTAssertEqual(PaneLayoutMath.scrollPane(
            at: CGPoint(x: 20, y: 50), contentOffset: .zero,
            cellSize: CGSize(width: 10, height: 20), panes: panes, fallback: PaneId(1)
        ), PaneId(1))
        XCTAssertEqual(PaneLayoutMath.scrollPane(
            at: .zero, contentOffset: .zero, cellSize: .zero, panes: panes, fallback: PaneId(1)
        ), PaneId(1))
    }

    func test_scrollPaneSingleAndZoomedCanvasKeepsFocusedPane() {
        for panes: [(PaneId, CellRect)] in [[], [(PaneId(7), CellRect(width: 10, height: 5, x: 0, y: 0))]] {
            XCTAssertEqual(PaneLayoutMath.scrollPane(
                at: CGPoint(x: 95, y: 95), contentOffset: .zero,
                cellSize: CGSize(width: 10, height: 20), panes: panes, fallback: PaneId(7)
            ), PaneId(7))
        }
    }

    func test_scrollGestureRetainsStartingPaneThroughMotionAndGlide() {
        var target = TmuxScrollGestureTarget()
        target.begin(paneID: PaneId(2))
        // Motion across a divider, a focus update, and synthetic glide frames
        // all read the same snapshot; only a new physical gesture replaces it.
        for _ in 0..<120 { XCTAssertEqual(target.paneID, PaneId(2)) }
        target.begin(paneID: PaneId(1))
        XCTAssertEqual(target.paneID, PaneId(1))
        target.begin(paneID: nil)
        XCTAssertNil(target.paneID)
    }

    private func root(_ string: String) -> LayoutNode {
        guard let layout = WindowLayout.parse(string) else {
            fatalError("fixture layout failed to parse: \(string)")
        }
        return layout.root
    }

    private func frame(_ frames: [PaneFrame], _ pane: Int) -> PaneFrame {
        guard let f = frames.first(where: { $0.paneId == PaneId(pane) }) else {
            fatalError("no frame for pane %\(pane)")
        }
        return f
    }

    func test_compactTmuxClientSizingProjectsFocusedPaneToPhoneViewport() throws {
        let cell = CGSize(width: 10, height: 20)
        let viewport = try XCTUnwrap(
            CompactTmuxClientSizing.viewportCells(
                for: CGSize(width: 390, height: 300),
                cellSize: cell
            )
        )
        XCTAssertEqual(viewport.cols, 39)
        XCTAssertEqual(viewport.rows, 15)

        func ratio(_ window: CellRect, _ focus: CellRect) -> (cols: Int, rows: Int) {
            CompactTmuxClientSizing.clientSize(
                for: viewport,
                layout: nil,
                focusPaneId: nil,
                windowRect: window,
                focusRect: focus
            )
        }

        let single = ratio(
            CellRect(width: 80, height: 24, x: 0, y: 0),
            CellRect(width: 80, height: 24, x: 0, y: 0)
        )
        XCTAssertEqual(single.cols, 39)
        XCTAssertEqual(single.rows, 15)

        let leftHalf = ratio(
            CellRect(width: 80, height: 24, x: 0, y: 0),
            CellRect(width: 40, height: 24, x: 0, y: 0)
        )
        XCTAssertEqual(leftHalf.cols, 78, "a 50/50 split needs two phone widths")
        XCTAssertEqual(leftHalf.rows, 15)

        let rightHalf = ratio(
            CellRect(width: 80, height: 24, x: 0, y: 0),
            CellRect(width: 39, height: 24, x: 41, y: 0)
        )
        XCTAssertEqual(rightHalf.cols, 80, "the gutter-adjusted right pane still gets 39 columns")
        XCTAssertEqual(rightHalf.rows, 15)

        let stackedBottom = ratio(
            CellRect(width: 80, height: 24, x: 0, y: 0),
            CellRect(width: 80, height: 11, x: 0, y: 13)
        )
        XCTAssertEqual(stackedBottom.cols, 39)
        XCTAssertEqual(stackedBottom.rows, 33, "a short stacked pane expands the client height")

        // With the layout tree the size is solved against tmux's resize: a
        // 59-of-200-column right pane needs 181 columns, not the ratio's 170,
        // because tmux takes a shrink from both panes in turn.
        let narrowRight = try XCTUnwrap(WindowLayout.parse("0000,200x40,0,0{140x40,0,0,0,59x40,141,0,1}"))
        let solved = CompactTmuxClientSizing.clientSize(
            for: (cols: 50, rows: 40),
            layout: narrowRight,
            focusPaneId: PaneId(1),
            windowRect: narrowRight.root.rect,
            focusRect: CellRect(width: 59, height: 40, x: 141, y: 0)
        )
        XCTAssertEqual(solved.cols, 181)
        XCTAssertEqual(solved.rows, 40)

        var memo = TmuxCompactReprojectionMemo()
        func reproject(
            last: (cols: Int, rows: Int),
            window: CellRect,
            focus: CellRect,
            layout: WindowLayout? = nil,
            pane: PaneId? = nil
        ) -> Bool {
            CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: last,
                layout: layout,
                focusPaneId: pane,
                windowRect: window,
                focusRect: focus,
                memo: &memo,
                diagnostics: .ssh
            )
        }
        XCTAssertTrue(
            reproject(
                last: viewport,
                window: CellRect(width: 80, height: 24, x: 0, y: 0),
                focus: CellRect(width: 40, height: 24, x: 0, y: 0)
            ),
            "initial split hydration must expand an unprojected phone viewport"
        )
        XCTAssertTrue(
            reproject(
                last: (78, 15),
                window: CellRect(width: 78, height: 15, x: 0, y: 0),
                focus: CellRect(width: 78, height: 15, x: 0, y: 0)
            ),
            "a local collapse on the phone-owned canvas must return to one viewport"
        )
        XCTAssertFalse(
            reproject(
                last: (78, 15),
                window: CellRect(width: 160, height: 50, x: 0, y: 0),
                focus: CellRect(width: 80, height: 50, x: 0, y: 0)
            ),
            "a larger peer layout must not make the phone reclaim tmux sizing"
        )
        // The layout tmux leaves after the solved advertisement holds.
        let fitted = try XCTUnwrap(WindowLayout.parse("0000,78x15,0,0{39x15,0,0,0,38x15,40,0,1}"))
        XCTAssertEqual(
            CompactTmuxClientSizing.clientSize(
                for: viewport,
                layout: fitted,
                focusPaneId: PaneId(0),
                windowRect: fitted.root.rect,
                focusRect: CellRect(width: 39, height: 15, x: 0, y: 0)
            ).cols,
            78
        )
        XCTAssertFalse(
            reproject(
                last: (78, 15),
                window: fitted.root.rect,
                focus: CellRect(width: 39, height: 15, x: 0, y: 0),
                layout: fitted,
                pane: PaneId(0)
            ),
            "the solved canvas is a fixed point"
        )

        XCTAssertNil(
            CompactTmuxClientSizing.viewportCells(
                for: CGSize(width: 5, height: 10),
                cellSize: cell
            ),
            "pre-layout sub-cell viewports must never resize tmux"
        )
    }

    /// A measured frame that keeps the phone's cell grid is judged like a
    /// layout update: it must neither reclaim a peer's grid nor restart a
    /// held resize cycle by re-pushing the current layout's projection. A
    /// new grid is the phone's own resize and always advertises.
    func test_compactMeasuredViewportWithTheSameGridIsJudgedLikeALayoutUpdate() {
        func advertises(
            _ viewport: (cols: Int, rows: Int),
            previous: (cols: Int, rows: Int)?,
            last: (cols: Int, rows: Int),
            window: (Int, Int),
            focus: (Int, Int),
            memo: inout TmuxCompactReprojectionMemo
        ) -> Bool {
            CompactTmuxClientSizing.shouldAdvertiseMeasuredViewport(
                viewport,
                previousViewport: previous,
                lastClientSize: last,
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: window.0, height: window.1, x: 0, y: 0),
                focusRect: CellRect(width: focus.0, height: focus.1, x: 0, y: 0),
                memo: &memo,
                diagnostics: .ssh
            )
        }
        let phone = (cols: 39, rows: 15)
        // A larger peer's grid whose projection (104x15) differs from what
        // the phone last advertised.
        var memo = TmuxCompactReprojectionMemo()
        XCTAssertFalse(
            advertises(phone, previous: phone, last: (78, 15), window: (160, 50), focus: (60, 50), memo: &memo),
            "an unchanged grid must not reclaim a peer's canvas"
        )
        XCTAssertTrue(advertises(phone, previous: nil, last: (78, 15), window: (160, 50), focus: (60, 50), memo: &memo))
        XCTAssertTrue(advertises(phone, previous: (40, 15), last: (78, 15), window: (160, 50), focus: (60, 50), memo: &memo))
        // The phone's own canvas drifted under it: the unchanged grid still
        // repairs it, as a layout update would.
        var own = TmuxCompactReprojectionMemo()
        XCTAssertTrue(advertises(phone, previous: phone, last: (78, 15), window: (78, 15), focus: (37, 15), memo: &own))

        // The ratio two-cycle (45 of 200 columns) stopped by the guard.
        let viewport = (cols: 50, rows: 40)
        var held = TmuxCompactReprojectionMemo()
        var last = viewport
        var window = 200
        var decisions: [Bool] = []
        for _ in 0..<5 {
            let reprojects = CompactTmuxClientSizing.shouldReprojectLayout(
                viewport: viewport,
                lastClientSize: last,
                layout: nil,
                focusPaneId: nil,
                windowRect: CellRect(width: window, height: 40, x: 0, y: 0),
                focusRect: CellRect(width: window == 200 ? 45 : 56, height: 40, x: 0, y: 0),
                memo: &held,
                diagnostics: .ssh
            )
            decisions.append(reprojects)
            guard reprojects else { break }
            last = (window == 200 ? 223 : 200, 40)
            window = last.cols
        }
        XCTAssertEqual(decisions, [true, true, true, true, false])
        XCTAssertTrue(held.isHoldingCycle)
        XCTAssertFalse(
            advertises(viewport, previous: viewport, last: last, window: (window, 40), focus: (window == 200 ? 45 : 56, 40), memo: &held),
            "an unchanged grid must not restart a held cycle"
        )
        XCTAssertTrue(held.isHoldingCycle)
    }

    @MainActor
    func test_compactShapeOnlyFlatteningReprojectsTheSSHCanvas() throws {
        let controller = TmuxController()
        controller.sendBytesAdmitting = { _ in true }
        defer { controller.reset() }
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.sendControlCommand("refresh-client -C 200,40")
        let published = try XCTUnwrap(controller.lastPublishedClientSize)
        let nested = try XCTUnwrap(WindowLayout.parse("0000,200x40,0,0{100x40,0,0,0,99x40,101,0{58x40,101,0,2,40x40,160,0,1}}"))
        let flat = try XCTUnwrap(WindowLayout.parse("0000,200x40,0,0{100x40,0,0,0,58x40,101,0,2,40x40,160,0,1}"))
        let focus = CellRect(width: 40, height: 40, x: 160, y: 0)
        func key(_ layout: WindowLayout) -> String {
            TmuxCompactClientSizing.observationKey(mode: "tmuxControl", windowId: WindowId(0),
                focusPaneId: PaneId(1), layout: layout, windowRect: layout.root.rect, focusRect: focus)
        }
        XCTAssertNotEqual(key(nested), key(flat))
        var memo = TmuxCompactReprojectionMemo()
        func reprojects(_ layout: WindowLayout) -> Bool {
            CompactTmuxClientSizing.shouldReprojectLayout(viewport: (50, 40), lastClientSize: (published.columns, published.rows),
                layout: layout, focusPaneId: PaneId(1), windowRect: layout.root.rect,
                focusRect: focus, memo: &memo, diagnostics: .ssh)
        }
        XCTAssertFalse(reprojects(nested))
        XCTAssertTrue(reprojects(flat))
        XCTAssertEqual(CompactTmuxClientSizing.clientSize(for: (50, 40), layout: flat,
            focusPaneId: PaneId(1), windowRect: flat.root.rect, focusRect: focus).cols, 230)
    }

    @MainActor
    func test_compactSSHWriteBeforeConnectionReportsFailure() {
        let session = SSHSession(host: Host(transport: .ssh))
        XCTAssertFalse(session.sendAdmitting(Array("refresh-client -C 202,40\n".utf8)),
            "a disconnected SSH request cannot enter the ordered writer")
    }

    @MainActor
    func test_compactMoshSideChannelWriteAfterDisconnectReportsFailure() {
        let channel = TmuxControlChannel(host: Host(transport: .mosh), sessionName: "compact-unit", initialSize: nil)
        channel.disconnect()
        XCTAssertFalse(channel.sendAdmitting(Array("refresh-client -C 202,40\n".utf8)),
            "a terminated side-channel writer cannot admit a size")
    }

    @MainActor
    func test_compactMoshSideChannelAdmissionIsSynchronousAndRejectsEmptyInput() {
        let channel = TmuxControlChannel(host: Host(transport: .mosh), sessionName: "compact-unit", initialSize: nil)
        defer { channel.disconnect() }
        XCTAssertFalse(channel.sendAdmitting([]))
        XCTAssertTrue(channel.sendAdmitting(Array("refresh-client -C 202,40\n".utf8)),
            "the ordered queue admits synchronously before its writer starts")
    }

    // MARK: - maxVerticalLeaves (header reserve-rows count)

    func test_maxVerticalLeaves_singlePane() {
        XCTAssertEqual(PaneLayoutMath.maxVerticalLeaves(root("b25d,80x24,0,0,0")), 1)
    }

    func test_maxVerticalLeaves_sideBySideIsOne() {
        // {a,b}: a vertical line through the layout crosses exactly one column,
        // so the tallest header stack is a single header.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")),
            1
        )
    }

    func test_maxVerticalLeaves_stackedIsTwo() {
        // [a,b]: a vertical line crosses both stacked leaves.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")),
            2
        )
    }

    func test_maxVerticalLeaves_nestedColumnStack() {
        // {leaf , [leaf , leaf]}: left column 1 leaf, right column 2 stacked.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(
                root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}")
            ),
            2
        )
    }

    func test_maxVerticalLeaves_fourPaneNested() {
        // {leaf , [leaf , {leaf,leaf}]}: deepest column is leaf-over-(side-by-
        // side pair) = 2 stacked.
        XCTAssertEqual(
            PaneLayoutMath.maxVerticalLeaves(
                root("1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}")
            ),
            2
        )
    }

    // MARK: - frames: positions and exact cell multiples

    func test_frames_singlePaneNoHeader() {
        let cell = CGSize(width: 8, height: 16)
        let frames = PaneLayoutMath.frames(root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0)
        XCTAssertEqual(frames.count, 1)
        let p0 = frame(frames, 0)
        XCTAssertEqual(p0.headerFrame.height, 0, "no header reserved for a single pane")
        XCTAssertEqual(p0.surfaceFrame, CGRect(x: 0, y: 0, width: 80 * 8, height: 24 * 16))
    }

    func test_frames_sideBySideNoHeader_matchesTmuxRectOrigins() {
        // The walk accumulates child sizes + a 1-cell gutter; the result must
        // reproduce tmux's own pane origins (pane 1 at cell x=41).
        let cell = CGSize(width: 10, height: 20)
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: 0
        )
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 0, width: 400, height: 480))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 0, width: 390, height: 480))
    }

    func test_frames_sideBySideWithHeader_pushesSurfaceDownByOneHeader() {
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 24
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: header
        )
        // Each pane in a side-by-side has exactly one header above its surface.
        XCTAssertEqual(frame(frames, 0).headerFrame, CGRect(x: 0, y: 0, width: 400, height: 24))
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 24, width: 400, height: 480))
        XCTAssertEqual(frame(frames, 1).headerFrame, CGRect(x: 410, y: 0, width: 390, height: 24))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 24, width: 390, height: 480))
    }

    func test_frames_nestedColumn_accumulatesHeadersAbove() {
        // Right column stacks pane 1 over pane 2; pane 2's surface is pushed
        // down by BOTH headers above it plus pane 1's content plus the gutter.
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 16
        let frames = PaneLayoutMath.frames(
            root: root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"),
            cellSize: cell, headerHeight: header
        )
        // Left pane: single header above its 40x24 surface.
        XCTAssertEqual(frame(frames, 0).surfaceFrame, CGRect(x: 0, y: 16, width: 400, height: 480))
        // Right-top pane 1: 39x12 surface under one header.
        XCTAssertEqual(frame(frames, 1).headerFrame, CGRect(x: 410, y: 0, width: 390, height: 16))
        XCTAssertEqual(frame(frames, 1).surfaceFrame, CGRect(x: 410, y: 16, width: 390, height: 240))
        // Right-bottom pane 2: header at y = header + pane1(header+content) +
        // gutter = 16 + 256 + 20 = 292 - 16 = 276; surface at 292.
        XCTAssertEqual(frame(frames, 2).headerFrame, CGRect(x: 410, y: 276, width: 390, height: 16))
        XCTAssertEqual(frame(frames, 2).surfaceFrame, CGRect(x: 410, y: 292, width: 390, height: 220))
    }

    func test_frames_allSurfacesAreExactCellMultiples() {
        // The load-bearing invariant (risk #2): across layouts, cell sizes, and
        // header heights, every surface is an exact integer number of cells.
        let layouts = [
            "b25d,80x24,0,0,0",
            "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
            "abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            "d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}",
            "1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}",
        ]
        let cells = [CGSize(width: 8, height: 16), CGSize(width: 10.5, height: 21.5), CGSize(width: 7, height: 15)]
        let headers: [CGFloat] = [0, 16, 28]

        for layoutString in layouts {
            for cell in cells {
                for header in headers {
                    let frames = PaneLayoutMath.frames(
                        root: root(layoutString), cellSize: cell, headerHeight: header
                    )
                    for f in frames {
                        let cols = f.surfaceFrame.width / cell.width
                        let rows = f.surfaceFrame.height / cell.height
                        XCTAssertEqual(
                            cols, cols.rounded(), accuracy: 0.0001,
                            "surface width must be an exact cell multiple (layout \(layoutString) cell \(cell) header \(header) pane \(f.paneId.rawValue))"
                        )
                        XCTAssertEqual(
                            rows, rows.rounded(), accuracy: 0.0001,
                            "surface height must be an exact cell multiple (layout \(layoutString) cell \(cell) header \(header) pane \(f.paneId.rawValue))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - dividers (hairlines in gutters)

    func test_dividers_singlePaneHasNone() {
        let cell = CGSize(width: 10, height: 20)
        XCTAssertTrue(
            PaneLayoutMath.dividers(root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0, thickness: 1).isEmpty
        )
    }

    func test_dividers_sideBySideOneVerticalHairlineCenteredInGutter() {
        let cell = CGSize(width: 10, height: 20)
        let header: CGFloat = 16
        let lines = PaneLayoutMath.dividers(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: header, thickness: 1
        )
        XCTAssertEqual(lines.count, 1)
        // Gutter occupies cell column x∈[400,410); a 1pt line centered → x=404.5.
        // It spans the full split height: header(16) + 24*20 = 496.
        XCTAssertEqual(lines[0], CGRect(x: 404.5, y: 0, width: 1, height: 496))
    }

    func test_dividers_stackedOneHorizontalHairlineCenteredInGutter() {
        let cell = CGSize(width: 10, height: 20)
        let lines = PaneLayoutMath.dividers(
            root: root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]"),
            cellSize: cell, headerHeight: 0, thickness: 2
        )
        XCTAssertEqual(lines.count, 1)
        // Top pane 12 rows * 20 = 240; gutter y∈[240,260); 2pt line centered → y=249.
        // Width spans the split: 80 cells * 10 = 800.
        XCTAssertEqual(lines[0], CGRect(x: 0, y: 249, width: 800, height: 2))
    }

    func test_dividers_nestedLayoutHasOuterAndInnerGutters() {
        // {leaf , [leaf,leaf]}: one outer vertical line (between the two columns)
        // and one inner horizontal line (between the right column's stacked panes).
        let cell = CGSize(width: 10, height: 20)
        let lines = PaneLayoutMath.dividers(
            root: root("d67e,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13,2]}"),
            cellSize: cell, headerHeight: 0, thickness: 1
        )
        XCTAssertEqual(lines.count, 2)
        let verticals = lines.filter { $0.height > $0.width }
        let horizontals = lines.filter { $0.width > $0.height }
        XCTAssertEqual(verticals.count, 1, "one vertical gutter between the two columns")
        XCTAssertEqual(horizontals.count, 1, "one horizontal gutter inside the right column")
        // Vertical divider sits in the gutter after the 40-cell left column.
        XCTAssertEqual(verticals.first?.minX ?? -1, 404.5, accuracy: 0.0001)
    }

    func test_frames_paneBoxUnionsHeaderAndSurfaceWhenHeaderPresent() {
        let cell = CGSize(width: 10, height: 20)
        let withHeader = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"),
            cellSize: cell, headerHeight: 24
        )
        let p0 = frame(withHeader, 0)
        XCTAssertEqual(p0.paneBox, CGRect(x: 0, y: 0, width: 400, height: 504),
                       "paneBox spans header + surface for the focus ring")

        let noHeader = PaneLayoutMath.frames(
            root: root("b25d,80x24,0,0,0"), cellSize: cell, headerHeight: 0
        )
        XCTAssertEqual(noHeader[0].paneBox, noHeader[0].surfaceFrame,
                       "with no header the pane box is just the surface")
    }

    // MARK: - pane(at:) hit-testing (mosh tap-to-focus)

    func test_paneAt_sideBySide_mapsLeftAndRightTaps() {
        // {40x24 , 39x24}: left pane surface x∈[0,400), right x∈[410,800).
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 50, y: 100), root: r, cellSize: cell), PaneId(0))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 600, y: 100), root: r, cellSize: cell), PaneId(1))
    }

    func test_paneAt_dividerGutterResolvesToNil() {
        // The 1-cell gutter column x∈[400,410) belongs to no surface — a tap
        // there must not switch focus (mirrors the SSH grid's exact tap).
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 405, y: 100), root: r, cellSize: cell))
    }

    func test_paneAt_boundaryIsHalfOpen() {
        // Pane 0 surface is x∈[0,400); x=400 is the gutter, x=399 still pane 0.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 399, y: 0), root: r, cellSize: cell), PaneId(0))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 400, y: 0), root: r, cellSize: cell))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 410, y: 0), root: r, cellSize: cell), PaneId(1))
    }

    func test_paneAt_stacked_mapsTopAndBottomTaps() {
        // [80x12 , 80x11]: top pane y∈[0,240), bottom y∈[260,480).
        let cell = CGSize(width: 10, height: 20)
        let r = root("abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 50), root: r, cellSize: cell), PaneId(0))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 300), root: r, cellSize: cell), PaneId(1))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 250), root: r, cellSize: cell),
                     "the horizontal gutter row maps to no pane")
    }

    func test_paneAt_nestedFourPane_eachQuadrantResolves() {
        // {leaf , [leaf , {leaf,leaf}]} — exercise every leaf of a nested tree.
        let cell = CGSize(width: 10, height: 20)
        let r = root("1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}")
        // Left full-height column → pane 0.
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 240), root: r, cellSize: cell), PaneId(0))
        // Right-top stacked leaf → pane 1 (x≥410, y<240).
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 500, y: 100), root: r, cellSize: cell), PaneId(1))
        // Right-bottom inner side-by-side: pane 2 (left) and pane 3 (right).
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 450, y: 400), root: r, cellSize: cell), PaneId(2))
        XCTAssertEqual(PaneLayoutMath.pane(at: CGPoint(x: 700, y: 400), root: r, cellSize: cell), PaneId(3))
    }

    func test_paneAt_outOfBoundsResolvesToNil() {
        // A tap past the grid's painted extent (remainder margin) hits nothing.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 5000, y: 5000), root: r, cellSize: cell))
        XCTAssertNil(PaneLayoutMath.pane(at: CGPoint(x: 100, y: 999), root: r, cellSize: cell))
    }

    func test_frameAt_returnsTheHitPaneFrame() {
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        XCTAssertEqual(PaneLayoutMath.frame(at: CGPoint(x: 50, y: 100), root: r, cellSize: cell)?.paneId, PaneId(0))
        XCTAssertEqual(PaneLayoutMath.frame(at: CGPoint(x: 600, y: 100), root: r, cellSize: cell)?.surfaceFrame,
                       CGRect(x: 410, y: 0, width: 390, height: 480))
        XCTAssertNil(PaneLayoutMath.frame(at: CGPoint(x: 405, y: 100), root: r, cellSize: cell))
    }

    // MARK: - closeButtonRect (mosh ✕ affordance)

    func test_closeButtonRect_anchoredTopRightOnePaneTall() {
        // Side-by-side {40x24, 39x24}, cell 10×20: each ✕ is a cellH square at
        // the pane's top-right corner (matching the SSH header's height×height ✕).
        let cell = CGSize(width: 10, height: 20)
        let frames = PaneLayoutMath.frames(
            root: root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}"), cellSize: cell, headerHeight: 0
        )
        let left = frame(frames, 0)   // surface (0,0,400,480)
        let right = frame(frames, 1)  // surface (410,0,390,480)
        XCTAssertEqual(PaneLayoutMath.closeButtonRect(for: left, cellSize: cell),
                       CGRect(x: 380, y: 0, width: 20, height: 20))
        XCTAssertEqual(PaneLayoutMath.closeButtonRect(for: right, cellSize: cell),
                       CGRect(x: 780, y: 0, width: 20, height: 20))
    }

    func test_closeButtonRect_isInsideItsPaneSurface() {
        // The ✕ rect must never poke outside its own pane (else a tap there would
        // hit-test to the neighbour / gutter and the kill would target the wrong
        // pane or no pane).
        let layouts = [
            "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
            "abcd,80x24,0,0[80x12,0,0,0,80x11,0,13,1]",
            "1558,80x24,0,0{40x24,0,0,0,39x24,41,0[39x12,41,0,1,39x11,41,13{19x11,41,13,2,19x11,61,13,3}]}",
        ]
        let cell = CGSize(width: 10, height: 20)
        for layoutString in layouts {
            for f in PaneLayoutMath.frames(root: root(layoutString), cellSize: cell, headerHeight: 0) {
                let x = PaneLayoutMath.closeButtonRect(for: f, cellSize: cell)
                XCTAssertTrue(f.surfaceFrame.contains(x),
                              "✕ rect \(x) escaped pane %\(f.paneId.rawValue) surface \(f.surfaceFrame) in \(layoutString)")
            }
        }
    }

    func test_closeButtonRect_aTapInItResolvesToTheSamePane() {
        // The center of a pane's ✕ rect must hit-test (via frame(at:)) back to
        // that same pane — the property the tap handler relies on to close it.
        let cell = CGSize(width: 10, height: 20)
        let r = root("8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}")
        for f in PaneLayoutMath.frames(root: r, cellSize: cell, headerHeight: 0) {
            let x = PaneLayoutMath.closeButtonRect(for: f, cellSize: cell)
            let center = CGPoint(x: x.midX, y: x.midY)
            XCTAssertEqual(PaneLayoutMath.frame(at: center, root: r, cellSize: cell)?.paneId, f.paneId)
        }
    }

    func test_closeButtonRect_narrowPaneClampsToWidth() {
        // A pane narrower than one cell-height keeps the ✕ within its width.
        let cell = CGSize(width: 10, height: 20)
        let tiny = PaneFrame(
            paneId: PaneId(9),
            headerFrame: .zero,
            surfaceFrame: CGRect(x: 0, y: 0, width: 12, height: 200)
        )
        let x = PaneLayoutMath.closeButtonRect(for: tiny, cellSize: cell)
        XCTAssertEqual(x.width, 12, "✕ width clamps to the pane width when narrower than cellH")
        XCTAssertTrue(tiny.surfaceFrame.contains(x))
    }
}

@MainActor
final class GeometryNeutralTmuxCanvasModifierTests: XCTestCase {
    private final class Mounts {
        var count = 0
        weak var view: UIView?
    }

    private struct CountingSurface: UIViewRepresentable {
        let mounts: Mounts
        func makeUIView(context: Context) -> UIView {
            mounts.count += 1
            let view = UIView()
            mounts.view = view
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private struct Host: View {
        let windowRect: CellRect?
        let mounts: Mounts
        var body: some View {
            CountingSurface(mounts: mounts)
                .modifier(GeometryNeutralTmuxCanvasModifier(
                    windowRect: windowRect,
                    focusRect: windowRect,
                    cellSize: CGSize(width: 9, height: 18),
                    onViewportSize: { _ in }
                ))
        }
    }

    @discardableResult
    private func settle(_ controller: UIViewController, until condition: () -> Bool = { true }) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        } while !condition() && Date() < deadline
        return condition()
    }

    /// A mosh terminal remounted when tmux metadata arrived came back blank:
    /// its screen was painted into the discarded view, and mosh does not
    /// resend an unchanged screen.
    func test_tmuxMetadataArrivingOrLeavingKeepsTheSurfaceMounted() throws {
        let mounts = Mounts()
        let controller = UIHostingController(rootView: Host(windowRect: nil, mounts: mounts))
        // A scene-less window never commits SwiftUI updates after its first layout.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func frameInWindow() -> CGRect? { mounts.view.map { $0.convert($0.bounds, to: nil) } }
        settle(controller)
        XCTAssertEqual(mounts.count, 1)
        let plain = try XCTUnwrap(frameInWindow())
        XCTAssertGreaterThan(plain.width, 0)
        XCTAssertGreaterThan(plain.height, 0)

        controller.rootView = Host(windowRect: CellRect(width: 46, height: 30, x: 0, y: 0), mounts: mounts)
        XCTAssertTrue(settle(controller) { frameInWindow() != plain }, "the projection never applied")
        XCTAssertEqual(mounts.count, 1, "the projected canvas must not remount the surface")
        // The surface is half a cell wider than the 46x30 grid, scaled to fit.
        let scale = min(plain.width / (46 * 9), plain.height / (30 * 18))
        let projected = try XCTUnwrap(frameInWindow())
        XCTAssertEqual(projected.width, (46 * 9 + 4.5) * scale, accuracy: 1)
        XCTAssertEqual(projected.height, 30 * 18 * scale, accuracy: 1)

        controller.rootView = Host(windowRect: nil, mounts: mounts)
        XCTAssertTrue(settle(controller) { frameInWindow() == plain }, "the plain viewport never returned")
        XCTAssertEqual(mounts.count, 1, "losing the layout must not remount the surface")
    }
}
