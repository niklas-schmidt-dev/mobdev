import Foundation

/// Performance on Android through adb. One shell command samples the app on the device: its CPU
/// time from /proc/<pid>/stat and its resident memory from /proc/<pid>/status about once a second,
/// with `dumpsys gfxinfo` reset before and read after for frame times, and `dumpsys meminfo` for
/// the PSS Android Studio shows. Launches are timed with `am start -W` after `am force-stop`.
extension AndroidApps: AppPerformance {
    var launchMethod: String { "am start -W, Android's own TotalTime until the first frame" }

    func sample(_ bundleID: String, seconds: TimeInterval) async throws -> PerformanceSample {
        let package = try ADB.checkPackage(bundleID)
        guard let pid = await pid(package) else {
            throw DeveloperError("\(package) is not running. Start it with launch_app first.")
        }
        let interval = UsageSampler.interval(for: seconds)
        let count = Int((seconds / interval).rounded())
        let output = try await adb.shell(
            serial, Self.sampleScript(package: package, pid: pid, count: count, interval: interval),
            timeout: seconds + 30)
        guard var sample = Self.parseSample(output, pid: pid) else {
            throw DeveloperError("\(package) ended before Mobdev could read it. Start it with launch_app.")
        }
        if sample.ended != nil {
            sample.ended = "\(package) ended after \(String(format: "%.1f", sample.points.last?.time ?? 0)) s."
        }
        return sample
    }

    /// Runs on the device. Each reading is one "S" line: the uptime, then the stat line, then the
    /// VmRSS line, so they parse in one piece. The pid and the package are checked values.
    static func sampleScript(package: String, pid: Int, count: Int, interval: TimeInterval) -> String {
        let pause = interval == 1 ? "1" : String(format: "%.1f", interval)
        return [
            "echo TCK $(getconf CLK_TCK)",
            "dumpsys gfxinfo \(package) reset >/dev/null 2>&1",
            "i=0",
            "while [ $i -le \(count) ]; do "
                + "s=$(cat /proc/\(pid)/stat 2>/dev/null) || { echo GONE; break; }; "
                + "[ -z \"$s\" ] && { echo GONE; break; }; "
                + "echo \"S $(cut -d' ' -f1 /proc/uptime) | $s | $(grep VmRSS /proc/\(pid)/status)\"; "
                + "i=$((i+1)); [ $i -le \(count) ] && sleep \(pause); done",
            "echo GFXINFO",
            "dumpsys gfxinfo \(package)",
            "echo MEMINFO",
            "dumpsys meminfo \(package) | grep -E 'TOTAL'",
            // A grep without a match would fail the whole command.
            "true",
        ].joined(separator: "; ")
    }

