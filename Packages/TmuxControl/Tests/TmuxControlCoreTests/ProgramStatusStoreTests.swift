import XCTest
@testable import TmuxControlCore

final class ProgramStatusStoreTests: XCTestCase {
    func testReplacementDropsOmittedMetadataAndSameTokenNoChange() {
        var store = ProgramStatusTerminalStore()
        XCTAssertTrue(store.isEmpty)
        let report = ProgramStatusReport(action: .set(.blocked), kind: .permission, progress: 40,
                                         app: "build", title: "Build", message: "Allow?")
        XCTAssertTrue(store.apply(report, token: 1))
        XCTAssertFalse(store.apply(report, token: 1))
        XCTAssertTrue(store.apply(.init(action: .set(.working)), token: 2))
        let record = store.records.first!
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.kind)
        XCTAssertNil(record.progress)
        XCTAssertNil(record.app)
        XCTAssertNil(record.title)
        XCTAssertNil(record.message)
        XCTAssertEqual(record.updateToken, 2)
        XCTAssertFalse(record.isHistorical)
        XCTAssertNil(record.resultToken)
        XCTAssertFalse(record.isResultAcknowledged)
    }

    func testClearSubtreeAndRootAndSegmentOrdering() {
        var store = ProgramStatusTerminalStore()
        let paths: [[String]] = [[], ["a"], ["a", "b"], ["a", "b", "c"], ["ab"], ["b"], ["a", "a"]]
        for (index, path) in paths.enumerated() { store.apply(.init(action: .set(.idle), idPath: path), token: UInt64(index)) }
        XCTAssertEqual(store.records.map(\.idPath), [[], ["a"], ["a", "a"], ["a", "b"], ["a", "b", "c"], ["ab"], ["b"]])
        XCTAssertTrue(store.apply(.init(action: .clear, idPath: ["a", "b"]), token: 10))
        XCTAssertEqual(store.records.map(\.idPath), [[], ["a"], ["a", "a"], ["ab"], ["b"]])
        XCTAssertFalse(store.apply(.init(action: .clear, idPath: ["missing"]), token: 11))
        XCTAssertTrue(store.apply(.init(action: .clear, idPath: ["a"]), token: 12))
        XCTAssertEqual(store.records.map(\.idPath), [[], ["ab"], ["b"]])
        XCTAssertTrue(store.apply(.init(action: .clear), token: 13))
        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(store.removeAll())
    }

    func testResultEpisodeRepeatsKeepTokenAndAcknowledgement() {
        var store = ProgramStatusTerminalStore()
        store.apply(.init(action: .set(.done)), token: 1)
        XCTAssertEqual(store.records[0].resultToken, 1)
        XCTAssertTrue(store.acknowledgeResults(through: 1))
        XCTAssertFalse(store.acknowledgeResults(through: 1))
        for (index, state) in [ProgramStatusState.done, .error, .done].enumerated() {
            store.apply(.init(action: .set(state), message: "update \(index)"), token: UInt64(index + 2))
            XCTAssertEqual(store.records[0].resultToken, 1)
            XCTAssertTrue(store.records[0].isResultAcknowledged)
        }
    }

    func testEveryLiveStateRearmsResultEpisode() {
        for state in [ProgramStatusState.working, .blocked, .idle] {
            var store = ProgramStatusTerminalStore()
            store.apply(.init(action: .set(.error)), token: 1)
            store.acknowledgeResults(through: 1)
            store.apply(.init(action: .set(state)), token: 2)
            XCTAssertNil(store.records[0].resultToken)
            XCTAssertFalse(store.records[0].isResultAcknowledged)
            store.apply(.init(action: .set(.done)), token: 3)
            XCTAssertEqual(store.records[0].resultToken, 3)
            XCTAssertFalse(store.records[0].isResultAcknowledged)
        }
    }

    func testClearAndRecreateRearmsAndAcknowledgementIsBounded() {
        var store = ProgramStatusTerminalStore()
        store.apply(.init(action: .set(.done), idPath: ["a"]), token: 1)
        store.acknowledgeResults(through: 1)
        store.apply(.init(action: .clear, idPath: ["a"]), token: 2)
        store.apply(.init(action: .set(.error), idPath: ["a"]), token: 3)
        store.apply(.init(action: .set(.done), idPath: ["b"]), token: 4)
        XCTAssertTrue(store.acknowledgeResults(through: 3))
        XCTAssertEqual(store.records[0].resultToken, 3)
        XCTAssertTrue(store.records[0].isResultAcknowledged)
        XCTAssertFalse(store.records[1].isResultAcknowledged)
        store.apply(.init(action: .set(.error), idPath: ["b"]), token: 9)
        XCTAssertEqual(store.records[1].resultToken, 4)
        XCTAssertTrue(store.acknowledgeResults(through: 4))
    }

    func testEvictionAt257UsesOldestUpdateAndNeverIncomingID() {
        var store = ProgramStatusTerminalStore()
        for index in 0..<256 { store.apply(.init(action: .set(.done), idPath: ["\(index)"]), token: UInt64(index + 1)) }
        XCTAssertEqual(store.records.count, ProgramStatusTerminalStore.maximumRecords)
        store.apply(.init(action: .set(.done), idPath: ["0"]), token: 500)
        store.apply(.init(action: .set(.error), idPath: ["new"]), token: 0)
        XCTAssertEqual(store.records.count, 256)
        XCTAssertFalse(store.records.contains { $0.idPath == ["1"] })
        XCTAssertTrue(store.records.contains { $0.idPath == ["new"] })
        XCTAssertTrue(store.records.contains { $0.idPath == ["0"] })
        store.apply(.init(action: .set(.done), idPath: ["1"]), token: 501)
        let recreated = store.records.first { $0.idPath == ["1"] }!
        XCTAssertEqual(recreated.resultToken, 501)
        XCTAssertFalse(recreated.isResultAcknowledged)
    }

    func testHistoricalLifetimeAndFreshReportOnlyRevivesItsID() {
        var store = ProgramStatusTerminalStore()
        for (index, state) in ProgramStatusState.allCases.enumerated() {
            store.apply(.init(action: .set(state), idPath: [state.rawValue]), token: UInt64(index + 1))
        }
        XCTAssertTrue(store.markLiveHistorical())
        XCTAssertFalse(store.markLiveHistorical())
        for record in store.records { XCTAssertEqual(record.isHistorical, record.state != .done && record.state != .error) }
        XCTAssertTrue(store.markAllHistorical())
        XCTAssertFalse(store.markAllHistorical())
        store.apply(.init(action: .set(.blocked), idPath: ["blocked"]), token: 10)
        for record in store.records { XCTAssertEqual(record.isHistorical, record.idPath != ["blocked"]) }
        XCTAssertTrue(store.dropLiveRecords())
        XCTAssertEqual(store.records.map { $0.state.rawValue }.sorted(), ["done", "error"])
        XCTAssertTrue(store.records.allSatisfy(\.isHistorical))
        XCTAssertFalse(store.dropLiveRecords())
        store.apply(.init(action: .set(.done), idPath: ["done"]), token: 11)
        XCTAssertFalse(store.records.first { $0.state == .done }!.isHistorical)
        XCTAssertEqual(store.records.first { $0.state == .done }!.resultToken, 11)
    }

    func testEmptyOperationsAndCopyIndependence() {
        var store = ProgramStatusTerminalStore()
        XCTAssertFalse(store.dropLiveRecords())
        XCTAssertFalse(store.markLiveHistorical())
        XCTAssertFalse(store.markAllHistorical())
        XCTAssertFalse(store.acknowledgeResults(through: 100))
        store.apply(.init(action: .set(.working)), token: 1)
        var copy = store
        copy.markAllHistorical()
        XCTAssertFalse(store.records[0].isHistorical)
        XCTAssertTrue(copy.records[0].isHistorical)
        XCTAssertNotEqual(copy, store)
    }
}
