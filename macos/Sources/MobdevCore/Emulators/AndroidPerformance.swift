import Foundation

/// Performance on Android through adb. One shell command samples the app on the device: its CPU
/// time from /proc/<pid>/stat and its resident memory from /proc/<pid>/status about once a second,
/// with `dumpsys gfxinfo` reset before and read after for frame times, and `dumpsys meminfo` for
/// the PSS Android Studio shows. Launches are timed with `am start -W` after `am force-stop`. The
/// device's load comes from `top`, /proc/meminfo and `dumpsys thermalservice`; traces from the
/// device's own `perfetto`, pulled to the Mac.
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

// MARK: - Device load and Perfetto

extension AndroidApps {
    func deviceLoad() async throws -> DeviceLoad {
        let output = try await adb.shell(serial, Self.loadScript, timeout: 40)
        return Self.parseLoad(output)
    }

    /// `top` twice a second apart, since its first frame's percentages count from boot; then
    /// memory and the thermal service. Sections start with a marker line.
    static let loadScript = [
        "echo TOP",
        "top -b -n 2 -d 1 -o PID,%CPU,RES,NAME 2>/dev/null || top -b -n 1",
        "echo MEMINFO",
        "cat /proc/meminfo",
        "echo THERMAL",
        "dumpsys thermalservice 2>/dev/null",
        "true",
    ].joined(separator: "; ")

