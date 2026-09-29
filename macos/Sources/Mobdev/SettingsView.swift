import MobdevCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
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
        }
        .formStyle(.grouped)
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
