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

    var modelName: String { info?.modelName ?? "iPhone" }
    var isConnected: Bool { status.screen.isConnected }
    var isReady: Bool { status.frameSize != nil && status.bluetooth.isConnected }

    /// One line for the window subtitle, sidebar and menu bar.
    var statusLine: String {
        switch (status.screen, status.bluetooth) {
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
    @ObservationIgnored private let router: APIRouter
    @ObservationIgnored private let server: HTTPServer
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
        let tools = DeviceTools(hub: hub)
        let portBox = self.portBox
        let router = APIRouter(tools: tools, token: { tokenBox.get() }, port: { portBox.get() })
        self.router = router
        server = HTTPServer(port: MobdevPaths.port(settings: settings)) { request in
            await router.handle(request, from: .local)
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
        showsOnboarding = !screenStarted || !bluetoothStarted
        do {
            try await server.start()
            portBox.set(server.port)
            serverSummary = "Listening on 127.0.0.1:\(server.port)"
            serverFailed = false
        } catch {
            serverSummary = "Could not listen on port \(MobdevPaths.port(settings: settings)): \(error.localizedDescription)"
            serverFailed = true
        }
        if settings.relayEnabled { startRelay() }
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

    func refresh() {
        let hardware = hub.devices
        let states = hardware.map { device in
            DeviceState(
                id: device.id, name: device.name, info: device.info, status: device.status(), onUSB: device.isOnUSB,
                activityCount: device.activity.all.count)
        }
        if states != devices { devices = states }
        for device in hardware where !observedLogs.contains(ObjectIdentifier(device.activity)) {
            observedLogs.insert(ObjectIdentifier(device.activity))
            device.activity.observe { [weak self] _ in Task { @MainActor in self?.refreshActivity() } }
        }
        refreshActivity()
        relay.updateDevices(hardware.map(DeviceSummary.init))
        for id in thumbnails.keys where !(states.first { $0.id == id }?.isConnected ?? false) {
            thumbnails[id] = nil
            ambient[id] = nil
        }
    }

    private func refreshActivity() {
        let merged = hub.devices.flatMap { device in
            device.activity.all.map { ActivityItem(deviceID: device.id, deviceName: device.name, entry: $0) }
        }
        .sorted { $0.entry.date > $1.entry.date }
        let recent = merged
        if recent != activity { activity = recent }
        for index in devices.indices {
            let count = hub.devices.first { $0.id == devices[index].id }?.activity.all.count ?? 0
            if devices[index].activityCount != count { devices[index].activityCount = count }
        }
    }

    /// Thumbnails for the overview and backdrop colors for each connected device. Rendering full
    /// frames takes a while, so it happens off the main thread, and views only update on change.
    private func samplePictures() async {
        for device in hub.devices where device.capture.state.isConnected {
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

    func device(_ id: String) -> HardwareDevice? { hub.devices.first { $0.id == id } }
    func state(_ id: String) -> DeviceState? { devices.first { $0.id == id } }

    /// The device the menu bar and setup assistant talk about: a ready one, else one with a screen.
    var primary: DeviceState? {
        devices.first(where: \.isReady) ?? devices.first(where: \.isConnected) ?? devices.first
    }

    var isReady: Bool { devices.contains(where: \.isReady) }

    /// Screen setup across devices: a connected screen, else camera access and the search.
    var setupScreen: ScreenState {
        devices.first(where: \.isConnected)?.status.screen ?? hub.screenAccess
    }

    /// Bluetooth setup across devices: connected once any iPhone is paired.
    var setupBluetooth: BluetoothState { hub.peripheral.state }

    var statusLine: String {
        guard let primary else { return screenStarted ? "Connect an iPhone with a USB cable" : "Not set up" }
        let ready = devices.filter(\.isReady).count
        return ready > 1 ? "\(ready) iPhones ready" : primary.statusLine
    }

    func clearActivity(device: String? = nil) {
        for hardware in hub.devices where device == nil || hardware.id == device { hardware.activity.clear() }
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

    /// Closes the setup assistant. Skipped steps start anyway, so macOS asks for what is missing.
    func finishOnboarding() {
        showsOnboarding = false
        startScreen()
        startBluetooth()
    }

    /// Moves the pointer to the middle of the iPhone without tapping. With AssistiveTouch on, iOS
    /// shows it as a round pointer.
    func showPointer() {
        guard let id = primary?.id, let device = device(id) else { return }
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
            "Agents that have this Mac's client key can then control your iPhone through the relay. You can turn this off under Remote Access at any time."
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

    var claudeCodeCommand: String { "claude mcp add --scope user \(mcpName) -- \(shellQuoted(executablePath)) mcp" }

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

    var httpCommand: String {
        "claude mcp add --transport http \(mcpName) \(localMCPURL) --header \"Authorization: Bearer \(token)\""
    }

    var curlCommand: String {
        "curl -H \"Authorization: Bearer \(token)\" http://127.0.0.1:\(port)/v1/status"
    }

    var remoteCommand: String {
        "claude mcp add --transport http \(mcpName)-remote \(remoteMCPURL) --header \"Authorization: Bearer \(relayClientKey)\""
    }

    private func shellQuoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    // MARK: Manual control

    func home(_ id: String) {
        guard let device = device(id) else { return }
        Task { try? await device.press(.home) }
    }

    func type(_ text: String, on id: String) {
        guard let device = device(id), let strokes = try? settings.keyboardLayout.strokes(typing: text) else {
            NSSound.beep()
            return
        }
        Task { try? await device.type(strokes) }
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
