import Foundation

/// `Mobdev secret set <name> [--relay]`, `Mobdev secret list` and `Mobdev secret remove <name>`:
/// the secrets `type_secret` types. `set` reads the value from the terminal without showing it, or
/// from standard input when it is piped, so it never lands in the shell's history.
public enum SecretCommand {
    static let usage = """
        Usage: Mobdev secret set <name> [--relay]
               Mobdev secret list
               Mobdev secret remove <name>

        Secrets are passwords and codes of test accounts that agents type with type_secret without
        seeing them. set asks for the value, or reads it from standard input. --relay lets agents
        connected through a relay type it too.
        """

    public static func run(_ arguments: [String]) -> Never {
        exit(execute(arguments, value: readValue, output: { print($0) }))
    }

    static func execute(_ arguments: [String], value: () -> String?, output: (String) -> Void) -> Int32 {
        do {
            switch arguments.first {
            case "set":
                let rest = Array(arguments.dropFirst())
                let names = rest.filter { !$0.hasPrefix("--") }
                guard names.count == 1, rest.allSatisfy({ !$0.hasPrefix("--") || $0 == "--relay" }) else {
                    throw ToolFailure("")
                }
                try TypedSecrets.validate(name: names[0])
                guard let secret = value(), !secret.isEmpty else { throw ToolFailure("No value given.") }
                try TypedSecrets.set(names[0], value: secret, relay: rest.contains("--relay"))
                output("Saved the secret \(names[0]).")
            case "list":
                let secrets = TypedSecrets.list()
                output(
                    secrets.isEmpty
                        ? "No secrets."
                        : secrets.map { "\($0.name)\($0.relay ? "  (also through the relay)" : "")" }.joined(separator: "\n"))
            case "remove":
                guard arguments.count == 2 else { throw ToolFailure("") }
                output(try TypedSecrets.remove(arguments[1]) ? "Removed \(arguments[1])." : "No secret \(arguments[1]).")
            default:
                throw ToolFailure("")
            }
            return 0
        } catch {
            let message = String(describing: error)
            output(message.isEmpty ? usage : message)
            return 2
        }
    }

    /// The value from the terminal without echo, or the first line of piped input.
    private static func readValue() -> String? {
        if isatty(STDIN_FILENO) == 1 {
            var buffer = [CChar](repeating: 0, count: PhoneTools.maxTypedCharacters * 4 + 2)
            guard readpassphrase("Value (not shown): ", &buffer, buffer.count, RPP_ECHO_OFF) != nil else { return nil }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let value = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            return value
        }
        return readLine(strippingNewline: true)
    }
}
