import Foundation

// MARK: - Export tables

/// One value of an `xctrace export` table, such as
/// `<size-in-bytes fmt="1,13 MiB">1179888</size-in-bytes>`, with the elements inside it (a
/// process holds its pid). References (`ref="12"`) are already replaced by the value they name.
public struct XctraceValue: Sendable, Equatable {
    public var tag: String
    /// The element's own text: the raw number, such as nanoseconds or bytes.
    public var text: String
    /// How Instruments shows it, e.g. "98.7%" or "sleep (76563)".
    public var fmt: String?
    public var attributes: [String: String]
    public var children: [XctraceValue]

    public init(tag: String, text: String = "", fmt: String? = nil, attributes: [String: String] = [:], children: [XctraceValue] = []) {
        self.tag = tag
        self.text = text
        self.fmt = fmt
        self.attributes = attributes
        self.children = children
    }

    public var number: Double? { Double(text) }

    public func child(_ tag: String) -> XctraceValue? { children.first { $0.tag == tag } }
}

/// One table of `xctrace export --xpath '…/table[@schema="…"]'`: the columns by their mnemonic and
/// every row. Instruments writes each value once with an `id` and later rows refer to it with
/// `ref`; an empty cell is `<sentinel/>`, kept here as nil.
public struct XctraceTable: Sendable, Equatable {
    public var schema: String
    public var columns: [String]
    public var rows: [[XctraceValue?]]

    public init(schema: String, columns: [String], rows: [[XctraceValue?]]) {
        self.schema = schema
        self.columns = columns
        self.rows = rows
    }

    public func value(_ row: [XctraceValue?], _ column: String) -> XctraceValue? {
        guard let index = columns.firstIndex(of: column), index < row.count else { return nil }
        return row[index]
    }

    /// Every table in an export, in order. Empty when the data is not an export.
    public static func parse(_ data: Data) -> [XctraceTable] {
        let builder = XctraceTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { return [] }
        return root.children.filter { $0.tag == "node" }.compactMap { node -> XctraceTable? in
            guard let schema = node.child("schema") else { return nil }
            let columns = schema.children.filter { $0.tag == "col" }.map { $0.child("mnemonic")?.text ?? "" }
            let rows = node.children.filter { $0.tag == "row" }.map { row in
                row.children.map { $0.tag == "sentinel" ? nil : $0 }
            }
            return XctraceTable(schema: schema.attributes["name"] ?? "", columns: columns, rows: rows)
        }
    }
}

/// Builds the element tree of an export, replacing each `ref` with the value of its `id`.
private final class XctraceTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XctraceValue] = []
    private var ids: [String: XctraceValue] = [:]
    var root: XctraceValue?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        stack.append(XctraceValue(tag: elementName, fmt: attributes["fmt"], attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard var value = stack.popLast() else { return }
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = value.attributes["ref"], let known = ids[ref] {
            value = known
        } else if let id = value.attributes["id"] {
            ids[id] = value
        }
        if stack.isEmpty {
            root = value
        } else {
            stack[stack.count - 1].children.append(value)
        }
    }
}

// MARK: - xctrace

/// Xcode's `xctrace`: records Instruments templates on iPhones, simulators and this Mac, and
/// exports tables of the recordings. Mobdev records the Activity Monitor template for an iPhone's
/// CPU and memory, where nothing else reads them, and any template for `record_trace`.
public struct Xctrace: Sendable {
    /// Whom a recording follows.
    public enum Target: Sendable, Equatable {
        /// A running process, by pid or name.
        case attach(String)
        /// Starts the app (a bundle ID or path) under the recording.
        case launch(String)
        case allProcesses
    }

    let runner: CommandRunning
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public init(runner: CommandRunning = ProcessRunner()) { self.runner = runner }

    /// The templates `xctrace list templates` names: Apple's and the user's own.
    public func templates() async throws -> [String] {
        let result = try await runner.run(Self.xcrun, ["xctrace", "list", "templates"], timeout: 60)
        guard result.status == 0 else {
            throw DeveloperError("xctrace could not list its templates: \(Self.reason(result.output)) Instruments comes with Xcode.")
        }
        return Self.templates(fromList: result.output)
    }

