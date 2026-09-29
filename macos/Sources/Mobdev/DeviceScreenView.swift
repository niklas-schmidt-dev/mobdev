import MobdevCore
import SwiftUI

/// One device's live screen on a Liquid Glass stage with its controls, and a floating panel that
/// shows what agents do on it, plus what setup still needs until the device is ready.
struct DeviceScreenView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @AppStorage("showDevicePanel") private var showPanel = true

    /// The panel floats over the stage instead of being an inspector column: resizing the column
    /// animated the whole stage and its video layer frame by frame, which made the window flicker.
    static let panelWidth: CGFloat = 340

    private var status: PhoneStatus? { model.state(id)?.status }

    var body: some View {
        ZStack {
            Backdrop(colors: status?.screen.isConnected == true ? model.ambient[id] ?? [] : [])
            Group {
                if let size = status?.frameSize, model.device(id)?.capture.session != nil {
                    PhoneStage(id: id, frameSize: CGSize(width: size.width, height: size.height))
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
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem {
                Button("Activity", systemImage: "sidebar.trailing") { showPanel.toggle() }
                    .help(showPanel ? "Hide activity" : "Show activity")
            }
        }
    }
}

/// Beside the phone: the device's state (expanded into setup steps while something is missing),
/// then its activity.
private struct DevicePanel: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let entries = model.state(id).map { _ in model.device(id)?.activity.all ?? [] } ?? []
        let ready = model.state(id)?.isReady ?? false
        VStack(spacing: 0) {
            Group {
                if ready {
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
                    Text("\(entries.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Clear", systemImage: "trash") { model.clearActivity(device: id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(entries.isEmpty)
                    .help("Clear this device's activity")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
            if entries.isEmpty {
                Text("Every action an agent takes on this iPhone appears here and stays after you quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(28)
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    ActivityRow(entry: entry, compact: true)
                        .listRowBackground(Color.clear)
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
    @State private var focused = false

    var body: some View {
        GeometryReader { proxy in
            let bezel: CGFloat = 10
            // Room for the setup panel is always kept, so opening it never resizes the phone.
            let available = CGSize(
                width: max(proxy.size.width - 80 - DeviceScreenView.panelWidth, 100),
                height: max(proxy.size.height - 150, 100))
            let scale = min(available.width / frameSize.width, available.height / frameSize.height)
            let screen = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
            let radius = screen.width * 0.14

            VStack(spacing: 22) {
                PhoneMirrorView(
                    id: id, session: model.device(id)?.capture.session, input: model.device(id)?.input,
                    layout: model.settings.keyboardLayout, focused: $focused
                )
                .frame(width: screen.width, height: screen.height)
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
                .accessibilityLabel("iPhone screen")
                .accessibilityHint("Click to tap, drag to swipe, type while focused")

                ControlBar(id: id, focused: focused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Floating Liquid Glass controls under the phone.
private struct ControlBar: View {
    @Environment(AppModel.self) private var model
    let id: String
    let focused: Bool
    @State private var text = ""

    var body: some View {
        let canTouch = model.state(id)?.status.bluetooth.isConnected == true
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.home(id) } label: {
                        Image(systemName: "house.fill").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Home")
                    .disabled(!canTouch)

                    HStack(spacing: 8) {
                        Image(systemName: "keyboard").foregroundStyle(.secondary)
                        TextField("Type on iPhone", text: $text)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                model.type(text, on: id)
                                text = ""
                            }
                    }
                    .padding(.horizontal, 16)
                    .frame(width: 260, height: 40)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .disabled(!canTouch)

                    Button { model.saveScreenshot(id) } label: {
                        Image(systemName: "camera.fill").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Save a screenshot")
                }
            }

            Text(hint(canTouch))
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    private func hint(_ canTouch: Bool) -> String {
        guard canTouch else { return "Pair over Bluetooth to control the phone from here." }
        return focused
            ? "Typing goes to the iPhone. ⌘V types the Mac clipboard."
            : "Click to tap · drag to swipe · scroll · click once, then type"
    }
}

private struct ConnectPhone: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        switch model.state(id)?.status.screen ?? model.setupScreen {
        case .cameraDenied:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "video.slash")
            } description: {
                Text("macOS treats the iPhone screen like a camera. Allow \(MobdevPaths.appName) in Privacy & Security.")
            } actions: {
                Button("Open Privacy Settings") { model.openPrivacySettings("Privacy_Camera") }
                    .buttonStyle(.glassProminent)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Screen Capture Failed", systemImage: "exclamationmark.triangle", description: Text(message))
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

/// The ready device's state in three short rows, so the panel does not change its layout.
private struct StatusSummary: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let status = model.state(id)?.status
        VStack(alignment: .leading, spacing: 8) {
            row("Screen", symbol: "rectangle.on.rectangle", value: screenText(status?.screen))
            row("Bluetooth", symbol: "dot.radiowaves.left.and.right", value: "Paired")
            row("Keyboard", symbol: "keyboard", value: model.settings.keyboardLayout.displayName)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Label(title, systemImage: symbol).labelStyle(.titleOnly)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
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

    private var status: PhoneStatus {
        model.state(id)?.status
            ?? PhoneStatus(screen: model.setupScreen, bluetooth: model.setupBluetooth, keyboardLayout: model.settings.keyboardLayout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup").font(.headline)
            StepRow(title: "Screen", detail: screenDetail, state: screenState)
            StepRow(title: "Bluetooth", detail: bluetoothDetail, state: bluetoothState)
            if status.bluetooth == .unauthorized {
                Button("Open Bluetooth Settings") { model.openPrivacySettings("Privacy_Bluetooth") }
            }
            StepRow(
                title: "AssistiveTouch",
                detail: "Settings › Accessibility › Touch › AssistiveTouch. Turns the pointer into taps.",
                state: .info)
            Button("Open Setup Assistant…") { model.showsOnboarding = true }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var screenState: StepRow.State {
        switch status.screen {
        case .connected: .done
        case .cameraDenied, .failed: .attention
        default: .waiting
        }
    }

    private var screenDetail: String {
        switch status.screen {
        case .connected(let name, let width, let height): width > 0 ? "\(name) · \(width) × \(height)" : name
        case .searching, .starting: "Connect with a USB data cable and tap Trust."
        default: status.screen.summary
        }
    }

    private var bluetoothState: StepRow.State {
        switch status.bluetooth {
        case .connected: .done
        case .advertising, .starting: .waiting
        default: .attention
        }
    }

    private var bluetoothDetail: String {
        switch status.bluetooth {
        case .connected: "Paired. \(MobdevPaths.appName) can tap and type."
        case .advertising: "On the iPhone: Settings › Bluetooth, then tap “\(HIDPeripheral.macName)” under Other Devices."
        default: status.bluetooth.summary
        }
    }
}
