import CoreGraphics
import Foundation

/// One element of an app's accessibility tree: what it is, what it says, where it is.
public struct UIElement: Sendable, Equatable {
    /// "Button", "TextField", "StaticText" on iOS; the view class ("Button", "TextView") on Android.
    public var role: String
    /// What it shows or what VoiceOver/TalkBack reads: text, label or content description.
    public var label: String
    /// The developer's identifier: accessibilityIdentifier on iOS, resource-id on Android.
    public var identifier: String
    public var value: String
    /// As fractions of the screen, origin top-left.
    public var frame: CGRect
    public var enabled: Bool
    /// Buttons, links, fields and anything else meant to be tapped.
    public var tappable: Bool

    public init(
        role: String, label: String, identifier: String, value: String, frame: CGRect, enabled: Bool, tappable: Bool
    ) {
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.tappable = tappable
    }

    public var center: NormalizedPoint { NormalizedPoint(x: frame.midX, y: frame.midY) }

    /// Identifiers match whole or by their last part, so "save" finds "com.example:id/save".
    func matches(identifier query: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return identifier == query || identifier.split(separator: "/").last.map(String.init) == query
    }
}

/// What tap_element and wait_for_element look for. Every given field must hold: an identifier, a
/// label (whole labels win over partial ones) or a regular expression, a role, a value, a state,
/// and where on the screen or next to which label.
struct ElementQuery: CustomStringConvertible {
    var id: String?
    var text: String?
    var regex: Pattern?
    var role: String?
    var value: String?
    var enabled: Bool?
    var region: ScreenRegion?
    var near: NearQuery?
    /// The screen's width over its height, so `near` measures distances as they look.
    var aspect = 1.0

    init(id: String?, text: String?) {
        self.id = id
        self.text = text
    }

