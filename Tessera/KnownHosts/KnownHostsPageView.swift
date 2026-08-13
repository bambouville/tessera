import NIOSSH
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct KnownHostsPageView: View {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @Environment(\.designTokens) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var rows: [KnownHostsStore.DisplayRow] = []
    @State private var filter: Filter = .all
    @State private var expandedIDs: Set<String> = []
    @State private var exportDocument: KnownHostsTextDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importReview: KnownHostsImportReview?
    @State private var notice: String?

    // The table cells render Dynamic-Type-scaling mono text; scale the fixed
    // column widths with it so larger text sizes don't wrap or collide.
    @ScaledMetric(relativeTo: .body) private var algoColumnWidth: CGFloat = 90
    @ScaledMetric(relativeTo: .body) private var addedColumnWidth: CGFloat = 140
    @ScaledMetric(relativeTo: .body) private var statusColumnWidth: CGFloat = 110

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The desktop table's fixed columns total 340pt at default text size and
    /// scale with Dynamic Type (@ScaledMetric below) — at accessibility sizes
    /// they would consume the whole viewport on iPad portrait / Split View,
    /// collapsing the flexible host column. Fall back to the stacked compact
    /// row there; it has no fixed columns.
    private var usesCompactRows: Bool {
        isPhone || dynamicTypeSize.isAccessibilitySize
    }

    private enum Filter {
        case all
        case ok
        case stale
        case changed
    }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if changedCount > 0 {
                        mismatchBanner
                    }

                    filterChips
                    table
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 40)
            }
        }
        .accessibilityIdentifier("known-hosts-page")
        .task { await reload() }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "known_hosts"
        ) { result in
            if case .failure(let error) = result {
                notice = "Export failed: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
        .sheet(item: $importReview) { review in
            KnownHostsImportReviewSheet(
                plan: review.plan,
                onCancel: { importReview = nil },
                onConfirm: {
                    Task { @MainActor in
                        do {
                            let summary = try await KnownHostsStore.shared
                                .applyConfirmedOpenSSHImport(review.plan.entries)
                            importReview = nil
                            await reload()
                            let conflictSuffix = summary.stalePlanConflicts == 0
                                ? ""
                                : ", \(summary.stalePlanConflicts) skipped because Known Hosts changed during review"
                            notice = "Imported \(summary.added) added, \(summary.replaced) replaced, \(summary.unchanged) unchanged\(conflictSuffix)"
                        } catch {
                            notice = "Import was not saved and Known Hosts was not changed: \(error.localizedDescription)"
                        }
                    }
                }
            )
        }
        .alert("known hosts", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                headerTitle
                Spacer(minLength: 8)
                headerActions
            }

            VStack(alignment: .leading, spacing: 10) {
                headerTitle
                HStack(spacing: 8) {
                    headerActions
                }
            }
        }
        .padding(.top, isPhone ? 14 : 28)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var headerTitle: some View {
        Text("known hosts")
            .font(Typography.pageTitle)
            .foregroundStyle(T.fg)
            .lineLimit(1)
    }

    @ViewBuilder
    private var headerActions: some View {
        Btn("export", compact: true) {
            Task { @MainActor in
                exportDocument = KnownHostsTextDocument(
                    text: await KnownHostsStore.shared.openSSHExportText()
                )
                showExporter = true
            }
        }
        .disabled(rows.isEmpty)
        .opacity(rows.isEmpty ? 0.45 : 1)
        .accessibilityHint("Exports public host keys and fingerprints as an OpenSSH known hosts file")

        Btn("import", compact: true) {
            showImporter = true
        }
        .accessibilityHint("Reviews an OpenSSH known hosts file before merging it")
    }

    private var mismatchBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusDot(color: T.red)

            Text(mismatchMessage)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(T.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(T.red.opacity(0.3), lineWidth: 1)
        )
        .padding(.vertical, isPhone ? 14 : 20)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Chip(text: "all · \(rows.count)", selected: filter == .all) {
                    filter = .all
                }
                Chip(text: "verified", selected: filter == .ok) {
                    filter = .ok
                }
                Chip(text: "stale", selected: filter == .stale) {
                    filter = .stale
                }
                Chip(text: "changed", selected: filter == .changed) {
                    filter = .changed
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, isPhone ? 14 : 20)
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var table: some View {
        VStack(spacing: 0) {
            if !usesCompactRows {
                tableHeader
            }

            ForEach(filteredRows) { row in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        if expandedIDs.contains(row.id) {
                            expandedIDs.remove(row.id)
                        } else {
                            expandedIDs.insert(row.id)
                        }
                    }
                } label: {
                    if usesCompactRows {
                        compactTableRow(row)
                    } else {
                        tableRow(row)
                    }
                }
                .buttonStyle(.plain)

                if expandedIDs.contains(row.id) {
                    expandedDetail(row)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
            }
        }
        .padding(.horizontal, isPhone ? 18 : 40)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 20)

            Text("host")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("algo")
                .frame(width: algoColumnWidth, alignment: .leading)

            Text("added")
                .frame(width: addedColumnWidth, alignment: .leading)

            Text("status")
                .frame(width: statusColumnWidth, alignment: .leading)

            Color.clear
                .frame(width: 28)
        }
        .font(Typography.tesseraMono(size: 10))
        .foregroundStyle(T.fgMuted)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func tableRow(_ row: KnownHostsStore.DisplayRow) -> some View {
        HStack(spacing: 0) {
            StatusDot(color: statusColor(row.status))
                .frame(width: 20, alignment: .leading)

            Text(row.host)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.matchedPeerLabel != nil {
                Tag(text: "matched peer", color: T.green.opacity(0.12))
                    .padding(.trailing, 8)
            }

            Tag(text: row.algorithm)
                .frame(width: algoColumnWidth, alignment: .leading)

            Text(formatDate(row.firstSeen))
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgDim)
                .frame(width: addedColumnWidth, alignment: .leading)

            Text(statusLabel(row.status))
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(statusColor(row.status))
                .frame(width: statusColumnWidth, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(T.fgMuted)
                .rotationEffect(.degrees(expandedIDs.contains(row.id) ? 90 : 0))
                .frame(width: 28, alignment: .center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(row.status == .changed ? T.red.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func compactTableRow(_ row: KnownHostsStore.DisplayRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor(row.status))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.host)
                    .font(Typography.tesseraMono(size: 12, weight: .medium))
                    .foregroundStyle(T.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Tag(text: row.algorithm)

                    if row.matchedPeerLabel != nil {
                        Tag(text: "matched peer", color: T.green.opacity(0.12))
                    }

                    Text("added \(formatDate(row.firstSeen))")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(statusLabel(row.status))
                .font(Typography.tesseraMono(size: 10, weight: .medium))
                .foregroundStyle(statusColor(row.status))

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.fgMuted)
                .rotationEffect(.degrees(expandedIDs.contains(row.id) ? 90 : 0))
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .background(row.status == .changed ? T.red.opacity(0.04) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    private func expandedDetail(_ row: KnownHostsStore.DisplayRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.status == .changed {
                Text("⚠ remote host identification has changed. man-in-the-middle attack, or server key was rotated.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(T.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 4)
            }

            fingerprintLine(
                label: "current fingerprint: ",
                value: row.fingerprint,
                valueColor: T.fg
            )

            if let peer = row.matchedPeerLabel {
                Text("matched \(peer) at trust time")
                    .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                    .foregroundStyle(T.green)
            }

            if let previousFingerprint = row.previousFingerprint {
                fingerprintLine(
                    label: "previous fingerprint: ",
                    value: previousFingerprint,
                    valueColor: T.fgDim
                )
            }

            if let pendingFingerprint = row.pendingFingerprint, row.status == .changed {
                fingerprintLine(
                    label: "new fingerprint: ",
                    value: pendingFingerprint,
                    valueColor: T.fg
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    expandedActions(row)
                }

                VStack(alignment: .leading, spacing: 8) {
                    expandedActions(row)
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 16)
        .padding(.trailing, isPhone ? 12 : 20)
        .padding(.bottom, 20)
        .padding(.leading, isPhone ? 12 : 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBgSoft)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(T.border)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func expandedActions(_ row: KnownHostsStore.DisplayRow) -> some View {
        Btn("copy fingerprint", compact: true) {
            UIPasteboard.general.string = row.fingerprint
        }

        if row.status == .changed {
            Btn("accept new key", style: .primary, compact: true) {
                Task { await acceptNewKey(row) }
            }
        }

        Btn("remove", style: .danger, compact: true) {
            Task { await remove(row) }
        }
    }

    private func fingerprintLine(label: String, value: String, valueColor: Color) -> some View {
        (Text(label)
            .foregroundColor(T.fgMuted)
        + Text(value)
            .foregroundColor(valueColor))
            .font(Typography.tesseraMono(size: 11))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var filteredRows: [KnownHostsStore.DisplayRow] {
        switch filter {
        case .all:
            rows
        case .ok:
            rows.filter { $0.status == .ok }
        case .stale:
            rows.filter { $0.status == .stale }
        case .changed:
            rows.filter { $0.status == .changed }
        }
    }

    private var changedCount: Int {
        rows.filter { $0.status == .changed }.count
    }

    private var mismatchMessage: String {
        let verb = changedCount == 1 ? "has" : "have"
        let keyLabel = changedCount == 1 ? "host key" : "host keys"
        return "\(changedCount) \(keyLabel) \(verb) changed since last connect — review before reconnecting"
    }

    private func statusColor(_ status: KnownHostsStore.HostStatus) -> Color {
        switch status {
        case .ok:
            return T.green
        case .stale:
            return T.amber
        case .changed:
            return T.red
        }
    }

    private func statusLabel(_ status: KnownHostsStore.HostStatus) -> String {
        switch status {
        case .ok:
            return "verified"
        case .stale:
            return "stale"
        case .changed:
            return "MISMATCH"
        }
    }

    private func formatDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    @MainActor
    private func reload() async {
        rows = await KnownHostsStore.shared.list()
        let liveIDs = Set(rows.map(\.id))
        expandedIDs.formIntersection(liveIDs)
    }

    @MainActor
    private func acceptNewKey(_ row: KnownHostsStore.DisplayRow) async {
        guard let keyString = row.pendingKeyString else { return }

        do {
            let key = try NIOSSHPublicKey(openSSHPublicKey: keyString)
            await KnownHostsStore.shared.trust(key, for: row.id)
            await reload()
        } catch {
            DiagnosticLogStore.appendKnownHosts("accept-new-key failed error='\(error)'")
        }
    }

    @MainActor
    private func remove(_ row: KnownHostsStore.DisplayRow) async {
        await KnownHostsStore.shared.remove(endpoint: row.id)
        await reload()
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let maximumImportBytes = 1_048_576
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let fileSize, fileSize > maximumImportBytes {
                notice = "Import failed: known_hosts files must be 1 MiB or smaller."
                return
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumImportBytes else {
                notice = "Import failed: known_hosts files must be 1 MiB or smaller."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                notice = "Import failed: the selected file is not UTF-8 text."
                return
            }
            let plan = KnownHostsOpenSSHCodec.importPlan(
                text: text,
                currentRows: rows
            )
            importReview = KnownHostsImportReview(plan: plan)
        } catch {
            notice = "Import failed: \(error.localizedDescription)"
        }
    }
}

private struct KnownHostsTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct KnownHostsImportReview: Identifiable {
    let id = UUID()
    let plan: KnownHostsOpenSSHImportPlan
}

private struct KnownHostsImportReviewSheet: View {
    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss

    let plan: KnownHostsOpenSSHImportPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Nothing changes until you confirm. Replacements preserve the prior fingerprint in Known Hosts for review.")
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fgDim)
                        .fixedSize(horizontal: false, vertical: true)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            summaryTags
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            summaryTags
                        }
                    }

                    if plan.entries.isEmpty {
                        Text("No importable host pins were found.")
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fgDim)
                    } else {
                        reviewSection("parsed entries") {
                            ForEach(plan.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.endpoint)
                                            .font(Typography.tesseraMono(size: 12, weight: .medium))
                                            .foregroundStyle(T.fg)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        summaryTag(
                                            entry.action.rawValue,
                                            color: actionColor(entry.action)
                                        )
                                    }
                                    Text(entry.fingerprint)
                                        .font(Typography.tesseraMono(size: 10))
                                        .foregroundStyle(T.fgDim)
                                        .textSelection(.enabled)
                                    if entry.action == .replace,
                                       let prior = entry.expectedPriorFingerprint {
                                        Text("replaces \(prior)")
                                            .font(Typography.tesseraMono(size: 10))
                                            .foregroundStyle(T.amber)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }

                    if !plan.rejections.isEmpty {
                        reviewSection("rejected lines") {
                            ForEach(plan.rejections) { rejection in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("line \(rejection.lineNumber) · \(rejection.reason)")
                                        .font(Typography.tesseraMono(size: 11, weight: .medium))
                                        .foregroundStyle(T.red)
                                    Text(rejection.source)
                                        .font(Typography.tesseraMono(size: 10))
                                        .foregroundStyle(T.fgDim)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }

                    if !plan.warnings.isEmpty {
                        reviewSection("warnings") {
                            ForEach(plan.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(Typography.tesseraMono(size: 10))
                                    .foregroundStyle(T.amber)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(T.bg.ignoresSafeArea())
            .navigationTitle("review known hosts import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmButtonLabel) {
                        onConfirm()
                    }
                    .disabled(plan.addCount + plan.replaceCount == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func actionColor(_ action: KnownHostsOpenSSHImportPlan.Action) -> Color {
        switch action {
        case .add: T.green
        case .replace: T.amber
        case .unchanged: T.fgDim
        }
    }

    private var confirmButtonLabel: String {
        "import \(plan.addCount) · replace \(plan.replaceCount)"
    }

    @ViewBuilder
    private var summaryTags: some View {
        summaryTag("add \(plan.addCount)", color: T.green)
        summaryTag("replace \(plan.replaceCount)", color: T.amber)
        summaryTag("unchanged \(plan.unchangedCount)", color: T.fgDim)
        if !plan.rejections.isEmpty {
            summaryTag("rejected \(plan.rejections.count)", color: T.red)
        }
    }

    private func summaryTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func reviewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(T.fgMuted)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
