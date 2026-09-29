import Carbon.HIToolbox
import MobdevCore
import SwiftUI

/// The setup assistant: one step per page. Each page checks itself off and moves on as soon as the
/// Mac sees the permission, the iPhone or the pairing, so most of setup is watching it happen.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, screen, connect, bluetooth, assistiveTouch, keyboard, done
    }

    private struct PageProgress: Equatable {
        let step: Step
        let complete: Bool
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var forward = true
    /// A first launch picks the keyboard layout from the Mac's; reopening keeps the user's choice.
    @State private var isFirstRun = false

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(step)
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 600, height: 580)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .animation(.smooth, value: step)
        }
        .clipped()
        .onAppear { isFirstRun = !model.screenStarted || !model.bluetoothStarted }
        .onChange(of: PageProgress(step: step, complete: isComplete(step))) { old, new in
            // Move on only when the current page completes, not when arriving on a finished one.
            guard old.step == new.step, !old.complete, new.complete else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.1))
                if step == new.step { go(to: next(new.step)) }
            }
        }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            WelcomePage()
        case .screen:
            StepPage(
                symbol: "rectangle.on.rectangle", title: "Allow Screen Access",
                message: "\(MobdevPaths.appName) sees your iPhone’s screen through the cable, the way QuickTime does. macOS calls this camera access.",
                waiting: model.screenStarted && !isComplete(.screen)
            ) {
                StatusPill(screenStatus)
            }
        case .connect:
            StepPage(
                symbol: "cable.connector", title: "Connect Your iPhone",
                message: "Plug it in with a USB cable, unlock it and tap Trust. If your Mac asks to allow the accessory, click Allow.",
                waiting: !isComplete(.connect)
            ) {
                StatusPill(connectStatus)
                Text("Charge-only cables give power but no picture.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        case .bluetooth:
            StepPage(
                symbol: "dot.radiowaves.left.and.right", title: "Pair over Bluetooth",
                message: "\(MobdevPaths.appName) taps and types as a Bluetooth keyboard and pointer.",
                waiting: model.bluetoothStarted && !isComplete(.bluetooth)
            ) {
                if model.bluetoothStarted {
                    Instructions(lines: [
                        "On your iPhone, open Settings › Bluetooth.",
                        "Under Other Devices, tap “\(MobdevPaths.appName)”.",
                        "Tap Pair.",
                    ])
                }
                StatusPill(bluetoothStatus)
            }
        case .assistiveTouch:
            StepPage(
                symbol: "hand.tap", title: "Turn On AssistiveTouch",
                message: "iOS turns a Bluetooth pointer into taps only with AssistiveTouch."
            ) {
                Instructions(lines: ["On your iPhone, open Settings › Accessibility › Touch › AssistiveTouch and turn it on."])
                VStack(spacing: 8) {
                    Button("Show Pointer", systemImage: "cursorarrow.rays") { model.showPointer() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(!model.status.bluetooth.isConnected)
                    Text(
                        model.status.bluetooth.isConnected
                            ? "A round pointer appears in the middle of your iPhone when it’s on."
                            : "Pair over Bluetooth first to try it."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        case .keyboard:
            StepPage(
                symbol: "keyboard", title: "Choose the Keyboard Layout",
                message: "Match Settings › General › Keyboard › Hardware Keyboard on your iPhone, so typed text comes out right."
            ) {
                Picker(
                    "Layout",
                    selection: Binding(get: { model.settings.keyboardLayout }, set: { model.setKeyboardLayout($0) })
                ) {
                    ForEach(KeyboardLayout.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .onAppear {
                    if isFirstRun, let layout = Self.macKeyboardLayout() { model.setKeyboardLayout(layout) }
                }
            }
        case .done:
            DonePage(ready: model.isReady) {
                UserDefaults.standard.set(Pane.agents.rawValue, forKey: "selectedPane")
                model.finishOnboarding()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .done {
                Button("Set Up Later") { model.finishOnboarding() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step != .welcome, step != .done {
                Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            primaryButton
        }
        .overlay { PageDots(count: Step.allCases.count, current: step.rawValue) }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder private var primaryButton: some View {
        let (title, prominent, action) = primary
        if prominent {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
    }

    /// The main button: the step's action first, then Continue once it is done, or Skip.
    private var primary: (String, Bool, () -> Void) {
        let advance = { go(to: next(step)) }
        switch step {
        case .welcome:
            return ("Get Started", true, advance)
        case .screen:
            if !model.screenStarted { return ("Allow Access", true, model.startScreen) }
            if model.status.screen == .cameraDenied {
                return ("Open Privacy Settings", true, { model.openPrivacySettings("Privacy_Camera") })
            }
        case .bluetooth:
            if !model.bluetoothStarted { return ("Turn On Bluetooth", true, model.startBluetooth) }
            if model.status.bluetooth == .unauthorized {
                return ("Open Privacy Settings", true, { model.openPrivacySettings("Privacy_Bluetooth") })
            }
        case .done:
            return ("Done", true, model.finishOnboarding)
        default:
            break
        }
        let complete = isComplete(step)
        return (complete ? "Continue" : "Skip", complete, advance)
    }

    // MARK: State

    private func isComplete(_ step: Step) -> Bool {
        switch step {
        case .screen:
            switch model.status.screen {
            case .searching, .connected, .failed: model.screenStarted
            default: false
            }
        case .connect: model.status.screen.isConnected
        case .bluetooth: model.status.bluetooth.isConnected
        case .welcome, .assistiveTouch, .keyboard, .done: true
        }
    }

    private var screenStatus: StatusPill.Status? {
        guard model.screenStarted else { return nil }
        switch model.status.screen {
        case .cameraDenied: return .problem("Turned off in Privacy & Security")
        case .starting: return .waiting("Waiting for your answer…")
        default: return .done("Screen access allowed")
        }
    }

    private var connectStatus: StatusPill.Status? {
        switch model.status.screen {
        case .connected(let name, _, _): .done("\(name) connected")
        case .failed(let message): .problem(message)
        case .cameraDenied: .problem("Allow screen access first")
        case .starting where !model.screenStarted: .problem("Allow screen access first")
        default: .waiting("Looking for your iPhone…")
        }
    }

    private var bluetoothStatus: StatusPill.Status? {
        guard model.bluetoothStarted else { return nil }
        switch model.status.bluetooth {
        case .starting: return .waiting("Starting Bluetooth…")
        case .advertising: return .waiting("Waiting for your iPhone…")
        case .connected: return .done("Paired")
        case .unauthorized: return .problem("Turned off in Privacy & Security")
        case .poweredOff: return .problem("Turn on Bluetooth on this Mac")
        case .unsupported, .failed: return .problem(model.status.bluetooth.summary)
        }
    }

    private var tint: Color { step == .done && model.isReady ? .green : .accentColor }

    // MARK: Navigation

    private func next(_ step: Step) -> Step { Step(rawValue: step.rawValue + 1) ?? .done }

    private func go(to target: Step) {
        forward = target.rawValue >= step.rawValue
        // Let the leaving page pick up the new direction before it animates out.
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.45)) { step = target }
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    /// The layout of the Mac's current keyboard, if Mobdev supports it.
    private static func macKeyboardLayout() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return identifier.localizedCaseInsensitiveContains("German") ? .german : .us
    }
}

// MARK: - Building blocks

/// Symbol in a glass disc, title, one sentence, then the page's own content.
private struct StepPage<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    var waiting = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: waiting)
                .frame(width: 104, height: 104)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.12)), in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 16) { content }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 48)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 12)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Welcome to \(MobdevPaths.appName)")
                    .font(.largeTitle.weight(.bold))
                Text("Let AI agents see and use your iPhone.\nSetup takes about two minutes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "rectangle.on.rectangle", title: "Sees the screen", detail: "Over the USB cable, like QuickTime.")
                Feature(symbol: "hand.tap", title: "Taps and types", detail: "As a Bluetooth keyboard and pointer.")
                Feature(
                    symbol: "lock.shield", title: "Stays on your Mac",
                    detail: "Nothing to install on the iPhone. No account.")
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 48)
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let detail: String

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DonePage: View {
    let ready: Bool
    let connectAgent: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            Image(systemName: ready ? "checkmark.circle.fill" : "iphone.gen3")
                .font(.system(size: 64, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ready ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: appeared)
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(ready ? "You’re All Set" : "Finish Anytime")
                    .font(.largeTitle.weight(.bold))
                Text(
                    ready
                        ? "Agents can now see and use your iPhone. Keep it unlocked while they work: set Auto-Lock to Never."
                        : "The iPhone view shows what is still missing. You can open this assistant again from the \(MobdevPaths.appName) menu."
                )
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Connect an Agent", systemImage: "point.3.connected.trianglepath.dotted", action: connectAgent)
                .buttonStyle(.glass)
                .controlSize(.large)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 48)
        .onAppear { appeared = true }
    }
}

/// Numbered steps to do on the iPhone.
private struct Instructions: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if lines.count > 1 {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .glassEffect(.regular, in: .circle)
                    }
                    Text(line)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
    }
}

/// Live state of a step: a spinner, a checkmark or a warning in a glass capsule.
private struct StatusPill: View {
    enum Status: Equatable {
        case waiting(String), done(String), problem(String)
    }

    let status: Status?

    init(_ status: Status?) { self.status = status }

    var body: some View {
        Group {
            if let status {
                HStack(spacing: 8) {
                    switch status {
                    case .waiting(let text):
                        ProgressView().controlSize(.small)
                        Text(text)
                    case .done(let text):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(text)
                    case .problem(let text):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(text)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .transition(.blurReplace)
            }
        }
        .animation(.smooth, value: status)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