    init(_ args: Arguments) throws {
        id = args.has("id") ? try args.string("id") : nil
        text = args.has("text") ? try args.string("text") : nil
        regex = args.has("regex") ? try Pattern(args.string("regex")) : nil
        role = args.has("role") ? try args.string("role") : nil
        // An empty value finds an empty field.
        if let raw = args.value["value"], !raw.isNull {
            guard let value = raw.stringValue else { throw ToolFailure("value must be a string.") }
            self.value = value
        }
        if args.has("enabled") {
            guard let enabled = args.bool("enabled") else { throw ToolFailure("enabled must be true or false.") }
            self.enabled = enabled
        }
        if args.has("region") {
            let raw = try args.string("region")
            guard let region = ScreenRegion(rawValue: raw) else {
                throw ToolFailure("region must be one of \(ScreenRegion.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            self.region = region
        }
        if let near = args.value["near"], !near.isNull { self.near = try NearQuery(near) }
        guard id != nil || text != nil || regex != nil || role != nil || value != nil else {
            throw ToolFailure("Pass id, text, regex, role or value.")
        }
    }

    var description: String {
        var parts: [String] = []
        if let role { parts.append("role \(role)") }
        if let id { parts.append("id \"\(id)\"") }
        if let text { parts.append("label \"\(text)\"") }
        if let regex { parts.append("label \(regex)") }
        if let value { parts.append("value \"\(value)\"") }
        if let enabled { parts.append(enabled ? "enabled" : "disabled") }
        if let region { parts.append("in the \(region.rawValue.replacingOccurrences(of: "_", with: " "))") }
        if let near { parts.append(near.description) }
        return parts.joined(separator: " ")
    }

    /// Exact labels win over partial ones, and what can be tapped over the text inside it. With
    /// `near`, the nearest match comes first.
    func matches(in elements: [UIElement]) -> [UIElement] {
        var matches = elements
        if let id { matches = matches.filter { $0.matches(identifier: id) } }
        if let regex { matches = matches.filter { regex.matches($0.label) || regex.matches($0.value) } }
        if let role { matches = matches.filter { Self.matches(role: $0.role, query: role) } }
        if let value { matches = matches.filter { Self.folded($0.value) == Self.folded(value) } }
        if let enabled { matches = matches.filter { $0.enabled == enabled } }
        if let region { matches = matches.filter { region.contains($0.center) } }
        // Measured from the first label that matches; without one on screen, nothing is near it.
        var anchor: CGRect?
        if let near {
            guard let found = Self.labelled(near.text, in: elements).first?.frame else { return [] }
            anchor = found
            matches = matches.filter { near.accepts($0.frame, anchor: found) }
        }
        // After the other fields, so a whole label elsewhere does not hide a partial one that fits.
        if let text { matches = Self.labelled(text, in: matches) }
        if let anchor {
            matches.sort { $0.frame.distance(to: anchor, aspect: aspect) < $1.frame.distance(to: anchor, aspect: aspect) }
        }
        let tappable = matches.filter(\.tappable)
        return Self.onePerPlace(tappable.isEmpty ? matches : tappable)
    }

    /// Kinds of elements by the names iOS and Android give them, so one query works on both: the
    /// simulator's tree lists a UISwitch as a CheckBox, and Android calls a text field EditText.
    static let roles: [String: [String]] = [
        "button": ["button"],
        "switch": ["switch", "toggle", "checkbox"],
        "checkbox": ["checkbox"],
        "textfield": ["textfield", "edittext", "searchfield"],
        "text": ["statictext", "textview"],
        "image": ["image"],
        "cell": ["cell"],
        "link": ["link"],
    ]

    /// A kind from `roles`, or else any role that contains the name: "button" finds ImageButton.
    static func matches(role: String, query: String) -> Bool {
        let role = folded(role)
        let query = folded(query)
        return (roles[query] ?? [query]).contains { role.contains($0) }
    }

    /// Elements labeled like `text`, whole labels first.
    static func labelled(_ text: String, in elements: [UIElement]) -> [UIElement] {
        let needle = folded(text)
        let exact = elements.filter { folded($0.label) == needle }
        return exact.isEmpty ? elements.filter { folded($0.label).contains(needle) } : exact
    }

    /// The arguments tap_element and wait_for_element take to find an element.
    static let properties: [String: JSONValue] = [
        "id": ["type": "string", "description": "Identifier, e.g. save_button or com.example:id/save"],
        "text": ["type": "string", "description": "Label, e.g. Save; whole labels win over partial ones"],
        "regex": ["type": "string", "description": "Regular expression for the label or value, e.g. ^\\d+ items$"],
        "role": [
            "type": "string",
            "description": "Kind of element on either platform: button, switch, checkbox, textfield, text, image, cell or link; other names match roles that contain them",
        ],
        "value": ["type": "string", "description": "Current value: what a field holds (\"\" when empty), or on and off for a switch"],
        "enabled": ["type": "boolean", "description": "Only enabled (true) or disabled (false) elements"],
        "region": [
            "type": "string", "enum": .array(ScreenRegion.allCases.map { .string($0.rawValue) }),
            "description": "Only elements whose center is in this part of the screen",
        ],
        "near": [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "A label on screen"],
                "direction": [
                    "type": "string", "enum": .array(NearQuery.Direction.allCases.map { .string($0.rawValue) }),
                    "description": "Which side of the label, default any",
                ],
            ],
            "required": ["text"],
            "description": "The element closest to this label, e.g. {\"text\": \"Email\", \"direction\": \"below\"} for the field under it",
        ],
    ]

