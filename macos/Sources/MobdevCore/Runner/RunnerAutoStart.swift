import Foundation

/// Whether Mobdev Runner runs on an iPhone, as the user left it under Developer Mode Control.
public enum RunnerChoice: Sendable, Equatable {
    /// Starts by itself once Developer Mode is on and a development team can sign it.
    case automatic
    /// Turned on by hand: starts without waiting for Developer Mode to show in Xcode's device list.
    case on
    /// Turned off for this iPhone: input goes over Bluetooth.
    case off
}

/// Decides when Mobdev Runner starts on a plugged-in iPhone. Developer Mode comes from Xcode's
/// device list, which takes a second or two to read, so it is read in the background: at once for
/// a new iPhone, again every `recheck` seconds while it is off or unknown, and not again once it is
/// on until the iPhone is unplugged (turning it on restarts the iPhone, which unplugs it).
public final class RunnerAutoStart: Sendable {
    private struct Reading {
        var value: Bool?
        var checked: Date
        var checking: Bool
    }

    private let check: @Sendable (String) async -> Bool?
    private let recheck: TimeInterval
    private let readings = Locked<[String: Reading]>([:])

    /// `check` reads Developer Mode for a UDID: true, false, or nil when Xcode cannot tell.
    public init(recheck: TimeInterval = 30, check: @escaping @Sendable (String) async -> Bool?) {
        self.recheck = recheck
        self.check = check
    }

    /// Whether to start an iPhone's runner that is off now.
    public static func shouldStart(choice: RunnerChoice, developerMode: Bool?, team: String) -> Bool {
        switch choice {
        case .off: false
        case .on: true
        case .automatic: developerMode == true && UIRunner.isTeamID(team)
        }
    }

    /// Developer Mode of a plugged-in iPhone as last read; nil until it is known. Reads it again in
    /// the background when that is due, and calls `onChange` once a reading changes it.
    public func developerMode(of udid: String, onChange: @escaping @Sendable () -> Void) -> Bool? {
        let (value, due) = readings.withLock { readings -> (Bool?, Bool) in
            let reading = readings[udid]
            let due = reading.map { !$0.checking && $0.value != true && Date().timeIntervalSince($0.checked) >= recheck } ?? true
            if due { readings[udid] = Reading(value: reading?.value, checked: Date(), checking: true) }
            return (reading?.value, due)
        }
        if due {
            Task.detached { [check] in
                let read = await check(udid)
                let changed = self.readings.withLock { readings -> Bool in
                    // Forgotten meanwhile: the iPhone was unplugged.
                    guard readings[udid] != nil else { return false }
                    let changed = readings[udid]?.value != read
                    readings[udid] = Reading(value: read, checked: Date(), checking: false)
                    return changed
                }
                if changed { onChange() }
            }
        }
        return value
    }

    /// Developer Mode as last read, without reading it.
    public func knownDeveloperMode(of udid: String) -> Bool? { readings.get()[udid]?.value }

    /// Forgets an iPhone that was unplugged, so it is read again when it comes back.
    public func forget(_ udid: String) { _ = readings.withLock { $0.removeValue(forKey: udid) } }
}
