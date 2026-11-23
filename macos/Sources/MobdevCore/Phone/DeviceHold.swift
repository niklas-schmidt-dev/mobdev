import Foundation

/// A flow, a test run or a crawl holds its device until it ends: actions from other callers fail
/// with "Busy" instead of tapping into the middle of it, while tools that only look still work.
/// The run's own steps carry its hold as a task local, so they pass.
struct DeviceHold: Sendable {
    let id = UUID()
    /// What holds the device, such as "a flow".
    let what: String
    let source: String
    /// How to learn more or end it sooner, after "Wait for it to finish".
    var advice: String? = nil

    @TaskLocal static var current: UUID?

    var busy: String {
        "Busy: \(what) from \(source) is running on this device. Wait for it to finish" + (advice.map { "; \($0)" } ?? "") + "."
    }

    /// A test run outlives the call that started it, so "Busy" says where it stands and how it stops.
    static let testRunAdvice = "test_result says how far it is, and run_tests with stop true stops it"
}

extension PhoneTools {
    /// The tools that hold the device while their call runs, and what they are called in "Busy".
    /// `run_tests` and `run_native_tests` hold it themselves, for as long as their run goes on.
    static let holdingTools: [String: String] = [
        "run_flow": "a flow", "crawl_app": "a crawl", "navigate_to": "navigate_to",
    ]

    /// Runs `body` holding the device, or within the hold this task already has. Throws "Busy"
    /// while another caller's run holds it.
    func holding<T: Sendable>(_ what: String, source: String, _ body: () async throws -> T) async throws -> T {
        if let current = DeviceHold.current, hold.get()?.id == current { return try await body() }
        let mine = DeviceHold(what: what, source: source)
        let other = hold.withLock { held -> DeviceHold? in
            if let held { return held }
            held = mine
            return nil
        }
        if let other { throw ToolFailure(other.busy) }
        defer { hold.set(nil) }
        return try await DeviceHold.$current.withValue(mine.id) { try await body() }
    }

    /// Fails while another caller's run holds the device.
    func checkNotHeld() throws {
        guard let held = hold.get(), held.id != DeviceHold.current else { return }
        throw ToolFailure(held.busy + " Tools that only look, such as screenshot and ui_tree, still work.")
    }
}
