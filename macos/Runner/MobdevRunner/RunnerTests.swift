import XCTest

/// Mobdev Runner: a UI test that does not end. Like WebDriverAgent, it serves what XCTest can read
/// and do on the device: the elements of the app in front, taps and typing. Mobdev builds it on the
/// Mac with Xcode, keeps `xcodebuild test-without-building` running, and reaches the port through
/// usbmuxd (on a simulator, on 127.0.0.1). `MOBDEV_RUNNER_PORT` and `MOBDEV_RUNNER_TOKEN` arrive as
/// `TEST_RUNNER_…` variables of xcodebuild.
///
///     GET  /health               {"ok": true, "version": 1}
///     GET  /tree[?bundle=<id>]   {"screen": {"width", "height"}, "apps": [names], "elements": [...]}
///                                each element: type, label, identifier, value, placeholder,
///                                frame [x, y, width, height] in points, enabled, selected
///     POST /tap   {"x", "y"}     fractions of the screen
///     POST /type  {"text"}       into the focused element; any characters, emoji included
final class RunnerTests: XCTestCase {
    static let protocolVersion = 1
    /// Failures XCTest records during a request, such as typing with no field focused.
    private var issues: [String] = []

    override func record(_ issue: XCTIssue) {
        // They answer the request; the run itself goes on.
        issues.append(issue.compactDescription)
    }

