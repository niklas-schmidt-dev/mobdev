import XCTest

/// Mobdev Runner: a UI test that does not end. Like WebDriverAgent, it serves what XCTest can read
/// and do on the device: the elements of the app in front, touches, typing, keys, the hardware
/// buttons and switching apps. On an iPhone in Developer Mode, Mobdev sends all its input this way.
/// Mobdev builds it on the Mac with Xcode, keeps `xcodebuild test-without-building` running, and
/// reaches the port through usbmuxd (on a simulator, on 127.0.0.1). `MOBDEV_RUNNER_PORT` and
/// `MOBDEV_RUNNER_TOKEN` arrive as `TEST_RUNNER_…` variables of xcodebuild. Points are fractions of
/// the screen, from the top-left corner.
///
///     GET  /health               {"ok": true, "version": 3}
///     GET  /tree[?bundle=<id>]   {"screen": {"width", "height"}, "apps": [names], "elements": [...]}
///                                each element: type, label, identifier, value, placeholder,
///                                frame [x, y, width, height] in points, enabled, selected
///     POST /tap      {"x", "y", "hold"?, "count"?}
///                                hold: seconds to press, a long press from 0.2; count 2: a double tap
///     POST /drag     {"from": [x, y], "to": [x, y], "duration", "press"?, "hold"?}
///                                a swipe or drag: press seconds before it moves (default 0.05), move
///                                in duration seconds, hold seconds at the end before lifting
///     POST /fingers  {"fingers": [{"from": [x, y], "to": [x, y]}, ...], "duration"}
///                                one to five fingers that touch down together, move in straight
///                                lines in duration seconds and lift together: two for a pinch
///     POST /type     {"text"}    into the focused element; any characters, emoji included
///     POST /key      {"key", "modifiers"?}
///                                one key: a name (return, escape, backspace, tab, space, up, down,
///                                left, right, home, end, pageup, pagedown, forwarddelete, f1-f12) or
///                                one character; modifiers: cmd, shift, option, ctrl. XCTest on iOS
///                                ignores escape and forwarddelete.
///     POST /button   {"name"}    home, volume_up or volume_down (the last two on iPhones only)
///     POST /activate {"bundle"}  brings an app to the front, launching it when it is not running
final class RunnerTests: XCTestCase {
    static let protocolVersion = 3
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
        // Without its token anything that reaches the port could tap and type; Mobdev always sets one.
        guard let token = environment["MOBDEV_RUNNER_TOKEN"], !token.isEmpty else {
            XCTFail("MOBDEV_RUNNER_TOKEN is missing; start Mobdev Runner from Mobdev.")
            return
        }
        let server = try RunnerServer(port: port, token: token) { [unowned self] in
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
            case ("POST", "/fingers"):
                let body = try request.json()
                guard let fingers = body["fingers"] as? [[String: Any]], (1...5).contains(fingers.count) else {
                    return .error("Pass fingers: one to five, each with from and to.", status: 400)
                }
                let paths = try fingers.map { (from: try Self.point($0["from"]), to: try Self.point($0["to"])) }
                let duration = min(max((body["duration"] as? NSNumber)?.doubleValue ?? 0.5, 0.05), 10)
                try touch(paths, duration: duration)
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
                // On iOS, typeKey presses neither Return nor Backspace, nor Escape and forward delete:
                // nothing happens (an iOS 27 simulator, 2026-10-28). Return and Backspace typed as
                // text work, as in WebDriverAgent; the others, and those with modifiers, are refused
                // rather than reported as pressed.
                let lowered = name.lowercased()
                if ["escape", "esc", "forwarddelete"].contains(lowered) || (!flags.isEmpty && Self.typedKeys[lowered] != nil) {
                    return .error("Mobdev Runner cannot press \(name)\(flags.isEmpty ? "" : " with modifiers") on iOS.", status: 400)
                }
                // Without a focused field typing fails, and the key goes to the app as a key after all.
                if flags.isEmpty, let text = Self.typedKeys[lowered] {
                    frontmost()[0].typeText(text)
                    if issues.isEmpty { return outcome() }
                    issues.removeAll()
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

    /// Fingers that touch down together, move in straight lines and lift together. XCTest's public
    /// API moves one finger, or pinches only around an element's center, so this builds the event
    /// as XCTest's own pinch and WebDriverAgent's actions do, with XCTest's private
    /// XCPointerEventPath and XCSynthesizedEventRecord (Xcode 27). Their points are the screen's in
    /// portrait, whatever orientation the record names, so the app's points (those of `/tree`)
    /// are turned the way WebDriverAgent's FBInvertPointForApplication turns them: an iPad
    /// simulator in landscape tapped elsewhere without (iOS 27, 2026-10-30).
    private func touch(_ fingers: [(from: CGVector, to: CGVector)], duration: Double) throws {
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>?
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>?
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
        let initPath = NSSelectorFromString("initForTouchAtPoint:offset:"), move = NSSelectorFromString("moveToPoint:atOffset:")
        let lift = NSSelectorFromString("liftUpAtOffset:"), add = NSSelectorFromString("addPointerEventPath:")
        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        let synthesize = NSSelectorFromString("synthesizeWithError:")
        guard let pathClass = NSClassFromString("XCPointerEventPath"),
            let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
            [initPath, move, lift].allSatisfy({ class_respondsToSelector(pathClass, $0) }),
            [initRecord, add, synthesize].allSatisfy({ class_respondsToSelector(recordClass, $0) }),
            let initPathIMP = class_getMethodImplementation(pathClass, initPath),
            let moveIMP = class_getMethodImplementation(pathClass, move),
            let liftIMP = class_getMethodImplementation(pathClass, lift),
            let initRecordIMP = class_getMethodImplementation(recordClass, initRecord),
            let addIMP = class_getMethodImplementation(recordClass, add),
            let synthesizeIMP = class_getMethodImplementation(recordClass, synthesize)
        else { throw RunnerError("This Xcode's XCTest cannot touch with several fingers.") }
        // `init…` takes the allocated object and returns its object retained, as in SimulatorKit.
        func allocate(_ type: AnyClass) -> AnyObject? {
            (type as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        }
        let app = frontmost()[0]
        let frame = app.frame
        // A UIInterfaceOrientation; unknown (0) is taken as portrait.
        let orientation =
            app.responds(to: NSSelectorFromString("interfaceOrientation"))
            ? (app.value(forKey: "interfaceOrientation") as? NSNumber)?.intValue ?? 1 : 1
        let short = min(frame.width, frame.height), long = max(frame.width, frame.height)
        func point(_ vector: CGVector) -> CGPoint {
            let x = frame.minX + vector.dx * frame.width, y = frame.minY + vector.dy * frame.height
            switch orientation {
            case 2: return CGPoint(x: frame.width - x, y: frame.height - y)  // portrait upside down
            case 3: return CGPoint(x: short - y, y: x)  // landscape right: the home side on the right
            case 4: return CGPoint(x: y, y: long - x)  // landscape left
            default: return CGPoint(x: x, y: y)
            }
        }
        guard let allocatedRecord = allocate(recordClass),
            let record = unsafeBitCast(initRecordIMP, to: InitRecord.self)(
                allocatedRecord, initRecord, "Mobdev fingers" as NSString, max(orientation, 1))?.takeRetainedValue()
        else { throw RunnerError("Could not build a touch event.") }
        // One move to the end: the device moves the finger there over the time between, about 60
        // times a second, and the call returns when it is done. Moves every 16 ms instead all
        // arrived within a few milliseconds, too fast for a pinch to register (iOS 27).
        for finger in fingers {
            guard let allocated = allocate(pathClass),
                let path = unsafeBitCast(initPathIMP, to: InitPath.self)(allocated, initPath, point(finger.from), 0)?
                    .takeRetainedValue()
            else { throw RunnerError("Could not build a touch event.") }
            unsafeBitCast(moveIMP, to: Move.self)(path, move, point(finger.to), duration)
            unsafeBitCast(liftIMP, to: Lift.self)(path, lift, duration)
            unsafeBitCast(addIMP, to: Add.self)(record, add, path)
        }
        var error: NSError?
        guard unsafeBitCast(synthesizeIMP, to: Synthesize.self)(record, synthesize, &error) else {
            throw RunnerError("The touch failed: \(error?.localizedDescription ?? "XCTest gave no reason").")
        }
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

    /// Keys that `/key` types as text without modifiers.
    private static let typedKeys = ["return": "\n", "enter": "\n", "backspace": "\u{8}", "delete": "\u{8}"]

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