    /// "== Standard Templates ==" headings, then one name per line.
    static func templates(fromList text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==") }
    }

    /// The template as `xctrace` spells it, matched without regard to case, or an error naming them all.
    public func template(named name: String) async throws -> String {
        let all = try await templates()
        if let found = all.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return found }
        throw DeveloperError("There is no Instruments template \"\(name)\". Templates: \(all.joined(separator: ", ")).")
    }

    /// Records `template` for `seconds` into `output` (a path ending in .trace, which must not
    /// exist yet) and returns what xctrace printed. `device` is a UDID; nil records this Mac.
    @discardableResult
    public func record(
        template: String, device: String?, target: Target, seconds: TimeInterval, output: URL
    ) async throws -> String {
        var arguments = ["xctrace", "record", "--no-prompt", "--template", template]
        if let device { arguments += ["--device", device] }
        arguments += ["--time-limit", "\(Int(seconds.rounded(.up)))s", "--output", output.path]
        switch target {
        case .attach(let process): arguments += ["--attach", process]
        case .allProcesses: arguments.append("--all-processes")
        case .launch(let app): arguments += ["--launch", "--", app]
        }
        // Instruments takes several seconds to start and to save, more for all processes.
        let result = try await runner.run(Self.xcrun, arguments, timeout: seconds + 75)
        let saved = FileManager.default.fileExists(atPath: output.path)
        if result.status != 0 || !saved || result.output.contains("Recording failed") {
            // A failed recording may still leave a trace behind; it holds nothing worth keeping.
            if saved { try? FileManager.default.removeItem(at: output) }
            throw DeveloperError("xctrace could not record \(template): \(Self.reason(result.output))")
        }
        return result.output
    }

    /// The tables of `schema` in the first run of a trace; empty when the trace has none.
    public func export(_ trace: URL, schema: String, timeout: TimeInterval = 45) async throws -> [XctraceTable] {
        let xpath = "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]"
        let data = try await exportData(trace, ["--xpath", xpath], timeout: timeout)
        return XctraceTable.parse(data).filter { $0.schema == schema }
    }

    /// The table of contents: which tables the trace has, the device, the template and the duration.
    public func contents(_ trace: URL) async throws -> TraceContents {
        TraceContents.parse(try await exportData(trace, ["--toc"], timeout: 45))
    }

    private func exportData(_ trace: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        // Written to a file: an export can be megabytes, and a pipe also carries xctrace's warnings.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-xctrace-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await runner.run(
            Self.xcrun, ["xctrace", "export", "--input", trace.path, "--output", file.path] + arguments, timeout: timeout)
        guard result.status == 0, let data = try? Data(contentsOf: file) else {
            throw DeveloperError("xctrace could not read \(trace.lastPathComponent): \(Self.reason(result.output))")
        }
        return data
    }

    /// The lines that explain a failure: errors first, else the first thing printed.
    static func reason(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = lines.filter { $0.contains("[Error]") || $0.hasPrefix("Cannot") || $0.hasPrefix("Error") }
            .map { $0.replacingOccurrences(of: "* [Error] ", with: "") }
        var unique: [String] = []
        for line in errors where !unique.contains(line) { unique.append(line) }
        let text = (unique.isEmpty ? Array(lines.prefix(2)) : unique).joined(separator: " ")
        return text.isEmpty ? "it ended without saying why." : text
    }
}

/// What `xctrace export --toc` says about a trace's first run.
public struct TraceContents: Sendable, Equatable {
    public var template: String?
    public var duration: Double?
    /// The schemas of its tables, e.g. "time-profile".
    public var schemas: [String]
    /// The recorded device's memory in bytes.
    public var memoryBytes: Double?
    public var deviceName: String?
    public var platform: String?

    static func parse(_ data: Data) -> TraceContents {
        let builder = XctraceTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        var contents = TraceContents(schemas: [])
        guard parser.parse(), let root = builder.root, let run = root.child("run") else { return contents }
        let device = run.child("info")?.child("target")?.child("device")
        contents.memoryBytes = device?.attributes["memory-size"].flatMap(Double.init)
        contents.deviceName = device?.attributes["name"]
        contents.platform = device?.attributes["platform"]
        let summary = run.child("info")?.child("summary")
        contents.template = summary?.child("template-name")?.text
        contents.duration = summary?.child("duration").flatMap(\.number)
        for table in run.child("data")?.children ?? [] where table.tag == "table" {
            if let schema = table.attributes["schema"], !contents.schemas.contains(schema) { contents.schemas.append(schema) }
        }
        return contents
    }
}

