import Foundation

/// A node of the YAML that Maestro flows use, with the line it starts on for errors.
///
/// The parser reads that subset only: block mappings and sequences, flow `{a: b}` and `[a, b]`,
/// plain, single- and double-quoted scalars, comments, `---` between documents and `|` and `>`
/// block scalars. Anchors, aliases, tags and multi-line plain scalars are refused with the line.
/// Scalars stay text, so `NO` is not false and `1.10` is not 1.1; whoever reads a node decides.
struct YAMLNode: Equatable {
    enum Value: Equatable {
        case scalar(String, quoted: Bool)
        case sequence([YAMLNode])
        case mapping([Entry])
        case null
    }

    struct Entry: Equatable {
        var key: String
        var value: YAMLNode
        var line: Int
    }

    var value: Value
    var line: Int

    var string: String? {
        if case .scalar(let text, _) = value { return text }
        return nil
    }

    var isNull: Bool {
        switch value {
        case .null: true
        case .scalar(let text, quoted: false): ["~", "null", "Null", "NULL"].contains(text)
        default: false
        }
    }

    var items: [YAMLNode]? {
        if case .sequence(let items) = value { return items }
        return nil
    }

    var entries: [Entry]? {
        if case .mapping(let entries) = value { return entries }
        return nil
    }

    subscript(key: String) -> YAMLNode? { entries?.first { $0.key == key }?.value }

    /// true and false as YAML writes them.
    var bool: Bool? {
        guard case .scalar(let text, false) = value else { return nil }
        switch text {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: return nil
        }
    }

    var number: Double? {
        guard let text = string, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite
        else { return nil }
        return number
    }
}

struct YAMLError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

enum YAML {
    /// The documents of a file, split at `---`; an empty document is nil.
    static func documents(_ text: String) throws -> [YAMLNode?] {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var separators: [Int] = []
        for (index, line) in raw.enumerated() where line.hasPrefix("---") || line.hasPrefix("...") {
            let marker = stripComment(line)
            guard marker == "---" || marker == "..." else {
                if line.hasPrefix("--- ") { throw YAMLError(line: index + 1, message: "put the document on the line after ---.") }
                continue
            }
            separators.append(index)
        }
        var ranges: [Range<Int>] = []
        var start = 0
        for separator in separators {
            ranges.append(start..<separator)
            start = separator + 1
        }
        ranges.append(start..<raw.count)
        var documents = try ranges.map { range -> YAMLNode? in
            var parser = try Parser(raw: raw, range: range)
            return try parser.document()
        }
        // A file that starts with --- has no document before it.
        if !separators.isEmpty, documents.count > 1, documents[0] == nil { documents.removeFirst() }
        return documents
    }