    /// The readings of `sampleScript`'s output, nil when there was not even one.
    static func parseSample(_ output: String, pid: Int) -> PerformanceSample? {
        var ticksPerSecond = 100.0
        var readings: [(uptime: Double, cpuSeconds: Double, memoryMB: Double)] = []
        var ended = false
        var section = ""
        var gfx: [Substring] = []
        var mem: [Substring] = []
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces)[...] }) {
            if line == "GFXINFO" || line == "MEMINFO" {
                section = String(line)
                continue
            }
            switch section {
            case "GFXINFO": gfx.append(line)
            case "MEMINFO": mem.append(line)
            default:
                if line.hasPrefix("TCK "), let value = Double(line.dropFirst(4)), value > 0 { ticksPerSecond = value }
                if line == "GONE" { ended = true }
                guard line.hasPrefix("S ") else { continue }
                let parts = line.dropFirst(2).components(separatedBy: " | ")
                guard parts.count >= 2, let uptime = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                    let ticks = cpuTicks(fromStat: parts[1])
                else { continue }
                let rss = parts.count > 2 ? residentKB(parts[2]) : nil
                readings.append((uptime, ticks / ticksPerSecond, (rss ?? 0) / 1024))
            }
        }
        guard let first = readings.first else { return nil }
        var points = [UsagePoint(time: 0, cpu: nil, memoryMB: first.memoryMB)]
        for (previous, reading) in zip(readings, readings.dropFirst()) {
            let elapsed = max(reading.uptime - previous.uptime, 0.01)
            points.append(
                UsagePoint(
                    time: reading.uptime - first.uptime,
                    cpu: max(reading.cpuSeconds - previous.cpuSeconds, 0) / elapsed * 100, memoryMB: reading.memoryMB))
        }
        let span = (readings.last?.uptime ?? first.uptime) - first.uptime
        let average = span > 0 ? max((readings.last?.cpuSeconds ?? 0) - first.cpuSeconds, 0) / span * 100 : 0
        return PerformanceSample(
            pid: pid, points: points, averageCPU: average, memoryKind: "resident (RSS)",
            frames: frameStats(gfx.joined(separator: "\n")), pssMB: pss(mem.joined(separator: "\n")),
            ended: ended ? "ended" : nil)
    }

    /// utime plus stime, fields 14 and 15 of /proc/<pid>/stat, in clock ticks. The process name in
    /// parentheses may contain spaces, so fields are counted after the last ")".
    static func cpuTicks(fromStat stat: String) -> Double? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        // fields[0] is the state, field 3.
        guard fields.count > 12, let user = Double(fields[11]), let system = Double(fields[12]) else { return nil }
        return user + system
    }

    /// "VmRSS:	  123456 kB".
    static func residentKB(_ line: String) -> Double? {
        guard line.contains("VmRSS") else { return nil }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }.first
    }

    /// `dumpsys gfxinfo <package>` since the reset: "Total frames rendered: 120", "Janky frames: 12
    /// (10.00%)", "50th percentile: 8ms". Nil when the output has no stats; no frame times when the
    /// app drew nothing.
    static func frameStats(_ text: String) -> FrameStats? {
        func value(_ prefix: String) -> Substring? {
            text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces)[...] }
                .first { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)[...] }
        }
        func milliseconds(_ prefix: String) -> Double? {
            value(prefix).flatMap { Double($0.replacingOccurrences(of: "ms", with: "").trimmingCharacters(in: .whitespaces)) }
        }
        guard let total = value("Total frames rendered:").flatMap({ Int($0) }) else { return nil }
        let jankyText = value("Janky frames:") ?? "0"
        let janky = Int(jankyText.split(separator: " ").first ?? "0") ?? 0
        let percent = jankyText.firstRange(of: "(").flatMap { open in
            Double(jankyText[open.upperBound...].prefix { $0.isNumber || $0 == "." })
        } ?? (total > 0 ? Double(janky) / Double(total) * 100 : 0)
        // Without frames gfxinfo still prints percentiles, all 4950 ms, its histogram's last bucket.
        func time(_ prefix: String) -> Double? { total > 0 ? milliseconds(prefix) : nil }
        return FrameStats(
            total: total, janky: janky, jankyPercent: percent, p50: time("50th percentile:"),
            p90: time("90th percentile:"), p95: time("95th percentile:"), p99: time("99th percentile:"))
    }

    /// The "TOTAL PSS: 98765" of newer `dumpsys meminfo` summaries, or the first number of the
    /// "TOTAL" row of older ones, in MB.
    static func pss(_ text: String) -> Double? {
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "TOTAL PSS:") {
                let number = line[range.upperBound...].split(separator: " ").first.flatMap { Double($0) }
                if let number { return number / 1024 }
            }
        }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.first == "TOTAL", fields.count > 1, let number = Double(fields[1]) { return number / 1024 }
        }
        return nil
    }

    func coldLaunch(_ bundleID: String) async throws -> LaunchTiming {
        let package = try ADB.checkPackage(bundleID)
        let component = try await launcherActivity(package)
        _ = try await adb.shell(serial, "am force-stop \(package)")
        try await Task.sleep(nanoseconds: 500_000_000)
        // The task can outlive the process with another app's activity on top, such as Settings'
        // search, which belongs to another package. Without clearing it the intent goes to that
        // activity and nothing launches.
        let output = try await adb.shell(
            serial, "am start -W --activity-clear-task -n \(ADB.quote(component))", timeout: 60)
        guard let timing = Self.launchTiming(output) else {
            let lines = output.split(separator: "\n")
            let reason =
                lines.first { $0.contains("Error") || $0.contains("Warning") }
                ?? lines.first { $0.contains("Status") }
            throw DeveloperError(
                "am start -W did not report a launch time for \(package)"
                    + (reason.map { ": \($0.trimmingCharacters(in: .whitespaces))" } ?? "."))
        }
        return timing
    }

    /// "TotalTime: 523" (or "WaitTime" on old versions) and "LaunchState: COLD" from `am start -W`.
    static func launchTiming(_ output: String) -> LaunchTiming? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let milliseconds = (values["TotalTime"] ?? values["WaitTime"]).flatMap(Double.init), milliseconds > 0
        else { return nil }
        return LaunchTiming(milliseconds: milliseconds, state: values["LaunchState"])
    }
}

extension AndroidDevice {
    public var performance: AppPerformance? { apps as? AndroidApps }

    /// React Native opens its developer menu on the Menu key, as `adb shell input keyevent 82` in its docs.
    public func developerMenu() async throws -> String? {
        _ = try await adb.shell(id, "input keyevent 82", timeout: 20)
        return "Pressed the Menu key"
    }
}
