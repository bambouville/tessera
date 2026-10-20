import SwiftUI

struct BridgeSetupView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tessera Bridge")
                        .font(.title2.weight(.semibold))
                    Text("Bidirectional Handoff feasibility build")
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    fieldRow("Mac name") {
                        TextField("This Mac", text: $model.displayName)
                    }
                    fieldRow("SSH user") {
                        TextField("username", text: $model.user)
                    }
                    fieldRow("Reachable address") {
                        TextField("mac-name.local", text: $model.address)
                    }
                    fieldRow("SSH port") {
                        TextField("22", value: $model.port, format: .number.grouping(.never))
                            .frame(maxWidth: 100)
                    }
                    fieldRow("tmux session") {
                        TextField("tessera-phase0", text: $model.tmuxSessionName)
                    }
                    fieldRow("SSH host-key hint") {
                        TextField("Optional SHA256 fingerprint", text: $model.hostKeyFingerprint)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Divider()

                HStack(spacing: 10) {
                    Circle()
                        .fill(model.isPublishing ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                        .lineLimit(2)
                    Spacer()
                    if model.continuationStreamCount > 0 {
                        Text("Streams: \(model.continuationStreamCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Publish for Handoff") {
                        model.publish()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Stop") {
                        model.stopPublishing()
                    }
                    .disabled(!model.isPublishing)

                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue on this Mac")
                        .font(.headline)
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(model.isHandlingIncoming ? 1 : 0)
                        Text(model.incomingStatus)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    #if DEBUG
                    Button("Test iPad → Mac with these fields") {
                        model.simulateIncomingLocalContinuation()
                    }
                    .disabled(model.isHandlingIncoming)
                    #endif
                }

                Text("Incoming continuations that resolve to this Mac are checked against the local account, SSH host-key hint, and exact tmux session before Bridge opens iTerm2. Bridge never SSHes to localhost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !model.descriptorJSON.isEmpty {
                    DisclosureGroup("Published descriptor") {
                        ScrollView(.horizontal) {
                            Text(model.descriptorJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(8)
                        }
                        .frame(height: 58)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(.ultraThinMaterial)
    }

    private func fieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .frame(maxWidth: .infinity)
        }
    }
}
