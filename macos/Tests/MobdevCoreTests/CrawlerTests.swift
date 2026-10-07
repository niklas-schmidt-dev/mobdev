import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A small app with screens: Home leads to Settings and About, Settings has a button that crashes
/// the app and one that deletes everything, which a crawler must never tap.
final class CrawlPhone: PhoneBackend, @unchecked Sendable {
    struct Screen {
        var title: String
        /// Label, identifier and where a tap on it leads ("crash" ends the app).
        var buttons: [(label: String, id: String, to: String)]
    }

    static let screens: [String: Screen] = [
        "home": Screen(title: "Home", buttons: [("Settings", "settings", "settings"), ("About", "about", "about")]),
        "settings": Screen(
            title: "Settings",
            buttons: [("Back", "back", "home"), ("Crash me", "crash", "crash"), ("Delete everything", "delete", "home")]),
        "about": Screen(title: "About", buttons: [("Back", "back", "home")]),
    ]

    let current = Locked("home")
    let crashed = Locked(false)
    let taps = Locked<[String]>([])
    let reports = Locked<[CrashReportFile]>([])
    lazy var apps: AppBackend? = CrawlApps(phone: self)

    func reset() {
        current.set("home")
        crashed.set(false)
    }

    func status() -> PhoneStatus {
        PhoneStatus(
            screen: .connected(name: "Crawl", width: 1179, height: 2556), bluetooth: .unsupported("fake"),
            keyboardLayout: .us, input: .direct("fake"))
    }

    func frame() -> CGImage? {
        FakePhone.render(lines: [(crashed.get() ? "Home screen" : Self.screens[current.get()]!.title, 100, 300)], width: 1179, height: 2556)
    }

    func uiTree() async throws -> [UIElement]? {
        guard !crashed.get(), let screen = Self.screens[current.get()] else { return [] }
        var elements = [
            UIElement(
                role: "Heading", label: screen.title, identifier: "", value: "", frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05),
                enabled: true, tappable: false)
        ]
        for (index, button) in screen.buttons.enumerated() {
            elements.append(
                UIElement(
                    role: "Button", label: button.label, identifier: button.id, value: "",
                    frame: CGRect(x: 0.1, y: 0.3 + Double(index) * 0.1, width: 0.8, height: 0.06), enabled: true, tappable: true))
        }
        return elements
    }

    func frontmostApp() async throws -> String? { crashed.get() ? "Home screen" : "Crawl App" }

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        guard let screen = Self.screens[current.get()],
            let index = screen.buttons.indices.first(where: { abs(0.33 + Double($0) * 0.1 - point.y) < 0.03 })
        else { return }
        let button = screen.buttons[index]
        taps.withLock { $0.append(button.id) }
        if button.to == "crash" {
            crashed.set(true)
            reports.withLock {
                $0.append(CrashReportFile(name: "CrawlApp-\($0.count + 1).ips", process: "CrawlApp", date: Date(), size: 10))
            }
        } else {
            current.set(button.to)
        }
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {}
    func scroll(at point: NormalizedPoint, ticks: Int) async throws {}
    func pan(at point: NormalizedPoint, ticks: Int) async throws {}
    func type(_ strokes: [KeyStroke]) async throws {}
    func press(_ stroke: KeyStroke) async throws {}
    func press(_ button: ConsumerUsage) async throws {}
}

/// Starting the app resets the fake to its first screen.
final class CrawlApps: AppBackend, @unchecked Sendable {
    let logs = AppLogs()
    let platform = AppPlatform.simulator
    weak var phone: CrawlPhone?

    init(phone: CrawlPhone) { self.phone = phone }

    func activate(_ bundleID: String) async throws { phone?.reset() }
    func apps(all: Bool) async throws -> [InstalledApp] { [] }
    func app(_ bundleID: String) async throws -> InstalledApp? {
        InstalledApp(bundleID: bundleID, name: "CrawlApp", version: "1", build: "1", developer: true, location: nil)
    }
    func install(at path: URL) async throws -> InstalledApp { throw DeveloperError("no") }
    func uninstall(_ bundleID: String) async throws -> InstalledApp { throw DeveloperError("no") }
    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool) async throws -> LaunchOutcome {
        phone?.reset()
        return .launched
    }
    func stop(_ bundleID: String) async throws -> Bool { true }
    func open(_ url: URL) async throws {}
    func crashReports() async throws -> [CrashReportFile] { phone?.reports.get().reversed() ?? [] }
    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) { throw DeveloperError("no") }
}

@Suite struct CrawlerTests {
    @Test func crawlMapsScreensAndKeepsCrashesButNeverDeletes() async throws {
        let phone = CrawlPhone()
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crawl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try await tools.call(
            "crawl_app", arguments: ["bundle_id": "dev.mobdev.crawl", "seconds": 120, "output": .string(folder.path)],
            source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        let map = try #require(PhoneTools.savedMap("dev.mobdev.crawl", file: folder.appendingPathComponent("crawl.json")))
        #expect(Set(map.screens.map(\.title)) == ["Home", "Settings", "About"])
        #expect(map.crashes.count == 1)
        #expect(map.crashes.first?.steps == [["tap_element": ["id": "settings"]], ["tap_element": ["id": "crash"]]])
        #expect(!phone.taps.get().contains("delete"))
        #expect(map.ended.hasPrefix("Every element"))
        // The crash's flow and the report are written next to the map.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("crash-1.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.md").path))
        let about = try #require(PhoneTools.find("about", in: map))
        #expect(about.path == [["tap_element": ["id": "about"]]])
    }

    @Test func navigateToReplaysThePathFromTheMap() async throws {
        let phone = CrawlPhone()
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crawl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await tools.call(
            "crawl_app", arguments: ["bundle_id": "dev.mobdev.crawl", "seconds": 120, "output": .string(folder.path)],
            source: "test", screenshotByDefault: false)
        let output = try await tools.call(
            "navigate_to",
            arguments: ["bundle_id": "dev.mobdev.crawl", "screen": "About", "map": .string(folder.appendingPathComponent("crawl.json").path)],
            source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(phone.current.get() == "about")
        let missing = try await tools.call(
            "navigate_to",
            arguments: ["bundle_id": "dev.mobdev.crawl", "screen": "Nowhere", "map": .string(folder.appendingPathComponent("crawl.json").path)],
            source: "test", screenshotByDefault: false)
        #expect(missing.isError)
        #expect(missing.text.contains("Screens:"))
    }

    @Test func androidFocusNamesThePackage() {
        let dumpsys = """
              mCurrentFocus=Window{a1b2c3 u0 com.android.settings/com.android.settings.Settings}
              mFocusedApp=ActivityRecord{d4e5f6 u0 com.android.settings/.Settings t12}
            """
        #expect(AndroidDevice.focusedPackage(dumpsys) == "com.android.settings")
        #expect(AndroidDevice.focusedPackage("mCurrentFocus=null") == nil)
    }
}
