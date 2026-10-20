public struct ProgramStatusRecord: Equatable, Sendable {
    public let idPath: [String]
    public internal(set) var state: ProgramStatusState
    public internal(set) var kind: ProgramStatusBlockedKind?
    public internal(set) var progress: Int?
    public internal(set) var app: String?
    public internal(set) var title: String?
    public internal(set) var message: String?
    public internal(set) var updateToken: UInt64
    public internal(set) var isHistorical: Bool
    public internal(set) var resultToken: UInt64?
    public internal(set) var isResultAcknowledged: Bool
}

public struct ProgramStatusTerminalStore: Sendable, Equatable {
    public static let maximumRecords = 256
    private var storage: [[String]: ProgramStatusRecord] = [:]

    public init() {}

    public var records: [ProgramStatusRecord] {
        storage.values.sorted { $0.idPath.lexicographicallyPrecedes($1.idPath) }
    }

    public var isEmpty: Bool { storage.isEmpty }

    @discardableResult
    public mutating func apply(_ report: ProgramStatusReport, token: UInt64) -> Bool {
        switch report.action {
        case .clear:
            if report.idPath.isEmpty { return removeAll() }
            let keys = storage.keys.filter { $0.starts(with: report.idPath) }
            for key in keys { storage.removeValue(forKey: key) }
            return !keys.isEmpty
        case .set(let state):
            let previous = storage[report.idPath]
            let isResult = state == .done || state == .error
            // A gap may hide intervening work. Only continuous result updates
            // can keep the previous episode's acknowledgement.
            let startsEpisode = isResult && (previous?.resultToken == nil || previous?.isHistorical == true)
            let record = ProgramStatusRecord(
                idPath: report.idPath, state: state, kind: report.kind,
                progress: report.progress, app: report.app, title: report.title,
                message: report.message, updateToken: token, isHistorical: false,
                resultToken: isResult ? (startsEpisode ? token : previous?.resultToken) : nil,
                isResultAcknowledged: isResult && !startsEpisode && (previous?.isResultAcknowledged ?? false)
            )
            storage[report.idPath] = record
            if previous == nil, storage.count > Self.maximumRecords,
               let oldest = storage.values.filter({ $0.idPath != report.idPath }).min(by: {
                   if $0.updateToken != $1.updateToken { return $0.updateToken < $1.updateToken }
                   return $0.idPath.lexicographicallyPrecedes($1.idPath)
               }) {
                storage.removeValue(forKey: oldest.idPath)
            }
            return previous != record
        }
    }

    @discardableResult
    public mutating func dropLiveRecords() -> Bool {
        let keys = storage.values.filter { $0.state != .done && $0.state != .error }.map(\.idPath)
        for key in keys { storage.removeValue(forKey: key) }
        return !keys.isEmpty
    }

    @discardableResult
    public mutating func markLiveHistorical() -> Bool {
        markHistorical { $0.state != .done && $0.state != .error }
    }

    @discardableResult
    public mutating func markAllHistorical() -> Bool {
        markHistorical { _ in true }
    }

    private mutating func markHistorical(_ includes: (ProgramStatusRecord) -> Bool) -> Bool {
        let keys = storage.values.filter { !$0.isHistorical && includes($0) }.map(\.idPath)
        for key in keys { storage[key]?.isHistorical = true }
        return !keys.isEmpty
    }

    @discardableResult
    public mutating func removeAll() -> Bool {
        guard !storage.isEmpty else { return false }
        storage.removeAll()
        return true
    }

    @discardableResult
    public mutating func acknowledgeResults(through token: UInt64) -> Bool {
        let keys = storage.values.filter {
            !$0.isResultAcknowledged && $0.resultToken.map { $0 <= token } == true
        }.map(\.idPath)
        for key in keys { storage[key]?.isResultAcknowledged = true }
        return !keys.isEmpty
    }
}
