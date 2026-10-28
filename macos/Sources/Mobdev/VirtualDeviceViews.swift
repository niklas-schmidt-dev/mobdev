import MobdevCore
import SwiftUI

enum VirtualDeviceAction {
    case start(window: Bool)
    case shutDown
    case delete
}

/// A simulator or AVD that is not running, in the sidebar: Start right in the row, more in its
/// context menu.
struct VirtualDeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var confirmsDelete = false

    private var busy: Bool {
        model.virtualBusy.contains(device.id) || device.state == .booting || device.state == .shuttingDown
    }

    private var caption: String {
        switch device.state {
        case .booting: return "Starting…"
        case .shuttingDown: return "Shutting down…"
        case .booted: return "Running"
        case .shutdown:
            if model.virtualBusy.contains(device.id) { return "Starting…" }
            return device.model == device.name ? device.system : "\(device.model) · \(device.system)"
        }
    }

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: device.kind == .android ? "candybarphone" : device.isTablet ? "ipad" : "iphone.gen3")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small)
            } else if device.state == .shutdown {
                Button {
                    model.virtualDevice(.start(window: false), device)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start \(device.name)")
                .accessibilityLabel("Start \(device.name)")
            }
        }
        .contextMenu {
            Button("Start") { model.virtualDevice(.start(window: false), device) }
            Button(device.kind == .simulator ? "Start in Simulator" : "Start with Emulator Window") {
                model.virtualDevice(.start(window: true), device)
            }
            if device.createdByMobdev {
                Divider()
                Button("Delete Simulator…", role: .destructive) { confirmsDelete = true }
            }
        }
        .disabled(busy)
        .confirmationDialog("Delete \(device.name)?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { model.virtualDevice(.delete, device) }
        } message: {
            Text("Its apps and their data are deleted with it.")
        }
    }
}

/// Creates an iOS simulator of a type and iOS version this Mac has.
struct NewSimulatorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: SimulatorCatalog?
    @State private var problem: String?
    @State private var type: SimulatorCatalog.DeviceType?
    @State private var runtime: SimulatorCatalog.Runtime?
    @State private var name = ""
    @State private var boot = true

    private var runtimes: [SimulatorCatalog.Runtime] { type.flatMap { catalog?.runtimes(for: $0) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if let catalog {
                        Picker("Device", selection: $type) {
                            ForEach(["iPhone", "iPad"], id: \.self) { family in
                                Section(family) {
                                    ForEach(catalog.deviceTypes.filter { $0.family == family }) { type in
                                        Text(type.name).tag(Optional(type))
                                    }
                                }
                            }
                        }
                        Picker("System", selection: $runtime) {
                            ForEach(runtimes) { runtime in
                                Text(runtime.name).tag(Optional(runtime))
                            }
                        }
                        .disabled(runtimes.isEmpty)
                        TextField("Name", text: $name, prompt: Text(type?.name ?? "iPhone"))
                        Toggle("Start it now", isOn: $boot)
                    } else if problem == nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Looking for simulator types…").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("New Simulator")
                } footer: {
                    Text("Mobdev remembers that it made this simulator, so you and agents can delete it again from Mobdev.")
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .task { await load() }
            .onChange(of: type) {
                // Keep the system when the new type runs it, else take the newest that does.
                if let runtime, runtimes.contains(runtime) { return }
                runtime = runtimes.first
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let type, let runtime else { return }
                    model.createSimulator(type: type, runtime: runtime, name: name, boot: boot)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(type == nil || runtime == nil)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func load() async {
        do {
            let loaded = try await model.tools.virtualDevices.catalog()
            catalog = loaded
            type = loaded.deviceTypes.first { $0.family == "iPhone" && !loaded.runtimes(for: $0).isEmpty }
            runtime = type.flatMap { loaded.runtimes(for: $0).first }
            if loaded.deviceTypes.isEmpty { problem = "No simulator types are installed. Add an iOS platform in Xcode › Settings › Components." }
        } catch {
            problem = String(describing: error)
        }
    }
}
