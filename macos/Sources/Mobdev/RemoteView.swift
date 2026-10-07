import MobdevCore
import SwiftUI

struct RemoteView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRotate = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(
                    "Allow agents on other computers",
                    isOn: Binding(get: { model.settings.relayEnabled }, set: { model.setRelayEnabled($0) }))
            } footer: {
                Text("Your Mac keeps an outgoing connection to a relay. No port is opened, and the relay stores nothing. The hosted relay is free; create an access token at mobdev.sh, or run your own relay.")
            }

            if model.settings.relayEnabled {
                Section("Relay") {
                    TextField("URL", text: $model.settings.relayURL, prompt: Text(AppModel.hostedRelayURL))
                        .onSubmit { model.applyRelaySettings() }
                    TextField("Mac name", text: $model.settings.hostName)
                        .onSubmit { model.applyRelaySettings() }
                    SecureField("Access token", text: $model.settings.relayAccessToken, prompt: Text("mda_…"))
                        .onSubmit { model.applyRelaySettings() }
                    LabeledContent("No token yet?") {
                        Link("Get one at mobdev.sh", destination: AppModel.dashboardURL)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 8) {
                            relayStatusLabel
                            Button("Apply") { model.applyRelaySettings() }
                                .buttonStyle(.glass)
                        }
                    }
                }

                Section {
                    CodeRow(
                        title: "Claude Code", subtitle: model.remoteMCPURL, symbol: "globe",
                        code: model.remoteCommand, secrets: [model.relayClientKey])
                    LabeledContent("Client key") {
                        HStack {
                            Text(model.relayClientKey.prefix(12) + "…")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            CopyButton { model.relayClientKey }
                        }
                    }
                    Button("New Client Key…", role: .destructive) { confirmRotate = true }
                } header: {
                    Text("Access")
                } footer: {
                    Text("Anyone with the client key can control the phone. A new key disconnects every agent using the old one.")
                }

                Section {
                    Toggle(
                        "Allow live view",
                        isOn: Binding(get: { model.settings.liveViewAllowed }, set: { model.setLiveViewAllowed($0) }))
                    ForEach(model.liveSessions) { session in
                        LabeledContent {
                            Button("Stop") { model.stopLiveView(session.deviceID) }
                                .help("End this live view for everyone watching")
                        } label: {
                            Label {
                                Text(session.deviceName)
                                Text("Watched in the browser now by \(LiveStreams.describe(session.viewers))")
                            } icon: {
                                Image(systemName: "eye.fill").foregroundStyle(.red)
                            }
                        }
                    }
                } header: {
                    Text("Live View")
                } footer: {
                    Text("Watch and control this Mac's devices in the browser at mobdev.sh, and share them with a link. Agents with the client key can watch too. Screens can show private data, so live view stays off until you turn it on here; turning it off ends every live view.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Remote Access")
        .navigationSubtitle(model.settings.relayEnabled ? model.relayState.summary : "Off")
        .confirmationDialog("Create a new client key?", isPresented: $confirmRotate) {
            Button("New Key", role: .destructive) { model.rotateRelayKey() }
        } message: {
            Text("Agents using the current key lose access until you give them the new one.")
        }
    }

    @ViewBuilder
    private var relayStatusLabel: some View {
        switch model.relayState {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting:
            Label("Connecting", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}