    /// iOS often wraps an element in another of the same size, and both match, as the Spotlight
    /// pill on the iPhone's home screen did. Elements at the same place count once, the one with a
    /// label first.
    static func onePerPlace(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        for element in elements {
            let same = unique.firstIndex { other in
                abs(other.frame.minX - element.frame.minX) < 0.002 && abs(other.frame.minY - element.frame.minY) < 0.002
                    && abs(other.frame.width - element.frame.width) < 0.002
                    && abs(other.frame.height - element.frame.height) < 0.002
            }
            if let same {
                if unique[same].label.isEmpty, !element.label.isEmpty { unique[same] = element }
            } else {
                unique.append(element)
            }
        }
        return unique
    }

    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Tools that read and use the element tree: taps by what an element is rather than by pixels.
extension PhoneTools {
    static let treeDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "ui_tree", title: "UI tree",
            description:
                "The elements on screen from the app's accessibility tree: role, label, identifier, value and position in screenshot pixels. Works on simulators and Android, and on iPhones once Mobdev Runner is turned on in the Mobdev app (Developer Mode and Xcode); otherwise use read_screen. More reliable than OCR for buttons without text and for fields.",
            inputSchema: schema(
                [
                    "contains": ["type": "string", "description": "Only elements whose label, identifier or value contains this"],
                    "all": ["type": "boolean", "description": "Include elements without label or identifier, default false"],
                ], screenshot: false),
            readOnly: true),
        ToolDefinition(
            name: "tap_element", title: "Tap element",
            description:
                "Tap an element from ui_tree by its identifier (accessibilityIdentifier or Android resource-id, whole or last part), its label or a regex, and narrow it down by role, value, enabled, region or near another label: {\"role\": \"textfield\", \"near\": {\"text\": \"Email\", \"direction\": \"below\"}} is the field under Email. Every given field must hold; exact label matches win over partial ones. Prefer near to index, which breaks when the layout changes; pass index when several match. Waits up to timeout seconds for the element to appear. double taps twice, hold presses long.",
            inputSchema: schema(
                ElementQuery.properties.merging([
                    "index": ["type": "integer", "minimum": 0],
                    "timeout": ["type": "number", "description": "Seconds to wait for the element, default 5"],
                    "double": ["type": "boolean", "description": "Tap twice quickly, a double tap"],
                    "hold": ["type": "number", "description": "Hold this many seconds, a long press (0.2 to 10)"],
                ]) { $1 }),
            readOnly: false),
        ToolDefinition(
            name: "wait_for_element", title: "Wait for element",
            description:
                "Wait until an element is on screen, or with gone until it is not, found as tap_element finds it: id, text or regex, role, value, enabled, region, near. Like wait_for_text, from the UI tree instead of OCR: simulators, Android and iPhones with Mobdev Runner. {\"role\": \"button\", \"text\": \"Sign In\", \"enabled\": true} waits until the button can be tapped.",
            inputSchema: schema(
                ElementQuery.properties.merging([
                    "timeout": ["type": "number", "description": "Seconds, default 10, at most 60"],
                    "gone": ["type": "boolean", "description": "Wait until no such element is left"],
                ]) { $1 }, screenshot: false),
            readOnly: true),
    ]

    func runTreeTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "ui_tree":
            let elements = try await tree()
            let query = args.has("contains") ? try args.string("contains") : nil
            let all = args.bool("all") ?? false
            let shown = elements.filter { element in
                (all || !element.label.isEmpty || !element.identifier.isEmpty)
                    && (query.map {
                        element.label.localizedCaseInsensitiveContains($0)
                            || element.identifier.localizedCaseInsensitiveContains($0)
                            || element.value.localizedCaseInsensitiveContains($0)
                    } ?? true)
            }
            let size = try screenshotSize()
            guard !shown.isEmpty else {
                return ToolOutput(text: query.map { "No element matches \"\($0)\"." } ?? "No elements.", data: .array([]))
            }
            let lines = shown.enumerated().map { index, element in
                var parts = ["\(index): \(element.role)"]
                if !element.label.isEmpty { parts.append("\"\(element.label)\"") }
                if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
                if !element.value.isEmpty { parts.append("value=\(element.value)") }
                if !element.enabled { parts.append("disabled") }
                parts.append("@ \(coordinates(element.center, size))")
                return parts.joined(separator: " ")
            }
            return ToolOutput(text: lines.joined(separator: "\n"), data: .array(shown.map { json($0, size) }))
        case "tap_element":
            var query = try ElementQuery(args)
            query.aspect = query.near == nil ? 1 : screenAspect()
            let timeout = try args.number("timeout", default: 5, range: 0...60)
            var last: [UIElement] = []
            let matches =
                try await poll(for: timeout) {
                    last = $0
                    return !query.matches(in: $0).isEmpty
                }.map(query.matches) ?? []
            let size = try screenshotSize()
            guard !matches.isEmpty else {
                throw ToolFailure("No element with \(query).\(Self.onScreen(last))")
            }
            let index = args.has("index") ? Int(try args.number("index", default: 0, range: 0...999)) : nil
            // With near, the nearest is meant; matches come nearest first.
            if index == nil, matches.count > 1, query.near == nil {
                let list = matches.enumerated().map { "\($0): \($1.role) \"\($1.label)\" @ \(coordinates($1.center, size))" }
                throw ToolFailure("\(matches.count) elements match. Pass index:\n" + list.joined(separator: "\n"))
            }
            let chosen = index ?? 0
            guard chosen < matches.count else { throw ToolFailure("index \(chosen) is out of range; \(matches.count) matches.") }
            let element = matches[chosen]
            try requireTouch()
            let how = try await tap(element.center, args)
            return ToolOutput(
                text: "\(how) \(element.role)\(element.label.isEmpty ? "" : " \"\(element.label)\"") at \(coordinates(element.center, size)).")
        case "wait_for_element":
            var query = try ElementQuery(args)
            query.aspect = query.near == nil ? 1 : screenAspect()
            let timeout = try args.number("timeout", default: 10, range: 0...60)
            let gone = args.bool("gone") ?? false
            if try await poll(for: timeout, until: { query.matches(in: $0).isEmpty == gone }) != nil {
                return ToolOutput(text: gone ? "No element with \(query) is left." : "Found \(query).")
            }
            throw ToolFailure(
                "Timed out after \(format(timeout)) s: \(gone ? "an element with \(query) is still there" : "no element with \(query) appeared").")
        default:
            return nil
        }
    }

    /// Width over height of the screenshot, which has the screen's proportions; 1 while there is
    /// no picture, since the tree can be read without one.
    func screenAspect() -> Double {
        guard let size = try? screenshotSize(), size.height > 0 else { return 1 }
        return Double(size.width) / Double(size.height)
    }

    /// What is on screen, for an error that says what was not found: labelled elements and those
    /// with an identifier, so the agent can correct its query without another call.
    static func onScreen(_ elements: [UIElement], limit: Int = 15) -> String {
        let named = ElementQuery.onePerPlace(elements.filter { !$0.label.isEmpty || !$0.identifier.isEmpty })
        guard !named.isEmpty else { return " Call ui_tree to see what is there." }
        let lines = named.prefix(limit).map { element in
            var parts = [element.role]
            if !element.label.isEmpty { parts.append("\"\(element.label)\"") }
            if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
            if !element.value.isEmpty { parts.append("value=\(element.value)") }
            if !element.enabled { parts.append("disabled") }
            return parts.joined(separator: " ")
        }
        let more = named.count > limit ? "\n… and \(named.count - limit) more; ui_tree lists them all." : ""
        return " On screen:\n" + lines.joined(separator: "\n") + more
    }

    /// How long past the timeout a tree that cannot be read is waited for. On GitHub's macOS runners
    /// the simulator was still typing several seconds after `type_text` returned, and meanwhile its
    /// app had no size, which failed the next `tap_element` after 5 s (2026-10-01 and -02).
    static let unreadableGrace: TimeInterval = 15

    /// Reads the tree every half second until `accepted` holds, and returns that tree; nil when time
    /// runs out. A tree that cannot be read yet, as while an app launches, counts as not accepted;
    /// it is waited for up to `unreadableGrace` longer, counted from the first unreadable read past
    /// the timeout so a stalled machine cannot use the grace up before the first read (GitHub's
    /// runners paused the test process for 15 s, 2026-10-07), and its error is thrown if it never
    /// could be read. A device without a tree fails at once.
    func poll(for timeout: TimeInterval, until accepted: ([UIElement]) -> Bool) async throws -> [UIElement]? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastChance: Date?
        var unreadable: (any Error)?
        while true {
            do {
                guard let elements = try await phone.uiTree() else { throw noTree }
                unreadable = nil
                if accepted(elements) { return elements }
            } catch let failure as ToolFailure {
                throw failure
            } catch {
                unreadable = error
            }
            let now = Date()
            if now >= deadline {
                guard unreadable != nil else { return nil }
                let chance = lastChance ?? now.addingTimeInterval(unreadableGrace)
                lastChance = chance
                if now >= chance { throw unreadable! }
            }
            try await pause(0.5)
        }
    }

    /// Why there is no tree. An iPhone has one once Mobdev Runner runs on it.
    private var noTree: ToolFailure {
        guard phone.status().input == .bluetooth else {
            return ToolFailure("This device has no UI tree. Use read_screen and tap_text instead.")
        }
        return ToolFailure(
            "This iPhone has no UI tree yet. It needs Mobdev Runner, a small UI test that Mobdev builds with Xcode and runs on the iPhone: turn on Developer Mode on the iPhone (Settings › Privacy & Security), then in the Mobdev app open the iPhone's info and click Turn On under UI Tree. Until then use read_screen and tap_text.")
    }

    func tree() async throws -> [UIElement] {
        guard let elements = try await phone.uiTree() else { throw noTree }
        return elements
    }

    private func json(_ element: UIElement, _ size: (width: Int, height: Int)) -> JSONValue {
        let w = Double(size.width), h = Double(size.height)
        return [
            "role": .string(element.role), "label": .string(element.label), "id": .string(element.identifier),
            "value": .string(element.value), "enabled": .bool(element.enabled), "tappable": .bool(element.tappable),
            "x": .number((element.center.x * w).rounded()), "y": .number((element.center.y * h).rounded()),
            "frame": [
                .number((element.frame.minX * w).rounded()), .number((element.frame.minY * h).rounded()),
                .number((element.frame.width * w).rounded()), .number((element.frame.height * h).rounded()),
            ],
        ]
    }
}

