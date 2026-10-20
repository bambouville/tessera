import XCTest

/// Input-only driver for visual evidence capture. Verification deliberately
/// stays outside XCUITest because SwiftTerm's CAMetalLayer is black in
/// XCUIScreenshot; the integration runner records with simctl and submits all
/// visual cases to one aggregate reviewer.
final class VisualCaptureProbe: XCTestCase {
    /// The milestone a lane acknowledges to release holdForExternalCapture.
    private var lastMarker: String?
    /// The floating session bar's bottom, measured once (see sessionBarBottom).
    private var measuredSessionBarBottom: CGFloat??

    func testSplitBatchPresentation() throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SPLIT_BATCH_HARNESS"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let status = app.staticTexts["split-batch-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let split = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "after split | panes=2 | focus=%6"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [split], timeout: 15), .completed)
        print("TESSERA_SPLIT_CAPTURE split")
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "returned to split | panes=2 | focus=%6"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 15), .completed)
        print("TESSERA_SPLIT_CAPTURE returned")
        sleep(5) // External simctl captures the actual terminal layers.
    }

    /// Runner-owned simulator setup only. Never launches an app or host.
    func testSetPrivatePaintSimulatorLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
    }

    func testBoundedIngestionWindowKeepsHistoryWhileHeadAdvances() throws {
        try exerciseBoundedIngestionWindow(phone: false)
    }

    func testBoundedIngestionWindowOnPhone() throws {
        try exerciseBoundedIngestionWindow(phone: true)
    }

    func testChatFollowsSameRecordGrowth() throws { try exerciseChatFollow(phone: false) }
    func testChatFollowsSameRecordGrowthOnPhone() throws { try exerciseChatFollow(phone: true) }
    func testShortTranscriptSitsAtTheEndAndFillsFromHistory() throws { try exerciseShortTranscript(phone: false) }
    func testShortTranscriptSitsAtTheEndAndFillsFromHistoryOnPhone() throws { try exerciseShortTranscript(phone: true) }
    func testFollowerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHead() throws { try exerciseHeadSplit(phone: false) }
    func testFollowerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHeadOnPhone() throws { try exerciseHeadSplit(phone: true) }
    func testReadProgressNeverShiftsAShownTranscript() throws { try exerciseReadProgressPulses(phone: false) }
    func testReadProgressNeverShiftsAShownTranscriptOnPhone() throws { try exerciseReadProgressPulses(phone: true) }

    /// Only every hundredth record is visible, so each page adds one row and
    /// the transcript is shorter than the viewport. Nothing can be scrolled
    /// to ask for history: it rests on the composer and pages older history
    /// itself, stopping before a page would evict the live head. The head
    /// keeps rolling meanwhile; its new record appears below that history.
    private func exerciseShortTranscript(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_SPARSE"] = "100"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if phone { row.tap() }
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        func record(_ index: Int) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History record \(index) ")).firstMatch
        }
        XCTAssertTrue(record(800).waitForExistence(timeout: 20), "An unscrollable transcript must page history without a gesture")
        XCTAssertTrue(record(1200).waitForExistence(timeout: 10), "The rolled head's new record follows the retained history")
        Thread.sleep(forTimeInterval: 3)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "short-transcript-filled"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(record(700).exists, "A fifth legacy page would evict the live head")
        XCTAssertTrue(record(800).exists, "Head rolls must keep the retained history")
        let newest = record(1200).frame
        XCTAssertLessThanOrEqual(newest.maxY, transcript.frame.maxY + 3)
        XCTAssertGreaterThanOrEqual(newest.maxY, transcript.frame.maxY - 48, "A short transcript rests on the composer")
    }

    /// A following reader keeps history beside the rolled head. A revision
    /// that splits the head drops rows between the viewport and its last
    /// part from the host's window. Those rows stay on screen, and a slow
    /// newer read retains them: the newest rows never vanish, history stays,
    /// and the reader is not left behind Return to latest.
    private func exerciseHeadSplit(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_SPLIT_HEAD"] = "1"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if phone { row.tap() }
        XCTAssertTrue(app.scrollViews["agent-center-v2-transcript"].firstMatch.waitForExistence(timeout: 10))
        let state = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")).firstMatch
        func value(_ field: String) -> String? {
            state.identifier.components(separatedBy: ";").first { $0.hasPrefix(field + "=") }?.components(separatedBy: "=").last
        }
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        // Each read snapshots the whole hierarchy, which takes seconds with a
        // long transcript: read the split's fields from the one that saw it.
        func field(_ name: String, in identifier: String) -> String? {
            identifier.components(separatedBy: ";").first { $0.hasPrefix(name + "=") }?.components(separatedBy: "=").last
        }
        var split = ""
        expectation(for: NSPredicate { _, _ in
            let identifier = state.identifier
            guard field("revisionSplits", in: identifier) == "1" else { return false }
            split = identifier; return true
        }, evaluatedWith: state)
        waitForExpectations(timeout: 15)
        let newest = "fixture-record-\((Int(field("sourceEnd", in: split) ?? "") ?? 0) - 1)"
        // The fixture holds the newer read for five seconds.
        XCTAssertEqual(field("bridged", in: split), "true", split)
        XCTAssertEqual(field("tail", in: split), newest, "The split's unretained rows stay shown")
        XCTAssertEqual(field("atLiveHead", in: split), "true")
        let bridged = XCTAttachment(screenshot: app.screenshot())
        bridged.name = "head-split-bridged"; bridged.lifetime = .keepAlways; add(bridged)
        expectation(for: NSPredicate { _, _ in value("bridged") == "false" && value("historyLoading") == "false" }, evaluatedWith: state)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(value("atLiveHead"), "true")
        XCTAssertGreaterThan(Int(value("windowSegments") ?? "") ?? 0, 1, "A newer page keeps the history, no re-bootstrap")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "head-split-retained"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertFalse(app.buttons["agent-center-v2-return-to-latest"].exists, "A following reader is not left on history")
    }

    /// Field sessions report "preparing" on most refreshes while an agent
    /// works. A status row inserted above the transcript pushed the whole
    /// conversation down and back each time.
    private func exerciseReadProgressPulses(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_READ_PROGRESS_HZ"] = "2"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if phone { row.tap() }
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        let status = app.staticTexts["agent-center-v2-read-status"]
        let top = transcript.frame.minY
        var samples = 0
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            XCTAssertFalse(status.exists, "Progress over a shown transcript must not insert a status row")
            XCTAssertEqual(transcript.frame.minY, top, accuracy: 0.5, "Read progress must never move the transcript")
            samples += 1
        }
        XCTAssertGreaterThan(samples, 10, "The pulses must be sampled across several on/off cycles")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "read-progress-steady"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Frame-timing benchmark for the rich history fixture. XCUIElement and
    /// XCUICoordinate gestures snapshot the app's whole accessibility tree on
    /// its main thread before every event, which dominates a deep
    /// transcript's timing, so after one launch query this synthesizes flicks
    /// through the runner's daemon session. The app logs frame gaps
    /// (`TESSERA_V2_SCROLL`) and window state (`TESSERA_WINDOW_FIXTURE`).
    func testRichHistoryScrollBenchmark() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let env = ProcessInfo.processInfo.environment
        if let handshake = env["TESSERA_RICH_SCROLL_EXTERNAL_LAUNCH"] {
            // XCUIApplication keeps an automation session that makes SwiftUI
            // maintain the app's accessibility graph. The runner launches the
            // app itself; this test only synthesizes flicks at a known frame.
            let values = (env["TESSERA_RICH_SCROLL_FRAME"] ?? "").split(separator: ",").compactMap { Double($0) }
            guard values.count == 6 else { throw XCTSkip("TESSERA_RICH_SCROLL_FRAME needs x,y,w,h,screenW,screenH") }
            print("TESSERA_BENCH_READY")
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: handshake), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            Thread.sleep(forTimeInterval: TimeInterval(env["TESSERA_RICH_SCROLL_SETTLE"] ?? "") ?? 8)
            try runRichHistoryFlicks(frame: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
                                     screen: CGSize(width: values[4], height: values[5]), orientation: 3, env: env)
            return
        }
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_RICH"] = "1"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_RECORDS"] = env["TESSERA_RICH_SCROLL_RECORDS"] ?? "3000"
        if env["TESSERA_RICH_SCROLL_CAPACITY"] != "legacy" {
            app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_CAPACITY"] = "device"
        }
        if let tier = env["TESSERA_RICH_SCROLL_TIER"] { app.launchEnvironment["TESSERA_AGENT_CONTENT_TIER"] = tier }
        for name in ["TESSERA_AGENT_RENDERED_COST", "TESSERA_AGENT_RENDERED_CHUNK_COST"] {
            if let value = env[name] { app.launchEnvironment[name] = value }
        }
        app.launchArguments += ["-Diagnostics.VerboseEnabled", "YES"]
        app.launch()
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let frame = transcript.frame
        let screen = app.frame
        let orientation = (app.value(forKey: "interfaceOrientation") as? Int) ?? 3
        print("TESSERA_BENCH_FRAME x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height)) screenW=\(Int(screen.width)) screenH=\(Int(screen.height)) orientation=\(orientation)")
        Thread.sleep(forTimeInterval: 3)
        try runRichHistoryFlicks(frame: frame, screen: screen.size, orientation: orientation, env: env)
    }

    private func runRichHistoryFlicks(frame: CGRect, screen: CGSize, orientation: Int, env: [String: String]) throws {
        // The daemon takes points in the portrait device space; device
        // landscape-left maps (x, y) to (screenHeight - y, x).
        func device(_ point: CGPoint) -> CGPoint {
            orientation == 3 ? CGPoint(x: screen.height - point.y, y: point.x) : point
        }
        let upper = device(CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.2))
        let lower = device(CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.85))
        let older = Int(env["TESSERA_RICH_SCROLL_SWIPES"] ?? "") ?? 45
        let newer = Int(env["TESSERA_RICH_SCROLL_BACK"] ?? "") ?? 20
        let gap = TimeInterval(env["TESSERA_RICH_SCROLL_GAP"] ?? "") ?? 0.8
        let flick = TimeInterval(env["TESSERA_RICH_SCROLL_FLICK"] ?? "") ?? 0.12
        for index in 0..<(older + newer) {
            // Moving the finger down reads older history.
            let toOlder = index < older
            try synthesizeFlick(from: toOlder ? upper : lower, to: toOlder ? lower : upper,
                                duration: flick, orientation: 1)
            print("TESSERA_BENCH_FLICK \(index) \(Date().timeIntervalSince1970)")
            Thread.sleep(forTimeInterval: gap)
        }
        Thread.sleep(forTimeInterval: 3)
    }

    /// One touch flick through the private runner event path that
    /// WebDriverAgent also uses.
    private func synthesizeFlick(from start: CGPoint, to end: CGPoint, duration: TimeInterval, orientation: Int) throws {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() else {
            throw XCTSkip("XCTest event synthesis is unavailable")
        }
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias MovePath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias LiftPath = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void
        func call<T>(_ object: AnyObject, _ name: String, as type: T.Type) throws -> T {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector), let method = (object as? NSObject)?.method(for: selector) else {
                throw XCTSkip("XCTest event synthesis lacks \(name)")
            }
            return unsafeBitCast(method, to: type)
        }
        // Leaks one path and record per flick; the benchmark issues few.
        let pathAlloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        let path = try call(pathAlloc, "initForTouchAtPoint:offset:", as: InitPath.self)(
            pathAlloc, NSSelectorFromString("initForTouchAtPoint:offset:"), start, 0)
        let steps = max(8, Int(duration * 60))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try call(path, "moveToPoint:atOffset:", as: MovePath.self)(
                path, NSSelectorFromString("moveToPoint:atOffset:"), point, duration * t)
        }
        try call(path, "liftUpAtOffset:", as: LiftPath.self)(path, NSSelectorFromString("liftUpAtOffset:"), duration)
        let recordAlloc = recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        let record = try call(recordAlloc, "initWithName:interfaceOrientation:", as: InitRecord.self)(
            recordAlloc, NSSelectorFromString("initWithName:interfaceOrientation:"), "flick" as NSString, orientation)
        try call(record, "addPointerEventPath:", as: AddPath.self)(record, NSSelectorFromString("addPointerEventPath:"), path)
        let done = expectation(description: "flick")
        var failure: NSError?
        try call(session, "synthesizeEvent:completion:", as: Synthesize.self)(
            session, NSSelectorFromString("synthesizeEvent:completion:"), record) { _, error in
                failure = error
                done.fulfill()
            }
        wait(for: [done], timeout: 30)
        if let failure { throw failure }
    }

    /// Rich device-sized records: scrolling deep into history and back must
    /// keep transcript rows on screen, never reject a page, and page on.
    func testRichHistoryScrollKeepsTranscriptContent() throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_RICH"] = "1"
        app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_RECORDS"] = ProcessInfo.processInfo.environment["TESSERA_RICH_SCROLL_RECORDS"] ?? "3000"
        // `legacy` reproduces the four-page window; the default is a current host.
        if ProcessInfo.processInfo.environment["TESSERA_RICH_SCROLL_CAPACITY"] != "legacy" {
            app.launchEnvironment["TESSERA_AGENT_WINDOW_FIXTURE_CAPACITY"] = "device"
        }
        if let tier = ProcessInfo.processInfo.environment["TESSERA_RICH_SCROLL_TIER"] {
            app.launchEnvironment["TESSERA_AGENT_CONTENT_TIER"] = tier
        }
        for name in ["TESSERA_AGENT_RENDERED_COST", "TESSERA_AGENT_RENDERED_CHUNK_COST"] {
            if let value = ProcessInfo.processInfo.environment[name] { app.launchEnvironment[name] = value }
        }
        app.launchArguments += ["-Diagnostics.VerboseEnabled", "YES"]
        app.launch()
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let state = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")).firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        func value(_ field: String) -> String? {
            state.identifier.components(separatedBy: ";").first { $0.hasPrefix(field + "=") }?.components(separatedBy: "=").last
        }
        func cursor() -> Int? { value("cursor").flatMap { Int($0.dropFirst(7)) } }
        // One atomic accessibility snapshot: element-by-element queries race
        // with rows that page in or out between the query and the frame read.
        var topRecord: Int?
        func visibleRows() -> Int {
            guard let root = try? transcript.snapshot() else { return -1 }
            let frame = root.frame
            var count = 0
            topRecord = nil
            func walk(_ node: XCUIElementSnapshot) {
                if node.elementType == .staticText, node.label.hasPrefix("History record ") || node.label.hasSuffix("tool calls"),
                   node.frame.maxY > frame.minY + 40, node.frame.minY < frame.maxY - 40 {
                    count += 1
                    if let number = Int(node.label.dropFirst("History record ".count).prefix { $0.isNumber }) {
                        topRecord = min(topRecord ?? .max, number)
                    }
                }
                node.children.forEach(walk)
            }
            walk(root)
            return count
        }
        Thread.sleep(forTimeInterval: 2)
        let swipes = Int(ProcessInfo.processInfo.environment["TESSERA_RICH_SCROLL_SWIPES"] ?? "") ?? 36
        var blank: [Int] = []
        var behind: [Int] = []
        _ = visibleRows()
        let startTop = topRecord
        var deepestTop = topRecord ?? Int.max
        var previousCursor = cursor()
        var admittedOlderPages = 0
        for index in 0..<swipes {
            transcript.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.6)
            let rows = visibleRows()
            let loaded = cursor()
            if let loaded, let previous = previousCursor, loaded < previous { admittedOlderPages += 1 }
            previousCursor = loaded ?? previousCursor
            if let top = topRecord {
                deepestTop = min(deepestTop, top)
                // The oldest loaded record must stay above the viewport, or
                // the reader has caught up with paging.
                if let loaded, top <= loaded { behind.append(index) }
            }
            print("TESSERA_RICH_SCROLL up=\(index) cursor=\(value("cursor") ?? "nil") segments=\(value("windowSegments") ?? "nil") messages=\(value("messages") ?? "nil") rejected=\(value("rejected") ?? "nil") rows=\(rows) top=\(topRecord.map(String.init) ?? "nil")")
            if rows == 0 { blank.append(index) }
        }
        let back = Int(ProcessInfo.processInfo.environment["TESSERA_RICH_SCROLL_BACK"] ?? "") ?? 12
        for index in 0..<back {
            transcript.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.6)
            let rows = visibleRows()
            print("TESSERA_RICH_SCROLL down=\(index) cursor=\(value("cursor") ?? "nil") segments=\(value("windowSegments") ?? "nil") messages=\(value("messages") ?? "nil") rejected=\(value("rejected") ?? "nil") rows=\(rows)")
            if rows == 0 { blank.append(1000 + index) }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "rich-history-final"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(value("rejected"), "0", "Rich history pages must be admitted")
        XCTAssertEqual(blank, [], "The transcript viewport must never be left without rows")
        XCTAssertEqual(behind, [], "Paging must stay ahead of the reader")
        XCTAssertGreaterThanOrEqual(admittedOlderPages, 2, "Scrolling must page several rich pages into history")
        // An XCUI fast swipe moves about five rich records (186 over the
        // default 36 in both bounded and unbounded render budgets); flings
        // cut short by paging or anchoring would travel much less.
        let travelled = (startTop ?? 0) - deepestTop
        XCTAssertGreaterThanOrEqual(travelled, swipes * 4, "Flings must carry the reader through history (\(travelled) records)")
    }

    func testInitiallyDetachedWindowCanPage() throws {
        try exerciseInitiallyDetachedWindow(phone: false)
    }

    func testInitiallyDetachedWindowCanPageOnPhone() throws {
        try exerciseInitiallyDetachedWindow(phone: true)
    }

    private func exerciseInitiallyDetachedWindow(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "detachedWindow"
        app.launch()
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if !transcript.exists { row.tap() }
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let state = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")).firstMatch
        XCTAssertTrue(state.identifier.contains("atLiveHead=false"))
        XCTAssertTrue(state.identifier.contains("cursor=offset_700"))
        transcript.swipeDown(velocity: .slow)
        expectation(for: NSPredicate { _, _ in !state.identifier.contains("cursor=offset_700") }, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(state.identifier.contains("atLiveHead=false"))
    }

    private func exerciseChatFollow(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "chatFollow"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        if phone { row.tap() }
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let tail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat tail")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        Thread.sleep(forTimeInterval: 1)
        capture("chat-initial-bottom")
        XCTAssertLessThanOrEqual(tail.frame.maxY, transcript.frame.maxY + 3, "Delayed bootstrap must open at bottom")
        expectation(for: NSPredicate { _, _ in tail.label.contains("Streaming line 80") }, evaluatedWith: tail)
        waitForExpectations(timeout: 15)
        Thread.sleep(forTimeInterval: 2)
        capture("chat-same-record-growth")
        XCTAssertLessThanOrEqual(tail.frame.maxY, transcript.frame.maxY + 3,
            "Growing the same record must follow its bottom without a new record ID")
        transcript.swipeDown(velocity: .slow)
        Thread.sleep(forTimeInterval: 2)
        let anchorY = tail.frame.minY
        let latest = app.buttons["agent-center-v2-return-to-latest"]
        XCTAssertTrue(latest.isHittable, "Scrolling within the current page must expose Return to Latest")
        XCTAssertGreaterThanOrEqual(latest.frame.minY, transcript.frame.maxY - 1,
            "Return to Latest must reserve space instead of obscuring conversation text")
        capture("chat-detached-before")
        app.buttons["agent-chat-advance"].tap()
        expectation(for: NSPredicate { _, _ in tail.label.contains("Streaming line 120") }, evaluatedWith: tail)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 2)
        capture("chat-detached-growth")
        XCTAssertEqual(tail.frame.minY, anchorY, accuracy: 3, "New output must not move detached history")
        latest.tap()
        Thread.sleep(forTimeInterval: 2)
        capture("chat-returned-to-latest")
        XCTAssertLessThanOrEqual(tail.frame.maxY, transcript.frame.maxY + 3)
        app.buttons["agent-chat-advance"].tap()
        expectation(for: NSPredicate { _, _ in tail.label.contains("Chat tail 1202") }, evaluatedWith: tail)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 2)
        capture("chat-coalesced-tools")
        XCTAssertLessThanOrEqual(tail.frame.maxY, transcript.frame.maxY + 3,
            "A new head that regroups the preceding tool run must remain bottom anchored")
    }

    private func exerciseBoundedIngestionWindow(phone: Bool) throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "ingestionWindow"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-bounded-window-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "A live fixture thread must remain present in the list")
        if phone { row.tap() }
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Shortened preview · some content is omitted"].firstMatch.waitForExistence(timeout: 5),
                      "Bounded previews must visibly disclose omitted content")
        let state = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")).firstMatch
        func value(_ field: String) -> String? {
            state.identifier.components(separatedBy: ";").first { $0.hasPrefix(field + "=") }?.components(separatedBy: "=").last
        }
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        let initial = try XCTUnwrap(value("cursor").flatMap { Int($0.dropFirst(7)) })
        XCTAssertGreaterThanOrEqual(initial, 1100, "Initial layout must not consume history before a user gesture")
        for _ in 0..<60 {
            if let cursor = value("cursor"), let start = Int(cursor.dropFirst(7)), start < 600 { break }
            transcript.swipeDown(velocity: .fast)
        }
        let oldest = try XCTUnwrap(value("cursor").flatMap { Int($0.dropFirst(7)) })
        XCTAssertLessThan(oldest, 600, "Scrolling must pass the original 512-record cache boundary")
        XCTAssertEqual(value("atLiveHead"), "false")
        XCTAssertLessThanOrEqual(Int(value("windowSegments") ?? "99") ?? 99, 4)
        func capture(_ name: String) {
            // This fixture is entirely SwiftUI; no Metal terminal is present.
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        // A completed swipe can still be decelerating in the compositor.
        // Establish the visual comparison only after the gesture settles,
        // using the same anchor interval that the numeric assertion measures.
        Thread.sleep(forTimeInterval: 1)
        let anchor = try XCTUnwrap(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History record "))
            .allElementsBoundByIndex.first { $0.frame.minY > transcript.frame.minY + 30 && $0.frame.maxY < transcript.frame.maxY - 60 })
        let label = anchor.label; let y = anchor.frame.minY
        capture("bounded-window-deep-history")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(value("revisionSplits"), "1", "The native reducer must apply a retained-page split during detached history")
        let retained = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(retained.exists)
        XCTAssertEqual(retained.frame.minY, y, accuracy: 3, "A live-head update must not move detached history")
        capture("bounded-window-live-head-does-not-move-history")
        for _ in 0..<60 {
            if let cursor = value("cursor"), let start = Int(cursor.dropFirst(7)), start > oldest { break }
            transcript.swipeUp(velocity: .fast)
        }
        let newer = try XCTUnwrap(value("cursor").flatMap { Int($0.dropFirst(7)) })
        XCTAssertGreaterThan(newer, oldest, "Scrolling toward the live head must load evicted newer history")
        XCTAssertLessThanOrEqual(Int(value("windowSegments") ?? "99") ?? 99, 4)
        capture("bounded-window-forward-history")
        // A fast phone gesture can legitimately reach the live head while
        // fetching the newer range. Detach again so the explicit Return to
        // Latest action is exercised rather than requiring an obsolete button.
        for _ in 0..<20 {
            if value("atLiveHead") == "false" { break }
            transcript.swipeDown(velocity: .fast)
        }
        XCTAssertEqual(value("atLiveHead"), "false")
        let latest = app.buttons["agent-center-v2-return-to-latest"]
        XCTAssertTrue(latest.isHittable)
        XCTAssertGreaterThanOrEqual(latest.frame.minY, transcript.frame.maxY - 1,
            "The history return control must not overlap the reading viewport")
        latest.tap()
        let caughtUp = NSPredicate { _, _ in value("atLiveHead") == "true" }
        expectation(for: caughtUp, evaluatedWith: state)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(value("atLiveHead"), "true", "Returning to latest must not immediately page backward from stale edge geometry")
        capture("bounded-window-returned-to-latest")
    }

    func testAgentCenterLiveConversationAndHistory() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TESSERA_AGENT_CENTER_LIVE_UI"] == "1",
              let config = env["TESSERA_LIVE_SCROLL_CONFIG_B64"],
              let codexSession = env["TESSERA_VERIFY_CODEX_SESSION"],
              let claudeSession = env["TESSERA_VERIFY_CLAUDE_SESSION"] else {
            throw XCTSkip("Requires an explicitly authorized live Agent Center fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_LIVE_SCROLL_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_LIVE_VERIFY"] = "1"
        app.launchEnvironment["TESSERA_LIVE_SCROLL_CONFIG_B64"] = config
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        for session in [codexSession, claudeSession] {
            let row = app.buttons["agent-center-v2-thread-\(session)"]
            XCTAssertTrue(row.waitForExistence(timeout: 60))
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-detail"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["agent-center-v2-open-terminal"].exists)
        }
        let search = app.textFields["agent-center-v2-search"]
        XCTAssertTrue(search.exists)
        for (provider, name) in [("pi", "Pi"), ("opencode", "OpenCode")] {
            let clear = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "agent-center-v2-search", "clear")).firstMatch
            if clear.exists { clear.tap() }
            search.tap()
            let query = "Tessera \(name) verification complete"
            search.typeText(query)
            XCTAssertEqual(search.value as? String, query)
            let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "agent-center-v2-search-result-\(provider)-", query)).firstMatch
            let found = result.waitForExistence(timeout: 45)
            XCTAssertTrue(found, "\(name) historical result must be searchable through the real projector")
            result.tap()
            XCTAssertTrue(app.staticTexts[query + "."].waitForExistence(timeout: 30))
        }
        print("TESSERA_AGENT_LIVE_UI verified=codex,claude,pi-history,opencode-history")
    }

    func testSetLandscapeOnly() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        usleep(500_000)
    }

    func testSetLandscapeWithActiveApp() throws {
        try requireVisualCaptureRun()
        // iPhone SpringBoard does not adopt a landscape orientation on its own.
        // Keep Tessera active while changing the device orientation so the
        // orientation persists for the following external simctl captures.
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_FORCE_TOUR_STEP"] = "0"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        usleep(500_000)
    }

    func testCaptureOnboardingLayoutMatrix() throws {
        try requireVisualCaptureRun()
        let app = XCUIApplication()
        continueAfterFailure = false
        let orientations: [(String, UIDeviceOrientation)] = [
            ("portrait", .portrait),
            ("landscape", .landscapeLeft),
        ]

        for (orientationName, orientation) in orientations {
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "TESSERA_FORCE_TOUR_STEP")
            app.launchEnvironment["TESSERA_FORCE_TOUR_WELCOME"] = "1"
            app.launch()
            XCUIDevice.shared.orientation = orientation

            let welcome = app.staticTexts["welcome to Tessera"]
            XCTAssertTrue(
                welcome.waitForExistence(timeout: 5),
                "missing onboarding welcome in \(orientationName)"
            )
            usleep(600_000)
            mark("onboarding-\(orientationName)-welcome")
            usleep(1_500_000)

            app.terminate()
            app.launchEnvironment.removeValue(forKey: "TESSERA_FORCE_TOUR_WELCOME")
            app.launchEnvironment["TESSERA_FORCE_TOUR_STEP"] = "0"
            app.launch()
            XCUIDevice.shared.orientation = orientation

            for step in 0..<9 {
                let counter = app.staticTexts["STEP \(step + 1) OF 9"]
                XCTAssertTrue(
                    counter.waitForExistence(timeout: 5),
                    "missing onboarding step \(step + 1) in \(orientationName)"
                )
                usleep(600_000)

                mark("onboarding-\(orientationName)-step-\(step + 1)")
                usleep(1_500_000)

                if step < 8 {
                    let next = app.buttons["onboarding-next"]
                    XCTAssertTrue(next.waitForExistence(timeout: 2), "next button is missing")
                    next.tap()
                }
            }
        }
    }

    func testFilesContextMenuLifecycle() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "README.md")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "README fixture row is missing")

        mark("before-long-press")
        // Give the external simctl recorder an unmistakable stable frame
        // after XCUITest's runner completes its portrait -> landscape change.
        usleep(500_000)
        row.press(forDuration: 1.1)
        mark("menu-presented")
        usleep(1_200_000)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.10)).tap()
        mark("menu-dismissed")
        usleep(1_500_000)
        mark("post-dismiss-settled")
    }

    func testAgentCenterMarkdownRendersStructuredReplyWithoutTabs() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "markdown"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-claude-thread-visual"]
        if !app.staticTexts["Deployment summary"].waitForExistence(timeout: 5), row.exists { row.tap() }
        XCTAssertTrue(app.staticTexts["Deployment summary"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Back up state"].exists)
        XCTAssertTrue(app.staticTexts["Check"].exists)
        XCTAssertTrue(app.staticTexts["passing"].exists)
        XCTAssertTrue(app.buttons["Copy code"].exists)
        XCTAssertFalse(app.staticTexts["# Deployment summary"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-tab-activity"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-tab-changes"].exists)
    }

    func testAgentStreamingRetainsAVisibleTranscriptAfterSourceReset() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "streaming"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        transcript.swipeDown(velocity: .fast)
        transcript.swipeDown(velocity: .fast)
        captureAgentHistory("streaming-before")
        Thread.sleep(forTimeInterval: 5)
        captureAgentHistory("streaming-after")
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History message "))
        let viewport = transcript.frame
        XCTAssertTrue(rows.allElementsBoundByIndex.contains {
            let frame = $0.frame
            return frame.width > 0 && frame.height > 0
                && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                && $0.isHittable
        },
                      "A replaced history anchor must not leave an empty transcript viewport")
    }

    func testSessionQueueKeepsUpWithTwoSustainedOutputStreams() throws {
        try runSessionQueuePressure(tmux: false)
    }

    func testSessionQueueKeepsUpWithTwoTmuxControlStreams() throws {
        try runSessionQueuePressure(tmux: true)
    }

    private func runSessionQueuePressure(tmux: Bool) throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_SESSION_QUEUE_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_QUEUE_TMUX"] = tmux ? "1" : "0"
        let rounds = min(9_000, max(1, Int(ProcessInfo.processInfo.environment["TESSERA_QUEUE_ROUNDS"] ?? "900") ?? 900))
        app.launchEnvironment["TESSERA_QUEUE_ROUNDS"] = String(rounds)
        app.launchEnvironment["TESSERA_QUEUE_BURST"] = ProcessInfo.processInfo.environment["TESSERA_QUEUE_BURST"] ?? "16"
        if let legacyPublication = ProcessInfo.processInfo.environment[
            "TESSERA_QUEUE_LEGACY_PUBLICATION"
        ] {
            app.launchEnvironment["TESSERA_QUEUE_LEGACY_PUBLICATION"] = legacyPublication
        }
        app.launch()
        let status = app.staticTexts["session-queue-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 8)
        captureAgentHistory("queue-under-load")
        let done = NSPredicate(format: "label CONTAINS %@", "done=true")
        expectation(for: done, evaluatedWith: status)
        waitForExpectations(timeout: Double(rounds) * 0.016 + 45)
        captureAgentHistory("queue-drained")
        XCTAssertTrue(status.label.contains("orderFailures=0"), status.label)
        let maximum = status.label.components(separatedBy: "maxAgeMs=").last?
            .components(separatedBy: " ").first.flatMap(Int.init)
        XCTAssertLessThan(try XCTUnwrap(maximum), 1_000, status.label)
        let maximumInput = status.label.components(separatedBy: "maxInputMs=").last?
            .components(separatedBy: " ").first.flatMap(Int.init)
        XCTAssertLessThan(try XCTUnwrap(maximumInput), 250, status.label)
    }

    func testAgentDiscoveryKeepsRowsStationaryWhilePolling() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "discovery"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        let claude = app.staticTexts["Claude stable row"].firstMatch
        let codex = app.staticTexts["Codex stable row"].firstMatch
        XCTAssertTrue(claude.waitForExistence(timeout: 8))
        XCTAssertTrue(codex.waitForExistence(timeout: 8))
        let firstY = claude.frame.minY
        let secondY = codex.frame.minY
        captureAgentHistory("discovery-before")
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.15)
            XCTAssertEqual(claude.frame.minY, firstY, accuracy: 1)
            XCTAssertEqual(codex.frame.minY, secondY, accuracy: 1)
        }
        captureAgentHistory("discovery-after")
    }

    func testAgentListRowsFollowSectionMoves() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "sectionMoves"
        app.launch()
        // A row that moved sections once kept the label it first had there.
        let settled = [
            ("moves-a", "Migrate signing tokens, waitingForInput"),
            ("moves-b", "Pricing page copy, finished"),
            ("moves-c", "Document npm scripts, finished"),
        ]
        for (session, label) in settled {
            let row = app.buttons["agent-center-v2-thread-\(session)"]
            wait(for: [expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: row)], timeout: 15)
        }
        captureAgentHistory("section-moves-settled")
        // ...and took no taps. The scene first selects moves-a.
        let fixture = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")
        ).firstMatch
        for session in ["moves-c", "moves-b", "moves-a"] {
            app.buttons["agent-center-v2-thread-\(session)"].tap()
            wait(for: [expectation(for: NSPredicate(format: "identifier ENDSWITH %@", ";selected=\(session)"),
                                   evaluatedWith: fixture)], timeout: 5)
        }
    }

    func testAgentHistoryLoadsWhileScrollingAndPreservesPosition() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "history"
        app.launch()
        let transcript = app.scrollViews["agent-center-v2-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["load older"].exists)
        let fixture = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")
        ).firstMatch
        XCTAssertTrue(fixture.identifier.contains("cursor=60;historyLoading=false"), "A long transcript should begin at the latest loaded page")
        let newest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History message 179 ")).firstMatch
        XCTAssertTrue(newest.isHittable, "Opening a thread must show its conversational tail")
        for _ in 0..<8 {
            if fixture.identifier.contains("historyLoading=true") { break }
            transcript.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(fixture.identifier.contains("cursor=60;"), "Capture the anchor before the first prepend")
        XCTAssertTrue(fixture.identifier.contains("historyLoading=true"), "Approaching history must automatically load a page")
        let visible = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History message "))
            .allElementsBoundByIndex.first { element in
                let frame = element.frame
                // AX can throw while asking an offscreen lazy text row for
                // an activation point. Filter by viewport geometry first;
                // the chosen row must still pass hittability below.
                return frame.minY > transcript.frame.minY + 25
                    && frame.maxY < transcript.frame.maxY - 25
                    && frame.width > 0 && frame.height > 0 && element.isHittable
            }
        let anchorLabel = try XCTUnwrap(visible).label
        // An index-bound XCUI element would silently become a different row
        // after prepend. Resolve the same message text on both sides instead.
        let anchor = app.staticTexts[anchorLabel]
        let before = anchor.frame.minY
        let beforeX = anchor.frame.minX
        captureAgentHistory("history-before")
        let loaded = NSPredicate { _, _ in fixture.identifier.contains("cursor=30;") }
        expectation(for: loaded, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(anchor.isHittable, "The original message must remain visible after prepend")
        XCTAssertEqual(anchor.frame.minY, before, accuracy: 4, "Prepending must preserve the visible message and its pixel offset")
        XCTAssertEqual(anchor.frame.minX, beforeX, accuracy: 1, "Prepending must preserve the transcript gutter")
        captureAgentHistory("history-after")
        XCTAssertFalse(app.buttons["load older"].exists)
    }

    func testAgentShortHistoryRetriesAndFillsWithoutAButton() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "shortHistory"
        app.launch()
        let fixture = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        let loaded = NSPredicate { _, _ in fixture.identifier.contains("cursor=58;") }
        expectation(for: loaded, evaluatedWith: nil)
        waitForExpectations(timeout: 12)
        captureAgentHistory("history-retried")
        XCTAssertFalse(app.buttons["load older"].exists)
    }

    /// Each live prompt card Core publishes from a real TUI screen, answered
    /// in place. The fixture logs the answer goal instead of writing to a
    /// terminal; the aggregate reviewer grades the retained `prompt-` shots.
    func testAgentLivePromptCardsAnswerInPlace() throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        func open(_ variant: String, showing text: String) -> XCUIElement {
            app.terminate()
            app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
            app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "prompt"
            app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_PROMPT"] = variant
            app.launch()
            let marker = app.staticTexts[text]
            if !marker.waitForExistence(timeout: 5) {
                let row = app.buttons["agent-center-v2-thread-claude-thread-visual"]
                if row.exists { row.tap() }
            }
            XCTAssertTrue(marker.waitForExistence(timeout: 8), "\(variant) card is missing \(text)")
            marker.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 1)
            return marker
        }
        func answer(_ id: String) -> XCUIElement { app.descendants(matching: .any)["agent-center-v2-answer-\(id)"].firstMatch }
        func control(_ kind: String) -> XCUIElement { answer("control-\(kind)") }

        _ = open("question", showing: "Which database should the service use for the new ledger?")
        for id in ["1", "2", "3", "4", "5"] { XCTAssertTrue(answer(id).exists, "question option \(id)") }
        XCTAssertTrue(app.staticTexts["Mature, transactional, already deployed."].exists)
        XCTAssertTrue(control("cancel").exists)
        captureAgentHistory("prompt-question")
        answer("4").tap()
        let field = answer("text")
        XCTAssertTrue(field.waitForExistence(timeout: 3), "the freeform row opens a text field")
        field.tap()
        dismissQuickPathTutorialIfNeeded(in: app)
        field.typeText("CockroachDB")
        Thread.sleep(forTimeInterval: 1)
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1,
                                     "the software keyboard must not hide the answer field")
        }
        let transcript = app.scrollViews["agent-center-v2-transcript"].firstMatch
        XCTAssertGreaterThanOrEqual(field.frame.minY, transcript.frame.minY - 1,
                                    "the answer field is scrolled fully into the transcript")
        XCTAssertTrue(answer("send").isHittable)
        captureAgentHistory("prompt-question-freeform-typing")

        _ = open("typed", showing: "Which database should the service use for the new ledger?")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CockroachDB, with a read replica")).firstMatch.exists,
                      "text already typed in the terminal is shown")
        captureAgentHistory("prompt-typed")

        _ = open("multiSelect", showing: "Which features should ship first?")
        for id in ["1", "2", "3"] { XCTAssertTrue(answer(id).exists, "multi-select option \(id)") }
        XCTAssertTrue(control("next").exists)
        captureAgentHistory("prompt-multi-select")

        _ = open("review", showing: "Ready to submit your answers?")
        XCTAssertTrue(answer("1").exists)
        captureAgentHistory("prompt-review")

        _ = open("text", showing: "Describe the rollout window you prefer.")
        XCTAssertTrue(answer("text").exists, "a text-only prompt shows its field directly")
        XCTAssertTrue(control("skip").exists)
        captureAgentHistory("prompt-text")

        _ = open("deferred", showing: "2 questions waiting")
        XCTAssertTrue(control("open").isHittable)
        captureAgentHistory("prompt-deferred")

        _ = open("permission", showing: "Run this command?")
        for id in ["1", "2", "3", "4"] { XCTAssertTrue(answer(id).exists, "permission option \(id)") }
        captureAgentHistory("prompt-permission")
        answer("1").tap()
    }

    private func captureAgentHistory(_ name: String) {
        // This fixture contains native SwiftUI only, with no Metal terminal.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAgentComposerActionFeedback() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["TESSERA_AGENT_COMPACT_PORTRAIT"] == "1" ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "outgoing"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-codex-thread-visual"]
        if !app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 2), row.exists { row.tap() }
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Check the next instruction.")
        let send = app.buttons["agent-center-v2-send"]
        XCTAssertTrue(send.isHittable)
        send.tap()
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(send.label, "sending message")
        composer.typeText(" Additional edit")
        usleep(4_000_000)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue((composer.value as? String)?.hasSuffix("Additional edit") == true)
        send.press(forDuration: 0.7)
        let queue = app.buttons["Queue message"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        queue.tap()
        XCTAssertFalse(send.isEnabled)
        usleep(4_000_000)

        let attach = app.buttons["agent-center-v2-attach"]
        XCTAssertTrue(attach.isHittable)
        attach.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        cancel.tap()
        XCTAssertTrue(attach.waitForExistence(timeout: 3))
        attach.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        let file = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "tessera-attachment-fixture")).firstMatch
        if !file.waitForExistence(timeout: 2) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
            if !file.waitForExistence(timeout: 2) {
                let local = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "On My i")).firstMatch
                XCTAssertTrue(local.waitForExistence(timeout: 5))
                local.tap()
                let folder = app.cells.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", "Tessera, Container", "Tessera,")).firstMatch
                XCTAssertTrue(folder.waitForExistence(timeout: 5))
                folder.tap()
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 1) { open.tap() }
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        XCTAssertEqual(attach.label, "uploading attachment")
        composer.tap()
        composer.typeText("Review this file")
        usleep(4_000_000)
        XCTAssertTrue((composer.value as? String)?.contains("Review this file") == true)
        XCTAssertTrue((composer.value as? String)?.contains("/fixture/private-upload/tessera-attachment-fixture.txt") == true)
        XCTAssertTrue(app.buttons["agent-center-v2-send"].isEnabled)
    }

    /// The connection-free fixture exercises both choices in the exact
    /// production alert. Provider delivery and one-key consumption are
    /// covered by the coordinator and adapter suites.
    func testAgentSendAnywayAlertKeepsOrSubmitsTheReturnedDraft() throws {
        try requireVisualCaptureRun()
        continueAfterFailure = false
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "sendAnyway"
        app.launch()
        let alert = app.alerts["Agent Center"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        // Native alert actions can omit SwiftUI accessibility identifiers.
        // Match the exact visible label as well, while requiring a real,
        // hittable button before either action is exercised.
        let sendAnyway = alert.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "agent-center-send-anyway", "Send anyway")).firstMatch
        XCTAssertTrue(sendAnyway.waitForExistence(timeout: 3))
        XCTAssertTrue(sendAnyway.isHittable)
        XCTAssertEqual(sendAnyway.label, "Send anyway")
        XCTAssertTrue(alert.buttons["OK"].isHittable)
        captureAgentHistory("send-anyway-eligible-alert")
        mark("agent-send-anyway-alert")
        holdForExternalCapture()

        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        func openSelectedFixtureThreadIfNeeded() {
            if !composer.waitForExistence(timeout: 2) {
                let row = app.buttons["agent-center-v2-thread-claude-thread-visual"]
                XCTAssertTrue(row.waitForExistence(timeout: 3))
                XCTAssertTrue(row.isHittable)
                row.tap()
            }
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
        }
        openSelectedFixtureThreadIfNeeded()
        XCTAssertEqual(composer.value as? String, "Please check the next result.", "OK must keep the returned draft")
        XCTAssertTrue(app.buttons["agent-center-v2-send"].isEnabled)

        app.terminate()
        app.launch()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(sendAnyway.isHittable)
        sendAnyway.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        openSelectedFixtureThreadIfNeeded()
        let dictation = app.buttons["agent-center-v2-dictation"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (composer.value as? String)?.isEmpty == true
                && dictation.exists && dictation.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 8), .completed)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "agent-center-send-anyway", "Send anyway")).firstMatch.exists, "the one-shot approval must be consumed")
        XCTAssertFalse(alert.exists)
        captureAgentHistory("send-anyway-submitted-draft")
        mark("agent-send-anyway-submitted")
        holdForExternalCapture()
    }

    func testAgentComposerNativeKeyboardGeometry() throws {
        try requireVisualCaptureRun()
        let portrait = ProcessInfo.processInfo.environment["TESSERA_AGENT_COMPACT_PORTRAIT"] == "1"
        XCUIDevice.shared.orientation = portrait ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "outgoing"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_DYNAMIC_TYPE"] =
            ProcessInfo.processInfo.environment["TESSERA_AGENT_COMPOSER_DYNAMIC_TYPE"] ?? "standard"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-codex-thread-visual"]
        if !app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 2), row.exists { row.tap() }
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Check the next instruction.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        usleep(1_000_000)
        // UIKit's full frame includes native prediction/shortcut chrome that
        // XCUI's keyboard element may omit from its own bounding rectangle.
        let marker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-keyboard|")
        ).firstMatch
        let fields = marker.label.split(separator: ";").reduce(into: [String: Double]()) { result, item in
            let pair = item.split(separator: "=")
            if pair.count == 2 { result[String(pair[0])] = Double(pair[1]) }
        }
        let top = try XCTUnwrap(fields["minY"])
        XCTAssertGreaterThan(try XCTUnwrap(fields["height"]), 100)
        let gap = top - composer.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "input must stay above the native keyboard")
        XCTAssertLessThanOrEqual(gap, 35, "only composer padding may separate the input from keyboard chrome")
        XCTAssertTrue(app.buttons["agent-center-v2-send"].isHittable)
        print("TESSERA_AGENT_COMPOSER_GEOMETRY portrait=\(portrait) gap=\(gap) composer=\(composer.frame) nativeKeyboardTop=\(top)")
        mark("agent-composer-native-keyboard")
        usleep(5_000_000)
        composer.typeText("\nSecond line\nThird line\nFourth line\nFifth line")
        XCTAssertTrue((composer.value as? String)?.hasSuffix("Fifth line") == true)
        XCTAssertGreaterThanOrEqual(top - composer.frame.maxY, -1)
        XCTAssertLessThanOrEqual(top - composer.frame.maxY, 35)
        XCTAssertTrue(app.buttons["agent-center-v2-send"].isHittable)
    }

    func testAgentCenterCompactComposerAndPendingMessage() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["TESSERA_AGENT_COMPACT_PORTRAIT"] == "1" ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "outgoing"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-codex-thread-visual"]
        if !app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 2), row.exists { row.tap() }
        XCTAssertTrue(app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["agent-center-v2-send"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "waiting for transcript…")).firstMatch.exists)
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        XCTAssertTrue(composer.exists)
        XCTAssertLessThan(composer.frame.height, 60)
        composer.tap()
        composer.typeText("Check the result")
        composer.typeText("\nSecond line")
        XCTAssertEqual(composer.value as? String, "Check the result\nSecond line", "Return must insert a newline, not submit or clear the draft")
        XCTAssertTrue(app.buttons["agent-center-v2-send"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["agent-center-v2-dictation"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-send"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["agent-center-v2-send"].frame.height, 44)
    }

    /// The send glyph carries the ⌘↩ hint only while it sends. XCUITest's
    /// `typeKey` never delivers Return itself here (the text view receives
    /// only the modifier presses), so the Return, ⇧Return, ⌘Return and
    /// ⌃Return behaviour is driven over real HID by
    /// scripts/uitest/run-agent-composer-hardware-keys.sh.
    func testAgentComposerSendShortcutHint() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["TESSERA_AGENT_COMPACT_PORTRAIT"] == "1" ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "outgoing"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_HARDWARE_KEYBOARD"] = "1"
        app.launch()
        let row = app.buttons["agent-center-v2-thread-codex-thread-visual"]
        if !app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 2), row.exists { row.tap() }
        XCTAssertTrue(app.buttons["agent-center-v2-dictation"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["agent-center-v2-dictation"].value as? String ?? "", "", "the microphone carries no send hint")
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("First line")
        composer.typeText("\nSecond line")
        XCTAssertEqual(composer.value as? String, "First line\nSecond line", "software Return must insert a newline")
        let send = app.buttons["agent-center-v2-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertEqual(send.value as? String, "command return")
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        mark("agent-composer-send-shortcut-hint")
        let hint = XCTAttachment(screenshot: app.screenshot())
        hint.name = "agent-composer-send-shortcut-hint"
        hint.lifetime = .keepAlways
        add(hint)
        send.tap()
        XCTAssertEqual(send.label, "sending message")
        XCTAssertEqual(send.value as? String ?? "", "", "no hint while the send is pending")
    }

    func testAgentCenterV2HarnessCoversThreadHierarchyAndActions() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-list"]
            .waitForExistence(timeout: 8), "V2 thread list is missing")
        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-detail"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-thread-claude-thread-visual"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-thread-codex-thread-visual"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-answer-1"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-answer-2"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-answer-3"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-tab-live"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-tab-activity"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-tab-changes"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-fork"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-open-terminal"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-new"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-dictation"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-send"].exists)
        XCTAssertFalse(app.buttons["agent-center-v2-interrupt"].exists)
        app.buttons["agent-center-v2-thread-codex-thread-visual"].tap()
        XCTAssertTrue(app.buttons["agent-center-v2-interrupt"].waitForExistence(timeout: 3))
        app.buttons["agent-center-v2-thread-claude-thread-visual"].tap()
        XCTAssertTrue(app.staticTexts["needs you"].exists)
        XCTAssertTrue(app.staticTexts["working"].exists)
        XCTAssertTrue(app.staticTexts["finished"].exists)
        XCTAssertTrue(app.staticTexts["recent"].exists)
        XCTAssertTrue(app.staticTexts["live terminals"].exists)
        XCTAssertTrue(app.buttons["agent-center-v2-candidate-fixture-unproven-live-agent"].exists)
        XCTAssertTrue(app.staticTexts["claude · opus"].exists)
        XCTAssertTrue(app.staticTexts["plan mode"].exists)
        XCTAssertTrue(app.staticTexts["tessera · fix/files-flicker"].exists)
        XCTAssertTrue(app.staticTexts["62% ctx"].exists)
        XCTAssertTrue(app.staticTexts["$1.24"].exists)
        XCTAssertTrue(app.staticTexts["Investigate the files panel flicker and make a plan."].exists)
        XCTAssertTrue(app.staticTexts["I found a context-menu backdrop transition that needs an opaque backstop."].exists)
        let toolRun = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agent-tool-run-")).firstMatch
        XCTAssertTrue(toolRun.exists)
        XCTAssertEqual(toolRun.value as? String, "collapsed")
        toolRun.staticTexts["1 tool call"].tap()
        XCTAssertTrue(app.staticTexts["thinking · tap to expand"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Read"].exists)
        toolRun.staticTexts["1 tool call"].tap()
        XCTAssertTrue(app.staticTexts["Tessera/Files/FilesPanelView.swift"].exists)
        XCTAssertTrue(app.staticTexts["workflow"].exists)
        XCTAssertTrue(app.staticTexts["subagents · 1"].exists)
        XCTAssertTrue(app.staticTexts["capture a reproducer"].exists)
        XCTAssertTrue(app.staticTexts["verify context-menu timing"].exists)

        app.buttons["agent-center-v2-new"].tap()
        XCTAssertTrue(app.buttons["agent-center-v2-submit-launch"].waitForExistence(timeout: 3))
        app.buttons["cancel"].tap()

        app.buttons["agent-center-v2-fork"].tap()
        XCTAssertTrue(app.buttons["agent-center-v2-submit-launch"].waitForExistence(timeout: 3))
        app.buttons["cancel"].tap()

        app.buttons["agent-center-v2-candidate-fixture-unproven-live-agent"].tap()
        let fallbackMessage = "This live agent has no proven provider conversation identity. Transcript history, search, cost, changes, spawn, and fork remain unavailable."
        let fallback = app.staticTexts.matching(
            NSPredicate(format: "label == %@", fallbackMessage)
        ).firstMatch
        XCTAssertTrue(
            fallback.waitForExistence(timeout: 3),
            "V2 degraded live-terminal fallback is missing"
        )
    }

    func testAgentCenterV2HarnessCoversLoadingAndCompactUrgentFallback() throws {
        try requireVisualCaptureRun()
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "loading"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-list"]
            .waitForExistence(timeout: 8), "V2 loading list is missing")
        XCTAssertEqual(app.textFields["search all transcripts"].value as? String, "files")
        XCTAssertTrue(app.staticTexts["transcript matches"].exists)
        XCTAssertTrue(app.activityIndicators.firstMatch.exists, "V2 search loading indicator is missing")

        app.terminate()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "compact"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-list"]
            .waitForExistence(timeout: 8), "V2 compact list is missing")
        XCTAssertTrue(app.buttons["agent-center-v2-new-fab"].exists, "V2 compact launch FAB is missing")
        XCTAssertTrue(app.buttons["open terminal to answer"].exists)
        let row = app.buttons["agent-center-v2-thread-claude-thread-visual"]
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-detail"]
            .waitForExistence(timeout: 3), "V2 compact detail did not open")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "V2 compact list did not return")
        XCTAssertTrue(app.buttons["open terminal to answer"].exists)

        app.terminate()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "integration"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["agent-center-v2-thread-list"]
            .waitForExistence(timeout: 8), "V2 integration fixture list is missing")
        XCTAssertFalse(
            app.descendants(matching: .any)["agent-center-v2-integration-status"].exists,
            "Host integration repair must not be rendered inside Agent Center",
        )
    }

    func testAgentCenterV2HarnessCoversErrorTraitsAndKeyboardFocus() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "error"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_APPEARANCE"] = "dark"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_DYNAMIC_TYPE"] = "accessibility3"
        app.launch()

        let fixture = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "agent-center-v2-fixture|")
        ).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 8), "V2 fixture state is missing")
        assertFixtureState(
            fixture,
            contains: "scene=error;appearance=dark;dynamicType=accessibility3",
            message: "V2 error fixture did not apply its dark Dynamic Type traits"
        )
        XCTAssertTrue(app.alerts["Agent Center"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The transcript source changed. Open Terminal to continue safely."].exists)
        app.alerts["Agent Center"].buttons["OK"].tap()

        app.terminate()
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_SCENE"] = "primary"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_APPEARANCE"] = "light"
        app.launchEnvironment["TESSERA_AGENT_CENTER_V2_HARNESS_DYNAMIC_TYPE"] = "standard"
        app.launch()

        XCTAssertTrue(fixture.waitForExistence(timeout: 8), "V2 light fixture state is missing")
        assertFixtureState(
            fixture,
            contains: "scene=primary;appearance=light;dynamicType=standard;focus=action",
            message: "V2 fixture did not expose the prompt action focus"
        )
        app.buttons["agent-center-v2-thread-codex-thread-visual"].tap()
        assertFixtureState(fixture, contains: "focus=list", message: "Selecting a row did not move V2 keyboard focus to the list")
        app.buttons["agent-center-v2-thread-claude-thread-visual"].tap()
        let composer = app.descendants(matching: .any)["agent-center-v2-composer"].firstMatch
        XCTAssertEqual(composer.label, "answer above, or type to redirect")
        composer.tap()
        assertFixtureState(fixture, contains: "focus=composer", message: "Composer focus did not reach the V2 keyboard focus model")
    }

    func testWaitForLiveScrollReady() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let ready = NSPredicate(format: "value == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "live scroll harness did not become ready; value=\(String(describing: status.value))"
        )
        waitForLiveScrollInitialRenderFence(in: app)
        usleep(1_500_000)
    }

    /// Presentation fence for captures that launch the live-session harness
    /// outside XCTest. Remote tmux geometry can settle while the app is still
    /// covering its not-yet-hydrated pane with the launch shield, so geometry
    /// alone is not safe evidence that a terminal is on screen.
    func testWaitForLiveScrollTerminalPresentation() throws {
        try requireVisualCaptureRun()
        let app = XCUIApplication()
        app.activate()

        waitForLiveScrollTerminalPresentation(in: app)
    }

    /// Phone-only presentation fence for P1. A brand-new simulator may put the
    /// system QuickPath tutorial over the first software keyboard. Clear that
    /// one-time sheet and prove the real keyboard is present before simctl
    /// captures the Metal-backed terminal surface.
    func testWaitForLiveScrollPhoneKeyboardPresentation() throws {
        try requireVisualCaptureRun()
        let app = XCUIApplication()
        app.activate()

        waitForLiveScrollTerminalPresentation(in: app)
        dismissQuickPathTutorialIfNeeded(in: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "phone software keyboard was not presented"
        )
        dismissDisposableSimulatorSystemBannerIfNeeded(returningTo: app)
        XCTAssertFalse(
            quickPathTutorial(in: app).exists,
            "QuickPath tutorial remained over the keyboard after the presentation fence"
        )
        // The capture script screenshots the device right after this probe
        // returns; the phone must still show the app, its keyboard, and a
        // hittable terminal, not whatever a system gesture may have opened.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "the app is not frontmost at the end of the phone keyboard probe"
        )
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the software keyboard was lost")
        let terminal = app.descendants(matching: .any)["live-scroll-terminal"]
        XCTAssertTrue(terminal.exists && terminal.isHittable, "the focused terminal is no longer hittable")
    }

    private func waitForLiveScrollTerminalPresentation(in app: XCUIApplication) {

        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let ready = NSPredicate(format: "value == %@", "ready")
        let readyExpectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [readyExpectation], timeout: 55),
            .completed,
            "live scroll harness did not finish its first pane render; value=\(String(describing: status.value))"
        )
        waitForLiveScrollInitialRenderFence(in: app)

        let terminal = app.descendants(matching: .any)["live-scroll-terminal"]
        let presented = NSPredicate { _, _ in
            terminal.exists
                && terminal.isHittable
                && terminal.frame.width >= 250
                && terminal.frame.height >= 250
        }
        let presentationExpectation = XCTNSPredicateExpectation(
            predicate: presented,
            object: terminal
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [presentationExpectation], timeout: 15),
            .completed,
            "focused terminal pane was not visibly presented; frame=\(terminal.frame), hittable=\(terminal.isHittable)"
        )
    }

    private func dismissQuickPathTutorialIfNeeded(in app: XCUIApplication) {
        let tutorialCopy = quickPathTutorial(in: app)
        guard tutorialCopy.waitForExistence(timeout: 2) else { return }

        // The sheet can ignore a tap that lands while the keyboard is still
        // settling (seen once in P1 with show edges); tap again, up to three
        // times, before judging it.
        let dismissed = NSPredicate(format: "exists == false")
        var result = XCTWaiter.Result.timedOut
        var taps = 0
        for _ in 0..<3 {
            let keyboardContinue = app.keyboards.buttons["Continue"].firstMatch
            let continueButton = keyboardContinue.exists
                ? keyboardContinue
                : app.buttons["Continue"].firstMatch
            guard continueButton.waitForExistence(timeout: 2) else { break }
            continueButton.tap()
            taps += 1
            let expectation = XCTNSPredicateExpectation(predicate: dismissed, object: tutorialCopy)
            result = XCTWaiter.wait(for: [expectation], timeout: 3)
            if result == .completed { break }
        }
        XCTAssertGreaterThan(taps, 0, "QuickPath tutorial appeared without its Continue button")
        XCTAssertEqual(result, .completed, "QuickPath tutorial did not dismiss after \(taps) taps")
    }

    /// A newly created iOS 26 simulator can post this one-time SpringBoard
    /// bulletin while the keyboard probe is running. It is not app output and
    /// otherwise obscures the terminal pixels that P1 is meant to grade.
    ///
    /// The swipe that dismisses it can land as a tap while the banner is still
    /// animating in; SpringBoard then opens the bulletin in Settings (Apple
    /// Intelligence & Siri) on top of the app. Either way the probe ends with
    /// Settings gone and the app frontmost again, so the capture that follows
    /// grades terminal pixels rather than a Settings page.
    private func dismissDisposableSimulatorSystemBannerIfNeeded(returningTo app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.staticTexts["Ready for Apple Intelligence"].firstMatch
        if banner.waitForExistence(timeout: 2) {
            banner.swipeUp()
            let dismissed = NSPredicate(format: "exists == false")
            let expectation = XCTNSPredicateExpectation(predicate: dismissed, object: banner)
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation], timeout: 5),
                .completed,
                "system setup notification remained over the P1 terminal capture"
            )
        }

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        if settings.state == .runningForeground {
            settings.terminate()
        }
        if app.state != .runningForeground {
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 5),
                "the app did not return to the foreground after the system banner"
            )
        }
    }

    private func quickPathTutorial(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "Speed up your typing by sliding your finger across the letters"
            )
        ).firstMatch
    }

    private func assertFixtureState(
        _ fixture: XCUIElement,
        contains value: String,
        message: String
    ) {
        let expected = NSPredicate(format: "identifier CONTAINS %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: expected, object: fixture)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, message)
    }

    func testLiveFirstFlickMomentum() throws {
        try requireVisualCaptureRun()
        let app = readyLiveScrollApp()
        let distance = CGFloat(Double(ProcessInfo.processInfo.environment["TESSERA_FLICK_DISTANCE"] ?? "900") ?? 900)
        let input = ProcessInfo.processInfo.environment["TESSERA_FLICK_INPUT"] ?? "pointer"
        func flick() {
            if input == "touch" { liveTerminal(in: app).swipeDown() }
            else if input == "diagonal" {
                let terminal = liveTerminal(in: app)
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35))
                    .press(forDuration: 0.05, thenDragTo: terminal.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)))
            }
            else { scrollLiveTerminal(in: app, deltaY: -distance) }
        }
        // Every milestone waits for the lane's capture: its three screenshot
        // candidates outlast the two-second settle, so an unheld second flick
        // landed inside the "first settled" capture.
        mark("flick-before")
        holdForExternalCapture()
        flick()
        mark("flick-first-return")
        holdForExternalCapture()
        usleep(2_000_000)
        mark("flick-first-settled")
        holdForExternalCapture()
        flick()
        mark("flick-second-return")
        holdForExternalCapture()
        usleep(2_000_000)
        mark("flick-second-settled")
        holdForExternalCapture()
    }

    func testLivePrimaryScrollRoundTrip() throws {
        try requireVisualCaptureRun()
        let app = readyLiveScrollApp()
        mark("primary-before")
        usleep(1_500_000)
        app.scroll(byDeltaX: 0, deltaY: -900)
        usleep(2_500_000)
        mark("primary-history")
        usleep(1_250_000)
        app.scroll(byDeltaX: 0, deltaY: 1_200)
        usleep(2_000_000)
        mark("primary-restored")
        usleep(1_250_000)
    }

    func testLiveAltScreenScrollRoundTrip() throws {
        try requireVisualCaptureRun()
        let app = readyLiveScrollApp()
        mark("alt-before")
        usleep(750_000)
        app.scroll(byDeltaX: 0, deltaY: -300)
        usleep(1_500_000)
        mark("alt-moved")
        usleep(1_000_000)
        app.scroll(byDeltaX: 0, deltaY: 300)
        usleep(1_500_000)
        mark("alt-restored")
        usleep(1_250_000)
    }

    /// S13: finger drags on a primary screen reach the whole history and come
    /// back, graded by the fixture rows the DEBUG harness reports on screen.
    /// A slow drag reveals history, flicks reach the oldest row, flicks return
    /// to the live tail where the fixture heartbeat must move again, and a
    /// second drag reveals history once more.
    func testLiveTouchPrimaryHistory() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)
        // 0: the local buffer has no complete history (plain mosh), so the
        // oldest loaded row is enough.
        let oldestRow = Int(ProcessInfo.processInfo.environment["TESSERA_TOUCH_HISTORY_OLDEST_ROW"] ?? "1") ?? 1
        func log(_ stage: String, _ rows: VisibleFixtureRows) {
            print("TESSERA_TOUCH_ROWS \(stage) \(rows)")
        }

        let start = waitForFixtureRows(in: app, timeout: 60) { $0.atTail && $0.high != nil && $0.tick != nil }
        log("start", start)
        XCTAssertTrue(start.atTail && start.high != nil, "the fixture rows never reached the live tail: \(start)")
        XCTAssertTrue(heartbeatAdvances(in: app, from: start), "the heartbeat never moved at the live tail")
        mark("touch-history-before")
        holdForExternalCapture()

        let before = visibleFixtureRows(in: app)
        fingerDragVisibleLiveTerminal(in: app, from: 0.2, to: 0.8, fast: false)
        let revealed = settledFixtureRows(in: app, from: waitForFixtureRows(in: app, timeout: 10) { rows in
            guard let high = rows.high, let beforeHigh = before.high else { return false }
            return high < beforeHigh
        })
        log("revealed", revealed)
        XCTAssertLessThan(revealed.high ?? .max, before.high ?? 0, "a finger drag did not reveal earlier rows: \(revealed)")
        mark("touch-history-revealed")
        holdForExternalCapture()

        // The pane kept ticking during the hold and printed the lane's burst
        // of new lines (TESSERA_TOUCH_HISTORY_BURST_LINES). Where those lines
        // reach this terminal, wait until they have. The lane grades whether
        // the reader stayed on the rows it was reading.
        let burst = Int(ProcessInfo.processInfo.environment["TESSERA_TOUCH_HISTORY_BURST_LINES"] ?? "0") ?? 0
        if burst > 0, let lines = revealed.lines {
            waitForFixtureRows(in: app, timeout: 6) { ($0.lines ?? 0) >= lines + burst }
        }
        var oldest = settledFixtureRows(in: app, from: visibleFixtureRows(in: app))
        log("held", oldest)
        var unchanged = 0
        for flick in 1...150 {
            if oldestRow > 0, oldest.low == oldestRow { break }
            if oldestRow == 0, oldest.atTop, unchanged >= 3 { break }
            fingerDragVisibleLiveTerminal(in: app, from: 0.15, to: 0.85, fast: true)
            usleep(1_200_000)
            let next = visibleFixtureRows(in: app)
            unchanged = next.raw == oldest.raw ? unchanged + 1 : 0
            oldest = next
            log("up-\(flick)", oldest)
            if unchanged >= 8 { break }
        }
        if oldestRow > 0 {
            XCTAssertEqual(oldest.low, oldestRow, "finger flicks did not reach the oldest row: \(oldest)")
        } else {
            XCTAssertTrue(oldest.atTop, "finger flicks did not reach the oldest loaded row: \(oldest)")
        }
        mark("touch-history-oldest")
        holdForExternalCapture()

        var tail = visibleFixtureRows(in: app)
        for flick in 1...150 {
            if tail.atTail, tail.high == start.high { break }
            fingerDragVisibleLiveTerminal(in: app, from: 0.85, to: 0.15, fast: true)
            usleep(1_200_000)
            tail = visibleFixtureRows(in: app)
            log("down-\(flick)", tail)
        }
        tail = waitForFixtureRows(in: app, timeout: 5) { $0.atTail && $0.tick != nil }
        log("tail", tail)
        XCTAssertTrue(tail.atTail, "finger flicks did not return to the live tail: \(tail)")
        XCTAssertTrue(heartbeatAdvances(in: app, from: tail), "live output did not resume at the tail: \(tail)")
        mark("touch-history-tail")
        holdForExternalCapture()

        // Returning to the tail must not latch the reveal off.
        let tailRows = visibleFixtureRows(in: app)
        fingerDragVisibleLiveTerminal(in: app, from: 0.2, to: 0.8, fast: false)
        let again = waitForFixtureRows(in: app, timeout: 10) { rows in
            guard let high = rows.high, let tailHigh = tailRows.high else { return false }
            return high < tailHigh
        }
        log("reentered", again)
        XCTAssertLessThan(again.high ?? .max, tailRows.high ?? 0, "a second finger drag did not reveal history: \(again)")
        mark("touch-history-reentered")
        holdForExternalCapture()

        fingerDragVisibleLiveTerminal(in: app, from: 0.8, to: 0.2, fast: false)
        var final = waitForFixtureRows(in: app, timeout: 5) { $0.atTail }
        for _ in 1...10 where !final.atTail {
            fingerDragVisibleLiveTerminal(in: app, from: 0.85, to: 0.15, fast: true)
            final = waitForFixtureRows(in: app, timeout: 3) { $0.atTail }
        }
        log("final", final)
        XCTAssertTrue(final.atTail, "the second reveal did not return to the live tail: \(final)")
        XCTAssertTrue(heartbeatAdvances(in: app, from: final), "live output did not resume after the second reveal: \(final)")
        mark("touch-history-final")
        holdForExternalCapture()
    }

    func testLiveScrollVisualSequence() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)
        // S12 drives htop and Vim with finger drags and taps. mosh+tmux
        // learns that they are full-screen only from the tmux pane state,
        // never from the relayed screen, and there the harness also keeps
        // their mouse modes off the surface. The lane keeps the keyboard up,
        // so a tap clicks instead of only focusing.
        let touch = ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_INPUT"] == "touch"
        func scrollProgram(_ deltaY: CGFloat) {
            if touch { dragLiveTerminal(in: app, deltaY: deltaY) }
            else { scrollLiveTerminal(in: app, deltaY: deltaY) }
        }

        mark("primary-before")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: -900)
        usleep(2_500_000)
        mark("primary-moved")
        holdForExternalCapture()
        scrollLiveTerminal(in: app, deltaY: 1_200)
        usleep(2_000_000)
        mark("primary-restored")
        holdForExternalCapture()

        mark("htop-before")
        holdForExternalCapture()
        scrollProgram(900)
        usleep(1_500_000)
        mark("htop-moved")
        holdForExternalCapture()
        scrollProgram(-900)
        usleep(1_500_000)
        mark("htop-restored")
        holdForExternalCapture()
        if touch {
            // A tap below the restored selection must select that process.
            tapVisibleLiveTerminal(in: app, fraction: 0.6, event: "htop-tapped")
            usleep(1_500_000)
            mark("htop-tapped")
            holdForExternalCapture()
        }
        // The lane ends htop after its last htop frame. Plain mosh cannot
        // report that Vim is up, so leave it paint time before the baseline;
        // the other transports' lanes also hold vim-before until Vim is up.
        usleep(touch ? 4_500_000 : 9_000_000)

        mark("vim-before")
        holdForExternalCapture()
        // Use the same asymmetric magnitude strategy as the primary-screen
        // round trip. Smaller symmetric wheel bursts can be swallowed by Vim
        // or fail to overcome the preceding synthesized gesture on the
        // simulator, yielding a no-op/continued-direction evidence frame even
        // though the forwarding path is live.
        scrollProgram(900)
        usleep(1_500_000)
        mark("vim-moved")
        holdForExternalCapture()
        scrollProgram(-1_200)
        usleep(1_500_000)
        mark("vim-restored")
        holdForExternalCapture()
        guard touch else { return }
        // Wheel scrolling leaves Vim's cursor on a window edge, so a click
        // in the middle of the visible rows must move it there. The lane
        // reads the pane cursor before acknowledging vim-tap-before and again
        // after vim-tapped, and grades it against the logged tap.
        mark("vim-tap-before")
        holdForExternalCapture()
        tapVisibleLiveTerminal(in: app, fraction: 0.5, event: "vim-tapped")
        usleep(1_500_000)
        mark("vim-tapped")
        holdForExternalCapture()
    }

    /// Lifecycle driver for the inline tmux foreground-repaint regression.
    /// The external simctl recorder is the oracle because SwiftTerm renders
    /// through CAMetalLayer and XCUIScreenshot sees a black surface.
    func testLiveTmuxForegroundRefresh() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)

        let status = app.descendants(matching: .any)["live-scroll-status"]
        mark("foreground-before-background")
        usleep(1_500_000)
        XCUIDevice.shared.press(.home)
        let leftForeground = NSPredicate { _, _ in
            app.state != .runningForeground
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: leftForeground, object: app)],
                timeout: 5
            ),
            .completed,
            "Home did not move Tessera out of the foreground"
        )
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "Tessera terminated instead of entering a background state"
        )
        mark("foreground-backgrounded")
        usleep(1_500_000)

        let activationStarted = Date()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        mark("foreground-activated")
        let live = NSPredicate(format: "value BEGINSWITH %@", "foreground-live")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: live, object: status)],
                timeout: 10
            ),
            .completed,
            "post-activation bytes did not traverse tmux into the rendered terminal"
        )
        let recoveryLatency = Date().timeIntervalSince(activationStarted)
        XCTAssertLessThan(
            recoveryLatency,
            4.0,
            "foreground recovery did not return Tessera and live tmux output promptly"
        )
        // Foreground metadata can remain empty while the control channel
        // recovers. Keep the recording alive through the controller's full
        // retry window so a delayed history replay cannot hide after teardown.
        usleep(20_000_000)
        XCTAssertGreaterThan(liveTerminal(in: app).frame.height, 200)
        guard let probeValue = status.value as? String,
              let feedCountField = probeValue.components(separatedBy: "|")
                .first(where: { $0.hasPrefix("feed-count=") }),
              let feedCount = Int(feedCountField.dropFirst("feed-count=".count)),
              let totalFeedField = probeValue.components(separatedBy: "|")
                .first(where: { $0.hasPrefix("total-feed=") }),
              let totalFeed = Int(totalFeedField.dropFirst("total-feed=".count)),
              let maxFeedText = probeValue.components(separatedBy: "max-feed=").last,
              let maxFeed = Int(maxFeedText)
        else {
            XCTFail("invalid foreground probe status: \(String(describing: status.value))")
            return
        }
        print("TESSERA_FOREGROUND_PROBE \(probeValue)")
        XCTAssertLessThanOrEqual(
            feedCount,
            4,
            "foreground recovery presented queued tmux redraws as separate visible feed steps (max-feed=\(maxFeed))"
        )
        XCTAssertLessThan(
            maxFeed,
            100_000,
            "foreground recovery replayed an unbounded redraw batch"
        )
        XCTAssertLessThan(
            totalFeed,
            150_000,
            "foreground recovery fed too much retained redraw data instead of the authoritative viewport"
        )
        mark("foreground-settled")
        usleep(1_500_000)
    }

    func testTmuxWindowOrderingDragAndMenu() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_TMUX_WINDOW_REORDER_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        let order = app.descendants(matching: .any)["tmux-window-order-value"]
        XCTAssertTrue(order.waitForExistence(timeout: 10))
        func capture(_ label: String) {
            NSLog("TESSERA_WINDOW_ORDER_CAPTURE %@", label)
            Thread.sleep(forTimeInterval: 1.5)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "tmux-order-" + label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let baseline = (1...15).map { "@\($0)" }
        XCTAssertEqual(order.value as? String, baseline.joined(separator: ","))
        let overflow = app.buttons["tmux-tab-overflow"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        overflow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tmux-window-list-1-row"].firstMatch.waitForExistence(timeout: 5))
        // The popover may initially reveal either end while layout settles.
        // Existence does not imply visibility in its scroll view.
        Thread.sleep(forTimeInterval: 0.5)
        let visibleIDs = (1...15).filter {
            app.descendants(matching: .any)["tmux-window-list-\($0)-row"].firstMatch.isHittable
        }
        XCTAssertGreaterThanOrEqual(visibleIDs.count, 4)
        guard visibleIDs.count >= 4 else { return }
        let sourceID = visibleIDs[visibleIDs.count / 2 - 1]
        let targetID = visibleIDs[visibleIDs.count / 2 + 1]
        let source = app.descendants(matching: .any)["tmux-window-list-\(sourceID)-row"].firstMatch
        let target = app.descendants(matching: .any)["tmux-window-list-\(targetID)-row"].firstMatch
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(target.isHittable)
        capture("before-drag")
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 0.32, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.9)))
        var expected = baseline
        expected.remove(at: sourceID - 1)
        expected.insert("@\(sourceID)", at: targetID - 1)
        XCTAssertTrue(order.waitForExistence(timeout: 3))
        let reordered = NSPredicate(format: "value == %@", expected.joined(separator: ","))
        expectation(for: reordered, evaluatedWith: order)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.descendants(matching: .any)["tmux-window-active-value"].value as? String, "@15")

        capture("after-drag")

        // Hold still opens a menu; an explicit action uses the same shared plan.
        source.press(forDuration: 0.85)
        let moveStart = app.buttons["Move to Start"].firstMatch
        XCTAssertTrue(moveStart.waitForExistence(timeout: 4))
        capture("menu")
        moveStart.tap()
        expected.removeAll { $0 == "@\(sourceID)" }
        expected.insert("@\(sourceID)", at: 0)
        expectation(for: NSPredicate(format: "value == %@", expected.joined(separator: ",")), evaluatedWith: order)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.descendants(matching: .any)["tmux-window-active-value"].value as? String, "@15")
    }

    func testTmuxWindowOrderingStrip() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TMUX_WINDOW_LIST_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_TMUX_WINDOW_REORDER_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        let order = app.descendants(matching: .any)["tmux-window-order-value"]
        XCTAssertTrue(order.waitForExistence(timeout: 10))
        let source = app.descendants(matching: .any)["tmux-window-8-tab"].firstMatch
        let target = app.descendants(matching: .any)["tmux-window-9-tab"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        // Let the initial active-tab reveal settle before measuring scrolling.
        Thread.sleep(forTimeInterval: 1)
        // A quick pan must actually scroll, not merely avoid a mutation.
        let sourceXBeforePan = source.frame.midX
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.86))
            .press(forDuration: 0.02, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.86)))
        XCTAssertEqual(order.value as? String, (1...15).map { "@\($0)" }.joined(separator: ","))
        XCTAssertGreaterThan(source.frame.midX - sourceXBeforePan, 8, "Quick pan did not scroll the strip")
        XCTAssertTrue(source.isHittable)
        XCTAssertTrue(target.isHittable)
        let before = XCTAttachment(screenshot: app.screenshot())
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE strip-before")
        Thread.sleep(forTimeInterval: 1.5)
        before.name = "tmux-order-strip-before"
        before.lifetime = .keepAlways
        add(before)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 0.32, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: 24, dy: 0)))
        let expected = (1...7).map { "@\($0)" } + ["@9", "@8"] + (10...15).map { "@\($0)" }
        expectation(for: NSPredicate(format: "value == %@", expected.joined(separator: ",")), evaluatedWith: order)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.descendants(matching: .any)["tmux-window-active-value"].value as? String, "@15")
        let after = XCTAttachment(screenshot: app.screenshot())
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE strip-after")
        Thread.sleep(forTimeInterval: 1.5)
        after.name = "tmux-order-strip-after"
        after.lifetime = .keepAlways
        add(after)
    }

    func testTmuxWindowOrderingCompact() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_SESSION_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_TMUX_WINDOW_REORDER_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_STATIC_RINGS"] = "1"
        app.launch()
        let order = app.descendants(matching: .any)["tmux-window-order-value"]
        XCTAssertTrue(order.waitForExistence(timeout: 10))
        XCTAssertEqual(order.value as? String, "@1,@2,@3")
        dismissQuickPathTutorialIfNeeded(in: app)
        let source = app.descendants(matching: .any)["command-palette-window-1-reorder"].firstMatch
        let target = app.descendants(matching: .any)["command-palette-window-2-reorder"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(target.exists)
        let before = XCTAttachment(screenshot: app.screenshot())
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE compact-before")
        Thread.sleep(forTimeInterval: 1.5)
        before.name = "tmux-order-compact-before"
        before.lifetime = .keepAlways
        add(before)
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.32, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        expectation(for: NSPredicate(format: "value == %@", "@2,@1,@3"), evaluatedWith: order)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.descendants(matching: .any)["tmux-window-active-value"].value as? String, "@1")
        XCTAssertTrue(app.descendants(matching: .any)["command-palette-window-1-reorder"].waitForExistence(timeout: 5))
        let after = XCTAttachment(screenshot: app.screenshot())
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE compact-after")
        Thread.sleep(forTimeInterval: 1.5)
        after.name = "tmux-order-compact-after"
        after.lifetime = .keepAlways
        add(after)
        let row = app.descendants(matching: .any)["tmux-window-@1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 0.85)
        let moveStart = app.buttons["Move to Start"].firstMatch
        XCTAssertTrue(moveStart.waitForExistence(timeout: 4))
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE compact-menu")
        Thread.sleep(forTimeInterval: 1.5)
        moveStart.tap()
        expectation(for: NSPredicate(format: "value == %@", "@1,@2,@3"), evaluatedWith: order)
        waitForExpectations(timeout: 8)
        let query = app.textFields["switch session, window or agent"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(query.isHittable)
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE compact-keyboard")
        Thread.sleep(forTimeInterval: 1.5)
        app.scrollViews["command-palette-results"].swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["tmux-window-@3"].firstMatch.isHittable)
        NSLog("TESSERA_WINDOW_ORDER_CAPTURE compact-scrolled")
        Thread.sleep(forTimeInterval: 1.5)
    }

    func testTmuxWindowCloseControls() throws {
        try requireVisualCaptureRun()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["TESSERA_TMUX_WINDOW_CLOSE_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["tmux-window-close-harness"]
                .waitForExistence(timeout: 8)
        )
        let singleClose = app.buttons["tmux-window-1-close"]
        let splitClose = app.buttons["tmux-window-2-close"]
        let zoomedSplitClose = app.buttons["tmux-window-3-close"]
        XCTAssertTrue(singleClose.exists, "single-pane tab is missing its X")
        XCTAssertTrue(splitClose.exists, "split tab is missing its X")
        XCTAssertTrue(zoomedSplitClose.exists, "zoomed split tab is missing its X")

        // Regression: a freshly-created window (bare %window-add, layout not
        // hydrated yet) is single-pane and must close without the spurious
        // "pane information still loading" confirmation. Close it first: any
        // other close refreshes the window list, which hydrates it.
        let freshClose = app.buttons["tmux-window-4-close"]
        XCTAssertTrue(freshClose.waitForExistence(timeout: 3), "fresh un-hydrated tab is missing its X")
        freshClose.tap()
        XCTAssertTrue(
            freshClose.waitForNonExistence(timeout: 3),
            "fresh single-pane X should close immediately without confirmation"
        )
        XCTAssertFalse(app.buttons["Close window"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)

        singleClose.tap()
        XCTAssertTrue(
            singleClose.waitForNonExistence(timeout: 3),
            "single-pane X should close immediately without confirmation"
        )
        XCTAssertFalse(app.buttons["Close window"].exists)

        splitClose.tap()
        var destructive = app.buttons["Close all 2 panes"]
        XCTAssertTrue(
            destructive.waitForExistence(timeout: 3),
            "split-window X did not require confirmation"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "contains 2 panes")
            ).firstMatch.exists,
            "confirmation does not disclose the split pane count"
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(splitClose.exists, "cancelling must preserve the split window")

        splitClose.tap()
        destructive = app.buttons["Close all 2 panes"]
        XCTAssertTrue(destructive.waitForExistence(timeout: 3))
        destructive.tap()
        XCTAssertTrue(
            splitClose.waitForNonExistence(timeout: 3),
            "confirming must close the targeted split window"
        )

        zoomedSplitClose.tap()
        XCTAssertTrue(
            app.buttons["Close all 2 panes"].waitForExistence(timeout: 3),
            "zoom must not hide the second pane from close confirmation"
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(zoomedSplitClose.exists)
    }

    private func readyLiveScrollApp() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let ready = NSPredicate(format: "value == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "live scroll harness did not become ready; value=\(String(describing: status.value))"
        )
        waitForLiveScrollInitialRenderFence(in: app)
        return app
    }

    /// Wire-probe driver: types `TESSERA_KEYPROBE_TEXT` (segments split on
    /// `|`, typed with a short pause between them) into the live harness
    /// terminal through XCTest's hardware-keyboard HID path, so shifted
    /// symbols arrive as real shift+key presses. The remote `keyprobe.py`
    /// pane logs the bytes the app actually put on the wire.
    func testLiveKeyProbeTyping() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        let terminal = liveTerminal(in: app)
        terminal.tap()
        usleep(700_000)
        let text = ProcessInfo.processInfo.environment["TESSERA_KEYPROBE_TEXT"] ?? "abc"
        mark("keyprobe-begin")
        for segment in text.components(separatedBy: "|") where !segment.isEmpty {
            // `key:<k>:<mods>` presses one hardware key with modifiers
            // (mods = comma list of shift,control,option,command); anything
            // else is typed as text.
            if segment.hasPrefix("key:") {
                let parts = segment.dropFirst(4).components(separatedBy: ":")
                var flags: XCUIElement.KeyModifierFlags = []
                if parts.count > 1 {
                    for mod in parts[1].components(separatedBy: ",") {
                        switch mod {
                        case "shift": flags.insert(.shift)
                        case "control": flags.insert(.control)
                        case "option": flags.insert(.option)
                        case "command": flags.insert(.command)
                        default: break
                        }
                    }
                }
                app.typeKey(parts[0], modifierFlags: flags)
            } else {
                app.typeText(segment)
            }
            usleep(400_000)
        }
        mark("keyprobe-end")
        usleep(1_500_000)
    }

    /// Selection-stickiness driver: long-presses the live terminal, picks
    /// "Select All" from the edit menu, then holds while the remote pane
    /// keeps printing. External simctl screenshots taken during the hold
    /// are the oracle (SwiftTerm renders on Metal; XCUIScreenshot is black).
    func testLiveSelectAllHold() throws {
        try requireVisualCaptureRun()
        let app = waitForLiveScrollApp()
        let terminal = liveTerminal(in: app)
        terminal.tap()
        usleep(500_000)
        terminal.press(forDuration: 1.2)
        usleep(800_000)
        mark("select-menu-shown")
        let itemName = ProcessInfo.processInfo.environment["TESSERA_SELECTION_MENU_ITEM"] ?? "Select All"
        let selectAll = app.menuItems[itemName].exists
            ? app.menuItems[itemName]
            : app.buttons[itemName]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 4), "\(itemName) menu item did not appear")
        selectAll.tap()
        usleep(600_000)
        mark("selected")
        let holdSeconds = Int(ProcessInfo.processInfo.environment["TESSERA_SELECTION_HOLD_SECONDS"] ?? "8") ?? 8
        usleep(UInt32(holdSeconds) * 1_000_000)
        mark("hold-end")
    }

    private func waitForLiveScrollApp() -> XCUIApplication {
        // Phones are mostly held upright; a lane can keep them portrait.
        XCUIDevice.shared.orientation =
            ProcessInfo.processInfo.environment["TESSERA_LIVE_SCROLL_PORTRAIT"] == "1"
                ? .portrait : .landscapeLeft
        let app = XCUIApplication()
        app.activate()
        let status = app.descendants(matching: .any)["live-scroll-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        let ready = NSPredicate(format: "value == %@", "ready")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: status)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "live scroll harness did not become ready; value=\(String(describing: status.value))"
        )
        waitForLiveScrollInitialRenderFence(in: app)
        usleep(8_000_000)
        return app
    }

    /// Plain SSH/Mosh never create a control-mode renderer, so they explicitly
    /// report `not-required`. Tmux modes can only reach this fence through
    /// the actual `TmuxController.isInitialRenderReady` observation in the
    /// DEBUG live-session harness; registry readiness alone can be advanced
    /// by its launch watchdog.
    private func waitForLiveScrollInitialRenderFence(in app: XCUIApplication) {
        let initialRender = app.descendants(matching: .any)["live-scroll-initial-render"]
        XCTAssertTrue(
            initialRender.waitForExistence(timeout: 8),
            "live scroll initial-render fence is missing"
        )
        let renderedOrNotRequired = NSPredicate(
            format: "value == %@ OR value == %@",
            "ready",
            "not-required"
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: renderedOrNotRequired,
            object: initialRender
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 55),
            .completed,
            "tmux initial render did not complete; value=\(String(describing: initialRender.value))"
        )
    }

    private func liveTerminal(in app: XCUIApplication) -> XCUIElement {
        let terminal = app.descendants(matching: .any)["live-scroll-terminal"]
        // waitForExistence spends about a second even on a present element,
        // twice per S13 flick.
        if terminal.exists { return terminal }
        XCTAssertTrue(
            terminal.waitForExistence(timeout: 5),
            "production terminal is not exposed by the live scroll harness"
        )
        return terminal
    }

    private func scrollLiveTerminal(in app: XCUIApplication, deltaY: CGFloat) {
        // Reacquire for every gesture. The DEBUG harness retags mosh's revealed
        // capture-pane TerminalView when it replaces the shared live surface.
        let terminal = liveTerminal(in: app)
        XCTAssertGreaterThan(terminal.frame.height, 200)
        terminal.scroll(byDeltaX: 0, deltaY: deltaY)
    }

    private func dragLiveTerminal(in app: XCUIApplication, deltaY: CGFloat) {
        // A pointer scroll's negative delta reveals earlier rows; a finger
        // does that by dragging down. Hold at the end so release inertia
        // cannot blur the milestone. The full grid can extend above the
        // screen or under the keyboard; aim within its visible rows.
        let (from, to): (CGFloat, CGFloat) = deltaY < 0 ? (0.2, 0.8) : (0.8, 0.2)
        fingerDragVisibleLiveTerminal(in: app, from: from, to: to, fast: false)
    }

    /// Taps `fraction` of the way down the terminal rows actually on screen.
    /// With the software keyboard up the grid is shifted above it, partly out
    /// of the window, so a fraction of the element itself can land off screen.
    /// Logs where the tap fell as a fraction of the whole grid.
    private func tapVisibleLiveTerminal(in app: XCUIApplication, fraction: CGFloat, event: String) {
        let band = visibleTerminalBand(in: app)
        let y = band.top + (band.bottom - band.top) * fraction
        let gridFraction = (y - band.grid.minY) / band.grid.height
        band.terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: gridFraction)).tap()
        print(
            "TESSERA_VISUAL_TAP \(event) gridFraction=\(String(format: "%.4f", gridFraction))"
                + " grid=\(band.grid) keyboard=\(band.keyboard) y=\(y)"
        )
    }

    /// The bottom of the floating session bar's buttons. The terminal runs
    /// under the bar, and on an iPhone the bar sits below the status bar and
    /// the Dynamic Island: a flick that starts on the bar's pill never
    /// reaches the terminal. The bar does not move during a test.
    private func sessionBarBottom(in app: XCUIApplication) -> CGFloat? {
        if let measured = measuredSessionBarBottom { return measured }
        let identifiers = ["session-home", "compact-session-switcher", "session-disconnect"]
        let bottom = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", identifiers))
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { !$0.isEmpty }
            .map(\.maxY)
            .max()
        measuredSessionBarBottom = .some(bottom)
        return bottom
    }

    /// The terminal rows actually on screen, clear of the top bar and of a
    /// software keyboard with its key bar.
    private func visibleTerminalBand(
        in app: XCUIApplication
    ) -> (terminal: XCUIElement, grid: CGRect, top: CGFloat, bottom: CGFloat, keyboard: CGRect) {
        let terminal = liveTerminal(in: app)
        let grid = terminal.frame
        var top = max(grid.minY, app.windows.firstMatch.frame.minY) + 44
        if let barBottom = sessionBarBottom(in: app) {
            // The bar's own bottom gap (SessionTopBar.floatBottomInset).
            top = max(top, barBottom + 8)
        }
        var bottom = min(grid.maxY, app.windows.firstMatch.frame.maxY)
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame : .null
        if !keyboardFrame.isNull, keyboardFrame.minY > top {
            // Keep clear of the key bar above the keys as well.
            bottom = min(bottom, keyboardFrame.minY - 56)
        }
        if bottom <= top { (top, bottom) = (grid.minY, grid.maxY) }
        return (terminal, grid, top, bottom, keyboardFrame)
    }

    /// A vertical finger drag across the visible rows, from `from` to `to`
    /// (fractions of that band). A fast release leaves momentum behind; a
    /// slow one holds still at the end first.
    private func fingerDragVisibleLiveTerminal(
        in app: XCUIApplication,
        from: CGFloat,
        to: CGFloat,
        fast: Bool
    ) {
        let band = visibleTerminalBand(in: app)
        // A split lane aims at the focused pane rather than the divider.
        let x = ProcessInfo.processInfo.environment["TESSERA_TOUCH_HISTORY_DRAG_X"]
            .flatMap(Double.init).map { CGFloat($0) } ?? 0.5
        func point(_ fraction: CGFloat) -> XCUICoordinate {
            let y = band.top + (band.bottom - band.top) * fraction
            return band.terminal.coordinate(
                withNormalizedOffset: CGVector(dx: x, dy: (y - band.grid.minY) / band.grid.height)
            )
        }
        point(from).press(
            forDuration: fast ? 0.02 : 0.05,
            thenDragTo: point(to),
            withVelocity: fast ? XCUIGestureVelocity(3_000) : XCUIGestureVelocity(600),
            thenHoldForDuration: fast ? 0 : 0.3
        )
        func y(_ fraction: CGFloat) -> Int { Int(band.top + (band.bottom - band.top) * fraction) }
        print(
            "TESSERA_VISUAL_DRAG from=\(y(from)) to=\(y(to)) fast=\(fast ? 1 : 0)"
                + " band=\(Int(band.top))-\(Int(band.bottom)) grid=\(band.grid) keyboard=\(band.keyboard)"
        )
    }

    /// The DEBUG row readout of the gesture target (TESSERA_LIVE_SCROLL_EXPOSE_ROWS).
    private struct VisibleFixtureRows: CustomStringConvertible {
        var low: Int?
        var high: Int?
        var atTop = false
        var atTail = false
        var tick: Int?
        var screen: Int?
        var lines: Int?
        var raw = ""

        init(_ value: String) {
            raw = value
            for field in value.split(separator: " ") {
                let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "rows":
                    let bounds = parts[1].split(separator: "-").compactMap { Int($0) }
                    if bounds.count == 2 { (low, high) = (bounds[0], bounds[1]) }
                case "top": atTop = parts[1] == "1"
                case "tail": atTail = parts[1] == "1"
                case "tick": tick = Int(parts[1])
                case "screen": screen = Int(parts[1])
                case "lines": lines = Int(parts[1])
                default: break
                }
            }
        }

        var description: String { raw }
    }

    private func visibleFixtureRows(in app: XCUIApplication) -> VisibleFixtureRows {
        VisibleFixtureRows(liveTerminal(in: app).value as? String ?? "")
    }

    /// Polls the row readout until `condition` holds or `timeout` passes.
    @discardableResult
    private func waitForFixtureRows(
        in app: XCUIApplication,
        timeout: TimeInterval,
        _ condition: (VisibleFixtureRows) -> Bool
    ) -> VisibleFixtureRows {
        let deadline = Date().addingTimeInterval(timeout)
        var rows = visibleFixtureRows(in: app)
        while !condition(rows), Date() < deadline {
            usleep(200_000)
            rows = visibleFixtureRows(in: app)
        }
        return rows
    }

    /// The rows once they have held still for 0.6 s: a drag's momentum has
    /// ended.
    private func settledFixtureRows(in app: XCUIApplication, from rows: VisibleFixtureRows) -> VisibleFixtureRows {
        let deadline = Date().addingTimeInterval(5)
        var current = rows
        var still = 0
        while still < 2, Date() < deadline {
            usleep(300_000)
            let next = visibleFixtureRows(in: app)
            still = next.low == current.low && next.high == current.high ? still + 1 : 0
            current = next
        }
        return current
    }

    /// Whether the heartbeat moves on screen: the painter reaches it.
    private func heartbeatAdvances(in app: XCUIApplication, from rows: VisibleFixtureRows) -> Bool {
        guard let tick = rows.tick else { return false }
        let later = waitForFixtureRows(in: app, timeout: 4) { ($0.tick ?? tick) > tick }
        return (later.tick ?? tick) > tick
    }

    private func mark(_ name: String) {
        lastMarker = name
        print("TESSERA_VISUAL_EVENT \(name) epoch=\(Date().timeIntervalSince1970)")
    }

    private func holdForExternalCapture() {
        // simctl must take three Metal-backed screenshots and select the most
        // complete frame. Keep XCTest (and therefore the app) alive until the
        // slowest of those captures has finished, including the final marker.
        // A lane that acknowledges milestones releases each hold itself, after
        // its captures and any remote stage wait: a fixed hold let slow
        // screenshots, or Vim still starting behind htop, overlap the next
        // gesture. Other lanes keep the three-second hold.
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["TESSERA_VISUAL_CAPTURE_ACK_DIR"], !directory.isEmpty,
              let marker = lastMarker
        else {
            usleep(3_000_000)
            return
        }
        let acknowledgement = URL(fileURLWithPath: directory).appendingPathComponent("\(marker).ack").path
        let abort = URL(fileURLWithPath: directory).appendingPathComponent("abort").path
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: acknowledgement) {
            if FileManager.default.fileExists(atPath: abort) {
                XCTFail("the lane stopped before acknowledging \(marker)")
                return
            }
            if Date() > deadline {
                XCTFail("the lane never acknowledged \(marker)")
                return
            }
            usleep(100_000)
        }
    }

    private func requireVisualCaptureRun() throws {
        guard ProcessInfo.processInfo.environment["TESSERA_VISUAL_CAPTURE"] == "1" else {
            throw XCTSkip("visual probes are driven by scripts/integration/run-integration-tests.sh")
        }
    }
}
