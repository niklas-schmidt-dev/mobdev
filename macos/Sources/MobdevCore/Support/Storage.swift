import Foundation
import Security

/// Where Mobdev keeps settings and secrets. `MOBDEV_HOME` overrides the location.
public enum MobdevPaths {
    /// "dev.mobdev.mac" for the released app. The development build, "Mobdev Dev" with
    /// "dev.mobdev.mac.dev" (see scripts/build-app.sh), keeps its own settings, secrets and port,
    /// so it runs next to an installed Mobdev without touching it.
    public static let bundleIdentifier: String = {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        return identifier.hasPrefix("dev.mobdev.mac") ? identifier : "dev.mobdev.mac"
    }()
    public static var isDevelopmentBuild: Bool { bundleIdentifier != "dev.mobdev.mac" }
    public static var appName: String { isDevelopmentBuild ? "Mobdev Dev" : "Mobdev" }
    public static var defaultPort: UInt16 { isDevelopmentBuild ? 4687 : 4686 }

    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["MOBDEV_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var tokenFile: URL { home.appendingPathComponent("token") }
    /// Where the app listens for `Mobdev mcp`. Unlike the loopback port, no other user can take it.
    public static var socketFile: URL { home.appendingPathComponent("mobdev.sock") }
    public static var relaySecretFile: URL { home.appendingPathComponent("relay-secret") }
    public static var settingsFile: URL { home.appendingPathComponent("settings.json") }
    /// Devices seen before, so they are listed (with their activity) while unplugged.
    public static var devicesFile: URL { home.appendingPathComponent("devices.json") }

    /// Crash reports copied from devices by `crash_reports`, one folder per device.
    public static var crashReportsFolder: URL { home.appendingPathComponent("crash-reports", isDirectory: true) }

    /// A device's activity log, one JSON object per line.
    public static func activityFile(device: String) -> URL {
        let safe = device.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return home.appendingPathComponent("activity", isDirectory: true).appendingPathComponent("\(safe).jsonl")
    }

    /// The port from `MOBDEV_PORT`, the settings file, or the default.
    public static func port(settings: AppSettings) -> UInt16 {
        if let value = ProcessInfo.processInfo.environment["MOBDEV_PORT"], let port = UInt16(value) { return port }
        return settings.port
    }

    static func ensureHome() throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Secrets live in files readable only by the current user (mode 0600), so the stdio bridge
/// can read the API token without the app running.
public enum SecretStore {
    public static func read(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func readOrCreate(_ url: URL, prefix: String) throws -> String {
        if let existing = read(url) { return existing }
        return try regenerate(url, prefix: prefix)
    }

    @discardableResult
    public static func regenerate(_ url: URL, prefix: String) throws -> String {
        try MobdevPaths.ensureHome()
        let secret = prefix + randomHex(bytes: 32)
        let data = Data((secret + "\n").utf8)
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return secret
    }

    public static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var port: UInt16 = MobdevPaths.defaultPort
    public var keyboardLayout: KeyboardLayout = .suggested
    public var captureDeviceID: String?
    public var relayEnabled = false
    public var relayURL = ""
    public var relayAccessToken = ""
    public var hostName = AppSettings.defaultHostName
    /// Lists booted iOS simulators and Android devices next to iPhones.
    public var emulatorsEnabled = true
    /// Chosen on the welcome page: simulators and Android only, so the setup assistant does not
    /// open by itself and nothing asks for camera or Bluetooth access until an iPhone is set up.
    public var iPhoneSetupDeferred = false
    /// The development team that signs Mobdev Runner on iPhones, e.g. "ABCDE12345".
    public var runnerTeam = ""
    /// UDIDs of the iPhones with the UI tree turned on: Mobdev Runner starts whenever one is connected.
    public var runnerDevices: [String] = []
    /// Project folders opened in Tests, newest first.
    public var testProjects: [String] = []

    public init() {}

    public static var defaultHostName: String {
        let name = Host.current().localizedName ?? "mac"
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "mac" : String(collapsed.prefix(40))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? defaults.port
        keyboardLayout = (try? container.decodeIfPresent(KeyboardLayout.self, forKey: .keyboardLayout)) ?? defaults.keyboardLayout
        captureDeviceID = try container.decodeIfPresent(String.self, forKey: .captureDeviceID)
        relayEnabled = try container.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? false
        relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL) ?? ""
        relayAccessToken = try container.decodeIfPresent(String.self, forKey: .relayAccessToken) ?? ""
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? defaults.hostName
        emulatorsEnabled = try container.decodeIfPresent(Bool.self, forKey: .emulatorsEnabled) ?? true
        iPhoneSetupDeferred = try container.decodeIfPresent(Bool.self, forKey: .iPhoneSetupDeferred) ?? false
        runnerTeam = (try? container.decodeIfPresent(String.self, forKey: .runnerTeam)) ?? ""
        runnerDevices = (try? container.decodeIfPresent([String].self, forKey: .runnerDevices)) ?? []
        testProjects = (try? container.decodeIfPresent([String].self, forKey: .testProjects)) ?? []
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: MobdevPaths.settingsFile),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save() throws {
        try MobdevPaths.ensureHome()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = MobdevPaths.settingsFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
