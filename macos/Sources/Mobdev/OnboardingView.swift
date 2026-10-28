import Carbon.HIToolbox
import MobdevCore
import SwiftUI

/// The setup assistant: one step per page. Each page checks itself off and moves on as soon as the
/// Mac sees the permission, the iPhone, Developer Mode or the runner, so most of setup is watching
/// it happen. With Developer Mode (the usual way for developers) Mobdev Runner controls the
/// iPhone; "Without Developer Mode" leads to Bluetooth pairing, AssistiveTouch and the keyboard
/// layout instead, and only that way asks for Bluetooth access.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, screen, connect, developerMode, xcode, runner, bluetooth, assistiveTouch, keyboard, done
    }

    /// The pages of one way through setup.
    static func steps(usesBluetooth: Bool) -> [Step] {
        usesBluetooth
            ? [.welcome, .screen, .connect, .bluetooth, .assistiveTouch, .keyboard, .done]
            : [.welcome, .screen, .connect, .developerMode, .xcode, .runner, .done]
    }

    private var steps: [Step] { Self.steps(usesBluetooth: model.settings.usesBluetooth) }

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
        case .developerMode:
            StepPage(
                symbol: "hammer", title: "Turn On Developer Mode",
                message: "With Developer Mode, \(MobdevPaths.appName) controls your iPhone directly: taps, swipes and typing, with nothing to pair.",
                waiting: model.primary?.developerMode != true
            ) {
                Instructions(lines: [
                    "On your iPhone, open Settings › Privacy & Security › Developer Mode and turn it on.",
                    "Tap Restart. After the restart, tap Turn On and enter your passcode.",
                ])
                StatusPill(developerModeStatus)
                Text("Not in Settings? It appears once the iPhone was connected to Xcode: open Xcode › Window › Devices and Simulators with the iPhone plugged in.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                    .fixedSize(horizontal: false, vertical: true)
                withoutDeveloperMode
            }
        case .xcode:
            StepPage(
                symbol: "person.badge.key", title: "Sign In to Xcode",
                message: "\(MobdevPaths.appName) builds Mobdev Runner, a small UI test, with Xcode and signs it with your development team.",
                waiting: !isComplete(.xcode)
            ) {
                Instructions(lines: [
                    "Install Xcode from the App Store and open it once.",
                    "In Xcode › Settings › Apple Accounts, sign in with your Apple Account. A free account works.",
                ])
                teamChooser
                StatusPill(teamStatus)
            }
            // Xcode makes the certificate a moment after signing in; look again while this page is open.
            .task {
                while !Task.isCancelled {
                    await model.refreshTeams()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        case .runner:
            StepPage(
                symbol: "iphone.gen3.radiowaves.left.and.right", title: "Start Mobdev Runner",
                message: "\(MobdevPaths.appName) installs Mobdev Runner on your iPhone and keeps it running. The first build takes a minute or two.",
                waiting: model.primary?.runnerStarting == true
            ) {
                StatusPill(runnerStatus)
                if let primary = model.primary, case .failed(let reason) = primary.runner {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .frame(maxWidth: 460)
                        .textSelection(.enabled)
                    Button("Try Again", systemImage: "arrow.clockwise") { model.restartRunner(primary.id) }
                        .buttonStyle(.glass)
                }
                Instructions(lines: [
                    "If iOS asks, allow UI automation: Settings › Developer › Enable UI Automation.",
                    "With a free Apple Account, trust yourself once: Settings › General › VPN & Device Management.",
                ])
                withoutDeveloperMode
            }
        case .bluetooth:
            StepPage(
                symbol: "dot.radiowaves.left.and.right", title: "Pair over Bluetooth",
                message: "Without Developer Mode, \(MobdevPaths.appName) taps and types as a Bluetooth keyboard and pointer.",
                waiting: model.bluetoothStarted && !isComplete(.bluetooth)
            ) {
                if model.bluetoothStarted {
                    Instructions(lines: [
                        "On your iPhone, open Settings › Bluetooth.",
                        "Under Other Devices, tap “\(HIDPeripheral.macName)”. That is this Mac.",
                        "Tap Pair.",
                    ])
                }
                StatusPill(bluetoothStatus)
                if model.setupBluetooth == .advertising {
                    VStack(spacing: 8) {
                        Button("Show on iPhone Again", systemImage: "arrow.clockwise") { model.offerBluetoothAgain() }
                            .buttonStyle(.glass)
                        Text("Not listed? iPhones on your Apple Account can miss this Mac. Mobdev offers it again by itself; this button does it now.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Use Developer Mode Instead") {
                    model.setUsesBluetooth(false)
                    go(to: .developerMode)
                }
                .buttonStyle(.link)
            }
        case .assistiveTouch:
            StepPage(
                symbol: "hand.tap", title: "Turn On AssistiveTouch",
                message: "iOS turns a Bluetooth pointer into taps only with AssistiveTouch."
            ) {
                Instructions(lines: [
                    "On your iPhone, open Settings › Accessibility › Touch › AssistiveTouch and turn it on.",
                    "On the same page, turn off Snap to Item and keep Perform Touch Gestures on. Otherwise swipes turn into taps.",
                ])
                VStack(spacing: 8) {
                    Button("Show Pointer", systemImage: "cursorarrow.rays") { model.showPointer() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(!model.setupBluetooth.isConnected)
                    Text(
                        model.setupBluetooth.isConnected
                            ? "A round pointer appears in the middle of your iPhone when it’s on."
                            : "Pair over Bluetooth first to try it."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    StatusPill(pointerStatus)
                }
                // While this page is open, check every few seconds, so the result follows the
                // switches on the iPhone. The check moves the pointer without tapping.
                .task {
                    while !Task.isCancelled {
                        if let device = model.primary, device.isReady, device.status.pointer != .follows {
                            model.checkPointer(device.id)
                        }
                        try? await Task.sleep(for: .seconds(4))
                    }
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
            if step == .welcome {
                // Simulators and Android need no setup, and no camera or Bluetooth access.
                Button("Simulators and Android Only") { model.useWithoutIPhone() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            } else if step != .done {
                Button("Set Up Later") { model.finishOnboarding() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step != .welcome, step != .done {
                Button("Back") { go(to: previous(step)) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            primaryButton
        }
        .overlay { PageDots(count: steps.count, current: steps.firstIndex(of: step) ?? 0) }
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
            return (
                "Set Up iPhone", true,
                {
                    model.beginIPhoneSetup()
                    advance()
                }
            )
        case .screen:
            if !model.screenStarted { return ("Allow Access", true, model.startScreen) }
            if model.setupScreen == .cameraDenied {
                return ("Open Privacy Settings", true, { model.openPrivacySettings("Privacy_Camera") })
            }
        case .bluetooth:
            if !model.bluetoothStarted {
                return (
                    "Turn On Bluetooth", true,
                    {
                        model.setUsesBluetooth(true)
                        model.startBluetooth()
                    }
                )
            }
            if model.setupBluetooth == .unauthorized {
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
            switch model.setupScreen {
            case .searching, .connected, .failed: model.screenStarted
            default: false
            }
        case .connect: model.setupScreen.isConnected
        case .developerMode: model.primary?.developerMode == true
        case .xcode: UIRunner.isTeamID(model.settings.runnerTeam)
        case .runner: model.primary?.runner == .running
        case .bluetooth: model.setupBluetooth.isConnected
        case .welcome, .assistiveTouch, .keyboard, .done: true
        }
    }

    /// Leaves the Developer Mode pages for Bluetooth, AssistiveTouch and the keyboard layout.
    private var withoutDeveloperMode: some View {
        Button("Without Developer Mode") {
            model.setUsesBluetooth(true)
            go(to: .bluetooth)
        }
        .buttonStyle(.link)
        .help("Control the iPhone as a Bluetooth keyboard and pointer instead; needs pairing and AssistiveTouch")
    }

    /// The teams of this Mac's Apple Development certificates, or a field for the team ID.
    @ViewBuilder private var teamChooser: some View {
        let selection = Binding(get: { model.settings.runnerTeam }, set: { model.setRunnerTeam($0) })
        if let teams = model.teams, !teams.isEmpty {
            Picker("Team", selection: selection) {
                ForEach(teams) { Text("\($0.name) (\($0.id))").tag($0.id) }
                if !teams.contains(where: { $0.id == model.settings.runnerTeam }) {
                    Text(model.settings.runnerTeam.isEmpty ? "None" : model.settings.runnerTeam).tag(model.settings.runnerTeam)
                }
            }
            .frame(width: 320)
        } else if model.teams != nil {
            TextField("Team ID", text: selection, prompt: Text("Team ID, e.g. ABCDE12345"))
                .frame(width: 260)
                .help("No Apple Development certificate was found yet. Xcode makes one when you sign in; or enter your team ID.")
        }
    }

    private var developerModeStatus: StatusPill.Status? {
        guard let device = model.primary, !device.isEmulated, device.isConnected else {
            return .problem("Connect your iPhone first")
        }
        return switch device.developerMode {
        case true?: .done("Developer Mode is on")
        case false?: .waiting("Waiting for Developer Mode…")
        case nil: .waiting("Asking Xcode about Developer Mode…")
        }
    }

    private var teamStatus: StatusPill.Status? {
        if UIRunner.isTeamID(model.settings.runnerTeam) { return .done("Team \(model.settings.runnerTeam)") }
        return model.teams == nil ? nil : .waiting("Looking for a development team…")
    }

    private var runnerStatus: StatusPill.Status? {
        guard let device = model.primary, !device.isEmulated else { return .problem("Connect your iPhone first") }
        switch device.runner ?? .off {
        case .running: return .done("Mobdev Runner controls your iPhone")
        case .building: return .waiting("Building with Xcode…")
        case .starting: return .waiting("Starting on your iPhone…")
        case .failed: return .problem("Could not start")
        case .off:
            if device.developerMode != true { return .problem("Turn on Developer Mode first") }
            if !UIRunner.isTeamID(model.settings.runnerTeam) { return .problem("Choose a development team first") }
            return .waiting("Starting…")
        }
    }

    private var screenStatus: StatusPill.Status? {
        guard model.screenStarted else { return nil }
        switch model.setupScreen {
        case .cameraDenied: return .problem("Turned off in Privacy & Security")
        case .starting: return .waiting("Waiting for your answer…")
        default: return .done("Screen access allowed")
        }
    }

    /// Checked by itself once the iPhone is ready: no click, two frames compared.
    private var pointerStatus: StatusPill.Status? {
        guard let device = model.primary, device.isReady else { return nil }
        return switch device.status.pointer {
        case .follows?: .done("AssistiveTouch works, and swipes do too")
        case .snaps?: .problem("Snap to Item is on: turn it off, or swipes turn into taps")
        case .hidden?: .problem("No pointer yet: turn on AssistiveTouch")
        case nil: .waiting("Checking the pointer…")
        }
    }

    private var connectStatus: StatusPill.Status? {
        switch model.setupScreen {
        case .connected(let name, _, _): .done("\(name) connected")
        case .noPicture: .problem("No picture from macOS: use Restart Screen Capture on the device page")
        case .locked(let name): .waiting("Unlock \(name)…")
        case .failed(let message): .problem(message)
        case .cameraDenied: .problem("Allow screen access first")
        case .starting where !model.screenStarted: .problem("Allow screen access first")
        default: .waiting("Looking for your iPhone…")
        }
    }

    private var bluetoothStatus: StatusPill.Status? {
        guard model.bluetoothStarted else { return nil }
        switch model.setupBluetooth {
        case .starting: return .waiting("Starting Bluetooth…")
        case .advertising: return .waiting("Waiting for your iPhone…")
        case .connected, .resting: return .done("Paired")
        case .unauthorized: return .problem("Turned off in Privacy & Security")
        case .poweredOff: return .problem("Turn on Bluetooth on this Mac")
        case .unsupported, .failed: return .problem(model.setupBluetooth.summary)
        }
    }

    private var tint: Color { step == .done && model.isReady ? .green : .accentColor }

    // MARK: Navigation

    private func next(_ step: Step) -> Step {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return .done }
        return steps[index + 1]
    }

    /// The page before on this way; a page of the other way goes back to where the ways part.
    private func previous(_ step: Step) -> Step {
        guard let index = steps.firstIndex(of: step) else { return .connect }
        return index > 0 ? steps[index - 1] : .welcome
    }

    private func go(to target: Step) {
        forward = (steps.firstIndex(of: target) ?? target.rawValue) >= (steps.firstIndex(of: step) ?? step.rawValue)
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
                Text("Mobile development, all in one app.\nSet up your iPhone in about two minutes.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 18) {
                Feature(
                    symbol: "iphone.gen3", title: "Your iPhone",
                    detail: "Screen and taps over the USB cable in Developer Mode, else Bluetooth.")
                Feature(
                    symbol: "macbook.and.iphone", title: "Simulators and Android",
                    detail: "Appear by themselves, with nothing to set up.")
                Feature(
                    symbol: "lock.shield", title: "Stays on your Mac",
                    detail: "No account, no telemetry.")
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
                        .fixedSize(horizontal: false, vertical: true)
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
