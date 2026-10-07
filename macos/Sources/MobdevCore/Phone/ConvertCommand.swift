import Foundation

/// `Mobdev convert <file> [--to maestro|mobdev]`: prints a flow in the other format, a Mobdev flow
/// (.json) as Maestro YAML and a Maestro flow (.yaml) as a Mobdev flow. Needs no device.
///
/// Notes on what changed on the way go to standard error, so the output can be redirected into a
/// file. Exits 0 when the flow converted and 2 when it did not, saying which steps or lines have
/// no counterpart.
public enum ConvertCommand {
    static let usage = """
        Usage: Mobdev convert <file> [--to maestro|mobdev]

        Prints a flow in the other format: a Mobdev flow (.json) as Maestro YAML, a Maestro flow
        (.yaml) as a Mobdev flow. Its subflows stay files of their own; convert each.
          --to  the format to print, by default the other one
        """

    struct Options: Equatable {
        var file: String
        var to: String?
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var file: String?
        var to: String?
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--to":
                guard let value = rest.popFirst(), ["maestro", "mobdev"].contains(value) else {
                    throw ToolFailure("--to needs maestro or mobdev.")
                }
                to = value
            case "-h", "--help": throw ToolFailure("")
            default:
                guard !argument.hasPrefix("-"), file == nil else { throw ToolFailure("Unexpected \(argument).") }
                file = argument
            }
        }
        guard let file else { throw ToolFailure("Which flow? Pass a .json or Maestro .yaml file.") }
        return Options(file: file, to: to)
    }

    public static func run(_ arguments: [String]) -> Never {
        let error: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        exit(execute(arguments, output: { FileHandle.standardOutput.write(Data($0.utf8)) }, error: error))
    }

    /// The converted flow goes to `output` as it is, notes and problems to `error` line by line.
    static func execute(_ arguments: [String], output: (String) -> Void, error: (String) -> Void) -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch let failure {
            let message = String(describing: failure)
            error(message.isEmpty ? usage : "\(message)\n\n\(usage)")
            return 2
        }
        let url = URL(fileURLWithPath: (options.file as NSString).expandingTildeInPath)
        let fromMaestro = Maestro.isMaestroFile(url)
        let to = options.to ?? (fromMaestro ? "mobdev" : "maestro")
        do {
            // Read only: subflows stay paths, each converted on its own.
            let flow = try Flow.read(url)
            if to == "mobdev" {
                for note in flow.notes { error("Note: \(note)") }
                output(String(decoding: flow.encoded(), as: UTF8.self))
            } else {
                let (yaml, notes) = try Maestro.export(flow)
                for note in flow.notes + notes { error("Note: \(note)") }
                output(yaml)
            }
            return 0
        } catch let failure {
            error(String(describing: failure))
            return 2
        }
    }
}
