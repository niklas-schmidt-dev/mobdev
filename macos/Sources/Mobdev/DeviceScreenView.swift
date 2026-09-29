import MobdevCore
import SwiftUI

/// One device's live screen on a Liquid Glass stage, with controls and a floating setup panel.
struct DeviceScreenView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @AppStorage("showSetupPanel") private var showSetup = true

    /// The setup panel floats over the stage instead of being an inspector column: resizing the
    /// column animated the whole stage and its video layer frame by frame, which made the window flicker.
    static let panelWidth: CGFloat = 320

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
            .offset(x: showSetup ? -(Self.panelWidth + 12) / 2 : 0)
        }
        .overlay(alignment: .trailing) {
            if showSetup {
                SetupInspector(id: id)
                    .scrollContentBackground(.hidden)
                    .frame(width: Self.panelWidth)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Button("Home", systemImage: "house") { model.home(id) }
                    .disabled(status?.bluetooth.isConnected != true)
                    .help("Go to the home screen")
                Button("Screenshot", systemImage: "camera") { model.saveScreenshot(id) }
                    .disabled(status?.frameSize == nil)
                    .help("Save a screenshot")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Setup", systemImage: "sidebar.trailing") {
                    withAnimation(.smooth(duration: 0.35)) { showSetup.toggle() }
                }
                .help(showSetup ? "Hide setup" : "Show setup")
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

struct SetupInspector: View {
    @Environment(AppModel.self) private var model
    let id: String

    private var status: PhoneStatus {
        model.state(id)?.status
            ?? PhoneStatus(screen: model.setupScreen, bluetooth: model.setupBluetooth, keyboardLayout: model.settings.keyboardLayout)
    }

    var body: some View {
        Form {
            Section {
                StepRow(title: "Screen", detail: screenDetail, state: screenState)
                StepRow(title: "Bluetooth", detail: bluetoothDetail, state: bluetoothState)
                if status.bluetooth == .unauthorized {
                    Button("Open Bluetooth Settings") { model.openPrivacySettings("Privacy_Bluetooth") }
                }
                StepRow(
                    title: "AssistiveTouch",
                    detail: "Settings › Accessibility › Touch › AssistiveTouch. Turns the pointer into taps.",
                    state: .info)
            } header: {
                Text("Setup")
            }

            Section {
                Picker(
                    "Layout",
                    selection: Binding(get: { model.settings.keyboardLayout }, set: { model.setKeyboardLayout($0) })
                ) {
                    ForEach(KeyboardLayout.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Match Settings › General › Keyboard › Hardware Keyboard on the iPhone.")
            }

            Section("Tips") {
                StepRow(title: "Auto-Lock: Never", detail: "The phone must stay unlocked while agents work.", state: .info)
                StepRow(
                    title: "Re-pair", detail: "If taps stop working, forget the device on the iPhone and pair again.",
                    state: .info)
            }
        }
        .formStyle(.grouped)
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
