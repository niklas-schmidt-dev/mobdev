import MobdevCore
import SwiftUI

enum Pane: Hashable {
    case overview, device(String), remoteDevice(mac: String, id: String), agents, activity, remote
    /// A project's part, by the project's folder path.
    case project(String, ProjectSection)
    /// The active project's tests, or how to get a project: what the Tests pane of 0.2.50 and
    /// earlier, stored as "tests", opens now.
    case projects

    /// Stored in user defaults as "overview", "device:<id>", "remote-device:<mac>/<id>",
    /// "project:<section>:<path>", "agents", …
    var rawValue: String {
        switch self {
        case .overview: "overview"
        case .device(let id): "device:\(id)"
        case .remoteDevice(let mac, let id): "remote-device:\(mac)/\(id)"
        case .project(let path, let section): "project:\(section.rawValue):\(path)"
        case .projects: "projects"
        case .agents: "agents"
        case .activity: "activity"
        case .remote: "remote"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "tests", "projects": self = .projects
        case "agents": self = .agents
        case "activity": self = .activity
        case "remote": self = .remote
        case let value where value.hasPrefix("device:"): self = .device(String(value.dropFirst("device:".count)))
        case let value where value.hasPrefix("project:"):
            let parts = value.dropFirst("project:".count).split(separator: ":", maxSplits: 1)
            if parts.count == 2, let section = ProjectSection(rawValue: String(parts[0])) {
                self = .project(String(parts[1]), section)
            } else {
                self = .projects
            }
        case let value where value.hasPrefix("remote-device:"):
            let parts = value.dropFirst("remote-device:".count).split(separator: "/", maxSplits: 1)
            self = parts.count == 2 ? .remoteDevice(mac: String(parts[0]), id: String(parts[1])) : .overview
        default: self = .overview
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    /// Reopens the pane that was last selected.
    @AppStorage("selectedPane") private var storedPane = Pane.overview.rawValue

    /// The stored pane; "projects" (and "tests" from 0.2.50 and earlier) is the active project's
    /// tests, so its row in the sidebar is selected.
    private var shownPane: Pane {
        let pane = Pane(rawValue: storedPane)
        if pane == .projects, let active = model.activeProject { return .project(active.path, .tests) }
        return pane
    }

    private var pane: Binding<Pane?> {
        Binding(
            get: { shownPane },
            // The list reports nil for clicks that select nothing; stay on the current pane then.
            set: { pane in
                guard let pane else { return }
                storedPane = pane.rawValue
                // The project you look at is the one that gets what is saved without a path.
                if case .project(let path, _) = pane { model.activateProject(URL(fileURLWithPath: path, isDirectory: true)) }
            })
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: pane)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            switch shownPane {
            case .overview: DevicesOverview()
            case .device(let id):
                if model.state(id) != nil {
                    DeviceDetailView(id: id).id(id)
                } else {
                    DevicesOverview()
                }
            case .remoteDevice(let mac, let id):
                if model.remoteDevice(mac: mac, id: id) != nil {
                    RemoteDeviceView(mac: mac, id: id).id(mac + id)
                } else {
                    DevicesOverview()
                }
            case .project(let path, let section):
                ProjectDetailView(folder: URL(fileURLWithPath: path, isDirectory: true), section: section).id(path + section.rawValue)
            case .projects:
                NoProjectView()
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
        .sheet(isPresented: Bindable(model).showsNewProject) {
            NewProjectSheet { folder in storedPane = Pane.project(folder.path, .overview).rawValue }
                .environment(model)
        }
        // The Tests pane of 0.2.50 and earlier becomes the active project's tests for good, so the
        // view stays on that project when another one becomes active.
        .onAppear { if case .project = shownPane, Pane(rawValue: storedPane) == .projects { storedPane = shownPane.rawValue } }
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

            Section("Projects") {
                ForEach(model.projects, id: \.path) { folder in
                    ProjectSidebarRows(folder: folder)
                }
                Button { model.showNewProject() } label: {
                    Label("New Project…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { ProjectActions.open(model) { selection = $0 } } label: {
                    Label("Open Project…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                let iPhones = model.devices.filter { !$0.isEmulated }
                if iPhones.isEmpty {
                    Label("No iPhones yet", systemImage: "iphone.gen3")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(iPhones) { device in
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
            let emulated = model.devices.filter(\.isEmulated)
            if !emulated.isEmpty {
                Section("Simulators and Android") {
                    ForEach(emulated) { device in
                        NavigationLink(value: Pane.device(device.id)) {
                            DeviceRow(device: device)
                        }
                    }
                }
            }
            ForEach(model.otherMacs) { mac in
                Section(mac.online ? mac.name : "\(mac.name) · Offline") {
                    if mac.devices.isEmpty {
                        Text("No iPhone connected").foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(mac.devices, id: \.id) { device in
                        NavigationLink(value: Pane.remoteDevice(mac: mac.name, id: device.id)) {
                            RemoteDeviceRow(device: device, online: mac.online)
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
                Text(device.isEmulated ? "\(device.kind.label) · \(device.statusLine)" : device.isConnected ? device.statusLine : device.modelName)
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
        case .android: "candybarphone"
        default: "iphone.gen3"
        }
    }
}

private struct RemoteDeviceRow: View {
    let device: DeviceSummary
    let online: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name.isEmpty ? device.modelName : device.name).lineLimit(1)
                Text(online ? (device.ready ? "Ready for agents" : "Not ready") : device.modelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: device.deviceClass == "iPad" ? "ipad" : device.deviceClass == "Android" ? "candybarphone" : "iphone.gen3")
                .foregroundStyle(online ? .primary : .secondary)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(ready: device.ready).opacity(online ? 1 : 0).offset(x: 3, y: 2)
                }
        }
    }
}
