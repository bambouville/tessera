import Foundation

enum SessionRestorePolicy: String, CaseIterable, Codable {
    case ask
    case always
    case never
}

struct SessionRestoreSnapshot: Codable, Equatable, Identifiable {
    var id: UUID { liveSessionID }

    let liveSessionID: UUID
    let persistedHostID: UUID
    let displayName: String
    let createdAt: Date
}

struct SessionRestoreDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    let sessions: [SessionRestoreSnapshot]
    let selectedSessionID: UUID?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        savedAt: Date,
        sessions: [SessionRestoreSnapshot],
        selectedSessionID: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
    }
}

struct SessionRestoreStore {
    static let defaultKey = "tessera.sessionRestore.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SessionRestoreDocument? {
        guard let data = defaults.data(forKey: key) else { return nil }

        do {
            let document = try JSONDecoder().decode(
                SessionRestoreDocument.self,
                from: data
            )
            guard document.schemaVersion == SessionRestoreDocument.currentSchemaVersion else {
                clear()
                return nil
            }
            return document
        } catch {
            clear()
            return nil
        }
    }

    func save(
        sessions: [SessionRestoreSnapshot],
        selectedSessionID: UUID?,
        savedAt: Date = Date()
    ) {
        guard !sessions.isEmpty else {
            clear()
            return
        }

        let selected = selectedSessionID.flatMap { id in
            sessions.contains(where: { $0.liveSessionID == id }) ? id : nil
        }
        let document = SessionRestoreDocument(
            savedAt: savedAt,
            sessions: sessions,
            selectedSessionID: selected
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: key)
    }

    func save(_ document: SessionRestoreDocument) {
        guard document.schemaVersion == SessionRestoreDocument.currentSchemaVersion,
              !document.sessions.isEmpty,
              let data = try? JSONEncoder().encode(document)
        else {
            clear()
            return
        }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    static func clearDefaultStore() {
        SessionRestoreStore().clear()
    }
}

enum SessionRestoreEligibility {
    static func isRestorable(
        host: PersistedHost,
        storedKey: (UUID) -> StoredKey?,
        passwordExists: (UUID) -> Bool = { KeychainHelper.password(forIdentityID: $0) != nil },
        legacyDevKeyExists: (String) -> Bool = Self.defaultLegacyDevKeyExists
    ) -> Bool {
        guard let identity = host.identity else { return false }

        switch identity.credentialMode {
        case .none:
            return false
        case .password:
            return passwordExists(identity.id)
        case .key(let id):
            return storedKey(id) != nil
        case .legacyDevKey(let filename):
            return legacyDevKeyExists(filename)
        }
    }

    private static func defaultLegacyDevKeyExists(_ filename: String) -> Bool {
        guard let docsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }

        let rawFilename = filename.hasSuffix(".raw")
            ? filename
            : filename + ".raw"
        let url = docsURL.appendingPathComponent(rawFilename)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }
}

struct SessionRestoreResolvedSession {
    let snapshot: SessionRestoreSnapshot
    var sourceSnapshotIDs: [UUID]
    let host: PersistedHost
    let displayName: String
}

struct SessionRestorePlan {
    let sessions: [SessionRestoreResolvedSession]
    let skippedCount: Int
    let selectedSnapshotID: UUID?

    var hasRestorableSessions: Bool { !sessions.isEmpty }
    var restorableCount: Int { sessions.count }
}

enum SessionRestoreResolver {
    static func resolve(
        _ document: SessionRestoreDocument,
        hosts: [PersistedHost],
        isCredentialRestorable: (PersistedHost) -> Bool
    ) -> SessionRestorePlan {
        var hostsByID: [UUID: PersistedHost] = [:]
        for host in hosts {
            hostsByID[host.id] = host
        }

        var skippedCount = 0
        var resolved: [SessionRestoreResolvedSession] = []
        var singletonIndexes: [String: Int] = [:]

        for snapshot in document.sessions {
            guard let host = hostsByID[snapshot.persistedHostID],
                  isCredentialRestorable(host)
            else {
                skippedCount += 1
                continue
            }

            if let singletonKey = singletonRestoreKey(for: host),
               let existingIndex = singletonIndexes[singletonKey] {
                resolved[existingIndex].sourceSnapshotIDs.append(snapshot.liveSessionID)
                continue
            }

            if let singletonKey = singletonRestoreKey(for: host) {
                singletonIndexes[singletonKey] = resolved.count
            }

            resolved.append(
                SessionRestoreResolvedSession(
                    snapshot: snapshot,
                    sourceSnapshotIDs: [snapshot.liveSessionID],
                    host: host,
                    displayName: displayName(for: host)
                )
            )
        }

        let selectedSnapshotID = document.selectedSessionID.flatMap { selected in
            resolved.contains { $0.sourceSnapshotIDs.contains(selected) }
                ? selected
                : nil
        }

        return SessionRestorePlan(
            sessions: resolved,
            skippedCount: skippedCount,
            selectedSnapshotID: selectedSnapshotID
        )
    }

    static func displayName(for host: PersistedHost) -> String {
        let name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return host.address
    }

    private static func singletonRestoreKey(for host: PersistedHost) -> String? {
        switch host.launchMode {
        case .customCommand:
            return nil
        case .autoTmux:
            return "auto:\(host.connectionKey)"
        case .pinnedTmux:
            let pinned = host.tmuxSessionName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !pinned.isEmpty else { return nil }
            return "pinned:\(host.connectionKey):\(pinned)"
        }
    }
}
