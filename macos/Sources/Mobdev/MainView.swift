import MobdevCore
import SwiftUI

enum Pane: String, Hashable {
    case phone, agents, activity, remote
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Reopens the pane that was last selected.
    @AppStorage("selectedPane") private var storedPane = Pane.phone.rawValue

    private var pane: Binding<Pane?> {
        Binding(get: { Pane(rawValue: storedPane) ?? .phone }, set: { storedPane = ($0 ?? .phone).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: pane)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            switch pane.wrappedValue ?? .phone {
            case .phone: PhoneView()
            case .agents: AgentsView()
            case .activity: ActivityView()
            case .remote: RemoteView()
            }
        }
        .frame(minWidth: 860, minHeight: 660)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Pane?

    var body: some View {
        List(selection: $selection) {
            Section("Device") {
                NavigationLink(value: Pane.phone) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.deviceName)
                            Text(model.statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "iphone")
                            .overlay(alignment: .bottomTrailing) {
                                StatusDot(ready: model.isReady)
                                    .offset(x: 3, y: 2)
                            }
                    }
                }
            }
            Section("Agents") {
                NavigationLink(value: Pane.agents) {
                    Label("Connect", systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink(value: Pane.activity) {
                    Label("Activity", systemImage: "waveform.path.ecg")
                }
                .badge(model.activity.count)
            }
            Section("Cloud") {
                NavigationLink(value: Pane.remote) {
                    Label("Remote Access", systemImage: "network")
                }
                .badge(model.settings.relayEnabled ? Text(model.relayState == .connected ? "On" : "…") : nil)
            }
        }
        .listStyle(.sidebar)
    }
}