    static func parseLoad(_ output: String) -> DeviceLoad {
        var sections: [String: [Substring]] = [:]
        var section = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["TOP", "MEMINFO", "THERMAL"].contains(trimmed) {
                section = trimmed
                continue
            }
            sections[section, default: []].append(line)
        }
        let top = parseTop(sections["TOP"] ?? [])
        let memory = parseMeminfo(sections["MEMINFO"] ?? [])
        let thermal = parseThermal(sections["THERMAL"] ?? [])
        return DeviceLoad(
            processes: top.processes, cpuPercent: top.cpuPercent, cores: top.cores,
            memoryUsedMB: memory.used, memoryTotalMB: memory.total, thermalState: thermal.state,
            temperatures: thermal.temperatures, memoryKind: "resident (RSS)", seconds: 1,
            source: "top, /proc/meminfo and dumpsys thermalservice")
    }

    /// The last frame of `top -b`: its "800%cpu … 750%idle" line and the rows under its header.
    /// The header marks the sort column with brackets, such as "[%CPU]".
    static func parseTop(_ lines: [Substring]) -> (processes: [DeviceLoad.Process], cpuPercent: Double?, cores: Int?) {
        var header: [String] = []
        var rows: [[String]] = []
        var cpu: (total: Double, idle: Double)?
        for line in lines {
            let text = line.replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
            let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !fields.isEmpty else { continue }
            if let total = fields.first(where: { $0.hasSuffix("%cpu") }).flatMap({ Double($0.dropLast(4)) }) {
                let idle = fields.first(where: { $0.hasSuffix("%idle") }).flatMap { Double($0.dropLast(5)) } ?? 0
                cpu = (total, idle)
                continue
            }
            if fields.contains("PID"), fields.contains(where: { $0.contains("CPU") }) {
                // A new frame: its rows replace the previous frame's.
                header = fields
                rows = []
                continue
            }
            if !header.isEmpty, Int(fields[0]) != nil { rows.append(fields) }
        }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let pidColumn = column(["PID"]) else { return ([], nil, nil) }
        let cpuColumn = column(["%CPU", "CPU%", "S%CPU"])
        let memoryColumn = column(["RES", "RSS"])
        // The name is the last column and may contain spaces.
        let nameColumn = column(["NAME", "ARGS", "CMD", "CMDLINE", "Name"]) ?? header.count - 1
        let processes = rows.compactMap { fields -> DeviceLoad.Process? in
            guard fields.count >= header.count, let pid = Int(fields[pidColumn]) else { return nil }
            let name = fields[nameColumn...].joined(separator: " ")
            return DeviceLoad.Process(
                name: name, pid: pid, cpuPercent: cpuColumn.flatMap { Double(fields[$0]) } ?? 0,
                memoryMB: memoryColumn.flatMap { megabytes(fields[$0]) } ?? 0)
        }
        let cores = cpu.map { Int(($0.total / 100).rounded()) }
        return (processes, cpu.map { max($0.total - $0.idle, 0) }, cores)
    }

    /// top's "183M", "45K", "1.2G"; a plain number is kilobytes.
    static func megabytes(_ text: String) -> Double? {
        let units: [Character: Double] = ["K": 1.0 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024]
        if let last = text.last, let factor = units[Character(last.uppercased())], let value = Double(text.dropLast()) {
            return value * factor
        }
        return Double(text).map { $0 / 1024 }
    }

    /// MemTotal and MemAvailable, in MB; used is what is not available.
    static func parseMeminfo(_ lines: [Substring]) -> (used: Double?, total: Double?) {
        var values: [String: Double] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let kilobytes = parts[1].split(separator: " ").first.flatMap({ Double($0) }) else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = kilobytes / 1024
        }
        guard let total = values["MemTotal"] else { return (nil, nil) }
        let available = values["MemAvailable"] ?? values["MemFree"]
        return (available.map { max(total - $0, 0) }, total)
    }

    /// "Thermal Status: 0" and the HAL's current temperatures, e.g.
    /// "Temperature{mValue=31.0, mType=0, mName=CPU, mStatus=0}".
    static func parseThermal(_ lines: [Substring]) -> (state: String?, temperatures: [String]) {
        let names = ["none", "light", "moderate", "severe", "critical", "emergency", "shutdown"]
        var state: String?
        var temperatures: [String] = []
        var current = false
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Thermal Status:"), let code = Int(text.dropFirst("Thermal Status:".count).trimmingCharacters(in: .whitespaces)) {
                state = code >= 0 && code < names.count ? "\(names[code]) (\(code))" : "status \(code)"
            } else if text.hasPrefix("Current temperatures from HAL") {
                current = true
            } else if current, text.hasPrefix("Temperature{") {
                func field(_ key: String) -> String? {
                    guard let range = text.range(of: key + "=") else { return nil }
                    return String(text[range.upperBound...].prefix { $0 != "," && $0 != "}" })
                }
                if let value = field("mValue").flatMap(Double.init), let name = field("mName"), temperatures.count < 8 {
                    temperatures.append(String(format: "%@ %.1f °C", name, value))
                }
            } else if current, !text.isEmpty, !text.hasPrefix("Temperature") {
                current = false
            }
        }
        return (state, temperatures)
    }

    /// What Perfetto records: scheduling, CPU frequencies and idle states from the kernel, and the
    /// framework's own sections (activity and window manager, graphics, views, input, binder).
    static let perfettoCategories = "sched freq idle am wm gfx view binder_driver hal dalvik input res"

    /// Records with the device's `perfetto` into its trace folder, then pulls the file to the Mac.
    /// With a package, the app's own trace sections are recorded too; with a launch, the app is
    /// started fresh once the recording runs.
    func recordTrace(_ request: TraceRequest) async throws -> TraceRecording {
        let seconds = Int(request.seconds.rounded(.up))
        let remote = "/data/misc/perfetto-traces/mobdev-\(UUID().uuidString.prefix(8)).perfetto-trace"
        var command: String
        let target: String
        switch request.target {
        case .allProcesses:
            target = "the whole device"
            command = Self.perfettoCommand(remote: remote, seconds: seconds, package: nil, background: false)
        case .attach(let bundleID):
            let package = try ADB.checkPackage(bundleID)
            target = package
            command = Self.perfettoCommand(remote: remote, seconds: seconds, package: package, background: false)
        case .launch(let bundleID):
            let package = try ADB.checkPackage(bundleID)
            let component = try await launcherActivity(package)
            target = "\(package), launched for the recording"
            command = "am force-stop \(package); "
                + "p=$(\(Self.perfettoCommand(remote: remote, seconds: seconds, package: package, background: true))) || exit 1; "
                + "sleep 1; am start --activity-clear-task -n \(ADB.quote(component)) >/dev/null; "
                + "while kill -0 $p 2>/dev/null; do sleep 0.5; done"
        }
        do {
            _ = try await adb.shell(serial, command, timeout: request.seconds + 40)
        } catch let error as DeveloperError {
            _ = try? await adb.shell(serial, "rm -f \(remote)")
            throw DeveloperError(
                "Perfetto could not record: \(error.description) Android 9 and 10 need it turned on first: adb shell setprop persist.traced.enable 1.")
        }
        try FileManager.default.createDirectory(at: request.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pulled = try await adb.run(serial, ["pull", remote, request.output.path], timeout: 60)
        _ = try? await adb.shell(serial, "rm -f \(remote)")
        guard pulled.status == 0, FileManager.default.fileExists(atPath: request.output.path) else {
            throw DeveloperError("Could not copy the trace from the device: \(pulled.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: request.output.path))?[.size] as? NSNumber)?.intValue ?? 0
        return TraceRecording(
            file: request.output, template: "Perfetto", target: target, seconds: Double(seconds),
            summary: [String(format: "%.1f MB of trace data", Double(size) / 1_048_576)],
            howToOpen: "Open it at https://ui.perfetto.dev (Open trace file), or in Android Studio's profiler")
    }

    /// Perfetto's short form: output, duration, buffer, the app's own sections, then categories.
    /// `--background` prints the pid of the recording and returns at once.
    static func perfettoCommand(remote: String, seconds: Int, package: String?, background: Bool) -> String {
        var parts = ["perfetto"]
        if background { parts.append("--background") }
        parts += ["-o", remote, "-t", "\(seconds)s", "-b", "64mb"]
        if let package { parts += ["-a", package] }
        return (parts + [perfettoCategories]).joined(separator: " ")
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