// MARK: - Activity Monitor

/// The Activity Monitor template's tables, which carry what Xcode's gauges and Activity Monitor
/// show: per process `activity-monitor-process-live` (CPU percent of one core over the last
/// interval, CPU time so far, physical footprint), for the device `activity-monitor-system`
/// (memory used, CPU load) and `device-thermal-state-intervals`.
enum ActivityMonitor {
    struct ProcessRow: Equatable {
        var name: String
        var pid: Int
        /// Seconds since the recording started.
        var time: Double
        var cpuPercent: Double?
        var cpuSeconds: Double?
        var footprintMB: Double?
    }

    /// "Settings (66546)" → "Settings".
    static func processName(_ fmt: String) -> String {
        guard fmt.hasSuffix(")"), let open = fmt.range(of: " (", options: .backwards) else { return fmt }
        return String(fmt[..<open.lowerBound])
    }

    static func processRows(_ table: XctraceTable) -> [ProcessRow] {
        table.rows.compactMap { row -> ProcessRow? in
            guard let process = table.value(row, "process") else { return nil }
            let pid = table.value(row, "pid")?.number ?? process.child("pid")?.number
            guard let pid, let start = table.value(row, "start")?.number else { return nil }
            return ProcessRow(
                name: processName(process.fmt ?? process.text), pid: Int(pid), time: start / 1e9,
                cpuPercent: table.value(row, "cpu-percent")?.number,
                cpuSeconds: table.value(row, "cpu-total")?.number.map { $0 / 1e9 },
                footprintMB: table.value(row, "memory-physical-footprint")?.number.map { $0 / 1_048_576 })
        }
    }

    /// One app's readings as a sample. The average comes from the CPU time used between the first
    /// and the last reading, as on simulators; the peak is the highest interval's percent.
    static func sample(_ rows: [ProcessRow], pid: Int) -> PerformanceSample? {
        let own = rows.filter { $0.pid == pid }.sorted { $0.time < $1.time }
        guard let first = own.first else { return nil }
        let points = own.map { row in
            UsagePoint(time: row.time - first.time, cpu: row.cpuPercent, memoryMB: row.footprintMB ?? 0)
        }
        var average = 0.0
        if let last = own.last, let end = last.cpuSeconds, let start = first.cpuSeconds, last.time > first.time {
            average = max(end - start, 0) / (last.time - first.time) * 100
        } else {
            let percents = own.compactMap(\.cpuPercent)
            if !percents.isEmpty { average = percents.reduce(0, +) / Double(percents.count) }
        }
        return PerformanceSample(pid: pid, points: points, averageCPU: average, memoryKind: "physical footprint")
    }

    /// Every process at its newest reading, and the device's memory, load and thermal state.
    static func deviceLoad(
        processes: XctraceTable?, system: XctraceTable?, thermal: XctraceTable?, memoryBytes: Double?, seconds: Double
    ) -> DeviceLoad {
        var newest: [Int: ProcessRow] = [:]
        for row in processes.map(processRows) ?? [] {
            if let known = newest[row.pid], known.time > row.time { continue }
            // The first reading of a process has no percent yet; a later one replaces it.
            if let known = newest[row.pid], row.cpuPercent == nil, known.cpuPercent != nil { continue }
            newest[row.pid] = row
        }
        let list = newest.values.map { row in
            DeviceLoad.Process(name: row.name, pid: row.pid, cpuPercent: row.cpuPercent ?? 0, memoryMB: row.footprintMB ?? 0)
        }
        let systemRow = system?.rows.last
        let used = systemRow.flatMap { system?.value($0, "memory-physical-used")?.number }
        let load = systemRow.flatMap { system?.value($0, "cpu-total-load")?.number }
        let state = thermal?.rows.last.flatMap { thermal?.value($0, "thermal-state") }
        return DeviceLoad(
            processes: list, cpuPercent: load, memoryUsedMB: used.map { $0 / 1_048_576 },
            memoryTotalMB: memoryBytes.map { $0 / 1_048_576 }, thermalState: state.map { $0.fmt ?? $0.text },
            memoryKind: "physical footprint", seconds: seconds,
            source: "Instruments' Activity Monitor template over \(Int(seconds)) s")
    }
}

