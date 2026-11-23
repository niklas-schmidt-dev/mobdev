/// The Mac app's repeating chores. Most only feed what the main window shows and pause while it
/// cannot be seen; the pointer checks serve agents too and run regardless.
public enum AppChore: CaseIterable, Hashable, Sendable {
    /// Thumbnails and backdrop colors of the connected devices, for the overview and device views.
    /// A simulator's frame is a copy of about 12 MB.
    case pictures
    /// Whether AssistiveTouch is set up on iPhones driven over Bluetooth. Setup and the `status`
    /// tool show the answer, so agents know it before anyone swipes.
    case pointerChecks
    /// The account's other Macs and their devices from the hosted relay, for the sidebar and the
    /// overview. Each run is a request to the relay.
    case otherMacs
    /// The simulators and AVDs on this Mac, running or not, for the sidebar. Listing them starts
    /// simctl, and reading the AVD folder can block until macOS has asked for access to its volume.
    case virtualDevices

    /// The time from the end of one run to the start of the next.
    public var interval: Duration {
        switch self {
        case .pictures, .pointerChecks: .seconds(2)
        case .otherMacs, .virtualDevices: .seconds(30)
        }
    }

    /// Whether it runs only while the main window can be seen, because nothing else uses its result.
    public var needsWindow: Bool { self != .pointerChecks }
}

/// When each chore runs: one run at a time, the next `interval` after the last one ended.
///
/// A chore that needs the window waits while it cannot be seen. Shown again, the chore runs at once
/// if its interval is up and otherwise when it would have run anyway, so the window never shows
/// older content than usual, and switching between windows does not run chores more often.
/// A chore asked for out of turn (the relay connected, a simulator started) runs at once; while it
/// runs already or waits for the window, it runs right after that instead.
public struct ChoreSchedule: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public private(set) var windowVisible = false
    private var lastEnd: [AppChore: Instant] = [:]
    private var running: Set<AppChore> = []
    private var requested: Set<AppChore> = []

    public init() {}

    /// Records whether the main window can be seen; true when that changed.
    public mutating func setWindowVisible(_ visible: Bool) -> Bool {
        guard visible != windowVisible else { return false }
        windowVisible = visible
        return true
    }

    /// The chores due at `now`. They count as running until `finished`.
    public mutating func start(at now: Instant) -> [AppChore] {
        let due = AppChore.allCases.filter { chore in dueTime(chore, at: now).map { $0 <= now } ?? false }
        for chore in due {
            running.insert(chore)
            requested.remove(chore)
        }
        return due
    }

    /// Asks for a chore out of turn. True when it may start now, and then it counts as running until
    /// `finished`; otherwise it starts as soon as it may.
    public mutating func request(_ chore: AppChore) -> Bool {
        guard allows(chore), !running.contains(chore) else {
            requested.insert(chore)
            return false
        }
        running.insert(chore)
        requested.remove(chore)
        return true
    }

    public mutating func finished(_ chore: AppChore, at now: Instant) {
        running.remove(chore)
        lastEnd[chore] = now
    }

    /// When the next chore is due after `now`'s `start`; nil while none can start, because each
    /// runs or waits for the window.
    public func nextDue(after now: Instant) -> Instant? {
        AppChore.allCases.compactMap { dueTime($0, at: now) }.min()
    }

    /// Whether a chore may run now as far as the window goes.
    public func allows(_ chore: AppChore) -> Bool { !chore.needsWindow || windowVisible }

    /// When a chore may start: nil while it runs or waits for the window, `now` when it never ran
    /// or was asked for.
    private func dueTime(_ chore: AppChore, at now: Instant) -> Instant? {
        guard allows(chore), !running.contains(chore) else { return nil }
        guard !requested.contains(chore), let end = lastEnd[chore] else { return now }
        return end + chore.interval
    }
}
