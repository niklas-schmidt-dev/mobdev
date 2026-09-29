import MobdevCore
import SwiftUI

/// Starts the phone services and API at launch, whether or not the window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.start() }
    }

    /// Agents keep working from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MobdevApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Mobdev", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 860)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isReady ? "iphone.radiowaves.left.and.right" : "iphone")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.deviceName): \(model.statusLine)")
        if model.settings.relayEnabled {
            Text("Relay: \(model.relayState.summary)")
        }
        Divider()
        Button("Open Mobdev") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Mobdev") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
