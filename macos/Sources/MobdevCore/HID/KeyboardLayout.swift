import Foundation

public struct KeyStroke: Equatable, Sendable {
    public var usage: UInt8
    public var modifiers: UInt8

    public init(_ usage: UInt8, _ modifiers: UInt8 = 0) {
        self.usage = usage
        self.modifiers = modifiers
    }

    public static let control: UInt8 = 0x01
    public static let shift: UInt8 = 0x02
    public static let option: UInt8 = 0x04
    public static let command: UInt8 = 0x08
}

public enum KeyboardError: Error, CustomStringConvertible, Equatable {
    case untypeable(Character, KeyboardLayout)
    case unknownKey(String)
    case unknownModifier(String)

    public var description: String {
        switch self {
        case .untypeable(let character, let layout):
            "Cannot type \(String(reflecting: character)) with the \(layout.displayName) hardware keyboard layout."
        case .unknownKey(let key): "Unknown key \"\(key)\"."
        case .unknownModifier(let modifier): "Unknown modifier \"\(modifier)\". Use cmd, shift, option or ctrl."
        }
    }
}

/// The hardware keyboard layout selected on the iPhone (Settings > General > Keyboard >
/// Hardware Keyboard). The iPhone turns key positions into characters with this layout, so
/// Mobdev has to pick positions with the same one. Both follow the macOS layouts of the same name.
public enum KeyboardLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case us
    case german

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .us: "U.S."
        case .german: "German"
        }
    }

    /// A reasonable default: iOS picks the hardware layout from the device language.
    public static var suggested: KeyboardLayout {
        Locale.current.language.languageCode?.identifier == "de" ? .german : .us
    }

    public func strokes(for character: Character) -> [KeyStroke]? {
        table[character]
    }

    public func strokes(typing text: String) throws -> [KeyStroke] {
        var result: [KeyStroke] = []
        for character in text {
            let normalized = character == "\r\n" || character == "\r" ? "\n" : character
            guard let strokes = strokes(for: normalized) else {
                throw KeyboardError.untypeable(character, self)
            }
            result += strokes
        }
        return result
    }

    /// A named key or single character with modifiers, for shortcuts such as cmd+space.
    public func stroke(forKey name: String, modifiers: [String]) throws -> KeyStroke {
        var mask: UInt8 = 0
        for modifier in modifiers {
            guard let bit = Self.modifierBits[modifier.lowercased()] else {
                throw KeyboardError.unknownModifier(modifier)
            }
            mask |= bit
        }
        if let usage = Self.namedKeys[name.lowercased()] {
            return KeyStroke(usage, mask)
        }
        if name.count == 1, let first = strokes(for: Character(name.lowercased()))?.first {
            return KeyStroke(first.usage, first.modifiers | mask)
        }
        throw KeyboardError.unknownKey(name)
    }

    public static let namedKeys: [String: UInt8] = {
        var keys: [String: UInt8] = [
            "enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29,
            "backspace": 0x2A, "delete": 0x2A, "tab": 0x2B, "space": 0x2C,
            "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
            "forwarddelete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
        ]
        for index in 1...12 { keys["f\(index)"] = 0x3A + UInt8(index - 1) }
        return keys
    }()

    public static let modifierBits: [String: UInt8] = [
        "ctrl": KeyStroke.control, "control": KeyStroke.control,
        "shift": KeyStroke.shift,
        "alt": KeyStroke.option, "option": KeyStroke.option, "opt": KeyStroke.option,
        "cmd": KeyStroke.command, "command": KeyStroke.command, "meta": KeyStroke.command,
    ]

    private var table: [Character: [KeyStroke]] {
        switch self {
        case .us: Self.usTable
        case .german: Self.germanTable
        }
    }

    // MARK: Tables

    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")

    private static func letterUsage(_ character: Character) -> UInt8? {
        letters.firstIndex(of: character).map { 0x04 + UInt8($0) }
    }

    private static func addDeadKey(
        _ table: inout [Character: [KeyStroke]], dead: KeyStroke, compose: [(Character, Character)],
        letterUsage: (Character) -> UInt8?
    ) {
        for (base, composed) in compose {
            guard let usage = letterUsage(base) else { continue }
            table[composed] = [dead, KeyStroke(usage)]
            if let upper = composed.uppercased().first, upper != composed {
                table[upper] = [dead, KeyStroke(usage, KeyStroke.shift)]
            }
        }
    }

    private static let common: [Character: [KeyStroke]] = [
        "\n": [KeyStroke(0x28)], "\t": [KeyStroke(0x2B)], " ": [KeyStroke(0x2C)],
    ]

    static let usTable: [Character: [KeyStroke]] = {
        var table = common
        for (index, letter) in letters.enumerated() {
            table[letter] = [KeyStroke(0x04 + UInt8(index))]
            table[Character(letter.uppercased())] = [KeyStroke(0x04 + UInt8(index), KeyStroke.shift)]
        }
        for (index, (digit, shifted)) in zip("1234567890", "!@#$%^&*()").enumerated() {
            table[digit] = [KeyStroke(0x1E + UInt8(index))]
            table[shifted] = [KeyStroke(0x1E + UInt8(index), KeyStroke.shift)]
        }
        let punctuation: [(Character, Character, UInt8)] = [
            ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30), ("\\", "|", 0x31),
            (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35), (",", "<", 0x36), (".", ">", 0x37),
            ("/", "?", 0x38),
        ]
        for (plain, shifted, usage) in punctuation {
            table[plain] = [KeyStroke(usage)]
            table[shifted] = [KeyStroke(usage, KeyStroke.shift)]
        }
        let option = KeyStroke.option
        table["ß"] = [KeyStroke(0x16, option)]
        table["ç"] = [KeyStroke(0x06, option)]
        table["Ç"] = [KeyStroke(0x06, option | KeyStroke.shift)]
        table["€"] = [KeyStroke(0x1F, option | KeyStroke.shift)]
        table["£"] = [KeyStroke(0x20, option)]
        table["–"] = [KeyStroke(0x2D, option)]
        table["—"] = [KeyStroke(0x2D, option | KeyStroke.shift)]
        table["…"] = [KeyStroke(0x33, option)]
        addDeadKey(&table, dead: KeyStroke(0x08, option),
            compose: [("a", "á"), ("e", "é"), ("i", "í"), ("o", "ó"), ("u", "ú")], letterUsage: letterUsage)
        addDeadKey(&table, dead: KeyStroke(0x35, option),
            compose: [("a", "à"), ("e", "è"), ("i", "ì"), ("o", "ò"), ("u", "ù")], letterUsage: letterUsage)
        addDeadKey(&table, dead: KeyStroke(0x18, option),
            compose: [("a", "ä"), ("e", "ë"), ("i", "ï"), ("o", "ö"), ("u", "ü"), ("y", "ÿ")],
            letterUsage: letterUsage)
        addDeadKey(&table, dead: KeyStroke(0x0C, option),
            compose: [("a", "â"), ("e", "ê"), ("i", "î"), ("o", "ô"), ("u", "û")], letterUsage: letterUsage)
        addDeadKey(&table, dead: KeyStroke(0x11, option),
            compose: [("a", "ã"), ("n", "ñ"), ("o", "õ")], letterUsage: letterUsage)
        return table
    }()

    static let germanTable: [Character: [KeyStroke]] = {
        // QWERTZ: the keys US calls Y and Z are swapped.
        func usage(_ letter: Character) -> UInt8? {
            switch letter {
            case "y": 0x1D
            case "z": 0x1C
            default: letterUsage(letter)
            }
        }
        var table = common
        for letter in letters {
            guard let code = usage(letter) else { continue }
            table[letter] = [KeyStroke(code)]
            table[Character(letter.uppercased())] = [KeyStroke(code, KeyStroke.shift)]
        }
        for (index, (digit, shifted)) in zip("1234567890", "!\"§$%&/()=").enumerated() {
            table[digit] = [KeyStroke(0x1E + UInt8(index))]
            table[shifted] = [KeyStroke(0x1E + UInt8(index), KeyStroke.shift)]
        }
        let punctuation: [(Character, Character, UInt8)] = [
            ("ß", "?", 0x2D), ("ü", "Ü", 0x2F), ("+", "*", 0x30), ("#", "'", 0x31), ("ö", "Ö", 0x33),
            ("ä", "Ä", 0x34), (",", ";", 0x36), (".", ":", 0x37), ("-", "_", 0x38), ("<", ">", 0x64),
        ]
        for (plain, shifted, code) in punctuation {
            table[plain] = [KeyStroke(code)]
            table[shifted] = [KeyStroke(code, KeyStroke.shift)]
        }
        let option = KeyStroke.option
        table["@"] = [KeyStroke(0x0F, option)]
        table["€"] = [KeyStroke(0x08, option)]
        table["["] = [KeyStroke(0x22, option)]
        table["]"] = [KeyStroke(0x23, option)]
        table["|"] = [KeyStroke(0x24, option)]
        table["{"] = [KeyStroke(0x25, option)]
        table["}"] = [KeyStroke(0x26, option)]
        table["\\"] = [KeyStroke(0x24, option | KeyStroke.shift)]
        table["~"] = [KeyStroke(0x11, option), KeyStroke(0x2C)]
        table["´"] = [KeyStroke(0x2E), KeyStroke(0x2C)]
        table["`"] = [KeyStroke(0x2E, KeyStroke.shift), KeyStroke(0x2C)]
        addDeadKey(&table, dead: KeyStroke(0x2E),
            compose: [("a", "á"), ("e", "é"), ("i", "í"), ("o", "ó"), ("u", "ú")], letterUsage: usage)
        addDeadKey(&table, dead: KeyStroke(0x2E, KeyStroke.shift),
            compose: [("a", "à"), ("e", "è"), ("i", "ì"), ("o", "ò"), ("u", "ù")], letterUsage: usage)
        addDeadKey(&table, dead: KeyStroke(0x11, option),
            compose: [("a", "ã"), ("n", "ñ"), ("o", "õ")], letterUsage: usage)
        return table
    }()
}