// MARK: - Android

/// Parses `uiautomator dump`: nested <node> elements with text, resource-id, class, content-desc,
/// bounds="[x1,y1][x2,y2]" in pixels and flags.
final class AndroidHierarchyParser: NSObject, XMLParserDelegate {
    private(set) var elements: [UIElement] = []
    private let width: Double
    private let height: Double

    init(width: Int, height: Int) {
        self.width = Double(max(width, 1))
        self.height = Double(max(height, 1))
    }

    static func parse(_ xml: Data, width: Int, height: Int) -> [UIElement]? {
        let delegate = AndroidHierarchyParser(width: width, height: height)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        return parser.parse() ? delegate.elements : nil
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        guard name == "node" else { return }
        let numbers = (attributes["bounds"] ?? "").split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] else { return }
        let frame = CGRect(
            x: numbers[0] / width, y: numbers[1] / height, width: (numbers[2] - numbers[0]) / width,
            height: (numbers[3] - numbers[1]) / height)
        let text = attributes["text"] ?? ""
        let description = attributes["content-desc"] ?? ""
        var value = ""
        if attributes["checkable"] == "true" { value = attributes["checked"] == "true" ? "on" : "off" }
        if attributes["selected"] == "true" { value = value.isEmpty ? "selected" : value }
        let role = (attributes["class"] ?? "View").split(separator: ".").last.map(String.init) ?? "View"
        // A field holds its text, as on iOS; an empty one shows its hint there instead.
        if role.contains("EditText"), text != attributes["hint"] { value = text }
        elements.append(
            UIElement(
                role: role, label: text.isEmpty ? description : text, identifier: attributes["resource-id"] ?? "",
                value: value, frame: frame, enabled: attributes["enabled"] != "false",
                tappable: attributes["clickable"] == "true" || attributes["long-clickable"] == "true"
                    || role.contains("EditText")))
    }
}
