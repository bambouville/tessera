import XCTest
@testable import TmuxControlCore

/// Seeds per run, each a fresh engine through random wire lines and public
/// mutators. Raise it (3000 found nothing new in review) for a deep run; the
/// default keeps a debug run to a few seconds.
private let runtimeSnapshotMemoFuzzSeedCount: UInt64 = 1_000
private let runtimeSnapshotMemoFuzzOperationsPerSeed = 150

private struct Mix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
}

/// Random wire lines and public mutators, with the memo checked against a
/// fresh build after every single operation: any published mutation that does
/// not move the revision would be served stale, both here and by the Android
/// ABI's snapshot elision, which keys on the same revision.
final class RuntimeSnapshotMemoFuzzTests: XCTestCase {
    func testRandomOperationsNeverServeAStaleMemo() {
        var failures: [String] = []
        for seed in UInt64(1)...runtimeSnapshotMemoFuzzSeedCount {
            var rng = Mix(state: seed)
            var engine = TmuxRuntimeEngine()
            var seq = 0
            var log: [String] = []
            func line() -> String {
                let w = 1 + rng.int(4), p = 1 + rng.int(6), s = 1 + rng.int(2)
                seq += 1
                switch rng.int(24) {
                case 0: return "%session-changed $\(s) work\(rng.int(2))"
                case 1: return "%window-add @\(w)"
                case 2: return "%unlinked-window-close @\(w)"
                case 3: return "%window-close @\(w)"
                case 4: return "%window-renamed @\(w) n\(rng.int(3))"
                case 5:
                    let layout = rng.chance(0.5)
                        ? "abcd,80x24,0,0,\(p)"
                        : "abcd,80x24,0,0{39x24,0,0,\(p),40x24,40,0,\(p + 1)}"
                    return "%layout-change @\(w) \(layout) \(layout) \(rng.chance(0.3) ? "*Z" : "*")"
                case 6: return "%session-window-changed $\(s) @\(w)"
                case 7: return "%window-pane-changed @\(w) %\(p)"
                case 8: return "%session-renamed $\(s) r\(rng.int(3))"
                case 9:
                    let dev = rng.chance(0.5) ? "dev0" : "peer\(rng.int(2))"
                    return "%subscription-changed tessera-authority $\(s) @\(w) 0 %\(p) : v1 \(dev) \(rng.int(4)) Nm"
                case 10:
                    let fields = ["@\(w)", "%\(p)", rng.chance(0.5) ? "1" : "0", "0", "0", "40", "12",
                                  "cmd\(rng.int(2))", "host", "win\(rng.int(2))", rng.chance(0.5) ? "title\(rng.int(2))" : "",
                                  rng.chance(0.5) ? "/p\(rng.int(2))" : "", "", "\(rng.int(2))", "\(rng.int(2))", "\(rng.int(2))"]
                    return "%subscription-changed tessera-pane-meta $\(s) @\(w) 0 %\(p) : " + fields.joined(separator: "\t")
                case 11:
                    let rows = (1...(1 + rng.int(3))).map { i in
                        "__tessera_windows__\t@\(i)\t\(rng.int(4))\t%\(i)\t\t\t0\tw\(i)"
                    }.joined(separator: "\n")
                    return "%begin 1 \(seq) 1\n\(rows)\n%end 1 \(seq) 1"
                case 12:
                    return "%begin 1 \(seq) 1\n__tessera_windows__\tgarbage\n%end 1 \(seq) 1"
                case 13:
                    return "%begin 1 \(seq) 1\n__tessera_active_window__\t@\(w)\t3.\(rng.int(5))\n%end 1 \(seq) 1"
                case 14:
                    return "%begin 1 \(seq) 1\n__tessera_panes__\t@\(w)\t%\(p)\t\(rng.int(2))\t0\t0\t\(30 + rng.int(20))\t24\tt\(rng.int(2))\t/x\(rng.int(2))\thost\n%end 1 \(seq) 1"
                case 15:
                    return "%begin 1 \(seq) 1\n__tessera_window_details__\t@\(w)\t\(rng.int(3))\t%\(p)\tabcd,80x24,0,0,\(p)\tabcd,80x24,0,0,\(p)\t0\tdet\n%end 1 \(seq) 1"
                case 16:
                    return "%begin 1 \(seq) 1\n__tessera_active_pane__\t@\(w)\t%\(p)\n%end 1 \(seq) 1"
                case 17: return "%subscription-changed tessera-window-order $\(s) - - - : 0=@2* 1=@1 "
                case 18: return "%subscription-changed tessera-bell $\(s) @\(w) 0 %\(p) : \(rng.int(2))"
                case 19: return "%begin 1 \(seq) 1\nerr\n%error 1 \(seq) 1"
                default: return "%output %\(p) x\(rng.int(9))"
                }
            }
            func mutate() {
                let w = WindowId(1 + rng.int(4)), p = PaneId(1 + rng.int(6))
                let window = TmuxWindowSnapshot(
                    id: w, index: rng.chance(0.5) ? rng.int(4) : nil, name: rng.chance(0.5) ? "m\(rng.int(3))" : nil,
                    activePaneID: rng.chance(0.7) ? p : nil, activePaneTitle: rng.chance(0.5) ? "t\(rng.int(2))" : nil,
                    activePaneTitleIsDefault: rng.chance(0.3),
                    panes: rng.chance(0.5) ? [TmuxPaneSnapshot(id: p, title: "pt\(rng.int(2))", isActive: true,
                                                                contentRect: rng.chance(0.5) ? CellRect(width: 10, height: 5, x: 0, y: 0) : nil)] : [],
                    layout: rng.chance(0.3) ? WindowLayout.parse("abcd,80x24,0,0,\(p.rawValue)") : nil,
                    isZoomed: rng.chance(0.2)
                )
                switch rng.int(26) {
                case 0: log.append("projectUnknown"); engine.projectAuthority(.unknown)
                case 1: log.append("projectPeer"); engine.projectAuthority(.peer(deviceID: "peer", displayName: "X", generation: UInt64(rng.int(5))))
                case 2: log.append("projectEqual"); engine.projectAuthority(engine.snapshot.authority)
                case 3: log.append("projectMine"); engine.projectAuthority(.mine(generation: UInt64(rng.int(5))))
                case 4: log.append("projectIdentity"); engine.projectAuthority(.peer(deviceID: "peer\(rng.int(2))", displayName: "D", generation: 1))
                case 5: log.append("projectFallback"); engine.projectAuthority(.peer(deviceID: "-", displayName: "lap\(rng.int(2))", generation: 0))
                case 6: log.append("projectEqual"); engine.projectAuthority(engine.snapshot.authority)
                case 7: log.append("projectUnknown"); engine.projectAuthority(.unknown)
                case 8: log.append("presentation"); _ = engine.ingestWindowPresentation(window)
                case 9: log.append("metadata"); _ = engine.ingestWindowMetadata(window)
                case 10: log.append("activePane"); _ = engine.ingestActivePaneQuery(windowID: w, paneID: p)
                case 11: log.append("activeWindow"); _ = engine.ingestActiveWindowQuery(w)
                case 12: log.append("provisional"); engine.ingestProvisionalActivePane(p)
                case 13: log.append("beginReorder"); _ = engine.beginReorder(expecting: engine.snapshot.authoritativeWindowOrder.shuffled())
                case 14: log.append("confirmReorder"); _ = engine.confirmReorder(token: UInt64(1 + rng.int(4)))
                case 15: log.append("takeRefresh"); _ = engine.takePendingOrderRefreshCommand()
                case 16: log.append("completeRefresh"); engine.completeOrderRefresh(succeeded: rng.chance(0.7))
                case 17: log.append("abandon"); _ = engine.abandonReorder(token: UInt64(1 + rng.int(4)))
                case 18: log.append("orderSub"); _ = engine.ingestWindowOrderSubscription("0=@2* 1=@1", sessionID: SessionId(1 + rng.int(2)))
                case 19: log.append("list"); _ = engine.ingestWindowListQuery(rng.chance(0.5) ? [window] : [])
                case 20: log.append("replay"); _ = engine.replayTopologyNotification(.windowRenamed(windowId: w, name: "rp"))
                case 21: log.append("takeDetails"); _ = engine.takePendingWindowDetailQueries()
                case 22: log.append("projectName"); engine.projectAuthority(.peer(deviceID: "peer", displayName: "P\(rng.int(2))", generation: 1))
                case 23: log.append("resetKeep"); engine.reset(keepingSnapshot: true)
                case 24: log.append("reset"); engine.reset(keepingSnapshot: false)
                default: log.append("replayLayout"); _ = engine.replayTopologyNotification(.layoutChange(windowId: w, layout: "abcd,80x24,0,0,\(p.rawValue)", visibleLayout: nil, rawFlags: nil))
                }
            }
            for _ in 0..<runtimeSnapshotMemoFuzzOperationsPerSeed {
                if rng.chance(0.65) {
                    let text = line()
                    log.append(text)
                    let batch = engine.feed(Array((text + "\n").utf8))
                    if batch.snapshot != engine.buildSnapshot() || engine.snapshot != engine.buildSnapshot() {
                        failures.append("seed \(seed) after line \(text.debugDescription)\n  " + log.suffix(12).joined(separator: "\n  "))
                        break
                    }
                } else {
                    // Refresh the memo first so a non-bumping mutation is caught.
                    _ = engine.feed(Array("%output %1 r\n".utf8))
                    mutate()
                    if engine.snapshot != engine.buildSnapshot() || !engine.servesSnapshotFromMemo {
                        failures.append("seed \(seed) after mutator \(log.last ?? "")\n  " + log.suffix(12).joined(separator: "\n  "))
                        break
                    }
                }
            }
            if failures.count >= 3 { break }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }
}