    func testServe() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        let port = environment["MOBDEV_RUNNER_PORT"].flatMap { UInt16($0) } ?? 47270
        let server = try RunnerServer(port: port, token: environment["MOBDEV_RUNNER_TOKEN"] ?? "") { [unowned self] in
            self.handle($0)
        }
        server.start()
        NSLog("Mobdev Runner: serving on port %d", Int(port))
        while true { RunLoop.main.run(until: Date(timeIntervalSinceNow: 1)) }
    }

    private func handle(_ request: RunnerServer.Request) -> RunnerServer.Response {
        issues.removeAll()
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return .json(["ok": true, "version": Self.protocolVersion])
            case ("GET", "/tree"):
                return .json(try tree(bundle: request.query["bundle"]))
            case ("POST", "/tap"):
                let body = try request.json()
                guard let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue,
                    (0...1).contains(x), (0...1).contains(y)
                else { return .error("Pass x and y as fractions of the screen, from 0 to 1.", status: 400) }
                frontmost()[0].coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                return outcome()
            case ("POST", "/type"):
                guard let text = try request.json()["text"] as? String, !text.isEmpty else {
                    return .error("Pass text.", status: 400)
                }
                frontmost()[0].typeText(text)
                return outcome()
            default:
                return .error("No such endpoint: \(request.method) \(request.path).", status: 404)
            }
        } catch let error as RunnerError {
            return .error(error.description, status: 400)
        } catch {
            // XCTest's errors, such as "Application com.example is not running".
            return .error((error as NSError).localizedDescription, status: 500)
        }
    }

    private func outcome() -> RunnerServer.Response {
        issues.isEmpty ? .json(["ok": true]) : .error(issues.joined(separator: " "), status: 500)
    }

    // MARK: Elements

    private func tree(bundle: String?) throws -> [String: Any] {
        let apps = bundle.map { [XCUIApplication(bundleIdentifier: $0)] } ?? frontmost()
        var elements: [[String: Any]] = []
        var names: [String] = []
        var screen = CGRect.zero
        for app in apps {
            let root = try app.snapshot()
            if screen.isEmpty { screen = root.frame }
            // XCUIApplication knows its bundle ID privately; the label is the app's name.
            let bundleID = app.responds(to: NSSelectorFromString("bundleID")) ? app.value(forKey: "bundleID") as? String : nil
            names.append(bundleID ?? root.label)
            for child in root.children { collect(child, into: &elements, depth: 0) }
        }
        return ["screen": ["width": screen.width, "height": screen.height], "apps": names, "elements": elements]
    }

    private func collect(_ snapshot: XCUIElementSnapshot, into elements: inout [[String: Any]], depth: Int) {
        guard elements.count < 3000, depth < 100 else { return }
        let frame = snapshot.frame
        var value = ""
        switch snapshot.value {
        case let text as String: value = text
        case let number as NSNumber: value = number.stringValue
        default: break
        }
        elements.append([
            "type": Self.typeNames[snapshot.elementType] ?? "Other",
            "label": snapshot.label, "identifier": snapshot.identifier, "value": value,
            "placeholder": snapshot.placeholderValue ?? "",
            "frame": [frame.minX, frame.minY, frame.width, frame.height].map { $0.isFinite ? $0 : 0 },
            "enabled": snapshot.isEnabled, "selected": snapshot.isSelected,
        ])
        for child in snapshot.children { collect(child, into: &elements, depth: depth + 1) }
    }

    /// The apps in front: with a system alert, SpringBoard and the app below it. There is no public
    /// API for this, so it uses XCTest's private one, as WebDriverAgent does: Xcode 27 has
    /// `XCUISystem.activeForegroundApplications`; older versions the accessibility client's active
    /// applications by process ID. SpringBoard (the home screen) is the fallback.
    private func frontmost() -> [XCUIApplication] {
        let device = XCUIDevice.shared as NSObject
        if device.responds(to: NSSelectorFromString("system")), let system = device.value(forKey: "system") as? NSObject,
            let apps = system.call("activeForegroundApplications") as? [XCUIApplication], !apps.isEmpty
        {
            return apps
        }
        typealias ApplicationWithPID = @convention(c) (AnyClass, Selector, Int32) -> XCUIApplication?
        let withPID = NSSelectorFromString("applicationWithPID:")
        if let client = device.call("accessibilityInterface") as? NSObject,
            let elements = client.call("activeApplications") as? [NSObject],
            let method = class_getClassMethod(XCUIApplication.self, withPID)
        {
            let make = unsafeBitCast(method_getImplementation(method), to: ApplicationWithPID.self)
            let apps = elements.compactMap { element -> XCUIApplication? in
                guard let pid = (element.value(forKey: "processIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
                return make(XCUIApplication.self, withPID, pid)
            }
            if !apps.isEmpty { return apps }
        }
        return [XCUIApplication(bundleIdentifier: "com.apple.springboard")]
    }

    private static let typeNames: [XCUIElement.ElementType: String] = [
        .other: "Other", .application: "Application", .group: "Group", .window: "Window", .sheet: "Sheet",
        .alert: "Alert", .dialog: "Dialog", .button: "Button", .radioButton: "RadioButton", .radioGroup: "RadioGroup",
        .checkBox: "CheckBox", .disclosureTriangle: "DisclosureTriangle", .popUpButton: "PopUpButton",
        .comboBox: "ComboBox", .menuButton: "MenuButton", .toolbarButton: "ToolbarButton", .popover: "Popover",
        .keyboard: "Keyboard", .key: "Key", .navigationBar: "NavigationBar", .tabBar: "TabBar", .tabGroup: "TabGroup",
        .toolbar: "Toolbar", .statusBar: "StatusBar", .table: "Table", .tableRow: "TableRow", .tableColumn: "TableColumn",
        .outline: "Outline", .outlineRow: "OutlineRow", .browser: "Browser", .collectionView: "CollectionView",
        .slider: "Slider", .pageIndicator: "PageIndicator", .progressIndicator: "ProgressIndicator",
        .activityIndicator: "ActivityIndicator", .segmentedControl: "SegmentedControl", .picker: "Picker",
        .pickerWheel: "PickerWheel", .switch: "Switch", .toggle: "Toggle", .link: "Link", .image: "Image",
        .icon: "Icon", .searchField: "SearchField", .scrollView: "ScrollView", .scrollBar: "ScrollBar",
        .staticText: "StaticText", .textField: "TextField", .secureTextField: "SecureTextField",
        .datePicker: "DatePicker", .textView: "TextView", .menu: "Menu", .menuItem: "MenuItem", .map: "Map",
        .webView: "WebView", .cell: "Cell", .stepper: "Stepper", .tab: "Tab", .layoutArea: "LayoutArea",
        .layoutItem: "LayoutItem", .handle: "Handle", .valueIndicator: "ValueIndicator",
    ]
}

private extension NSObject {
    /// Calls a method without arguments that returns an object, if this object has it.
    func call(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return nil }
        return perform(selector)?.takeUnretainedValue()
    }
}
