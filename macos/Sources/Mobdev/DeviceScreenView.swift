import MobdevCore
import SwiftUI

/// One device's live screen on a Liquid Glass stage with its controls, and a floating panel that
/// shows what agents do on it, plus what setup still needs until the device is ready.
struct DeviceScreenView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @AppStorage("showDevicePanel") private var showPanel = true
    /// Whether the element inspector lies over the screen.
    @State private var inspecting = false

    /// The panel floats over the stage instead of being an inspector column: resizing the column
    /// animated the whole stage and its video layer frame by frame, which made the window flicker.
    static let panelWidth: CGFloat = 340

    /// The room for a device's screen and frame on a stage of `size`: a margin all around, minus
    /// the panel while it is shown. An upright phone is limited by the height and keeps its size
    /// when the panel opens or closes; a wide screen, such as an iPad held sideways, takes the
    /// whole width while the panel is hidden.
    static func room(in size: CGSize, panel: Bool) -> CGSize {
        CGSize(
            width: max(size.width - 80 - (panel ? panelWidth : 0), 100),
            height: max(size.height - 90, 100))
    }

    private var status: PhoneStatus? { model.state(id)?.status }

    var body: some View {
        ZStack {
            Backdrop(colors: status?.screen.isConnected == true ? model.ambient[id] ?? [] : [])
            Group {
                if model.state(id)?.isEmulated == true {
                    if let size = status?.frameSize {
                        EmulatorStage(
                            id: id, frameSize: CGSize(width: size.width, height: size.height), panel: showPanel,
                            inspecting: inspecting)
                    } else {
                        ProgressView("Waiting for the screen…")
                    }
                } else if let size = status?.frameSize, model.hardware(id)?.capture.session != nil {
                    PhoneStage(
                        id: id, frameSize: CGSize(width: size.width, height: size.height), panel: showPanel,
                        inspecting: inspecting)
                } else {
                    ConnectPhone(id: id)
                }
            }
            // Only moves, so the phone keeps its size and the video layer is not resized.
            .offset(x: showPanel ? -(Self.panelWidth + 12) / 2 : 0)
        }
        .overlay(alignment: .trailing) {
            if showPanel {
                DevicePanel(id: id)
                    .frame(width: Self.panelWidth)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.4), value: showPanel)
        .onChange(of: id) { inspecting = false }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Button("Home", systemImage: "house") { model.home(id) }
                    .disabled(status?.inputReady != true)
                    .help("Go to the home screen")
                Button("Screenshot", systemImage: "camera") { model.saveScreenshot(id) }
                    .disabled(status?.frameSize == nil)
                    .help("Save a screenshot")
                Toggle("Inspect", systemImage: "scope", isOn: $inspecting)
                    .disabled(status?.frameSize == nil)
                    .help(
                        inspecting
                            ? "Stop inspecting and control the device again"
                            : "Inspect elements: see identifiers and labels, click to copy the step that taps one")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { showPanel.toggle() }
                    .help(showPanel ? "Hide the inspector" : "Show activity and info")
            }
        }
    }
}

enum PanelTab: String, CaseIterable {
    case activity, apps, info

    var title: String {
        switch self {
        case .activity: "Activity"
        case .apps: "Apps"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "waveform.path.ecg"
        case .apps: "square.grid.2x2"
        case .info: "info.circle"
        }
    }
}

/// The inspector beside the phone, with icon tabs like Xcode's: activity and device info.
private struct DevicePanel: View {
    let id: String
    @AppStorage("devicePanelTab") private var tab = PanelTab.activity

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(PanelTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                    .background(tab == item ? Color.accentColor.opacity(0.14) : .clear, in: .capsule)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider().padding(.horizontal, 14)
            switch tab {
            case .activity: ActivityPane(id: id)
            case .apps: AppsPane(id: id)
            case .info: DeviceInfoView(id: id, compact: true)
            }
        }
    }
}

