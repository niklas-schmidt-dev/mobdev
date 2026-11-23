import Testing
@testable import MobdevCore

@Suite struct ChoreScheduleTests {
    let t0 = ContinuousClock.now

    func at(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    /// A schedule with the window shown, every chore run once and finished at t0.
    func ranOnce() -> ChoreSchedule {
        var schedule = ChoreSchedule()
        _ = schedule.setWindowVisible(true)
        for chore in schedule.start(at: t0) { schedule.finished(chore, at: t0) }
        return schedule
    }

    @Test func onlyPointerChecksRunWithoutWindow() {
        #expect(AppChore.allCases.filter { !$0.needsWindow } == [.pointerChecks])
        #expect(AppChore.pictures.interval == .seconds(2))
        #expect(AppChore.pointerChecks.interval == .seconds(2))
        #expect(AppChore.otherMacs.interval == .seconds(30))
        #expect(AppChore.virtualDevices.interval == .seconds(30))
    }

    @Test func choresForWindowWaitUntilItIsShown() {
        var schedule = ChoreSchedule()
        var started = schedule.start(at: t0)
        #expect(started == [.pointerChecks])
        // Pointer checks run; nothing else may start.
        #expect(schedule.nextDue(after: t0) == nil)
        schedule.finished(.pointerChecks, at: at(1))
        #expect(schedule.nextDue(after: at(1)) == at(3))
        started = schedule.start(at: at(60))
        #expect(started == [.pointerChecks])

        let shown = schedule.setWindowVisible(true)
        let shownAgain = schedule.setWindowVisible(true)
        #expect(shown && !shownAgain)
        // Never run before, so at once.
        started = schedule.start(at: at(61))
        #expect(started == [.pictures, .otherMacs, .virtualDevices])
    }

    @Test func eachRunsAnIntervalAfterItsLastRunEnded() {
        var schedule = ranOnce()
        #expect(schedule.nextDue(after: t0) == at(2))
        var started = schedule.start(at: at(1))
        #expect(started == [])
        started = schedule.start(at: at(2))
        #expect(started == [.pictures, .pointerChecks])
        // A run that takes long pushes the next one back.
        schedule.finished(.pictures, at: at(5))
        schedule.finished(.pointerChecks, at: at(2))
        started = schedule.start(at: at(6))
        #expect(started == [.pointerChecks])
        started = schedule.start(at: at(29))
        #expect(started == [.pictures])
        started = schedule.start(at: at(30))
        #expect(started == [.otherMacs, .virtualDevices])
    }

    @Test func oneRunAtATime() {
        var schedule = ChoreSchedule()
        _ = schedule.setWindowVisible(true)
        var started = schedule.start(at: t0)
        #expect(started == AppChore.allCases)
        started = schedule.start(at: at(100))
        #expect(started == [])
        #expect(schedule.nextDue(after: at(100)) == nil)
        schedule.finished(.otherMacs, at: at(100))
        #expect(schedule.nextDue(after: at(100)) == at(130))
    }

    @Test func hiddenWindowStopsItsChores() {
        var schedule = ranOnce()
        let hidden = schedule.setWindowVisible(false)
        #expect(hidden)
        // Only the pointer checks keep a timer.
        #expect(schedule.nextDue(after: t0) == at(2))
        let started = schedule.start(at: at(300))
        #expect(started == [.pointerChecks])
        schedule.finished(.pointerChecks, at: at(300))
        #expect(schedule.nextDue(after: at(300)) == at(302))
    }

    @Test func shownAgainRunsWhatIsDueAtOnceAndTheRestOnTime() {
        var schedule = ranOnce()
        _ = schedule.setWindowVisible(false)
        _ = schedule.setWindowVisible(true)
        // Hidden for ten seconds: the pictures are due, the other Macs and simulators are not yet.
        var started = schedule.start(at: at(10))
        #expect(started == [.pictures, .pointerChecks])
        schedule.finished(.pictures, at: at(10))
        schedule.finished(.pointerChecks, at: at(10))
        #expect(schedule.nextDue(after: at(10)) == at(12))
        started = schedule.start(at: at(29))
        #expect(!started.contains(.otherMacs))
        started = schedule.start(at: at(30))
        #expect(started.contains(.otherMacs))

        // Hidden for longer than the interval: everything at once.
        var later = ranOnce()
        _ = later.setWindowVisible(false)
        started = later.start(at: at(120))
        #expect(started == [.pointerChecks])
        _ = later.setWindowVisible(true)
        started = later.start(at: at(121))
        #expect(started == [.pictures, .otherMacs, .virtualDevices])
    }

    @Test func requestRunsAtOnceWhileShownAndIdle() {
        var schedule = ranOnce()
        let now = schedule.request(.otherMacs)
        #expect(now)
        // It counts as running, so the timer does not start it a second time.
        var started = schedule.start(at: at(40))
        #expect(!started.contains(.otherMacs))
        schedule.finished(.otherMacs, at: at(41))
        started = schedule.start(at: at(42))
        #expect(!started.contains(.otherMacs))
        started = schedule.start(at: at(71))
        #expect(started.contains(.otherMacs))
    }

    @Test func requestWhileRunningRunsRightAfter() {
        var schedule = ranOnce()
        var started = schedule.start(at: at(30))
        #expect(started.contains(.virtualDevices))
        let now = schedule.request(.virtualDevices)
        #expect(!now)
        started = schedule.start(at: at(31))
        #expect(!started.contains(.virtualDevices))
        schedule.finished(.virtualDevices, at: at(32))
        // Asked for, so not 30 seconds later.
        #expect(schedule.nextDue(after: at(32)) == at(32))
        started = schedule.start(at: at(32))
        #expect(started.contains(.virtualDevices))
        schedule.finished(.virtualDevices, at: at(33))
        // Once only.
        started = schedule.start(at: at(34))
        #expect(!started.contains(.virtualDevices))
    }

    @Test func requestWhileHiddenWaitsForTheWindow() {
        var schedule = ranOnce()
        _ = schedule.setWindowVisible(false)
        let simulators = schedule.request(.virtualDevices)
        let macs = schedule.request(.otherMacs)
        #expect(!simulators && !macs)
        var started = schedule.start(at: at(5))
        #expect(started == [.pointerChecks])
        schedule.finished(.pointerChecks, at: at(5))
        #expect(schedule.nextDue(after: at(5)) == at(7))
        // Shown a moment later: asked for, so at once although their interval is not up.
        _ = schedule.setWindowVisible(true)
        started = schedule.start(at: at(6))
        #expect(started == [.pictures, .otherMacs, .virtualDevices])
    }

    @Test func pointerChecksNeverWaitForTheWindow() {
        var schedule = ChoreSchedule()
        #expect(schedule.allows(.pointerChecks))
        #expect(!schedule.allows(.pictures))
        let pointer = schedule.request(.pointerChecks)
        let pictures = schedule.request(.pictures)
        #expect(pointer && !pictures)
    }
}
