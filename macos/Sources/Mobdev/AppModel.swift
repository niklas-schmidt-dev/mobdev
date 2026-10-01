import AppKit
import CoreImage
import MobdevCore
import Observation
import SwiftUI

/// Lets core objects created before the model notify it once it exists.
final class ChangeSignal: Sendable {
    private let handler = Locked<(@Sendable () -> Void)?>(nil)
    func fire() { handler.get()?() }
    func connect(_ handler: @escaping @Sendable () -> Void) { self.handler.set(handler) }
}

/// A device as the interface shows it.
struct DeviceState: Identifiable, Equatable {
    let id: String
    var name: String
    var info: DeviceInfo?
    var status: PhoneStatus
    var onUSB: Bool
    var activityCount: Int
    /// A connected Bluetooth host that may be this iPhone paired again, while its own is away.
    var replacementHost: BluetoothHost? = nil
    var kind: DeviceKind = .iPhone

    var modelName: String { info?.modelName ?? kind.label }
    var isConnected: Bool { status.screen.isConnected }
    var isReady: Bool { status.isReady }
    /// A simulator or Android device: no cable, no Bluetooth, no setup.
    var isEmulated: Bool { kind != .iPhone }

    /// One line for the window subtitle, sidebar and menu bar.
    var statusLine: String {
        if isEmulated { return isReady ? "Ready for agents" : "Starting" }
        if case .noPicture = status.screen { return "No picture from macOS" }
        // Found over USB, but no picture has arrived yet.
        if isConnected, status.frameSize == nil { return "Waiting for the screen" }
        return switch (status.screen, status.bluetooth) {
        case (.cameraDenied, _): "Camera access needed"
        case (.failed, _): "Screen capture failed"
        case (.connected, .connected): "Ready for agents"
        case (.connected, .unauthorized): "Bluetooth access needed"
        case (.connected, .poweredOff): "Bluetooth is off"
        case (.connected, _): "Pair over Bluetooth to control"
        default: onUSB ? "Unlock the iPhone to see its screen" : "Not connected"
        }
    }
}

/// One action in the activity across all devices.
struct ActivityItem: Identifiable, Equatable {
    let deviceID: String
    let deviceName: String
    let entry: ActivityLog.Entry
    var id: UUID { entry.id }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings
    /// Every device seen, connected ones first.
    private(set) var devices: [DeviceState] = []
    var serverSummary = "Starting…"
    var serverFailed = false
    var relayState: RelayState = .off
    /// Every loaded action across all devices (each device loads its newest 1000), newest first.
    private(set) var activity: [ActivityItem] = []
    /// Small live pictures of each connected device and the average colors of its screen.
    private(set) var thumbnails: [String: CGImage] = [:]
    private(set) var ambient: [String: [Color]] = [:]
    /// Your other Macs and their iPhones, from the hosted relay. Empty without Remote Access.
    private(set) var otherMacs: [RemoteMac] = []
    /// The setup assistant. It opens by itself until macOS has asked for camera and Bluetooth
    /// access, so both prompts appear on the page that explains them.
    var showsOnboarding = false
    private(set) var screenStarted = false
    private(set) var bluetoothStarted = false
    private(set) var token: String
    private(set) var relaySecret: String

    let hub: DeviceHub
    /// Booted simulators and Android devices.
    let emulators: EmulatorHub
    /// The tools agents call, which the app's own controls call too.
    @ObservationIgnored let tools: DeviceTools
    @ObservationIgnored private let router: APIRouter
    @ObservationIgnored private let server: HTTPServer
    /// Where `Mobdev mcp` connects: a Unix socket in the private data directory.
    @ObservationIgnored private let socketServer: HTTPServer
    @ObservationIgnored private let relay: RelayClient
    @ObservationIgnored private let tokenBox: Locked<String>
    @ObservationIgnored private let portBox = Locked<UInt16>(0)
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observedLogs = Set<ObjectIdentifier>()

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        let token = (try? SecretStore.readOrCreate(MobdevPaths.tokenFile, prefix: "mdl_")) ?? SecretStore.randomHex(bytes: 32)
        self.token = token
        relaySecret = (try? SecretStore.readOrCreate(MobdevPaths.relaySecretFile, prefix: "mdh_")) ?? ""
        let tokenBox = Locked(token)
        self.tokenBox = tokenBox