// MARK: - Summaries

/// A few lines about a trace that its export gives away cheaply: the heaviest functions of a Time
/// Profiler recording, hangs, hitches and leaks, an Activity Monitor recording's CPU and memory.
/// Anything that cannot be read is left out; the trace itself is what to look at.
enum TraceSummary {
    static func read(_ trace: URL, template: String, contents: TraceContents?, pid: Int?, xctrace: Xctrace) async -> [String] {
        let schemas = contents?.schemas ?? []
        var lines: [String] = []
        func table(_ schema: String) async -> XctraceTable? {
            guard schemas.contains(schema) else { return nil }
            return try? await xctrace.export(trace, schema: schema).first
        }
        if let profile = await table("time-profile") { lines += heaviest(profile, pid: pid) }
        if let hangs = await table("potential-hangs") { lines += count(hangs, pid: pid, one: "hang", many: "hangs", threshold: "potential") }
        for schema in schemas where schema.localizedCaseInsensitiveContains("hitch") && !schema.hasSuffix("-stats") {
            if let hitches = await table(schema) { lines += count(hitches, pid: pid, one: "hitch", many: "hitches", threshold: nil) }
            break
        }
        if let leaks = await table("leaks") { lines += count(leaks, pid: pid, one: "leaked allocation", many: "leaked allocations", threshold: nil) }
        if let live = await table("activity-monitor-process-live") {
            let rows = ActivityMonitor.processRows(live)
            if let pid, let sample = ActivityMonitor.sample(rows, pid: pid) {
                lines.append(
                    String(
                        format: "CPU: average %.1f%%, peak %.1f%% of one core; memory peak %.1f MB", sample.averageCPU,
                        sample.peakCPU, sample.peakMemoryMB))
            } else if pid == nil {
                let load = ActivityMonitor.deviceLoad(processes: live, system: nil, thermal: nil, memoryBytes: nil, seconds: 0)
                let busiest = load.top(byCPU: 5).map { String(format: "%@ %.1f%%", $0.name, $0.cpuPercent) }
                if !busiest.isEmpty { lines.append("Busiest processes: " + busiest.joined(separator: ", ")) }
            }
        }
        return lines
    }

    /// The functions most samples ended in (self time), with their share of the process's samples.
    static func heaviest(_ table: XctraceTable, pid: Int?, count: Int = 5) -> [String] {
        var weights: [String: Double] = [:]
        var total = 0.0
        for row in table.rows {
            if let pid, let process = table.value(row, "process"), let owner = process.child("pid")?.number, Int(owner) != pid {
                continue
            }
            let weight = table.value(row, "weight")?.number ?? 1
            total += weight
            guard let stack = table.value(row, "stack"), let leaf = stack.children.first(where: { $0.tag == "frame" }) else {
                continue
            }
            var name = leaf.attributes["name"] ?? leaf.attributes["addr"] ?? "?"
            if let binary = leaf.child("binary")?.attributes["name"] { name += " (\(binary))" }
            weights[name, default: 0] += weight
        }
        guard total > 0, !weights.isEmpty else { return [] }
        let top = weights.sorted { $0.value > $1.value }.prefix(count).map { name, weight in
            String(format: "%.1f%% %@", weight / total * 100, String(name.prefix(160)))
        }
        let samples = Int((total / 1_000_000).rounded())
        return ["Heaviest functions (self time, \(samples) ms of samples):"] + top.map { "  " + $0 }
    }

    /// "3 potential hangs" in the process, or across the trace.
    static func count(_ table: XctraceTable, pid: Int?, one: String, many: String, threshold: String?) -> [String] {
        let rows = table.rows.filter { row in
            guard let pid, let process = table.value(row, "process") else { return true }
            return (process.child("pid")?.number).map { Int($0) == pid } ?? true
        }
        let words = rows.count == 1 ? one : many
        return ["\(rows.count) \(threshold.map { "\($0) " } ?? "")\(words)"]
    }
}
