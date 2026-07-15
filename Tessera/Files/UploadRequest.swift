// Tessera/Files/UploadRequest.swift
//
// Model types for the share-in Upload sheet (design mockup §5). A file
// shared into Tessera arrives via onOpenURL (document-handler route),
// gets staged into our container — share-provided URLs are only
// guaranteed readable inside the open callback — and is presented as an
// UploadRequest. ContentView builds the host candidate rows from
// PersistedHosts + the live session registry; the sheet itself owns no
// host or transport knowledge.

import Foundation
import Observation

/// Live host rows for the Upload sheet. An @Observable box rather than
/// a value prop: sheet content closures do not reliably re-evaluate on
/// the presenter's @State changes (the rows froze at their
/// presentation-time snapshot — "connecting…" forever), but Observation
/// tracking fires inside the presentation host regardless of the
/// presenter's invalidation.
@Observable
@MainActor
final class UploadSheetModel {
    var candidates: [UploadHostCandidate] = []
}

/// One file shared into Tessera, staged and awaiting a host/destination
/// choice. Drives `.sheet(item:)` on ContentView (M3 wiring).
struct UploadRequest: Identifiable {
    let id = UUID()
    /// Staged copy under our container (survives the share callback).
    let stagedURL: URL
    let displayName: String
    let fileSize: UInt64?
    /// Origin clause for the subtitle ("from Photos"); nil hides it.
    let sourceHint: String?
}

/// Destination resolved by the sheet on submit.
enum UploadDestination: Equatable {
    /// The selected host's live-session cwd (absolute path).
    case sessionCwd(String)
    /// `~/.cache/tessera` — the reaped temp dir, for files whose only
    /// purpose is to be referenced by path (paste flow).
    case temp
}

/// One selectable host row. Connected hosts sort first (the sheet
/// orders: active session, then connected, then the rest). Rows are
/// LIVE while the sheet is up — ContentView refreshes them on session
/// state changes, so a host auto-reconnecting after a background kill
/// walks connecting… → connected in place.
struct UploadHostCandidate: Identifiable, Equatable {
    /// PersistedHost id — also keys the per-host last-destination
    /// memory (RemoteFilesConstants.lastDestinationKey).
    let id: UUID
    /// "user@name" — matches the session sidebar's host labels.
    let label: String
    /// A live terminal session to this host is connected.
    let isConnected: Bool
    /// No connected session yet, but one is connecting/auto-restoring.
    let isConnecting: Bool
    /// This host owns the currently focused session.
    let isActiveSession: Bool
    /// Its live session gave up reconnecting (state == .failed). The
    /// row says so instead of the "connect on upload…" promise — a
    /// host that just failed to reconnect will likely fail the
    /// bridge connect too.
    var isFailed: Bool = false
    /// cwd reported by its live session (tmux pane path / OSC 7 /
    /// poller), when known. nil disables the "session cwd" destination.
    let sessionCwd: String?
}
