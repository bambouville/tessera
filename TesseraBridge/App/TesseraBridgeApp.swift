import AppKit
import SwiftUI

@MainActor
final class BridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = BridgeModel()

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
    ) -> Bool {
        model.receive(userActivity)
    }
}

@main
struct TesseraBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Window("Tessera Bridge", id: "bridge") {
            BridgeSetupView(model: applicationDelegate.model)
                .frame(minWidth: 540, idealWidth: 580, minHeight: 570)
        }
        .defaultSize(width: 580, height: 650)

        MenuBarExtra {
            BridgeMenu(model: applicationDelegate.model)
        } label: {
            BridgeMenuLabel(model: applicationDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct BridgeMenuLabel: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        Label(
            "Tessera Bridge",
            systemImage: model.isPublishing
                ? "iphone.and.arrow.forward"
                : "terminal"
        )
    }
}
