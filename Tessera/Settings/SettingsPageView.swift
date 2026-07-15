// Tessera/Settings/SettingsPageView.swift
import Foundation
import SwiftUI

struct SettingsPageView: View {
    @Environment(\.designTokens) private var T
    @Environment(SwipePadProfileStore.self) private var swipePadStore

    var onUploadDiagnosticLog: () -> Void = {}

    @State private var selectedSection: SettingsSection = .appearance

    var body: some View {
        HStack(spacing: 0) {
            leftPane

            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("settings")
                .font(Typography.tesseraMono(size: 20, weight: .medium))
                .foregroundStyle(T.fg)
                .padding(.top, 28)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    settingsRow(section)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(T.bg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(T.border)
                .frame(width: 1)
        }
    }

    private var rightPane: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                sectionContent
                    .frame(maxWidth: 560, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg)
    }

    private func settingsRow(_ section: SettingsSection) -> some View {
        let isSelected = selectedSection == section

        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 8) {
                if section == .experimental {
                    Image(systemName: "flask")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(isSelected ? T.accent : T.fgMuted)
                }
                if section == .files {
                    Image(systemName: "folder")
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(isSelected ? T.accent : T.fgMuted)
                }

                Text(section.rawValue)
                    .font(Typography.tesseraMono(size: 13))
                    .foregroundStyle(isSelected ? T.accent : T.fgMuted)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? T.accentSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsView()
        case .terminal:
            TerminalSettingsView()
        case .files:
            FilesSettingsView()
        case .themes:
            ThemeSettingsView()
        case .keyboard:
            KeyboardSettingsView()
        case .security:
            SecuritySettingsView()
        case .experimental:
            ExperimentalSettingsView(store: swipePadStore)
        case .diagnostics:
            DiagnosticsSettingsView(onUploadLog: onUploadDiagnosticLog)
        case .about:
            AboutSettingsView()
        }
    }
}

struct SettingsH: View {
    let title: String

    @Environment(\.designTokens) private var T

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Typography.tesseraMono(size: 22, weight: .medium))
            .foregroundStyle(T.fg)
            .padding(.bottom, 24)
    }
}

private enum SettingsSection: String, CaseIterable {
    case appearance
    case terminal
    case files
    case themes
    case keyboard = "keyboard & input"
    case security
    case experimental
    case diagnostics
    case about
}

struct DiagnosticLogInfo: Equatable {
    var exists: Bool
    var byteCount: Int64
    var modifiedAt: Date?

    var isEmpty: Bool {
        byteCount <= 0
    }

