import Foundation

public enum Shell {
    /// One POSIX shell word. Anything beyond plain characters goes in single quotes, inside which the
    /// shell expands nothing, so a value such as a relay URL cannot run commands when the user pastes
    /// a copied snippet into a terminal.
    public static func quoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(plain.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