/// The device's state (expanded into setup steps while something is missing), then its activity.
private struct ActivityPane: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var pager = ActivityPager()

    var body: some View {
        let entries = model.state(id).map { _ in pager.items(in: model, device: id).map(\.entry) } ?? []
        let ready = model.state(id)?.isReady ?? false
        VStack(spacing: 0) {
            Group {
                if ready || model.state(id)?.isEmulated == true {
                    StatusSummary(id: id)
                } else {
                    SetupSteps(id: id)
                }
            }
            .padding(16)
            .transition(.opacity)
            .animation(.smooth, value: ready)
            Divider().padding(.horizontal, 16)
            HStack(spacing: 6) {
                Text("Activity").font(.headline)
                if !entries.isEmpty {
                    Text("\(entries.count)\(pager.hasMore(in: model, device: id) ? "+" : "")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                FlowButtons(id: id)
                Button("Clear", systemImage: "trash") {
                    model.clearActivity(device: id)
                    pager.reset()
                }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(entries.isEmpty)
                    .help("Clear this device's activity")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
            if model.recording.contains(id) {
                RecordingBar(id: id)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            if entries.isEmpty {
                Text("Every action an agent takes on this device appears here and stays after you quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(28)
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(ActivityDay.group(entries, date: \.date)) { day in
                        Section(day.title) {
                            ForEach(day.items) { entry in
                                ActivityRow(entry: entry, compact: true)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    if pager.hasMore(in: model, device: id) {
                        LoadMoreRow(page: pager.pagesLoaded) { await pager.loadMore(in: model, device: id) }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// A soft wash of the phone's own colors behind it, so the glass has something to refract.
private struct Backdrop: View {
    let colors: [Color]

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if colors.count == 2 {
                LinearGradient(colors: colors.map { $0.opacity(0.7) }, startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: colors)
        .ignoresSafeArea()
        .backgroundExtensionEffect()
    }
}

private struct PhoneStage: View {
    @Environment(AppModel.self) private var model
    let id: String
    let frameSize: CGSize
    /// Whether the panel is shown beside the screen.
    let panel: Bool
    let inspecting: Bool
    @State private var focused = false

    var body: some View {
        GeometryReader { proxy in
            let frame = ScreenFrame(form: model.state(id)?.info?.formFactor)
            let screen = frame.fit(frameSize, in: DeviceScreenView.room(in: proxy.size, panel: panel))
            let radius = frame.corner(for: screen)
            let bezel = frame.bezel(for: screen)

            VStack(spacing: 16) {
                PhoneMirrorView(
                    id: id, session: model.hardware(id)?.capture.session, input: model.hardware(id)?.input,
                    layout: model.settings.keyboardLayout, focused: $focused,
                    onDrag: { model.checkPointerAfterDrag(id, at: $0) },
                    onInput: { input in
                        switch input {
                        case .tap(let point): model.recordTap(id, at: point)
                        case .swipe(let start, let end, let duration):
                            model.recordSwipe(id, from: start, to: end, duration: duration)
                        case .text(let text): model.recordText(id, text)
                        case .key(let stroke): model.recordKey(id, stroke)
                        }
                    }
                )
                .frame(width: screen.width, height: screen.height)
                .overlay {
                    if inspecting { ElementInspector(id: id, screen: screen, frameSize: frameSize) }
                }
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .padding(bezel)
                .background {
                    RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                        .fill(.black)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.3)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1.5)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                }
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: radius + bezel + 4, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 3)
                            .padding(-4)
                    }
                }
                .accessibilityLabel("\(noun) screen")
                .accessibilityHint("Click to tap, drag to swipe, type while focused")

                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: focused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A new size when the panel opens or closes is not animated: animating the video layer's
        // size frame by frame made the window flicker.
        .transaction(value: panel) { $0.animation = nil }
    }

    private var hint: String {
        if inspecting { return "Inspecting: point at an element to see it · click to copy the step that taps it" }
        guard model.state(id)?.status.bluetooth.isConnected == true else {
            return "Pair over Bluetooth to control the \(noun) from here."
        }
        return focused
            ? "Typing goes to the \(noun). ⌘V types the Mac clipboard."
            : "Click to tap · drag to swipe · scroll · click, then type"
    }

    private var noun: String { model.state(id)?.noun ?? "iPhone" }
}

private struct ConnectPhone: View {
    @Environment(AppModel.self) private var model
    let id: String
    private var noun: String { model.state(id)?.noun ?? "iPhone" }

    var body: some View {
        switch model.state(id)?.status.screen ?? model.setupScreen {
        case .cameraDenied:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "video.slash")
            } description: {
                Text("macOS treats the \(noun) screen like a camera. Allow \(MobdevPaths.appName) in Privacy & Security.")
            } actions: {
                Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_Camera") }
                    .buttonStyle(.glassProminent)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Screen Capture Failed", systemImage: "exclamationmark.triangle", description: Text(message))
        case .noPicture(let name):
            ContentUnavailableView {
                Label("No Picture from macOS", systemImage: "exclamationmark.triangle")
            } description: {
                Text(
                    "\(name) is connected, but macOS's screen capture helper delivers no picture. This can happen after a macOS or Xcode update. Restarting the helper fixes it; macOS asks for an administrator password."
                )
            } actions: {
                Button("Restart Screen Capture…") { model.restartScreenCapture() }
                    .buttonStyle(.glassProminent)
            }
        case .locked(let name):
            ContentUnavailableView {
                Label("Unlock Your \(noun)", systemImage: noun == "iPad" ? "lock.ipad" : "lock.iphone")
            } description: {
                Text("\(name) is connected but locked, so it shows no picture. Unlock it with Face ID or the passcode.")
            }
        case .connected:
            // Connected over USB, but no picture yet. Mobdev starts the capture again by itself.
            ContentUnavailableView {
                Label("Waiting for the Screen", systemImage: "iphone.gen3")
                    .symbolEffect(.pulse, options: .repeating)
            } description: {
                Text(
                    "\(model.state(id)?.name ?? "The iPhone") is connected, but no picture has arrived yet. Wake and unlock it. If it stays like this, plug the cable in again."
                )
            }
        default:
            ContentUnavailableView {
                Label("Connect \(model.state(id)?.name ?? "Your iPhone")", systemImage: "iphone.gen3")
                    .symbolEffect(.pulse, options: .repeating)
            } description: {
                Text("Plug it in with a USB data cable, unlock it and tap Trust.\nIf your Mac asks to allow the accessory, click Allow.")
            } actions: {
                Button("Set Up iPhone…") { model.showsOnboarding = true }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

/// The ready device's state in four short rows, so the panel does not change its layout.
private struct StatusSummary: View {
    @Environment(AppModel.self) private var model
    let id: String
    private var noun: String { model.state(id)?.noun ?? "iPhone" }

    var body: some View {
        let state = model.state(id)
        let status = state?.status
        VStack(alignment: .leading, spacing: 8) {
            if let state, state.isEmulated {
                let waiting = ("circle.dashed", Color.secondary)
                row(
                    "Screen", symbol: "rectangle.on.rectangle", value: status?.frameSize == nil ? "Starting" : screenText(status?.screen),
                    mark: status?.frameSize == nil ? waiting : ("checkmark.circle.fill", .green))
                row("Input", symbol: "hand.tap", value: state.kind == .android ? "adb" : "Direct")
                row(
                    "Keyboard", symbol: "keyboard",
                    value: state.kind == .android ? "Typed as text" : status?.keyboardLayout.displayName ?? "U.S.")
                    .help(
                        state.kind == .android
                            ? "Text goes in as a whole through adb; it can be ASCII only."
                            : "Keys are sent for the simulator's own keyboard layout.")
                row("Apps", symbol: "square.stack.3d.up", value: "Install, launch, logs")
                    .help("install_app, launch_app, logs and crash_reports work without further setup.")
            } else {
                row("Screen", symbol: "rectangle.on.rectangle", value: screenText(status?.screen))
                row("Bluetooth", symbol: "dot.radiowaves.left.and.right", value: "Paired")
                row("Keyboard", symbol: "keyboard", value: model.settings.keyboardLayout.displayName)
                pointerRow(status?.pointer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(
        _ title: String, symbol: String, value: String, mark: (name: String, color: Color) = ("checkmark.circle.fill", .green)
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mark.name).foregroundStyle(mark.color)
            Label(title, systemImage: symbol).labelStyle(.titleOnly)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
    }

    /// Known after the first swipe or drag; with Snap to Item on, swipes turn into taps.
    private func pointerRow(_ pointer: PointerBehavior?) -> some View {
        let warning = ("exclamationmark.triangle.fill", Color.orange)
        return switch pointer {
        case .follows:
            row("Pointer", symbol: "cursorarrow", value: "Swipes work")
                .help("The pointer lands where it is aimed, so swipes work.")
        case .snaps:
            row("Pointer", symbol: "cursorarrow", value: "Snap to Item is on", mark: warning)
                .help(
                    "Swipes turn into taps. On the \(noun): Settings › Accessibility › Touch › AssistiveTouch, turn off Snap to Item.")
        case .hidden:
            row("Pointer", symbol: "cursorarrow", value: "Not visible", mark: warning)
                .help("The pointer did not appear. Turn on Settings › Accessibility › Touch › AssistiveTouch.")
        case nil:
            row("Pointer", symbol: "cursorarrow", value: "Not checked yet", mark: ("circle.dashed", .secondary))
                .help("Checked on the first swipe or drag. Snap to Item must be off in AssistiveTouch.")
        }
    }

    private func screenText(_ screen: ScreenState?) -> String {
        if case .connected(_, let width, let height) = screen, width > 0 { return "\(width) × \(height)" }
        return "Connected"
    }
}

/// What the device still needs: screen, Bluetooth and AssistiveTouch, with the way to fix each.
struct SetupSteps: View {
    @Environment(AppModel.self) private var model
    let id: String
    private var noun: String { model.state(id)?.noun ?? "iPhone" }

    private var status: PhoneStatus {
        model.state(id)?.status
            ?? PhoneStatus(screen: model.setupScreen, bluetooth: model.setupBluetooth, keyboardLayout: model.settings.keyboardLayout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup").font(.headline)
            StepRow(title: "Screen", detail: screenDetail, state: screenState)
            if case .noPicture = status.screen {
                Button("Restart Screen Capture…") { model.restartScreenCapture() }
            }
            StepRow(title: "Bluetooth", detail: bluetoothDetail, state: bluetoothState)
            if status.bluetooth == .unauthorized {
                Button("Open Bluetooth Settings") { model.openPrivacySettings("Privacy_Bluetooth") }
            } else if status.bluetooth == .advertising, !model.setupBluetooth.isConnected {
                // Hidden while another iPhone is paired: republishing would interrupt it.
                Button("Show on \(noun) Again", systemImage: "arrow.clockwise") { model.offerBluetoothAgain() }
            }
            if let host = model.state(id)?.replacementHost {
                // Input never moves to another Bluetooth host on its own: a host's name is only what it says.
                Text(
                    "“\(host.name ?? "An iPhone")” is connected over Bluetooth, but this \(noun) was paired as another device before. Use the connection only if it is this \(noun)."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Use This Connection") { model.useBluetoothHost(host.id, for: id) }
            }
            StepRow(title: "AssistiveTouch", detail: assistiveTouchDetail, state: assistiveTouchState)
            HStack {
                Button("Open Setup Assistant…") { model.showsOnboarding = true }
                    .buttonStyle(.glass)
                if model.state(id) != nil {
                    Button("Diagnose…") { diagnosing = true }
                        .buttonStyle(.glass)
                        .help("Check screen, USB, Bluetooth and AssistiveTouch, with a fix for each")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $diagnosing) { DiagnosisView(id: id) }
    }

    @State private var diagnosing = false

    private var screenState: StepRow.State {
        switch status.screen {
        case .connected: .done
        case .cameraDenied, .failed, .noPicture: .attention
        default: .waiting
        }
    }

    private var screenDetail: String {
        switch status.screen {
        case .connected(let name, let width, let height): width > 0 ? "\(name) · \(width) × \(height)" : name
        case .searching, .starting: "Connect with a USB data cable and tap Trust."
        case .noPicture: "Connected, but macOS's screen capture helper delivers no picture. Restart it below."
        case .locked: "Connected but locked. Unlock the \(noun)."
        default: status.screen.summary
        }
    }

    /// From the last pointer check, which Mobdev runs by itself once the iPhone is ready.
    private var assistiveTouchState: StepRow.State {
        switch status.pointer {
        case .follows: .done
        case .snaps, .hidden: .attention
        case nil: .info
        }
    }

    private var assistiveTouchDetail: String {
        switch status.pointer {
        case .follows: "On. Taps and swipes work."
        case .snaps:
            "Snap to Item is on, so swipes turn into taps. On the \(noun): Settings › Accessibility › Touch › AssistiveTouch, turn off Snap to Item."
        case .hidden: "The pointer did not appear. Turn on Settings › Accessibility › Touch › AssistiveTouch."
        case nil:
            "Checking by itself once the \(noun) is ready. Settings › Accessibility › Touch › AssistiveTouch: turn it on, turn off Snap to Item and keep Perform Touch Gestures on."
        }
    }

    private var bluetoothState: StepRow.State {
        switch status.bluetooth {
        case .connected, .resting: .done
        case .advertising, .starting: .waiting
        default: .attention
        }
    }

    private var bluetoothDetail: String {
        switch status.bluetooth {
        case .connected: "Paired. \(MobdevPaths.appName) can tap and type."
        case .resting:
            "Paired, resting: after five minutes without input \(MobdevPaths.appName) lets go, so the \(noun) shows its own keyboard. The next tap connects again."
        case .advertising: "On the \(noun): Settings › Bluetooth, then tap “\(HIDPeripheral.macName)” under Other Devices."
        default: status.bluetooth.summary
        }
    }
}
