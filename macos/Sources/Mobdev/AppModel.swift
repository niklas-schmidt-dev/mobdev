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

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings
    var status: PhoneStatus
    var serverSummary = "Starting…"
    var serverFailed = false
    var relayState: RelayState = .off
    var activity: [ActivityLog.Entry] = []
    var captureDevices: [CaptureDeviceInfo] = []
    /// Average colors of the top and bottom of the phone screen, for the backdrop behind it.
    var ambient: [Color] = []
    /// The setup assistant. It opens by itself until macOS has asked for camera and Bluetooth
    /// access, so both prompts appear on the page that explains them.
    var showsOnboarding = false
    private(set) var screenStarted = false
    private(set) var bluetoothStarted = false
    private(set) var token: String
    private(set) var relaySecret: String

    let phone: HardwarePhone
    @ObservationIgnored private let activityLog = ActivityLog()
    @ObservationIgnored private let router: APIRouter
    @ObservationIgnored private let server: HTTPServer
    @ObservationIgnored private let relay: RelayClient
    @ObservationIgnored private let tokenBox: Locked<String>
    @ObservationIgnored private let portBox = Locked<UInt16>(0)
    @ObservationIgnored private var started = false

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        let token = (try? SecretStore.readOrCreate(MobdevPaths.tokenFile, prefix: "mdl_")) ?? SecretStore.randomHex(bytes: 32)
        self.token = token
        relaySecret = (try? SecretStore.readOrCreate(MobdevPaths.relaySecretFile, prefix: "mdh_")) ?? ""
        let tokenBox = Locked(token)
        self.tokenBox = tokenBox

        let signal = ChangeSignal()
        let phone = HardwarePhone(keyboardLayout: settings.keyboardLayout) { signal.fire() }
        self.phone = phone
        status = phone.status()

        let tools = PhoneTools(phone: phone, activity: activityLog)
        let portBox = self.portBox
        let router = APIRouter(tools: tools, phone: phone, token: { tokenBox.get() }, port: { portBox.get() })
        self.router = router
        server = HTTPServer(port: MobdevPaths.port(settings: settings)) { request in
            await router.handle(request, from: .local)
        }
        let relaySignal = ChangeSignal()
        relay = RelayClient(handler: { request in await router.handle(request, from: .relay) }) { _ in
            relaySignal.fire()
        }

        signal.connect { [weak self] in Task { @MainActor in self?.refresh() } }
        relaySignal.connect { [weak self] in Task { @MainActor in self?.relayState = self?.relay.state ?? .off } }
        activityLog.observe { [weak self] entries in Task { @MainActor in self?.activity = entries } }
    }

    func start() async {
        guard !started else { return }
        started = true
        try? settings.save()
        if HardwarePhone.screenAccessDetermined { startScreen() }
        if HardwarePhone.bluetoothAccessDetermined { startBluetooth() }
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
        Task { [weak self] in
            while let self {
                await self.sampleAmbient()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() {
        status = phone.status()
        if status.frameSize == nil { ambient = [] }
        // Device discovery can take a moment, so it stays off the main thread.
        let capture = phone.capture
        Task {
            let devices = await Task.detached(priority: .utility) { capture.availableDevices() }.value
            if devices != captureDevices { captureDevices = devices }
        }
        if ambient.isEmpty { Task { await sampleAmbient() } }
    }

    /// Averages the colors of the current frame for the backdrop. Rendering a full-size frame takes
    /// a while, so it happens off the main thread, and views only update when the colors change.
    private func sampleAmbient() async {
        guard status.frameSize != nil else { return }
        let phone = self.phone
        let colors = await Task.detached(priority: .utility) { phone.frame().map(Ambient.colors(of:)) }.value
        if let colors, status.frameSize != nil, colors != ambient { ambient = colors }
    }

    var port: UInt16 { portBox.get() == 0 ? MobdevPaths.port(settings: settings) : portBox.get() }
    var isReady: Bool { status.frameSize != nil && status.bluetooth.isConnected }

    var deviceName: String {
        if case .connected(let name, _, _) = status.screen { return name }
        return "iPhone"
    }

    /// One line for the window subtitle, sidebar and menu bar.
    var statusLine: String {
        switch (status.screen, status.bluetooth) {
        case (.cameraDenied, _): "Camera access needed"
        case (.failed, _): "Screen capture failed"
        case (.connected, .connected): "Ready for agents"
        case (.connected, .unauthorized): "Bluetooth access needed"
        case (.connected, .poweredOff): "Bluetooth is off"
        case (.connected, _): "Pair over Bluetooth to control"
        default: "Connect with a USB cable"
        }
    }

    func clearActivity() { activityLog.clear() }

    // MARK: Setup

    /// Starts reading the iPhone screen; the first time, macOS asks for camera access.
    func startScreen() {
        guard !screenStarted else { return }
        screenStarted = true
        phone.startScreen(preferredCaptureDeviceID: settings.captureDeviceID)
        refresh()
    }

    /// Starts the Bluetooth keyboard and pointer; the first time, macOS asks for Bluetooth access.
    func startBluetooth() {
        guard !bluetoothStarted else { return }
        bluetoothStarted = true
        phone.startBluetooth()
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
        Task { try? await phone.input.move(to: NormalizedPoint(x: 0.5, y: 0.5)) }
    }

    // MARK: Settings

    func setKeyboardLayout(_ layout: KeyboardLayout) {
        settings.keyboardLayout = layout
        phone.keyboardLayout = layout
        save()
        refresh()
    }

    func selectCaptureDevice(_ id: String?) {
        settings.captureDeviceID = id
        phone.capture.select(deviceID: id)
        save()
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

    func home() {
        Task { try? await phone.press(.home) }
    }

    func type(_ text: String) {
        guard let strokes = try? settings.keyboardLayout.strokes(typing: text) else {
            NSSound.beep()
            return
        }
        Task { try? await phone.type(strokes) }
    }

    func saveScreenshot() {
        guard let frame = phone.frame(), let image = ImageTools.encode(frame, png: true) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "iPhone \(formatter.string(from: Date())).png"
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
