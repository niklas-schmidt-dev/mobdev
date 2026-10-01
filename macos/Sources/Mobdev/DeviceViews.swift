import MobdevCore
import SwiftUI

// MARK: - All devices

/// Every iPhone at a glance: a live picture of each, with model, iOS version and state.
struct DevicesOverview: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedPane") private var storedPane = Pane.overview.rawValue

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices Yet", systemImage: "iphone.gen3")
                } description: {
                    Text(
                        "Connect an iPhone with a USB data cable. Booted simulators and running Android emulators appear here too."
                    )
                } actions: {
                    Button("Set Up iPhone…") { model.showsOnboarding = true }
                        .buttonStyle(.glassProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("This Mac")
                            .font(.title3.weight(.semibold))
                        LazyVGrid(columns: Self.columns, spacing: 20) {
                            ForEach(model.devices) { device in
                                Button { storedPane = Pane.device(device.id).rawValue } label: {
                                    DeviceCard(device: device, thumbnail: model.thumbnails[device.id])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        ForEach(model.otherMacs) { mac in
                            HStack(spacing: 8) {
                                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                                Text(mac.name).font(.title3.weight(.semibold))
                                if !mac.online { Text("Offline").foregroundStyle(.secondary) }
                            }
                            .padding(.top, 18)
                            LazyVGrid(columns: Self.columns, spacing: 20) {
                                ForEach(mac.devices, id: \.id) { device in
                                    Button {
                                        storedPane = Pane.remoteDevice(mac: mac.name, id: device.id).rawValue
                                    } label: {
                                        RemoteDeviceCard(device: device, online: mac.online)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("All Devices")
        .navigationSubtitle(subtitle)
    }

    private static let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)]

    private var subtitle: String {
        let ready = model.devices.filter(\.isReady).count
        let connected = model.devices.filter(\.isConnected).count
        if model.devices.isEmpty { return "No devices" }
        return ready > 0 ? "\(ready) ready, \(connected) connected" : "\(connected) connected"
    }
}

private struct DeviceCard: View {
    let device: DeviceState
    let thumbnail: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 14) {
            DeviceArtwork(info: device.info, screen: device.isConnected ? thumbnail : nil, height: 210)
                .opacity(device.isConnected ? 1 : 0.55)
            VStack(spacing: 3) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                Text([device.modelName, device.info.map(\.systemName)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StateBadge(device: device)
                    .padding(.top, 5)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.smooth(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(.rect(cornerRadius: 26))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A device on another Mac of the account: no live picture, the state it last reported.
private struct RemoteDeviceCard: View {
    let device: DeviceSummary
    let online: Bool

    var body: some View {
        VStack(spacing: 14) {
            DeviceArtwork(info: device.info, height: 210)
                .opacity(online ? 0.9 : 0.5)
            VStack(spacing: 3) {
                Text(device.name.isEmpty ? device.modelName : device.name).font(.headline).lineLimit(1)
                Text([device.modelName, device.osVersion.isEmpty ? nil : device.info.systemName].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                RemoteStateBadge(device: device, online: online).padding(.top, 5)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .contentShape(.rect(cornerRadius: 26))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RemoteStateBadge: View {
    let device: DeviceSummary
    let online: Bool

    var body: some View {
        let (text, color): (String, Color) =
            !online ? ("Mac offline", .secondary) : device.ready ? ("Ready", .green)
            : device.screen ? ("Pair over Bluetooth", .orange) : ("Not ready", .orange)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// A device on another Mac: what it is, its state, and how agents reach it.
struct RemoteDeviceView: View {
    @Environment(AppModel.self) private var model
    let mac: String
    let id: String

    var body: some View {
        if let (remote, device) = model.remoteDevice(mac: mac, id: id) {
            Form {
                Section {
                    HStack(spacing: 20) {
                        DeviceArtwork(info: device.info, height: 120)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name.isEmpty ? device.modelName : device.name).font(.title2.weight(.semibold))
                            Text("\(device.modelName) · on \(remote.name)").foregroundStyle(.secondary)
                            RemoteStateBadge(device: device, online: remote.online).padding(.top, 6)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                Section("Device") {
                    LabeledContent("Model", value: device.modelName)
                    if !device.model.isEmpty { LabeledContent("Model Identifier", value: device.model) }
                    if !device.osVersion.isEmpty { LabeledContent("Software", value: device.info.systemName) }
                    LabeledContent("Mac", value: remote.name)
                    LabeledContent("Screen (USB)", value: device.screen ? "Connected" : "Not connected")
                    LabeledContent("Input (Bluetooth)", value: device.bluetooth ? "Paired" : "Not paired")
                }
                Section {
                    LabeledContent("Device ID") {
                        HStack {
                            Text(device.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            CopyButton { device.id }
                        }
                    }
                } header: {
                    Text("For Agents")
                } footer: {
                    Text("Agents reach this iPhone through \(remote.name)'s remote MCP command, found under Remote Access in Mobdev on that Mac. Pass this id as `device` when that Mac has several iPhones.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device.name.isEmpty ? device.modelName : device.name)
            .navigationSubtitle("On \(remote.name)")
        }
    }
}

/// Ready, screen only, or not connected, as a dot and a word.
struct StateBadge: View {
    let device: DeviceState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }

    private var text: String {
        if device.isEmulated { return device.isReady ? "Ready" : "Starting" }
        return device.isReady ? "Ready" : device.isConnected ? "Pair over Bluetooth" : device.onUSB ? "Locked" : "Not connected"
    }

    private var color: Color {
        device.isReady ? .green : device.isConnected || device.onUSB ? .orange : .secondary
    }
}

// MARK: - Device artwork

/// A drawing of the device's front in its color family, with the live screen if there is one.
struct DeviceArtwork: View {
    let info: DeviceInfo?
    var screen: CGImage?
    var height: CGFloat

    var body: some View {
        let form = info?.formFactor ?? .dynamicIsland
        let width = height * (form == .iPad ? 0.72 : form == .homeButton ? 0.49 : 0.47)
        let corner = width * (form == .homeButton ? 0.15 : form == .iPad ? 0.08 : 0.2)
        let bezel = width * (form == .homeButton ? 0.055 : 0.04)
        let chin = form == .homeButton ? height * 0.11 : bezel
        let light = info?.isLightColor ?? false

        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: light ? [Color(white: 0.93), Color(white: 0.8)] : [Color(white: 0.24), Color(white: 0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.white.opacity(light ? 0.8 : 0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: height * 0.06, y: height * 0.03)

            screenView(corner: max(corner - bezel, 2))
                .frame(width: width - bezel * 2, height: height - chin * 2)
                .padding(.top, chin)

            switch form {
            case .dynamicIsland:
                Capsule()
                    .fill(.black)
                    .frame(width: width * 0.3, height: width * 0.085)
                    .padding(.top, chin + width * 0.035)
            case .notch:
                UnevenRoundedRectangle(bottomLeadingRadius: width * 0.06, bottomTrailingRadius: width * 0.06)
                    .fill(.black)
                    .frame(width: width * 0.42, height: width * 0.07)
                    .padding(.top, chin)
            case .homeButton:
                Circle()
                    .strokeBorder(light ? Color.black.opacity(0.15) : Color.white.opacity(0.18), lineWidth: 1.5)
                    .frame(width: chin * 0.62, height: chin * 0.62)
                    .padding(.top, height - chin + chin * 0.19)
            case .android:
                Circle()
                    .fill(.black)
                    .frame(width: width * 0.075, height: width * 0.075)
                    .padding(.top, chin + width * 0.04)
            case .iPad:
                EmptyView()
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func screenView(corner: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if let screen {
            Image(decorative: screen, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(shape)
        } else {
            shape.fill(
                LinearGradient(
                    colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.04, green: 0.05, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Device detail

/// One device: its live screen, with its activity and info in the inspector beside it.
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let state = model.state(id) {
            DeviceScreenView(id: id)
                .navigationTitle(state.name)
                .navigationSubtitle(state.statusLine)
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "iphone.slash")
        }
    }
}

/// Artwork, name, model and iOS version at the top of the activity and info tabs.
private struct DeviceHeader: View {
    @Environment(AppModel.self) private var model
    let state: DeviceState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 14 : 20) {
            DeviceArtwork(
                info: state.info, screen: state.isConnected ? model.thumbnails[state.id] : nil, height: compact ? 84 : 120)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.name).font(compact ? .headline : .title2.weight(.semibold))
                Text([state.modelName, state.info.map(\.systemName)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                StateBadge(device: state).padding(.top, 6)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

struct DeviceInfoView: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// Inside the inspector: smaller header, no window background.
    var compact = false

    var body: some View {
        if let state = model.state(id), state.isEmulated {
            EmulatorInfo(state: state, compact: compact)
        } else if let state = model.state(id) {
            Form {
                Section { DeviceHeader(state: state, compact: compact) }
                Section("Device") {
                    LabeledContent("Name", value: state.name)
                    LabeledContent("Model", value: state.modelName)
                    if let info = state.info {
                        LabeledContent("Model Identifier", value: info.productType)
                        LabeledContent("Software", value: "\(info.systemName) (\(info.buildVersion))")
                        LabeledContent("Finish", value: info.isLightColor ? "Light" : "Dark")
                    }
                }
                Section {
                    Picker(
                        "Keyboard Layout",
                        selection: Binding(get: { model.settings.keyboardLayout }, set: { model.setKeyboardLayout($0) })
                    ) {
                        ForEach(KeyboardLayout.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Match Settings › General › Keyboard › Hardware Keyboard on the iPhone, and turn off Auto-Correction there so typed text is not changed.")
                }
                Section("Connection") {
                    LabeledContent("Screen (USB)") { Text(screenText(state)).foregroundStyle(.secondary) }
                    LabeledContent("Input (Bluetooth)") { Text(state.status.bluetooth.summary).foregroundStyle(.secondary) }
                }
                UITreeSection(state: state)
                Section {
                    LabeledContent("Device ID") {
                        HStack {
                            Text(state.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            CopyButton { state.id }
                        }
                    }
                } header: {
                    Text("For Agents")
                } footer: {
                    Text("Pass this id or the name as `device` to any tool when several iPhones are connected. `list_devices` returns them all.")
                }
                Section("Tips") {
                    StepRow(title: "Auto-Lock: Never", detail: "The iPhone must stay unlocked while agents work.", state: .info)
                    StepRow(
                        title: "Re-pair", detail: "If taps stop working, forget this Mac on the iPhone and pair again.",
                        state: .info)
                    Button("Diagnose…") { diagnosing = true }
                        .help("Check screen, USB, Bluetooth and AssistiveTouch, with a fix for each")
                }
                if !state.isConnected {
                    Section {
                        Button("Forget This Device", role: .destructive) { model.forget(id) }
                    } footer: {
                        Text("Removes it from the list and deletes its activity. It comes back when you connect it again.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(compact ? .hidden : .automatic)
            .sheet(isPresented: $diagnosing) { DiagnosisView(id: id) }
        }
    }

    @State private var diagnosing = false

    private func screenText(_ state: DeviceState) -> String {
        if case .connected(_, let width, let height) = state.status.screen, width > 0 { return "Connected · \(width) × \(height)" }
        return state.status.screen.summary
    }
}

/// A simulator or Android device: what it is and how agents reach it. Nothing to set up.
private struct EmulatorInfo: View {
    let state: DeviceState
    let compact: Bool

    var body: some View {
        Form {
            Section { DeviceHeader(state: state, compact: compact) }
            Section("Device") {
                LabeledContent("Name", value: state.name)
                LabeledContent("Kind", value: state.kind == .simulator ? "iOS Simulator" : "Android")
                LabeledContent("Model", value: state.modelName)
                if let info = state.info { LabeledContent("Software", value: info.systemName) }
                if let size = state.status.frameSize { LabeledContent("Screen", value: "\(size.width) × \(size.height)") }
            }
            Section {
                LabeledContent("Device ID") {
                    HStack {
                        Text(state.id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        CopyButton { state.id }
                    }
                }
            } header: {
                Text("For Agents")
            } footer: {
                Text("Pass this id or the name as `device` when several devices are connected. `list_devices` returns them all.")
            }
            Section("Tips") {
                if state.kind == .simulator {
                    StepRow(
                        title: "Builds", detail: "install_app takes an .app built for the simulator (Debug-iphonesimulator).",
                        state: .info)
                    StepRow(
                        title: "Crash reports", detail: "Read from the Mac's DiagnosticReports folder; nothing to turn on.",
                        state: .info)
                } else {
                    StepRow(title: "Builds", detail: "install_app takes an .apk.", state: .info)
                    StepRow(
                        title: "Phones", detail: "Android phones appear too once USB debugging is on and this Mac is allowed.",
                        state: .info)
                    StepRow(title: "Back", detail: "press_key with escape is Android's Back button.", state: .info)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(compact ? .hidden : .automatic)
    }
}

// MARK: - Activity rows

/// One agent action: its tool's icon, what happened, when and from where.
struct ActivityRow: View {
    let entry: ActivityLog.Entry
    var deviceName: String?
    /// For the narrow panel beside the phone: the time moves next to the title.
    var compact = false

    var body: some View {
        HStack(alignment: compact ? .top : .center, spacing: compact ? 10 : 12) {
            ToolIcon(tool: entry.tool, failed: entry.failed)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ToolIcon.title(for: entry.tool)).font(.body.weight(.medium)).lineLimit(1)
                    if entry.count > 1 {
                        // Identical calls in a row, e.g. an agent polling status; the time is the last one's.
                        Text("×\(entry.count)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(entry.count) times")
                    }
                    if let deviceName {
                        Label(deviceName, systemImage: "iphone.gen3")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: .capsule)
                    }
                    if compact {
                        Spacer(minLength: 4)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(entry.failed ? .red : .secondary)
                    .lineLimit(compact ? 3 : 2)
                    .help(entry.summary)
            }
            if !compact {
                Spacer(minLength: 8)
                times
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var times: some View {
        VStack(alignment: .trailing, spacing: 2) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(entry.source == "relay" ? "Remote" : entry.source == "app" ? "You" : "This Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }
}

/// A rounded square with the tool's symbol, colored by what kind of action it is.
struct ToolIcon: View {
    let tool: String
    var failed = false

    var body: some View {
        Image(systemName: failed ? "xmark" : Self.symbol(for: tool))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(failed ? Color.red.gradient : Self.color(for: tool).gradient, in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "tap": "hand.tap.fill"
        case "long_press": "hand.point.up.left.fill"
        case "swipe": "hand.draw.fill"
        case "scroll": "arrow.up.arrow.down"
        case "tap_text": "text.cursor"
        case "type_text": "keyboard.fill"
        case "press_key": "command"
        case "home": "house.fill"
        case "open_app": "square.grid.2x2.fill"
        case "screenshot": "camera.fill"
        case "read_screen": "text.viewfinder"
        case "find_text": "magnifyingglass"
        case "wait_for_text": "hourglass"
        case "ui_tree": "list.bullet.indent"
        case "tap_element": "hand.point.up.braille.fill"
        case "wait_for_element": "hourglass.bottomhalf.filled"
        case "run_flow": "play.rectangle.fill"
        case "list_devices": "iphone.gen3"
        case "list_apps": "apps.iphone"
        case "install_app": "arrow.down.app.fill"
        case "uninstall_app": "trash.fill"
        case "launch_app": "play.fill"
        case "stop_app": "stop.fill"
        case "open_url": "link"
        case "logs": "text.alignleft"
        case "crash_reports": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    static func color(for tool: String) -> Color {
        switch tool {
        case "tap", "long_press", "swipe", "scroll": .blue
        case "tap_text", "tap_element": .purple
        case "type_text", "press_key": .indigo
        case "home", "open_app": .green
        case "screenshot", "read_screen", "find_text", "wait_for_text", "ui_tree", "wait_for_element": .orange
        case "run_flow": .pink
        case "install_app", "uninstall_app", "launch_app", "stop_app", "open_url": .teal
        case "list_apps", "logs", "crash_reports": .brown
        default: .gray
        }
    }

    /// "Tap text" for "tap_text", from the tool's own title.
    static func title(for tool: String) -> String {
        DeviceTools.definitions.first { $0.name == tool }?.title ?? tool
    }
}
