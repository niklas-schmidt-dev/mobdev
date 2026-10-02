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
    /// Runs to completion on the calling thread and returns stdout alone, byte for byte, e.g. a
    /// raw screenshot. Blocks; call off the main thread.
    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data)
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let (process, pipe) = Self.process(executable, arguments)
        let box = ProcessBox(process)
        try process.run()
        // SIGKILL: devicectl does not always stop on SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stop() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Reading until EOF keeps a chatty command from blocking on a full pipe.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: CommandResult(status: box.waitForExit(timeout: timeout), output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    public func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        let (process, pipe) = Self.process(executable, arguments)
        let box = ProcessBox(process)
        try process.run()
        Thread.detachNewThread {
            let handle = pipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    // devicectl's console is a terminal, which ends lines with \r\n.
                    var end = newline
                    if end > pending.startIndex, pending[pending.index(before: end)] == 0x0D { end = pending.index(before: end) }
                    onLine(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                // A line without an end is handed over in pieces rather than held in memory.
                if pending.count > 64 * 1024 {
                    onLine(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                }
            }
            if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
            onExit(box.waitForExit(timeout: 10))
        }
        return box
    }

    public func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws
        -> (status: Int32, data: Data)
    {
        try runBinary(executable, arguments, input: nil, timeout: timeout)
    }

    /// Like `runBinary(_:_:timeout:)`, with `input` written to the command's standard input.
    public func runBinary(_ executable: URL, _ arguments: [String], input: Data?, timeout: TimeInterval) throws
        -> (status: Int32, data: Data)
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let box = ProcessBox(process)
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.stop() }
        if let stdin, let input {
            // On its own thread, so a command that answers before reading everything cannot block
            // this one. A command that exits early fails the write instead of raising SIGPIPE.
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (box.waitForExit(timeout: timeout), data)
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
    private let exited = DispatchSemaphore(value: 0)

    /// Before `run()`: the handler must be in place when the process ends.
    init(_ process: Process) {
        self.process = process
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
    }

    /// The exit status once the process ended. `waitUntilExit` was seen to wait forever for a
    /// process that had exited while many others ran, so this waits for the termination handler,
    /// at most `timeout`, then kills the process; -1 if it still does not end.
    func waitForExit(timeout: TimeInterval) -> Int32 {
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            stop()
            guard exited.wait(timeout: .now() + 2) == .success else { return -1 }
        }
        return process.terminationStatus
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
