import Foundation

/// What Mobdev Runner does on a device for the tools: `UIRunner` while it runs, a fake in tests.
/// Points are fractions of the screen.
public protocol RunnerControl: Sendable {
    /// A tap, or a press of `hold` seconds from 0.2 on (a long press).
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws
    func doubleTap(at point: NormalizedPoint) async throws
    /// A swipe from `start` to `end` in `duration` seconds.
    func drag(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws
    /// Types into the focused field; any characters, emoji included.
    func type(_ text: String) async throws
    /// One key by the runner's name for it (`RunnerKeys`) or its character, with modifiers.
    func press(key: String, modifiers: [String]) async throws
    /// home, volume_up or volume_down.
    func press(button: String) async throws
    /// Brings an app to the front, launching it when it is not running.
    func activate(_ bundleID: String) async throws
    func elements() async throws -> [UIElement]
}

extension UIRunner: RunnerControl {}

/// The Mac's Bluetooth keyboard and pointer for one iPhone: `HIDInput`, a fake in tests.
public protocol BluetoothInput: Sendable {
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws
    func scroll(at point: NormalizedPoint, ticks: Int) async throws
    func pan(at point: NormalizedPoint, ticks: Int) async throws
    func type(_ strokes: [KeyStroke]) async throws
    func press(_ stroke: KeyStroke) async throws
    func consumer(_ usage: ConsumerUsage) async throws
}

extension HIDInput: BluetoothInput {}

/// Where an iPhone's input goes: to Mobdev Runner while it runs on the iPhone (Developer Mode),
/// and otherwise to the Mac's Bluetooth keyboard and pointer, which needs pairing and
/// AssistiveTouch. Points are fractions of the screenshot on both routes. Keys arrive as key
/// strokes of the hardware keyboard layout and go to the runner as the keys or characters they
/// stand for.
struct IPhoneInput {
    /// Mobdev Runner while it runs on the iPhone; nil sends everything over Bluetooth.
    var runner: RunnerControl?
    /// The paired Bluetooth input; throws `HIDError.notConnected` until the iPhone is paired.
    var bluetooth: () throws -> BluetoothInput
    /// The layout the key strokes were made with.
    var layout: KeyboardLayout

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        if let runner { return try await runner.tap(at: point, hold: hold) }
        try await bluetooth().tap(at: point, hold: hold)
    }

    /// One gesture through the runner: two of its taps come too far apart for iOS to see a double tap.
    func doubleTap(at point: NormalizedPoint) async throws {
        if let runner { return try await runner.doubleTap(at: point) }
        let input = try bluetooth()
        try await input.tap(at: point, hold: 0.05)
        try await input.tap(at: point, hold: 0.05)
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        if let runner { return try await runner.drag(from: start, to: end, duration: duration) }
        try await bluetooth().swipe(from: start, to: end, duration: duration)
    }

    /// A wheel: a swipe through the runner (see `wheelSwipe`), wheel reports over Bluetooth.
    func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        if let runner {
            let (start, end) = wheelSwipe(at: point, ticks: ticks)
            return try await runner.drag(from: start, to: end, duration: 0.35)
        }
        try await bluetooth().scroll(at: point, ticks: ticks)
    }

    func pan(at point: NormalizedPoint, ticks: Int) async throws {
        if let runner {
            let (start, end) = wheelSwipe(at: point, ticks: ticks, sideways: true)
            return try await runner.drag(from: start, to: end, duration: 0.35)
        }
        try await bluetooth().pan(at: point, ticks: ticks)
    }

    /// Typed as text through the runner when every stroke stands for a character, else key by key.
    func type(_ strokes: [KeyStroke]) async throws {
        guard let runner else { return try await bluetooth().type(strokes) }
        if let text = RunnerKeys.text(for: strokes, layout: layout) { return try await runner.type(text) }
        for stroke in strokes {
            try Task.checkCancellation()
            try await press(stroke)
        }
    }

    func press(_ stroke: KeyStroke) async throws {
        guard let runner else { return try await bluetooth().press(stroke) }
        guard let key = RunnerKeys.key(for: stroke, layout: layout) else {
            throw ToolFailure("Mobdev Runner has no key for HID usage \(stroke.usage) on the \(layout.displayName) layout.")
        }
        try await runner.press(key: key.name, modifiers: key.modifiers)
    }

    /// Home and the volume buttons through the runner. XCTest has no mute or play/pause button, so
    /// those take the Bluetooth keyboard when the iPhone is paired.
    func press(_ button: ConsumerUsage) async throws {
        guard let runner else { return try await bluetooth().consumer(button) }
        if let name = RunnerKeys.buttons[button] { return try await runner.press(button: name) }
        guard let input = try? bluetooth() else {
            throw ToolFailure(
                "Mobdev Runner presses only Home and the volume buttons. This button needs the Bluetooth keyboard: pair the iPhone over Bluetooth (Settings › Bluetooth).")
        }
        try await input.consumer(button)
    }

    /// Types `text` through the runner and says so. False without it: the tools then type key by
    /// key with the keyboard layout.
    func typeText(_ text: String) async throws -> Bool {
        guard let runner else { return false }
        try await runner.type(text)
        return true
    }

    /// Opens an app by name or bundle ID without Spotlight through the runner, finding the bundle
    /// ID in the iPhone's app list. Nil without the runner or the list: Spotlight then.
    func openApp(named name: String, apps: AppBackend?) async throws -> String? {
        guard let runner, let apps else { return nil }
        let app = try await AppMatcher.find(name, in: apps.apps(all: true))
        try AppBlocklist.checkResolved(name: app.name, bundleID: app.bundleID)
        try await runner.activate(app.bundleID)
        return "Opened \(app.name) (\(app.bundleID))."
    }
}

