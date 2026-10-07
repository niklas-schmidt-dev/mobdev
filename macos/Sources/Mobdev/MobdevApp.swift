import MobdevCore
import SwiftUI

/// Starts the phone services and API at launch, whether or not the window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // mobdev:// links from the dashboard. Handled here so they work without an open window.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            _ = Updates.shared
            await AppModel.shared.start()
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text)
        else { return }
        Task { @MainActor in AppModel.shared.open(url) }
    }

    /// Ends the UI tests Mobdev Runner keeps running on iPhones; xcodebuild would outlive the app.
    /// Kills scrcpy's servers on Android devices too, and removes Mobdev's proxy from them, which
    /// would otherwise leave them without network.
    func applicationWillTerminate(_ notification: Notification) {
        UIRunners.shared.stopAll()
        ScrcpySession.closeAll()
        AndroidNetworkCapture.stopAll()
    }

    /// Agents keep working from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MobdevApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window(MobdevPaths.appName, id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                SetUpIPhoneButton()
                if Updates.shared.isAvailable {
                    Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.showsNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") {
                    ProjectActions.open(model) { UserDefaults.standard.set($0.rawValue, forKey: "selectedPane") }
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            // The development build gets its own icon, so it is never mistaken for the installed app.
            Image(
                systemName: MobdevPaths.isDevelopmentBuild
                    ? "hammer" : model.isReady ? "iphone.radiowaves.left.and.right" : "iphone")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.primary.map { "\($0.name): \(model.statusLine)" } ?? model.statusLine)
        if model.settings.relayEnabled {
            Text("Relay: \(model.relayState.summary)")
        }
        Divider()
        if !model.isReady { SetUpIPhoneButton() }
        if Updates.shared.isAvailable {
            Button("Check for Updates…") { Updates.shared.checkForUpdates() }
        }
        Button("Open \(MobdevPaths.appName)") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit \(MobdevPaths.appName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Opens the setup assistant over the main window.
private struct SetUpIPhoneButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Set Up iPhone…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            AppModel.shared.showsOnboarding = true
        }
    }
}
