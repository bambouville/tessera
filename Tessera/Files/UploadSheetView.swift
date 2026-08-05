// Tessera/Files/UploadSheetView.swift
//
// Share-in Upload sheet (design mockup §5): pick host, pick
// destination, go. Connected hosts sort first; picking the temp
// destination auto-enables "paste path" (the one-gesture "paste a file
// into the session" flow). Never auto-connects: a disconnected host's
// upload runs over the lazily-connected FileBridge when the user taps
// Upload — an explicit gesture — and its CTA reads "connect & upload".
// SessionRestoreSheet is the structural exemplar; FilesPanelView the
// visual one (mono type, hairlines, monochrome glyphs).

import SwiftUI

struct UploadSheetView: View {
    let request: UploadRequest
    /// Live rows (any order; the sheet sorts active → connected →
    /// rest). Observed, so state flips land while presented.
    let model: UploadSheetModel
    private var candidates: [UploadHostCandidate] { model.candidates }
    var onUpload: (UploadHostCandidate, UploadDestination, _ pastePath: Bool) -> Void
    var onCancel: () -> Void
    /// Asks the owner to fetch the selected host's cwd on demand (one
    /// bridge exec) when the mirror doesn't know it yet; the refreshed
    /// candidates flow back in and enable the cwd row live.
    var onResolveCwd: ((UploadHostCandidate) -> Void)? = nil

    @Environment(\.designTokens) private var T

    @State private var selectedHostID: UUID?
    private enum DestinationKind: String { case cwd, temp }
    @State private var destinationKind: DestinationKind = .temp
    @State private var pastePath = false
    /// The remembered destination was cwd but none was known at
    /// adoption time — upgrade back to cwd if one arrives.
    @State private var forcedTempForMissingCwd = false
    /// Row order captured once at presentation. Live refreshes update
    /// each row's status in place but must not reshuffle the list —
    /// hosts walking connecting…→connected mid-sheet made rows swap
    /// tiers under the user's finger (they tap a POSITION).
    @State private var frozenOrder: [UUID] = []