        let signal = ChangeSignal()
        let hub = DeviceHub(keyboardLayout: settings.keyboardLayout) { signal.fire() }
        self.hub = hub
        let emulators = EmulatorHub { signal.fire() }
        self.emulators = emulators
        let tools = DeviceTools(hub: hub, emulators: emulators)
        self.tools = tools
        let portBox = self.portBox
        let router = APIRouter(tools: tools, token: { tokenBox.get() }, port: { portBox.get() })
        self.router = router
        server = HTTPServer(port: MobdevPaths.port(settings: settings)) { request in
            await router.handle(request, from: .local)
        }
        socketServer = HTTPServer(socket: MobdevPaths.socketFile) { request in
            await router.handle(request, from: .socket)
        }
        let relaySignal = ChangeSignal()
        relay = RelayClient(handler: { request in await router.handle(request, from: .relay) }) { _ in
            relaySignal.fire()
        }

        signal.connect { [weak self] in Task { @MainActor in self?.refresh() } }
        relaySignal.connect { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.relayState = self.relay.state
                if self.relayState == .connected { await self.refreshOtherMacs() }
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        try? settings.save()
        if DeviceHub.screenAccessDetermined { startScreen() }
        if DeviceHub.bluetoothAccessDetermined { startBluetooth() }
        showsOnboarding = (!screenStarted || !bluetoothStarted) && !settings.iPhoneSetupDeferred
        do {
            try await server.start()
            portBox.set(server.port)
            serverSummary = "Listening on 127.0.0.1:\(server.port)"
            serverFailed = false
        } catch {
            serverSummary = "Could not listen on port \(MobdevPaths.port(settings: settings)): \(error.localizedDescription)"
            serverFailed = true
        }
        do {
            try await socketServer.start()
        } catch {
            Log.error("stdio bridge socket: \(error)")
            serverSummary += ". Agents started with “mcp” cannot connect: \(error)"
            serverFailed = true
        }
        if settings.relayEnabled { startRelay() }
        if settings.emulatorsEnabled { emulators.start() }
        refresh()
        Task.detached(priority: .utility) { TextRecognizer.warmUp() }
        Task { [weak self] in
            while let self {
                await self.samplePictures()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task { [weak self] in
            while let self {
                await self.refreshOtherMacs()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Asks the relay which Macs and devices the account has, using this Mac's access token.
    func refreshOtherMacs() async {
        let token = settings.relayAccessToken.trimmingCharacters(in: .whitespaces)
        guard settings.relayEnabled, !token.isEmpty, let base = try? RelayClient.validatedURL(settings.relayURL) else {
            if !otherMacs.isEmpty { otherMacs = [] }
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/account/devices"), timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let decoded = try? JSONDecoder().decode(RemoteMac.Response.self, from: data)
        else { return }
        let others = decoded.macs.filter { $0.name != settings.hostName }
        if others != otherMacs { otherMacs = others }
    }

    func remoteDevice(mac: String, id: String) -> (mac: RemoteMac, device: DeviceSummary)? {
        guard let remote = otherMacs.first(where: { $0.name == mac }),
            let device = remote.devices.first(where: { $0.id == id })
        else { return nil }
        return (remote, device)
    }

    /// iPhones, then simulators, then Android devices.
    var allDevices: [any Device] { hub.devices + emulators.devices }

    func refresh() {
        let peripheral = hub.peripheral.state
        if peripheral != bluetoothState { bluetoothState = peripheral }
        let access = hub.screenAccess
        if access != screenAccess { screenAccess = access }
        let hardware = hub.devices
        let emulated = emulators.devices
        let states =
            hardware.map { device in
                DeviceState(
                    id: device.id, name: device.name, info: device.info, status: device.status(), onUSB: device.isOnUSB,
                    activityCount: device.activity.all.count, replacementHost: hub.replacementHost(for: device.id))
            }
            + emulated.map { device in
                DeviceState(
                    id: device.id, name: device.name, info: device.info, status: device.status(), onUSB: true,
                    activityCount: device.activity.all.count, kind: device.kind)
            }
        if states != devices { devices = states }
        let all: [any Device] = hardware + emulated
        for device in all where !observedLogs.contains(ObjectIdentifier(device.activity)) {
            observedLogs.insert(ObjectIdentifier(device.activity))
            device.activity.observe { [weak self] _ in Task { @MainActor in self?.refreshActivity() } }
        }
        refreshActivity()
        relay.updateDevices(all.map(DeviceSummary.init))
        for id in thumbnails.keys where !(states.first { $0.id == id }?.isConnected ?? false) {
            thumbnails[id] = nil
            ambient[id] = nil
        }
    }

    private func refreshActivity() {
        let all = allDevices
        let merged = all.flatMap { device in
            device.activity.all.map { ActivityItem(deviceID: device.id, deviceName: device.name, entry: $0) }
        }
        .sorted { $0.entry.date > $1.entry.date }
        let recent = merged
        if recent != activity { activity = recent }
        for index in devices.indices {
            let count = all.first { $0.id == devices[index].id }?.activity.all.count ?? 0
            if devices[index].activityCount != count { devices[index].activityCount = count }
        }
    }

    @ObservationIgnored private var sampleRound = 0

    /// Thumbnails for the overview and backdrop colors for each connected device. Rendering full
    /// frames takes a while, so it happens off the main thread, and views only update on change.
    /// An Android screenshot travels over adb, so those are taken every third round only.
    private func samplePictures() async {
        sampleRound += 1
        let connected: [any Device] =
            hub.devices.filter { $0.capture.state.isConnected }
            + emulators.devices.filter { $0.kind != .android || sampleRound % 3 == 1 }
        for device in connected {
            let id = device.id
            let result = await Task.detached(priority: .utility) { () -> (CGImage, [Color])? in
                guard let frame = device.frame() else { return nil }
                return (ImageTools.scaled(frame, longEdge: 420), Ambient.colors(of: frame))
            }.value
            guard let (thumbnail, colors) = result else { continue }
            thumbnails[id] = thumbnail
            if ambient[id] != colors { ambient[id] = colors }
        }
    }

    var port: UInt16 { portBox.get() == 0 ? MobdevPaths.port(settings: settings) : portBox.get() }

    func device(_ id: String) -> (any Device)? { allDevices.first { $0.id == id } }
    /// An iPhone, for what only iPhones have: the USB capture and Bluetooth input.
    func hardware(_ id: String) -> HardwareDevice? { hub.devices.first { $0.id == id } }
    func state(_ id: String) -> DeviceState? { devices.first { $0.id == id } }

    /// Setup is about iPhones: simulators and Android devices are always connected and ready.
    private var iPhones: [DeviceState] { devices.filter { !$0.isEmulated } }

    /// The device the menu bar and setup assistant talk about: a ready iPhone, else one with a
    /// screen, else any iPhone, else a ready simulator or Android device.
    var primary: DeviceState? {
        iPhones.first(where: \.isReady) ?? iPhones.first(where: \.isConnected) ?? iPhones.first
            ?? devices.first(where: \.isReady)
    }

    /// Whether an iPhone is ready, which the setup assistant and the menu bar wait for.
    var isReady: Bool { iPhones.contains(where: \.isReady) }

    /// Screen setup across iPhones: a connected screen, else camera access and the search.
    var setupScreen: ScreenState {
        iPhones.first(where: \.isConnected)?.status.screen ?? screenAccess
    }

    /// Bluetooth setup across iPhones: connected once any iPhone is paired.
    var setupBluetooth: BluetoothState { bluetoothState }

    /// Copies of the Bluetooth and camera states, stored so views update when they change: SwiftUI
    /// does not see changes inside `hub`.
    private(set) var bluetoothState: BluetoothState = .starting
    private(set) var screenAccess: ScreenState = .starting

    var statusLine: String {
        guard let primary else { return screenStarted ? "Connect an iPhone with a USB cable" : "Not set up" }
        let ready = devices.filter(\.isReady).count
        return ready > 1 ? "\(ready) devices ready" : primary.statusLine
    }

    func clearActivity(device: String? = nil) {
        for item in allDevices where device == nil || item.id == device { item.activity.clear() }
    }

    func setEmulatorsEnabled(_ enabled: Bool) {
        settings.emulatorsEnabled = enabled
        save()
        if enabled { emulators.start() } else { emulators.stop() }
    }

    func forget(_ id: String) { hub.forget(id) }

    // MARK: Setup

    /// Starts reading iPhone screens; the first time, macOS asks for camera access.
    func startScreen() {
        guard !screenStarted else { return }
        screenStarted = true
        hub.startScreens()
        refresh()
    }

    /// Starts the Bluetooth keyboard and pointer; the first time, macOS asks for Bluetooth access.
    func startBluetooth() {
        guard !bluetoothStarted else { return }
        bluetoothStarted = true
        hub.startBluetooth()
        refresh()
    }

    /// Sends a device's input to another Bluetooth host after the user confirmed it is this iPhone.
    func useBluetoothHost(_ host: UUID, for id: String) { hub.useHost(host, for: id) }

    /// Offers the Mac to iPhones again, for one that does not list it under Other Devices.
    func offerBluetoothAgain() { hub.peripheral.republish() }

    /// Restarts macOS's screen capture helper, which can keep a stale iPhone after Apple's USB
    /// service restarted (seen after a macOS and Xcode update) and then delivers no picture at all.
    /// It runs as root, so macOS asks for an administrator password; launchd starts it again on
    /// the next capture, which follows right after.
    func restartScreenCapture() {
        var error: NSDictionary?
        let script = NSAppleScript(
            source: "do shell script \"/usr/bin/killall iOSScreenCaptureAssistant\" with administrator privileges")
        script?.executeAndReturnError(&error)
        // -128: the password prompt was cancelled. Exit status 1 from killall: it was not running,
        // which is fine too.
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -128 { return }
        if let error { Log.error("restarting screen capture: \(error)") }
        Task {
            try? await Task.sleep(for: .seconds(1))
            hub.restartScreens()
        }
    }

    private var checkingPointer: Set<String> = []

    /// A drag in the mirror only swipes when the pointer does not snap to items. Until that is
    /// known, each drag is followed by a check that moves the pointer without clicking; the setup
    /// panel shows the result.
    func checkPointerAfterDrag(_ id: String, at point: NormalizedPoint) {
        guard let device = hardware(id), device.status().pointer != .follows, !checkingPointer.contains(id) else {
            return
        }
        checkingPointer.insert(id)
        Task {
            _ = try? await device.checkPointer(at: point)
            checkingPointer.remove(id)
        }
    }

    /// Moves the pointer to the middle without clicking and reads how it reacts (AssistiveTouch).
    func checkPointer(_ id: String) {
        guard let device = hardware(id) else { return }
        Task { _ = try? await device.checkPointer(at: NormalizedPoint(x: 0.5, y: 0.5)) }
    }

    /// Closes the setup assistant. Skipped steps start anyway, so macOS asks for what is missing,
    /// unless the welcome page chose simulators and Android only.
    func finishOnboarding() {
        showsOnboarding = false
        guard !settings.iPhoneSetupDeferred else { return }
        startScreen()
        startBluetooth()
    }

    /// "Set Up iPhone" on the welcome page: the iPhone steps follow, and their prompts are wanted.
    func beginIPhoneSetup() {
        guard settings.iPhoneSetupDeferred else { return }
        settings.iPhoneSetupDeferred = false
        save()
    }

    /// "Simulators and Android Only" on the welcome page: no camera or Bluetooth prompts, and the
    /// assistant stays closed on later launches. Set Up iPhone… opens it again.
    func useWithoutIPhone() {
        settings.iPhoneSetupDeferred = true
        save()
        UserDefaults.standard.set(Pane.overview.rawValue, forKey: "selectedPane")
        showsOnboarding = false
    }

    /// Moves the pointer to the middle of the iPhone without tapping. With AssistiveTouch on, iOS
    /// shows it as a round pointer.
    func showPointer() {
        guard let id = primary?.id, let device = hardware(id) else { return }
        Task { try? await device.move(to: NormalizedPoint(x: 0.5, y: 0.5)) }
    }

    // MARK: Settings

    func setKeyboardLayout(_ layout: KeyboardLayout) {
        settings.keyboardLayout = layout
        hub.keyboardLayout = layout
        save()
        refresh()
    }

    func regenerateToken() {
        guard let token = try? SecretStore.regenerate(MobdevPaths.tokenFile, prefix: "mdl_") else { return }
        self.token = token
        tokenBox.set(token)
    }

    private func save() {
        try? settings.save()
    }

    // MARK: Relay

    static let hostedRelayURL = "https://relay.mobdev.sh"
    static let dashboardURL = URL(string: "https://mobdev.sh/dashboard")!

    var relayClientKey: String { RelayClient.clientKey(forSecret: relaySecret) }

    /// Handles `mobdev://connect?relay=<url>&token=<access token>` from the dashboard.
    func open(_ url: URL) {
        guard let invite = RelayInvite(url: url) else {
            NSSound.beep()
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Connect this Mac to \(invite.relay.host ?? "the relay")?"
        alert.informativeText =
            "Relay: \(invite.relay.absoluteString)\n\nAgents that have this Mac's client key can then control your iPhone through the relay. You can turn this off under Remote Access at any time."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.relayURL = invite.relay.absoluteString
        settings.relayAccessToken = invite.token
        settings.relayEnabled = true
        save()
        startRelay()
        UserDefaults.standard.set("remote", forKey: "selectedPane")
    }

    var remoteMCPURL: String {
        var base = settings.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/h/\(settings.hostName)/mcp"
    }

    func setRelayEnabled(_ enabled: Bool) {
        settings.relayEnabled = enabled
        if enabled, settings.relayURL.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.relayURL = Self.hostedRelayURL
        }
        save()
        if enabled { startRelay() } else { relay.stop() }
    }

    func applyRelaySettings() {
        save()
        if settings.relayEnabled { startRelay() }
    }

    func rotateRelayKey() {
        guard let secret = try? SecretStore.regenerate(MobdevPaths.relaySecretFile, prefix: "mdh_") else { return }
        relaySecret = secret
        if settings.relayEnabled { startRelay() }
    }

    private func startRelay() {
        do {
            let url = try RelayClient.validatedURL(settings.relayURL)
            relay.start(
                url: url, secret: relaySecret, hostName: settings.hostName,
                accessToken: settings.relayAccessToken.isEmpty ? nil : settings.relayAccessToken)
        } catch {
            relay.stop()
            relayState = .failed(String(describing: error))
        }
    }

    // MARK: Agent configuration snippets

    var executablePath: String { Bundle.main.executablePath ?? "/Applications/Mobdev.app/Contents/MacOS/Mobdev" }
    var localMCPURL: String { "http://127.0.0.1:\(port)/mcp" }

    /// The name agents register. The development build uses its own, so copying its snippets never
    /// replaces the installed app's entry.
    var mcpName: String { MobdevPaths.isDevelopmentBuild ? "mobdev-dev" : "mobdev" }

    var claudeCodeCommand: String { "claude mcp add --scope user \(mcpName) -- \(Shell.quoted(executablePath)) mcp" }

    var codexConfig: String {
        """
        [mcp_servers.\(mcpName)]
        command = "\(executablePath)"
        args = ["mcp"]
        """
    }

    var jsonConfig: String {
        """
        {
          "mcpServers": {
            "\(mcpName)": {
              "command": "\(executablePath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    // Every value goes through Shell.quoted: the relay URL comes from a connect link, and the user
    // pastes these into a terminal.
    var httpCommand: String {
        "claude mcp add --transport http \(mcpName) \(Shell.quoted(localMCPURL)) --header \(Shell.quoted("Authorization: Bearer \(token)"))"
    }

    var curlCommand: String {
        "curl -H \(Shell.quoted("Authorization: Bearer \(token)")) \(Shell.quoted("http://127.0.0.1:\(port)/v1/status"))"
    }

    var remoteCommand: String {
        "claude mcp add --transport http \(Shell.quoted("\(mcpName)-remote")) \(Shell.quoted(remoteMCPURL)) --header \(Shell.quoted("Authorization: Bearer \(relayClientKey)"))"
    }

    // MARK: Manual control

    func home(_ id: String) {
        guard let device = device(id) else { return }
        record(id, "home")
        enqueue(id) { try? await device.press(.home) }
    }

    /// Runs a tool on a device for the person at the Mac, through the same checks as an agent's
    /// call. It appears in the activity as "You".
    func run(_ tool: String, on id: String, _ arguments: [String: JSONValue] = [:]) async -> ToolOutput {
        var arguments = arguments
        arguments["device"] = .string(id)
        do {
            return try await tools.call(tool, arguments: .object(arguments), source: "app", screenshotByDefault: false)
        } catch {
            return ToolOutput(text: String(describing: error), isError: true)
        }
    }

    // MARK: Flows

    /// Devices recording a flow. The steps themselves live with the device's tools, which record
    /// every call an agent or this app makes; clicks and keys in the window are added below.
    private(set) var recording: Set<String> = []

    func startRecording(_ id: String) {
        guard let device = device(id), let recorder = tools.recorder(for: id) else { return }
        // Simulators and Android say what is under a click, so it replays as tap_element.
        var tree: (@Sendable () async throws -> [UIElement]?)?
        if device.kind != .iPhone { tree = { try await device.uiTree() } }
        recorder.start(tree: tree)
        recording.insert(id)
    }

    /// Stops recording and returns the steps.
    func stopRecording(_ id: String) -> [Flow.Step] {
        recording.remove(id)
        return tools.recorder(for: id)?.stop() ?? []
    }

    func recordedStepCount(_ id: String) -> Int { tools.recorder(for: id)?.stepCount ?? 0 }

    private func record(_ id: String, _ tool: String, _ arguments: [String: JSONValue] = [:]) {
        guard recording.contains(id) else { return }
        tools.recorder(for: id)?.record(tool, arguments)
    }

    /// Input from the window, recorded as the tool call that replays it: the mirror of an iPhone
    /// calls these itself, simulators and Android through `tap`, `swipe`, `type` and `pressKey`.
    func recordTap(_ id: String, at point: NormalizedPoint) {
        guard recording.contains(id), let pixels = pixels(point, on: id) else { return }
        tools.recorder(for: id)?.recordTap(at: point, pixels: pixels)
    }

    func recordSwipe(_ id: String, from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) {
        guard let from = pixels(start, on: id), let to = pixels(end, on: id) else { return }
        record(
            id, "swipe",
            [
                "from_x": .number(Double(from.x)), "from_y": .number(Double(from.y)), "to_x": .number(Double(to.x)),
                "to_y": .number(Double(to.y)), "duration": .number((duration * 20).rounded() / 20),
            ])
    }

    func recordText(_ id: String, _ text: String) { record(id, "type_text", ["text": .string(text)]) }

    /// Named keys (Return, Escape, arrows) only; characters arrive through `recordText`.
    func recordKey(_ id: String, _ stroke: KeyStroke) {
        guard let name = FlowRecorder.keyName(usage: stroke.usage) else { return }
        let modifiers = ["ctrl", "shift", "alt", "cmd"].filter { stroke.modifiers & KeyboardLayout.modifierBits[$0]! != 0 }
        var arguments: [String: JSONValue] = ["key": .string(name)]
        if !modifiers.isEmpty { arguments["modifiers"] = .array(modifiers.map(JSONValue.string)) }
        record(id, "press_key", arguments)
    }

    /// A point of the screen in screenshot pixels, as tools take it.
    private func pixels(_ point: NormalizedPoint, on id: String) -> (x: Int, y: Int)? {
        guard let frame = device(id)?.status().frameSize else { return nil }
        let size = ScreenGeometry.screenshotSize(forFrameWidth: frame.width, height: frame.height)
        return (Int((point.x * Double(size.width)).rounded()), Int((point.y * Double(size.height)).rounded()))
    }

    /// The last input queued for each device. Each key press and click becomes a task, and a
    /// simulator or adb has no queue of its own, so every task waits for the one before it.
    @ObservationIgnored private var inputQueues: [String: Task<Void, Never>] = [:]

    private func enqueue(_ id: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = inputQueues[id]
        inputQueues[id] = Task {
            await previous?.value
            await work()
        }
    }

    func type(_ text: String, on id: String) {
        guard let device = device(id) else {
            NSSound.beep()
            return
        }
        // Simulators say which layout they read keys with; iPhones use the one picked in Settings.
        let layout = device.kind == .iPhone ? settings.keyboardLayout : device.status().keyboardLayout
        guard let strokes = try? layout.strokes(typing: text) else {
            // Android types whole text; others need every character on the layout.
            guard device.kind == .android else {
                NSSound.beep()
                return
            }
            recordText(id, text)
            enqueue(id) { _ = try? await device.typeText(text) }
            return
        }
        recordText(id, text)
        enqueue(id) {
            if (try? await device.typeText(text)) == true { return }
            try? await device.type(strokes)
        }
    }

    /// A click or drag in a simulator's or Android device's screen.
    func tap(_ id: String, at point: NormalizedPoint) {
        guard let device = device(id) else { return }
        recordTap(id, at: point)
        enqueue(id) { try? await device.tap(at: point, hold: 0.08) }
    }

    func swipe(_ id: String, from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) {
        guard let device = device(id) else { return }
        let duration = max(0.1, min(duration, 2))
        recordSwipe(id, from: start, to: end, duration: duration)
        enqueue(id) { try? await device.swipe(from: start, to: end, duration: duration) }
    }

    func pressKey(_ stroke: KeyStroke, on id: String) {
        guard let device = device(id) else { return }
        recordKey(id, stroke)
        enqueue(id) { try? await device.press(stroke) }
    }

    func saveScreenshot(_ id: String) {
        guard let device = device(id), let frame = device.frame(), let image = ImageTools.encode(frame, png: true) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "\(device.name) \(formatter.string(from: Date())).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? image.data.write(to: url)
        }
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Samples the dominant colors of the phone screen.
enum Ambient {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func colors(of frame: CGImage) -> [Color] {
        let image = CIImage(cgImage: frame)
        let extent = image.extent
        let half = extent.height / 2
        let regions = [
            CGRect(x: extent.minX, y: extent.minY + half, width: extent.width, height: half),
            CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: half),
        ]
        return regions.compactMap { region in
            guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: region), forKey: kCIInputExtentKey)
            guard let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            // The 1×1 result sits at the region's origin, not at zero.
            context.render(
                output, toBitmap: &pixel, rowBytes: 4, bounds: output.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            // Coarse steps, so a ticking clock or small changes on screen do not restart the
            // backdrop's cross-fade every few seconds.
            func channel(_ value: UInt8) -> Double { Double(value / 16 * 16) / 255 }
            return Color(.sRGB, red: channel(pixel[0]), green: channel(pixel[1]), blue: channel(pixel[2]))
        }
    }
}
