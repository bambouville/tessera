import AppKit
import SwiftUI

struct BridgeMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: BridgeModel

    var body: some View {
        Text(model.isPublishing ? "Ready for Handoff" : "Not publishing")
        Text(model.status)
            .font(.caption)
        Text(model.incomingStatus)
            .font(.caption)
        Divider()
        Button("Open Bridge…") {
            openWindow(id: "bridge")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.isPublishing {
            Button("Stop Publishing") {
                model.stopPublishing()
            }
        }
        Divider()
        Button("Quit Tessera Bridge") {
            NSApp.terminate(nil)
        }
    }
}