    /// The line without a comment: `#` at the start or after a space, outside quotes. A quote opens
    /// only where a scalar can start, so the apostrophe in `it's` is text.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if open == "\"", character == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    previous = "x"
                    continue
                }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'", " :-[{,".contains(previous) {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(line[..<index]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            previous = character
            index = line.index(after: index)
        }
        return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    // MARK: Parsing

    private struct Line {
        var number: Int
        var indent: Int
        /// Without the indent and a comment.
        var text: String
        /// Indented with a tab, which is an error unless the line is inside a block scalar.
        var tabbed = false
    }

    private struct Parser {
        let raw: [String]
        var lines: [Line] = []
        var index = 0

        init(raw: [String], range: Range<Int>) throws {
            self.raw = raw
            for number in range {
                let line = raw[number]
                let stripped = YAML.stripComment(line)
                guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let indent = stripped.prefix(while: { $0 == " " }).count
                lines.append(
                    Line(
                        number: number + 1, indent: indent, text: String(stripped.dropFirst(indent)),
                        tabbed: stripped.dropFirst(indent).first == "\t"))
            }
        }

        mutating func document() throws -> YAMLNode? {
            guard index < lines.count else { return nil }
            let node = try block(indent: 0)
            if index < lines.count {
                throw YAMLError(line: lines[index].number, message: "this line is indented where nothing can continue.")
            }
            return node
        }

        var current: Line? { index < lines.count ? lines[index] : nil }

        static func isDash(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

        /// The node whose lines start at `indent` or deeper, nil when there is none.
        mutating func block(indent minimum: Int) throws -> YAMLNode? {
            guard let line = current, line.indent >= minimum else { return nil }
            if line.tabbed { throw YAMLError(line: line.number, message: "indent with spaces, not tabs.") }
            if Self.isDash(line.text) { return try sequence(at: line.indent) }
            if YAML.splitKey(line.text) != nil, !line.text.hasPrefix("{"), !line.text.hasPrefix("[") {
                return try mapping(at: line.indent)
            }
            index += 1
            return try inline(line.text, line: line.number, indent: line.indent)
        }

        mutating func sequence(at indent: Int) throws -> YAMLNode {
            let first = current!.number
            var items: [YAMLNode] = []
            while let line = current, line.indent == indent, Self.isDash(line.text) {
                let rest = line.text.dropFirst()
                let spaces = rest.prefix(while: { $0 == " " }).count
                let content = String(rest.dropFirst(spaces))
                if content.isEmpty {
                    index += 1
                    items.append(try block(indent: indent + 1) ?? YAMLNode(value: .null, line: line.number))
                } else {
                    // "- key: value" starts a node at the column of key, where its next lines go.
                    lines[index] = Line(number: line.number, indent: indent + 1 + spaces, text: content)
                    items.append(try block(indent: indent + 1 + spaces)!)
                }
            }
            return YAMLNode(value: .sequence(items), line: first)
        }

        mutating func mapping(at indent: Int) throws -> YAMLNode {
            let first = current!.number
            var entries: [YAMLNode.Entry] = []
            while let line = current, line.indent == indent, !Self.isDash(line.text) {
                if line.tabbed { throw YAMLError(line: line.number, message: "indent with spaces, not tabs.") }
                guard let (key, rest) = YAML.splitKey(line.text) else {
                    throw YAMLError(line: line.number, message: "expected key: value.")
                }
                if entries.contains(where: { $0.key == key }) {
                    throw YAMLError(line: line.number, message: "\(key) appears twice.")
                }
                index += 1
                let value: YAMLNode
                if rest.isEmpty {
                    if let next = current, next.indent > indent {
                        value = try block(indent: indent + 1)!
                    } else if let next = current, next.indent == indent, Self.isDash(next.text) {
                        // A list may start at the key's own indent.
                        value = try sequence(at: indent)
                    } else {
                        value = YAMLNode(value: .null, line: line.number)
                    }
                } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    value = try blockScalar(rest, line: line, parentIndent: indent)
                } else {
                    value = try inline(rest, line: line.number, indent: indent)
                }
                entries.append(YAMLNode.Entry(key: key, value: value, line: line.number))
            }
            return YAMLNode(value: .mapping(entries), line: first)
        }

        /// A value on one line, or a flow collection that may go on over the next lines.
        mutating func inline(_ text: String, line: Int, indent: Int) throws -> YAMLNode {
            guard let first = text.first else { return YAMLNode(value: .null, line: line) }
            if "&*!".contains(first) {
                throw YAMLError(line: line, message: "anchors, aliases and tags (\(first)) are not supported.")
            }
            if first == "{" || first == "[" {
                var source = text
                while !YAML.balanced(source) {
                    guard let next = current, next.indent > indent || "]}".contains(next.text.first ?? " ") else {
                        throw YAMLError(line: line, message: "\(first) is not closed.")
                    }
                    source += " " + next.text
                    index += 1
                }
                var flow = FlowParser(text: Array(source), line: line)
                let node = try flow.value()
                flow.skipSpaces()
                guard flow.position == flow.text.count else {
                    throw YAMLError(line: line, message: "unexpected text after the closing bracket.")
                }
                return node
            }
            if first == "\"" || first == "'" {
                var flow = FlowParser(text: Array(text), line: line)
                let node = try flow.quoted()
                flow.skipSpaces()
                guard flow.position == flow.text.count else {
                    throw YAMLError(line: line, message: "unexpected text after the closing quote.")
                }
                return node
            }
            if let next = current, next.indent > indent, !Self.isDash(next.text), YAML.splitKey(next.text) == nil {
                throw YAMLError(line: next.number, message: "a value that goes on over several lines needs quotes or |.")
            }
            return YAMLNode(value: .scalar(text, quoted: false), line: line)
        }

        /// `|` keeps line breaks, `>` folds lines into one; `-` drops the final line break, `+`
        /// keeps every trailing one.
        mutating func blockScalar(_ header: String, line: Line, parentIndent: Int) throws -> YAMLNode {
            let folded = header.hasPrefix(">")
            let chomp = header.dropFirst().first
            var body: [String] = []
            var number = line.number  // 1-based number of the header; raw[number] is the next line.
            var contentIndent: Int?
            while number < raw.count {
                let text = raw[number]
                let indent = text.prefix(while: { $0 == " " }).count
                let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank {
                    guard indent > parentIndent else { break }
                    contentIndent = contentIndent ?? indent
                    guard indent >= contentIndent! else { break }
                }
                body.append(blank ? "" : String(text.dropFirst(contentIndent!)))
                number += 1
            }
            // The structural lines the scalar covered are skipped.
            while let next = current, next.number <= number { index += 1 }
            while body.last == "" && chomp != "+" { body.removeLast() }
            var text: String
            if folded {
                text = ""
                for (offset, part) in body.enumerated() {
                    if part.isEmpty {
                        text += "\n"
                    } else {
                        text += (offset > 0 && !body[offset - 1].isEmpty ? " " : "") + part
                    }
                }
            } else {
                text = body.joined(separator: "\n")
            }
            if chomp != "-", !body.isEmpty { text += "\n" }
            return YAMLNode(value: .scalar(text, quoted: true), line: line.number)
        }
    }

    /// Whether every bracket outside quotes is closed.
    static func balanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false } else if open == "\"" && character == "\\" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return depth <= 0 && quote == nil
    }

    /// "key: value" split at the first colon followed by a space or the end, outside quotes; the
    /// key without its quotes.
    static func splitKey(_ text: String) -> (String, String)? {
        var characters = Array(text)
        var keyEnd: Int?
        if let first = characters.first, first == "\"" || first == "'" {
            var flow = FlowParser(text: characters, line: 0)
            guard case .scalar(let key, _)? = (try? flow.quoted())?.value, flow.position < characters.count,
                characters[flow.position] == ":"
            else { return nil }
            let rest = String(characters[(flow.position + 1)...])
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (key, rest.trimmingCharacters(in: .whitespaces))
        }
        for index in characters.indices where characters[index] == ":" {
            if index + 1 == characters.count || characters[index + 1] == " " {
                keyEnd = index
                break
            }
        }
        guard let keyEnd, keyEnd > 0 else { return nil }
        let key = String(characters[..<keyEnd]).trimmingCharacters(in: .whitespaces)
        characters.removeFirst(keyEnd + 1)
        return (key, String(characters).trimmingCharacters(in: .whitespaces))
    }

    /// Flow collections and quoted scalars, character by character.
    private struct FlowParser {
        let text: [Character]
        let line: Int
        var position = 0

        init(text: [Character], line: Int) {
            self.text = text
            self.line = line
        }

        mutating func skipSpaces() {
            while position < text.count, text[position] == " " { position += 1 }
        }

        func error(_ message: String) -> YAMLError { YAMLError(line: line, message: message) }

        mutating func value() throws -> YAMLNode {
            skipSpaces()
            guard position < text.count else { return YAMLNode(value: .null, line: line) }
            switch text[position] {
            case "{":
                position += 1
                var entries: [YAMLNode.Entry] = []
                while true {
                    skipSpaces()
                    guard position < text.count else { throw error("{ is not closed.") }
                    if text[position] == "}" {
                        position += 1
                        break
                    }
                    let key = try scalar(stops: ":,}", keyMode: true)
                    skipSpaces()
                    var value = YAMLNode(value: .null, line: line)
                    if position < text.count, text[position] == ":" {
                        position += 1
                        value = try self.value()
                    }
                    guard let name = key.string else { throw error("a key must be text.") }
                    entries.append(YAMLNode.Entry(key: name, value: value, line: line))
                    skipSpaces()
                    if position < text.count, text[position] == "," { position += 1 }
                }
                return YAMLNode(value: .mapping(entries), line: line)
            case "[":
                position += 1
                var items: [YAMLNode] = []
                while true {
                    skipSpaces()
                    guard position < text.count else { throw error("[ is not closed.") }
                    if text[position] == "]" {
                        position += 1
                        break
                    }
                    items.append(try value())
                    skipSpaces()
                    if position < text.count, text[position] == "," { position += 1 }
                }
                return YAMLNode(value: .sequence(items), line: line)
            default:
                return try scalar(stops: ",]}", keyMode: false)
            }
        }

        mutating func scalar(stops: String, keyMode: Bool) throws -> YAMLNode {
            skipSpaces()
            if position < text.count, text[position] == "\"" || text[position] == "'" { return try quoted() }
            if position < text.count, text[position] == "{" || text[position] == "[" { return try value() }
            var result = ""
            while position < text.count {
                let character = text[position]
                if stops.contains(character) {
                    // In a key, ":" ends it only before a space or a bracket; "http://x" is a value.
                    if character != ":" || !keyMode || position + 1 == text.count || " ,}".contains(text[position + 1]) {
                        break
                    }
                }
                result.append(character)
                position += 1
            }
            return YAMLNode(value: .scalar(result.trimmingCharacters(in: .whitespaces), quoted: false), line: line)
        }

        mutating func quoted() throws -> YAMLNode {
            let quote = text[position]
            position += 1
            var result = ""
            while position < text.count {
                let character = text[position]
                position += 1
                if quote == "'" {
                    if character == "'" {
                        if position < text.count, text[position] == "'" {
                            result.append("'")
                            position += 1
                            continue
                        }
                        return YAMLNode(value: .scalar(result, quoted: true), line: line)
                    }
                    result.append(character)
                    continue
                }
                if character == "\"" { return YAMLNode(value: .scalar(result, quoted: true), line: line) }
                guard character == "\\" else {
                    result.append(character)
                    continue
                }
                guard position < text.count else { break }
                let escape = text[position]
                position += 1
                switch escape {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\"", "\\", "/", " ": result.append(escape)
                case "u", "U", "x":
                    let length = escape == "u" ? 4 : escape == "U" ? 8 : 2
                    guard position + length <= text.count,
                        let code = UInt32(String(text[position..<(position + length)]), radix: 16),
                        let scalar = Unicode.Scalar(code)
                    else { throw error("\\\(escape) needs \(length) hex digits.") }
                    result.append(Character(scalar))
                    position += length
                default: throw error("unknown escape \\\(escape) in a double-quoted string.")
                }
            }
            throw error("the string's closing \(quote) is missing; a quoted string ends on its line.")
        }
    }

    // MARK: Writing

    /// What `emit` writes: Maestro commands and their settings.
    enum Out: Sendable {
        case string(String)
        /// Written without quotes, like a command without settings: `- back`.
        case plain(String)
        case number(Double)
        case bool(Bool)
        case list([Out])
        case map([(String, Out)])

        var isScalar: Bool {
            switch self {
            case .list, .map: false
            default: true
            }
        }
    }

    /// Block-style YAML, strings always double-quoted so nothing is read as a number or a bool.
    static func emit(_ value: Out, indent: Int = 0) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .list(let items):
            return items.flatMap { item -> [String] in
                if item.isScalar { return ["\(pad)- \(scalar(item))"] }
                if case .list(let inner) = item, inner.isEmpty { return ["\(pad)- []"] }
                if case .map(let entries) = item, entries.isEmpty { return ["\(pad)- {}"] }
                var lines = emit(item, indent: indent + 2)
                lines[0] = pad + "- " + lines[0].dropFirst(indent + 2)
                return lines
            }
        case .map(let entries):
            return entries.flatMap { key, value -> [String] in
                let name = isPlainKey(key) ? key : scalar(.string(key))
                if value.isScalar { return ["\(pad)\(name): \(scalar(value))"] }
                if case .list(let items) = value, items.isEmpty { return ["\(pad)\(name): []"] }
                if case .map(let inner) = value, inner.isEmpty { return ["\(pad)\(name): {}"] }
                return ["\(pad)\(name):"] + emit(value, indent: indent + 2)
            }
        default:
            return [pad + scalar(value)]
        }
    }

    static func isPlainKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    static func scalar(_ value: Out) -> String {
        switch value {
        case .string(let text):
            var escaped = ""
            for character in text {
                switch character {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default: escaped.append(character)
                }
            }
            return "\"\(escaped)\""
        case .plain(let text): return text
        case .number(let number):
            if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .list, .map: return ""
        }
    }
}
