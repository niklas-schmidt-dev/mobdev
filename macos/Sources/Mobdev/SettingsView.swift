import MobdevCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Agents", systemImage: "hand.raised") { AgentSettings() }
            Tab("API", systemImage: "key") { APISettings() }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker(
                "iPhone keyboard layout",
                selection: Binding(get: { model.settings.keyboardLayout }, set: { model.setKeyboardLayout($0) })
            ) {
                ForEach(KeyboardLayout.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Must match Settings › General › Keyboard › Hardware Keyboard on the iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Section {
                Toggle(
                    "Show simulators and Android devices",
                    isOn: Binding(get: { model.settings.emulatorsEnabled }, set: { model.setEmulatorsEnabled($0) }))
            } footer: {
                Text(
                    "Booted iOS simulators (with Xcode) and Android emulators and phones (with a running adb) appear next to your iPhones. Agents drive them with the same tools."
                )
            }

            Section("Updates") {
                LabeledContent("Version", value: Updates.version)
                if Updates.shared.isAvailable {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { Updates.shared.automaticallyChecks },
                            set: { Updates.shared.automaticallyChecks = $0 }))
                    Button("Check Now") { Updates.shared.checkForUpdates() }
                } else {
                    Text("This is a local build. Release builds from mobdev.sh update themselves.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Guard rails for agents: apps they may not open.
private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newApp = ""
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(model.settings.blockedApps, id: \.self, selection: $selection) { app in
                    Text(app)
                }
                .frame(minHeight: 120)
                .overlay {
                    if model.settings.blockedApps.isEmpty {
                        Text("No blocked apps").foregroundStyle(.secondary)
                    }
                }
                .onDeleteCommand { remove() }
                HStack {
                    TextField("App name or bundle ID", text: $newApp, prompt: Text("e.g. Sparkasse or com.apple.mobilemail"))
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove", action: remove).disabled(selection == nil)
                }
            } header: {
                Text("Blocked apps")
            } footer: {
                Text(
                    "Agents cannot open or launch these apps with open_app or launch_app, in flows and tests too. A name also matches the end of a bundle ID. This prevents mistakes; it is not a sandbox, since an agent can still tap the app's icon."
                )
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let app = newApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !model.settings.blockedApps.contains(app) else { return }
        model.setBlockedApps(model.settings.blockedApps + [app])
        newApp = ""
    }

    private func remove() {
        guard let selection else { return }
        model.setBlockedApps(model.settings.blockedApps.filter { $0 != selection })
        self.selection = nil
    }
}

private struct APISettings: View {
    @Environment(AppModel.self) private var model
    @State private var reveal = false
    @State private var confirm = false

    var body: some View {
        Form {
            LabeledContent("Address", value: "127.0.0.1:\(model.port)")
            LabeledContent("Token") {
                HStack {
                    Text(reveal ? model.token : String(repeating: "•", count: 16))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                    CopyButton { model.token }
                }
            }
            Button("New Token…", role: .destructive) { confirm = true }
            Text("Needed for HTTP clients only. The stdio MCP config reads it automatically. Set MOBDEV_PORT to use another port.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .confirmationDialog("Create a new API token?", isPresented: $confirm) {
            Button("New Token", role: .destructive) { model.regenerateToken() }
        } message: {
            Text("HTTP clients using the current token stop working until you update them.")
        }
    }
}