    private var sortedCandidates: [UploadHostCandidate] {
        candidates.sorted { a, b in
            if a.isActiveSession != b.isActiveSession { return a.isActiveSession }
            if a.isConnected != b.isConnected { return a.isConnected }
            if a.isConnecting != b.isConnecting { return a.isConnecting }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    /// What the list renders: the presentation-time order with fresh
    /// row data swapped in; hosts added later (none expected) append.
    private var displayCandidates: [UploadHostCandidate] {
        guard !frozenOrder.isEmpty else { return sortedCandidates }
        var byID: [UUID: UploadHostCandidate] = [:]
        for candidate in candidates { byID[candidate.id] = candidate }
        var rows = frozenOrder.compactMap { byID[$0] }
        let known = Set(frozenOrder)
        rows.append(contentsOf: sortedCandidates.filter { !known.contains($0.id) })
        return rows
    }

    /// Paste-path is meaningful while a session is connected OR still
    /// auto-reconnecting: the injection target resolves when the upload
    /// completes, by which point a reconnect has usually landed.
    private var selectionCanReceivePastePath: Bool {
        guard let selection else { return false }
        return selection.isConnected || selection.isConnecting
    }

    private var selection: UploadHostCandidate? {
        displayCandidates.first { $0.id == selectedHostID } ?? displayCandidates.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("upload to host")
                        .font(Typography.sheetTitle)
                        .foregroundStyle(T.fg)

                    fileRow

                    sectionLabel("Host")
                    VStack(spacing: 6) {
                        ForEach(displayCandidates) { candidate in
                            hostRow(candidate)
                        }
                    }

                    sectionLabel("Destination")
                    VStack(spacing: 6) {
                        cwdRow
                        tempRow
                    }

                    ToggleRow(
                        title: "Paste path into active session",
                        subtitle: pasteSubtitle,
                        isOn: $pastePath
                    )
                    .disabled(!selectionCanReceivePastePath)
                    .opacity(selectionCanReceivePastePath ? 1 : 0.4)
                    .padding(.top, 2)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Btn("Cancel", style: .default, action: onCancel)
                Btn(style: .primary, action: submit) {
                    Text(uploadTitle)
                        .font(Typography.tesseraMono(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(T.presentationBg)
            .overlay(alignment: .top) {
                Rectangle().fill(T.border).frame(height: 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.presentationBg)
        .onAppear {
            frozenOrder = sortedCandidates.map(\.id)
            adoptSelectionDefaults(for: selection)
            requestCwdIfMissing()
        }
        .onChange(of: selection?.isConnected) { _, _ in
            // A host that finishes auto-reconnecting while the sheet is
            // up can have its cwd fetched now.
            requestCwdIfMissing()
        }
        .onChange(of: selection?.sessionCwd) { _, cwd in
            guard let cwd, !cwd.isEmpty, forcedTempForMissingCwd else { return }
            // The user's remembered preference was cwd; honor it now
            // that one is known.
            destinationKind = .cwd
            forcedTempForMissingCwd = false
        }
    }

    /// Fetch is worthwhile only for a connected selection with no
    /// known cwd; the owner dedups in-flight requests.
    private func requestCwdIfMissing() {
        guard let selection, selection.isConnected,
              selection.sessionCwd == nil else { return }
        onResolveCwd?(selection)
    }

    // MARK: - Rows

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(T.fgMuted)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.border, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayName)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Text(fileSubtitle)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
    }

    private func hostRow(_ candidate: UploadHostCandidate) -> some View {
        let selected = candidate.id == selection?.id
        return Button {
            selectedHostID = candidate.id
            adoptSelectionDefaults(for: candidate)
            requestCwdIfMissing()
        } label: {
            HStack(spacing: 8) {
                StatusDot(
                    color: candidate.isConnected
                        ? T.green
                        : candidate.isConnecting ? T.amber
                        : candidate.isFailed ? T.red : T.fgFaint,
                    pulse: candidate.isConnecting,
                    size: 6
                )
                Text(candidate.label)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(hostStatus(candidate))
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cwdRow: some View {
        let cwd = selection?.sessionCwd
        return destinationRow(
            kind: .cwd,
            systemImage: "link",
            title: cwd.map(abbreviateHome) ?? "no session cwd",
            detail: "session cwd",
            enabled: cwd != nil
        )
    }

    private var tempRow: some View {
        destinationRow(
            kind: .temp,
            systemImage: "clock",
            title: "~/" + RemoteFilesConstants.tempDirectory + "/",
            detail: "temp · auto-cleans after \(reaperDays) d",
            enabled: true
        )
    }

    private func destinationRow(
        kind: DestinationKind,
        systemImage: String,
        title: String,
        detail: String,
        enabled: Bool
    ) -> some View {
        let selected = destinationKind == kind
        return Button {
            destinationKind = kind
            // Mockup: picking temp auto-enables paste path — temp files
            // exist only to be referenced by path. Re-picking re-enables;
            // the user can still switch the toggle off afterwards.
            if kind == .temp, selectionCanReceivePastePath { pastePath = true }
            persistDestinationChoice(kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(selected ? T.accent : T.fgMuted)
                    .frame(width: 16)
                Text(title)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text(detail)
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? T.accent : T.border, lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 11, weight: .medium))
            .foregroundStyle(T.fgDim)
            .padding(.top, 2)
    }

    // MARK: - Derived text

    private var fileSubtitle: String {
        var parts: [String] = []
        if let size = request.fileSize {
            parts.append(ByteCountFormatter.string(
                fromByteCount: Int64(size), countStyle: .file))
        }
        if let hint = request.sourceHint { parts.append("from \(hint)") }
        return parts.isEmpty ? "file" : parts.joined(separator: " · ")
    }

    private func hostStatus(_ candidate: UploadHostCandidate) -> String {
        if candidate.isActiveSession { return "connected · active session" }
        if candidate.isConnected { return "connected" }
        if candidate.isConnecting { return "connecting…" }
        if candidate.isFailed { return "reconnect failed" }
        return "connect on upload…"
    }

    private var pasteSubtitle: String {
        guard let selection, selectionCanReceivePastePath else {
            return "needs a live session on the selected host"
        }
        if selection.isConnecting {
            return "types the file's remote path into \(selection.label) once its session finishes connecting"
        }
        return "types the file's remote path into \(selection.label) after upload — on by default for temp"
    }

    private var uploadTitle: String {
        // Connecting counts as "Upload": the transfer rides the file
        // bridge, which connects on its own regardless of the terminal
        // session's reconnect progress.
        guard let selection else { return "Upload" }
        return (selection.isConnected || selection.isConnecting)
            ? "Upload" : "Connect & upload"
    }

    private var reaperDays: Int {
        let stored = UserDefaults.standard.integer(forKey: RemoteFilesConstants.reaperDaysKey)
        return stored > 0 ? stored : RemoteFilesConstants.defaultReaperDays
    }

    private func abbreviateHome(_ path: String) -> String {
        // Cosmetic only — the sheet doesn't know the remote $HOME, so
        // abbreviate the common Linux/macOS layouts.
        for prefix in ["/home/", "/Users/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                return "~" + rest[slash...]
            }
            return "~"
        }
        return path
    }

    // MARK: - Selection defaults / persistence

    /// Applies the per-host destination memory (falling back to the
    /// app-wide default), and the paste-path convention for it.
    private func adoptSelectionDefaults(for candidate: UploadHostCandidate?) {
        guard let candidate else { return }
        let defaults = UserDefaults.standard
        let remembered = defaults.string(
            forKey: RemoteFilesConstants.lastDestinationKey(hostID: candidate.id))
            ?? defaults.string(forKey: RemoteFilesConstants.defaultDestinationKey)
        var kind = remembered.flatMap(DestinationKind.init(rawValue:)) ?? .temp
        if kind == .cwd, candidate.sessionCwd == nil {
            kind = .temp
            forcedTempForMissingCwd = true
        } else {
            forcedTempForMissingCwd = false
        }
        destinationKind = kind
        pastePath = kind == .temp && (candidate.isConnected || candidate.isConnecting)
    }

    private func persistDestinationChoice(_ kind: DestinationKind) {
        guard let selection else { return }
        UserDefaults.standard.set(
            kind.rawValue,
            forKey: RemoteFilesConstants.lastDestinationKey(hostID: selection.id))
    }

    private func submit() {
        guard let selection else { return }
        let destination: UploadDestination
        if destinationKind == .cwd, let cwd = selection.sessionCwd {
            destination = .sessionCwd(cwd)
        } else {
            destination = .temp
        }
        onUpload(selection, destination, pastePath && selectionCanReceivePastePath)
    }
}

#Preview("Upload sheet", traits: .fixedLayout(width: 460, height: 640)) {
    let model = UploadSheetModel()
    model.candidates = [
        UploadHostCandidate(
            id: UUID(), label: "qi@perch", isConnected: true, isConnecting: false,
            isActiveSession: true, sessionCwd: "/home/qi/projects/dashboard"),
        UploadHostCandidate(
            id: UUID(), label: "qi@mini", isConnected: false, isConnecting: true,
            isActiveSession: false, sessionCwd: nil),
        UploadHostCandidate(
            id: UUID(), label: "root@vps-fra", isConnected: false, isConnecting: false,
            isActiveSession: false, sessionCwd: nil),
    ]
    return UploadSheetView(
        request: UploadRequest(
            stagedURL: URL(fileURLWithPath: "/tmp/IMG_4211.png"),
            displayName: "IMG_4211.png",
            fileSize: 1_887_437,
            sourceHint: "Photos"
        ),
        model: model,
        onUpload: { _, _, _ in },
        onCancel: {}
    )
    .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))
}