    var displaySize: String {
        guard exists else { return "no file" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var displayUpdatedAt: String {
        guard let modifiedAt else { return "not written" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

enum DiagnosticLogCategory: String {
    case agentCenter = "AgentCenterDiag"
    case app = "AppDiag"
    case forwarding = "ForwardingDiag"
    case knownHosts = "KnownHostsDiag"
    case keys = "KeysDiag"
    case mosh = "MoshTrace"
    case sessionRestore = "SessionRestoreDiag"
    case scroll = "ScrollDiag"
    case ssh = "SSHDiag"
    case speech = "SpeechDiag"
    case swipePad = "SwipePadDiag"
    case tmux = "TmuxControlDiag"
}

enum DiagnosticLogStore {
    static let verboseDiagnosticsDefaultsKey = "Diagnostics.VerboseEnabled"
    static let scrollDiagnosticsDefaultsKey = "Diagnostics.ScrollEnabled"

    private static let maxBytes: Int64 = 20_000_000
    private static let maxLineCharacters = 900
    private static let retainedTailLineCount = 100
    private static let maxEntriesPerSignaturePerWindow = 18
    private static let rateLimitWindow: TimeInterval = 60
    private static let fileName = "tessera-diagnostics.log"
    private static let queue = DispatchQueue(label: "app.tessera.diagnostic-log")
    private static var rateStates: [String: RateState] = [:]

    private struct RateState {
        var windowStart: Date
        var emitted: Int
        var suppressed: Int
    }

    static var logFileURL: URL {
        diagnosticsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    static var isVerboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: verboseDiagnosticsDefaultsKey)
    }

    static var isScrollDiagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: scrollDiagnosticsDefaultsKey)
    }

    static func append(_ category: DiagnosticLogCategory, _ message: @autoclosure () -> String) {
        let rawMessage = message()
        queue.async {
            appendOnQueue(category, rawMessage)
        }
    }

    static func appendApp(_ message: @autoclosure () -> String) {
        append(.app, message())
    }

    static func appendAgentCenter(_ message: @autoclosure () -> String) {
        append(.agentCenter, message())
    }

    static func appendForwarding(_ message: @autoclosure () -> String) {
        append(.forwarding, message())
    }

    static func appendKnownHosts(_ message: @autoclosure () -> String) {
        append(.knownHosts, message())
    }

    static func appendKeys(_ message: @autoclosure () -> String) {
        append(.keys, message())
    }

    static func appendMosh(_ message: @autoclosure () -> String) {
        append(.mosh, message())
    }

    static func appendRestore(_ message: String) {
        append(.sessionRestore, message)
    }

    static func appendScroll(_ message: @autoclosure () -> String) {
        append(.scroll, message())
    }

    static func appendSSH(_ message: @autoclosure () -> String) {
        append(.ssh, message())
    }

    static func appendSpeech(_ message: @autoclosure () -> String) {
        append(.speech, message())
    }

    static func appendSwipePad(_ message: @autoclosure () -> String) {
        append(.swipePad, message())
    }

    static func appendTmux(_ message: @autoclosure () -> String) {
        append(.tmux, message())
    }

    static func clear() {
        queue.sync {
            rateStates.removeAll(keepingCapacity: true)
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }

    static func info() -> DiagnosticLogInfo {
        queue.sync {
            let url = logFileURL
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            else {
                return DiagnosticLogInfo(exists: false, byteCount: 0, modifiedAt: nil)
            }

            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modifiedAt = attributes[.modificationDate] as? Date
            return DiagnosticLogInfo(
                exists: true,
                byteCount: byteCount,
                modifiedAt: modifiedAt
            )
        }
    }

    private static var diagnosticsDirectoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static func appendOnQueue(_ category: DiagnosticLogCategory, _ rawMessage: String) {
        let manager = FileManager.default
        let directoryURL = diagnosticsDirectoryURL
        let fileURL = logFileURL
        let safeMessage = bounded(sanitize(rawMessage))

        guard shouldEmit(category: category, message: safeMessage) else {
            return
        }

        let signature = "\(category.rawValue):\(signature(for: safeMessage))"

        do {
            let rateLimitSummary = applyRateLimit(category: category, signature: signature)
            guard rateLimitSummary.shouldEmit else { return }

            try manager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            var lines = ""
            if let suppressionLine = rateLimitSummary.suppressionLine {
                lines += suppressionLine
            }
            lines += "\(timestamp()) [Tessera][\(category.rawValue)] \(safeMessage)\n"

            var payload = (shouldWriteHeader(fileURL: fileURL, manager: manager) ? headerLine() : "") + lines
            guard var data = payload.data(using: .utf8) else { return }

            if shouldRotate(fileURL: fileURL, appendingBytes: data.count) {
                let retainedTail = retainedTailPayload(fileURL: fileURL)
                try? manager.removeItem(at: fileURL)
                payload = headerLine()
                    + "\(timestamp()) [Tessera][DiagnosticLog] rotated retainedTailLines=\(retainedTail.lineCount) maxBytes=\(maxBytes)\n"
                    + retainedTail.payload
                    + lines
                guard let rotatedData = payload.data(using: .utf8) else { return }
                data = rotatedData
            }

            if !manager.fileExists(atPath: fileURL.path) {
                _ = manager.createFile(atPath: fileURL.path, contents: data)
                return
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            return
        }
    }

    private static func shouldWriteHeader(fileURL: URL, manager: FileManager) -> Bool {
        !manager.fileExists(atPath: fileURL.path)
            || ((try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0) == 0
    }

    private static func shouldRotate(fileURL: URL, appendingBytes: Int) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }

        return size.int64Value + Int64(appendingBytes) > maxBytes
    }

    private static func retainedTailPayload(fileURL: URL) -> (payload: String, lineCount: Int) {
        guard
            let data = try? Data(contentsOf: fileURL),
            !data.isEmpty
        else {
            return ("", 0)
        }

        let content = String(decoding: data, as: UTF8.self)
        let retainedLines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(retainedTailLineCount)
            .map { bounded(sanitize(String($0))) }

        guard !retainedLines.isEmpty else {
            return ("", 0)
        }

        return (retainedLines.joined(separator: "\n") + "\n", retainedLines.count)
    }

    private static func applyRateLimit(
        category: DiagnosticLogCategory,
        signature: String
    ) -> (shouldEmit: Bool, suppressionLine: String?) {
        let now = Date()
        var state = rateStates[signature] ?? RateState(
            windowStart: now,
            emitted: 0,
            suppressed: 0
        )
        var suppressionLine: String?

        if now.timeIntervalSince(state.windowStart) >= rateLimitWindow {
            if state.suppressed > 0 {
                suppressionLine = "\(timestamp()) [Tessera][DiagnosticLog] suppressed=\(state.suppressed) category=\(category.rawValue) signature='\(signature)' windowSeconds=\(Int(rateLimitWindow))\n"
            }
            state = RateState(windowStart: now, emitted: 0, suppressed: 0)
        }

        let maxEntries: Int
        switch category {
        case .agentCenter, .scroll:
            // Lifecycle/tool transitions and gesture frames are bounded at
            // their producers. Preserve a complete short repro timeline.
            maxEntries = 240
        default:
            maxEntries = maxEntriesPerSignaturePerWindow
        }
        guard state.emitted < maxEntries else {
            state.suppressed += 1
            rateStates[signature] = state
            return (false, nil)
        }

        state.emitted += 1
        rateStates[signature] = state
        return (true, suppressionLine)
    }

    private static func shouldEmit(category: DiagnosticLogCategory, message: String) -> Bool {
        if isVerboseEnabled {
            return true
        }

        switch category {
        case .agentCenter, .app, .forwarding, .knownHosts, .keys, .ssh, .speech:
            return true
        case .sessionRestore:
            return shouldEmitStandardRestore(message)
        case .scroll:
            return isScrollDiagnosticsEnabled
        case .mosh:
            return shouldEmitStandardMosh(message)
        case .swipePad:
            return shouldEmitStandardSwipePad(message)
        case .tmux:
            return shouldEmitStandardTmux(message)
        }
    }

    private static func shouldEmitStandardRestore(_ message: String) -> Bool {
        if message.hasPrefix("persist-include ")
            || message.hasPrefix("persist-finished ")
            || message.hasPrefix("selected-changed ")
            || message.hasPrefix("session-state ") {
            return false
        }
        return true
    }

    private static func shouldEmitStandardMosh(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("failed")
            || lower.contains("error")
            || lower.contains("rejected")
            || lower.contains("invalid")
            || lower.contains("cancelled")
            || lower.contains("degraded")
            || lower.contains("hostkey")
            || lower.contains("host-key") {
            return true
        }

        return message.hasPrefix("connect begin ")
            || message.hasPrefix("connect result=")
            || message.hasPrefix("bootstrap begin ")
            || message.hasPrefix("bootstrap success ")
            || message.hasPrefix("bootstrap retry ")
            || message.hasPrefix("driver connected ")
            || message.hasPrefix("driver finished ")
            || message.hasPrefix("driver transport reachability=")
            || message.hasPrefix("mosh launch overlay dismissed ")
            || message.hasPrefix("mosh tmux sidechannel reconnect loop ended ")
    }

    private static func shouldEmitStandardSwipePad(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("failed")
            || lower.contains("invalid")
            || lower.contains("refused")
            || lower.contains("rejected")
            || lower.contains("error") {
            return true
        }

        return message.hasPrefix("profile-store ")
            || message.hasPrefix("resolve fallback ")
            || message.hasPrefix("plain-ssh detect failed ")
            || message.hasPrefix("tmux-response failure ")
    }

    private static func shouldEmitStandardTmux(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("failed")
            || lower.contains("rejected")
            || lower.contains("retry exhausted")
            || lower.contains("dropped")
            || lower.contains("unknown")
            || lower.contains("not-in-tmux")
            || lower.contains("no-active-pane")
    }

    private static func sanitize(_ message: String) -> String {
        var sanitized = SensitiveDataRedactor.redact(message)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"(?i)\b(currentProfile|title)=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)"#,
            template: "$1=<redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"(?i)\b(commandLine|command|preview|payload|prompt|summary|target|endpoint|user|address|remoteHost|names|process|profile|session|spec|matchProcess|pane_current_command|path|env|environment|error)=('.*?'|".*?"|[^\s]+)"#,
            template: "$1=<redacted>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            template: "<uuid>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"\S+@\S+"#,
            template: "<redacted-endpoint>"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"failed\([^)]*\)"#,
            template: "failed(<redacted>)"
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #" {2,}"#,
            template: " "
        )
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if DEBUG
    /// Exercises the exact diagnostic-file boundary without mutating the
    /// user's diagnostic log from a unit test.
    static func sanitizedMessageForTesting(_ message: String) -> String {
        sanitize(message)
    }
    #endif

    private static func bounded(_ message: String) -> String {
        guard message.count > maxLineCharacters else {
            return message
        }
        return String(message.prefix(maxLineCharacters)) + "... truncated"
    }

    private static func signature(for message: String) -> String {
        let tokens = message
            .split(separator: " ")
            .prefix(4)
            .map { token in
                String(token.map { $0.isNumber ? "#" : $0 })
            }
        return tokens.isEmpty ? "empty" : tokens.joined(separator: " ")
    }

    private static func replacingMatches(
        in string: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return string
        }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return expression.stringByReplacingMatches(
            in: string,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func headerLine() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(timestamp()) [Tessera][DiagnosticLog] file-created version=\(version) build=\(build) maxBytes=\(maxBytes) lineLimit=\(maxLineCharacters) rateWindowSeconds=\(Int(rateLimitWindow)) verbose=\(isVerboseEnabled)\n"
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private struct DiagnosticsSettingsView: View {
    @Environment(\.designTokens) private var T
    @AppStorage(DiagnosticLogStore.verboseDiagnosticsDefaultsKey) private var verboseDiagnostics = false
    @AppStorage(DiagnosticLogStore.scrollDiagnosticsDefaultsKey) private var scrollDiagnostics = false

    var onUploadLog: () -> Void

    @State private var logInfo = DiagnosticLogStore.info()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsH("diagnostics")

            ToggleRow(
                title: "verbose diagnostics",
                subtitle: "full tmux, mosh, SwipePad, and restore trace",
                isOn: $verboseDiagnostics
            )
            .padding(.bottom, 18)

            ToggleRow(
                title: "scroll diagnostics",
                subtitle: "include ScrollDiag lines in exported logs",
                isOn: $scrollDiagnostics
            )
            .padding(.bottom, 18)

            Field(
                label: "debug log",
                sub: "\(logInfo.displaySize) - updated \(logInfo.displayUpdatedAt)"
            ) {
                HStack(spacing: 8) {
                    ShareLink(
                        item: DiagnosticLogStore.logFileURL,
                        preview: SharePreview(
                            "tessera-diagnostics.log",
                            icon: Image(systemName: "doc.text")
                        )
                    ) {
                        Label("export log", systemImage: "square.and.arrow.up")
                            .font(Typography.tesseraMono(size: 13))
                            .foregroundStyle(T.fg)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(T.inputBg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(T.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(logInfo.isEmpty)
                    .opacity(logInfo.isEmpty ? 0.45 : 1)

                    Btn("upload log", compact: true) {
                        onUploadLog()
                        refresh()
                    }
                    .disabled(logInfo.isEmpty)
                    .opacity(logInfo.isEmpty ? 0.45 : 1)

                    Btn("refresh", compact: true) {
                        refresh()
                    }

                    Btn("clear", style: .danger, compact: true) {
                        DiagnosticLogStore.clear()
                        refresh()
                    }
                    .disabled(logInfo.isEmpty)
                    .opacity(logInfo.isEmpty ? 0.45 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refresh()
        }
        .onChange(of: verboseDiagnostics) { _, enabled in
            DiagnosticLogStore.appendApp("diagnostics verbose changed enabled=\(enabled)")
            refresh()
        }
        .onChange(of: scrollDiagnostics) { _, enabled in
            DiagnosticLogStore.appendApp("diagnostics scroll changed enabled=\(enabled)")
            refresh()
        }
    }

    private func refresh() {
        logInfo = DiagnosticLogStore.info()
    }
}