/// Maps macOS virtual key codes (by physical position) to HID usages, so keys pressed while
/// the phone mirror has focus land on the same key of the iPhone's keyboard layout.
public enum MacKeyCodes {
    public static func hidUsage(forKeyCode keyCode: UInt16, isISO: Bool) -> UInt8? {
        // Apple ISO keyboards swap the key left of 1 and the key left of Z.
        if keyCode == 0x0A { return isISO ? 0x35 : 0x64 }
        if keyCode == 0x32 { return isISO ? 0x64 : 0x35 }
        return table[keyCode]
    }

    private static let table: [UInt16: UInt8] = [
        0x00: 0x04, 0x01: 0x16, 0x02: 0x07, 0x03: 0x09, 0x04: 0x0B, 0x05: 0x0A, 0x06: 0x1D, 0x07: 0x1B,
        0x08: 0x06, 0x09: 0x19, 0x0B: 0x05, 0x0C: 0x14, 0x0D: 0x1A, 0x0E: 0x08, 0x0F: 0x15,
        0x10: 0x1C, 0x11: 0x17, 0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x16: 0x23, 0x17: 0x22,
        0x18: 0x2E, 0x19: 0x26, 0x1A: 0x24, 0x1B: 0x2D, 0x1C: 0x25, 0x1D: 0x27, 0x1E: 0x30, 0x1F: 0x12,
        0x20: 0x18, 0x21: 0x2F, 0x22: 0x0C, 0x23: 0x13, 0x24: 0x28, 0x25: 0x0F, 0x26: 0x0D, 0x27: 0x34,
        0x28: 0x0E, 0x29: 0x33, 0x2A: 0x31, 0x2B: 0x36, 0x2C: 0x38, 0x2D: 0x11, 0x2E: 0x10, 0x2F: 0x37,
        0x30: 0x2B, 0x31: 0x2C, 0x33: 0x2A, 0x35: 0x29, 0x4C: 0x28,
        0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        0x7B: 0x50, 0x7C: 0x4F, 0x7D: 0x51, 0x7E: 0x52,
    ]
}