/// Key strokes of a hardware keyboard layout as Mobdev Runner takes them: named keys by the names
/// `press_key` uses, everything else as the character it types on that layout.
enum RunnerKeys {
    /// The runner's names for keys without a character, by HID usage.
    static let names: [UInt8: String] = {
        var names: [UInt8: String] = [
            0x28: "return", 0x29: "escape", 0x2A: "backspace", 0x2B: "tab", 0x2C: "space", 0x4F: "right",
            0x50: "left", 0x51: "down", 0x52: "up", 0x4C: "forwarddelete", 0x4A: "home", 0x4D: "end",
            0x4B: "pageup", 0x4E: "pagedown",
        ]
        for index in 1...12 { names[0x3A + UInt8(index - 1)] = "f\(index)" }
        return names
    }()

    static let buttons: [ConsumerUsage: String] = [.home: "home", .volumeUp: "volume_up", .volumeDown: "volume_down"]

    /// A key and its modifiers for the runner's /key. Shift and option that are part of a character,
    /// such as the option of "@" on the German layout, go with the character; command and control
    /// stay modifiers, so ⌘A arrives as "a" with cmd. Nil for a dead key or an unknown usage.
    static func key(for stroke: KeyStroke, layout: KeyboardLayout) -> (name: String, modifiers: [String])? {
        let commands = stroke.modifiers & (KeyStroke.command | KeyStroke.control)
        if let name = names[stroke.usage] {
            return (name, modifiers(stroke.modifiers))
        }
        let character = KeyStroke(stroke.usage, stroke.modifiers & (KeyStroke.shift | KeyStroke.option))
        guard let text = characters(layout)[[character]] else { return nil }
        return (String(text), modifiers(commands))
    }

    /// The text strokes type on `layout`, or nil when one is a shortcut, a named key other than
    /// Return, Tab and Space, or no character.
    static func text(for strokes: [KeyStroke], layout: KeyboardLayout) -> String? {
        let table = characters(layout)
        var text = ""
        var index = 0
        while index < strokes.count {
            // Accents take two strokes: the dead key, then the letter.
            if index + 1 < strokes.count, let pair = table[Array(strokes[index...index + 1])] {
                text.append(pair)
                index += 2
            } else if let single = table[[strokes[index]]] {
                text.append(single)
                index += 1
            } else {
                return nil
            }
        }
        return text
    }

    /// Each layout's characters by the strokes that type them. Where two characters share strokes,
    /// the smaller one wins, so the table does not depend on dictionary order.
    private static func characters(_ layout: KeyboardLayout) -> [[KeyStroke]: Character] {
        switch layout {
        case .us: usCharacters
        case .german: germanCharacters
        }
    }

    private static let usCharacters = reversed(KeyboardLayout.usTable)
    private static let germanCharacters = reversed(KeyboardLayout.germanTable)

    private static func reversed(_ table: [Character: [KeyStroke]]) -> [[KeyStroke]: Character] {
        var result: [[KeyStroke]: Character] = [:]
        for (character, strokes) in table where result[strokes].map({ character < $0 }) ?? true {
            result[strokes] = character
        }
        return result
    }

    private static func modifiers(_ bits: UInt8) -> [String] {
        [(KeyStroke.command, "cmd"), (KeyStroke.shift, "shift"), (KeyStroke.option, "option"), (KeyStroke.control, "ctrl")]
            .filter { bits & $0.0 != 0 }.map(\.1)
    }
}
