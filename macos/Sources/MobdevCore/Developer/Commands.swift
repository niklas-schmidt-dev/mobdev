import Foundation

/// A finished command: its exit status and everything it printed.
public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// A command that keeps running, such as an app's console.
public protocol RunningCommand: Sendable {
    /// Ends the command with SIGKILL.
    func stop()
}

/// Runs command-line tools. `ProcessRunner` runs real ones; tests script the answers.
public protocol CommandRunning: Sendable {
    /// Runs to completion, or until `timeout`, and returns stdout and stderr together.
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
    /// Starts a command and hands over its output line by line, then its exit status.
    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let (process, pipe) = Self.process(executable, arguments)
        try process.run()
        let box = ProcessBox(process)
        // SIGKILL: devicectl does not always stop on SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stop() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Reading until EOF keeps a chatty command from blocking on a full pipe.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                box.process.waitUntilExit()
                continuation.resume(
                    returning: CommandResult(
                        status: box.process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    public func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        let (process, pipe) = Self.process(executable, arguments)
        try process.run()
        let box = ProcessBox(process)
        Thread.detachNewThread {
            let handle = pipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                // A line without an end is handed over in pieces rather than held in memory.
                if pending.count > 64 * 1024 {
                    onLine(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                }
            }
            if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
            box.process.waitUntilExit()
            onExit(box.process.terminationStatus)
        }
        return box
    }

    private static func process(_ executable: URL, _ arguments: [String]) -> (Process, Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return (process, pipe)
    }
}

private final class ProcessBox: RunningCommand, @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
