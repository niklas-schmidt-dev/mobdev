import XCTest

/// Mobdev Runner: a UI test that does not end. Like WebDriverAgent, it serves what XCTest can read
/// and do on the device: the elements of the app in front, touches, typing, keys, the hardware
/// buttons and switching apps. On an iPhone in Developer Mode, Mobdev sends all its input this way.
/// Mobdev builds it on the Mac with Xcode, keeps `xcodebuild test-without-building` running, and
/// reaches the port through usbmuxd (on a simulator, on 127.0.0.1). `MOBDEV_RUNNER_PORT` and
/// `MOBDEV_RUNNER_TOKEN` arrive as `TEST_RUNNER_…` variables of xcodebuild. Points are fractions of
/// the screen, from the top-left corner.
///
///     GET  /health               {"ok": true, "version": 2}
///     GET  /tree[?bundle=<id>]   {"screen": {"width", "height"}, "apps": [names], "elements": [...]}
///                                each element: type, label, identifier, value, placeholder,
///                                frame [x, y, width, height] in points, enabled, selected
///     POST /tap      {"x", "y", "hold"?, "count"?}
///                                hold: seconds to press, a long press from 0.2; count 2: a double tap
///     POST /drag     {"from": [x, y], "to": [x, y], "duration", "press"?, "hold"?}
///                                a swipe or drag: press seconds before it moves (default 0.05), move
///                                in duration seconds, hold seconds at the end before lifting
///     POST /type     {"text"}    into the focused element; any characters, emoji included
///     POST /key      {"key", "modifiers"?}
///                                one key: a name (return, escape, backspace, tab, space, up, down,
///                                left, right, home, end, pageup, pagedown, forwarddelete, f1-f12) or
///                                one character; modifiers: cmd, shift, option, ctrl
///     POST /button   {"name"}    home, volume_up or volume_down (the last two on iPhones only)
///     POST /activate {"bundle"}  brings an app to the front, launching it when it is not running
final class RunnerTests: XCTestCase {
    static let protocolVersion = 2
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
                let point = try Self.point(body["x"], body["y"])
                let hold = (body["hold"] as? NSNumber)?.doubleValue ?? 0
                let coordinate = coordinate(at: point)
                if hold >= 0.2 {
                    coordinate.press(forDuration: min(hold, 10))
                } else if (body["count"] as? NSNumber)?.intValue == 2 {
                    coordinate.doubleTap()
                } else {
                    coordinate.tap()
                }
                return outcome()
            case ("POST", "/drag"):
                let body = try request.json()
                let from = try Self.point(body["from"]), to = try Self.point(body["to"])
                let duration = min(max((body["duration"] as? NSNumber)?.doubleValue ?? 0.3, 0.05), 10)
                let press = min(max((body["press"] as? NSNumber)?.doubleValue ?? 0.05, 0), 10)
                let hold = min(max((body["hold"] as? NSNumber)?.doubleValue ?? 0, 0), 10)
                // XCTest moves the finger at a speed, not in a time: the distance in points over the
                // duration.
                let size = frontmost()[0].frame.size
                let distance = hypot((to.dx - from.dx) * size.width, (to.dy - from.dy) * size.height)
                coordinate(at: from).press(
                    forDuration: press, thenDragTo: coordinate(at: to),
                    withVelocity: XCUIGestureVelocity(rawValue: max(distance / duration, 1)), thenHoldForDuration: hold)
                return outcome()
            case ("POST", "/type"):
                guard let text = try request.json()["text"] as? String, !text.isEmpty else {
                    return .error("Pass text.", status: 400)
                }
                frontmost()[0].typeText(text)
                return outcome()
            case ("POST", "/key"):
                let body = try request.json()
                guard let name = body["key"] as? String, !name.isEmpty else { return .error("Pass key.", status: 400) }
                var flags: XCUIElement.KeyModifierFlags = []
                for modifier in body["modifiers"] as? [String] ?? [] {
                    guard let flag = Self.modifiers[modifier.lowercased()] else {
                        return .error("Unknown modifier \(modifier). Use cmd, shift, option or ctrl.", status: 400)
                    }
                    flags.insert(flag)
                }
                let key = Self.keys[name.lowercased()]?.rawValue ?? name
                guard Self.keys[name.lowercased()] != nil || key.count == 1 else {
                    return .error("Unknown key \(name).", status: 400)
                }
                frontmost()[0].typeKey(key, modifierFlags: flags)
                return outcome()
            case ("POST", "/button"):
                guard let name = try request.json()["name"] as? String else { return .error("Pass name.", status: 400) }
                switch name {
                case "home": XCUIDevice.shared.press(.home)
                case "volume_up", "volume_down":
                    #if targetEnvironment(simulator)
                        return .error("A simulator has no volume buttons.", status: 400)
                    #else
                        XCUIDevice.shared.press(name == "volume_up" ? .volumeUp : .volumeDown)
                    #endif
                default: return .error("Unknown button \(name). Use home, volume_up or volume_down.", status: 400)
                }
                return outcome()
            case ("POST", "/activate"):
                guard let bundle = try request.json()["bundle"] as? String, !bundle.isEmpty else {
                    return .error("Pass bundle.", status: 400)
                }
                let app = XCUIApplication(bundleIdentifier: bundle)
                app.activate()
                guard issues.isEmpty else { return outcome() }
                return app.state == .runningForeground
                    ? .json(["ok": true]) : .error("\(bundle) did not come to the front.", status: 500)
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

    // MARK: Input

    /// A point of the app in front, which covers the screen.
    private func coordinate(at point: CGVector) -> XCUICoordinate {
        frontmost()[0].coordinate(withNormalizedOffset: point)
    }

    /// x and y as fractions of the screen, from two numbers or one [x, y] array.
    private static func point(_ x: Any?, _ y: Any? = nil) throws -> CGVector {
        let pair = (x as? [NSNumber]).map { $0.map(\.doubleValue) } ?? [x, y].compactMap { ($0 as? NSNumber)?.doubleValue }
        guard pair.count == 2, (0...1).contains(pair[0]), (0...1).contains(pair[1]) else {
            throw RunnerError("Pass points as fractions of the screen, from 0 to 1.")
        }
        return CGVector(dx: pair[0], dy: pair[1])
    }

    /// The keys `/key` knows by name, as `press_key` names them on the Mac.
    private static let keys: [String: XCUIKeyboardKey] = {
        var keys: [String: XCUIKeyboardKey] = [
            "enter": .return, "return": .return, "escape": .escape, "esc": .escape, "backspace": .delete,
            "delete": .delete, "tab": .tab, "space": .space, "up": .upArrow, "down": .downArrow, "left": .leftArrow,
            "right": .rightArrow, "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
            "forwarddelete": .forwardDelete,
        ]
        let functionKeys: [XCUIKeyboardKey] = [.F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12]
        for (index, key) in functionKeys.enumerated() { keys["f\(index + 1)"] = key }
        return keys
    }()

    private static let modifiers: [String: XCUIElement.KeyModifierFlags] = [
        "cmd": .command, "command": .command, "shift": .shift, "option": .option, "alt": .option, "ctrl": .control,
        "control": .control,
    ]

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
