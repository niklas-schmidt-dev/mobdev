import MobdevCore
import SwiftUI

enum Pane: Hashable {
    case overview, device(String), agents, activity, remote

    /// Stored in user defaults as "overview", "device:<id>", "agents", …
    var rawValue: String {
        switch self {
        case .overview: "overview"
        case .device(let id): "device:\(id)"
        case .agents: "agents"
        case .activity: "activity"
        case .remote: "remote"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "agents": self = .agents
        case "activity": self = .activity
        case "remote": self = .remote
        case let value where value.hasPrefix("device:"): self = .device(String(value.dropFirst("device:".count)))
        default: self = .overview
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Reopens the pane that was last selected.
    @AppStorage("selectedPane") private var storedPane = Pane.overview.rawValue

    private var pane: Binding<Pane?> {
        Binding(
            get: { Pane(rawValue: storedPane) },
            // The list reports nil for clicks that select nothing; stay on the current pane then.
            set: { if let pane = $0 { storedPane = pane.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: pane)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            switch Pane(rawValue: storedPane) {
            case .overview: DevicesOverview()
            case .device(let id):
                if model.state(id) != nil {
                    DeviceDetailView(id: id).id(id)
                } else {
                    DevicesOverview()
                }
            case .agents: AgentsView()
            case .activity: ActivityView()
            case .remote: RemoteView()
            }
        }
        .frame(minWidth: 900, minHeight: 660)
        .sheet(isPresented: Bindable(model).showsOnboarding, onDismiss: model.finishOnboarding) {
            OnboardingView()
                .environment(model)
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Pane?

    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: Pane.overview) {
                Label("All Devices", systemImage: "square.grid.2x2")
            }
            .badge(model.devices.filter(\.isReady).count)
            // A badge hides the link's value from the list's selection, so tag the row again.
            .tag(Pane.overview)

            Section("This Mac") {
                if model.devices.isEmpty {
                    Label("No iPhones yet", systemImage: "iphone.gen3")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.devices) { device in
                    NavigationLink(value: Pane.device(device.id)) {
                        DeviceRow(device: device)
                    }
                    .contextMenu {
                        if !device.isConnected {
                            Button("Forget Device", role: .destructive) { model.forget(device.id) }
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
                .tag(Pane.activity)
            }
            Section("Cloud") {
                NavigationLink(value: Pane.remote) {
                    Label("Remote Access", systemImage: "network")
                }
                .badge(model.settings.relayEnabled ? Text(model.relayState == .connected ? "On" : "…") : nil)
                .tag(Pane.remote)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct DeviceRow: View {
    let device: DeviceState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(device.isConnected ? device.statusLine : device.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(device.isConnected ? .primary : .secondary)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(ready: device.isReady)
                        .opacity(device.isConnected ? 1 : 0)
                        .offset(x: 3, y: 2)
                }
        }
    }

    private var symbol: String {
        switch device.info?.formFactor {
        case .homeButton: "iphone.gen1"
        case .notch: "iphone.gen2"
        case .iPad: "ipad"
        default: "iphone.gen3"
        }
    }
}
