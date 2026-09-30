import Foundation

/// A crash or hang report file in the phone's crash log folder.
public struct CrashReportFile: Sendable, Equatable {
    /// The path inside the crash log folder, e.g. "MyApp-2026-09-29-173246.ips".
    public var name: String
    /// The process the report is about, e.g. "MyApp" or "UIKit-runloop-MyApp" for a hang.
    public var process: String
    public var date: Date?
    public var size: Int

    public init(name: String, process: String, date: Date?, size: Int) {
        self.name = name
        self.process = process
        self.date = date
        self.size = size
    }

    /// "MyApp-2026-09-29-173246.ips" → "MyApp". Resource reports (".cpu_resource-…") are not crashes: nil.
    static func process(fromName name: String) -> String? {
        let file = name.split(separator: "/").last.map(String.init) ?? name
        guard file.hasSuffix(".ips"), !file.contains("_resource-") else { return nil }
        let stem = file.dropLast(4)
        // The date suffix is "-YYYY-MM-DD-HHMMSS": 18 characters.
        guard stem.count > 18 else { return String(stem) }
        let process = stem.dropLast(18)
        let suffix = stem.suffix(18)
        guard suffix.first == "-", suffix.dropFirst().allSatisfy({ $0.isNumber || $0 == "-" }) else { return String(stem) }
        return String(process)
    }
}

/// What an agent needs from an iOS crash report (.ips): what crashed, why, and where.
public struct CrashReport: Sendable, Equatable {
    public var app: String
    public var bundleID: String
    public var version: String
    public var date: String
    public var osVersion: String
    /// e.g. "EXC_BREAKPOINT (SIGTRAP)".
    public var exception: String?
    /// The termination reason and any messages the app left, e.g. "Fatal error: Index out of range".
    public var reasons: [String]
    /// The crashed thread (or the uncaught exception's backtrace), top first.
    public var frames: [String]

    /// Parses the JSON header line and body of an .ips file. Returns nil for anything else.
    public static func parse(_ text: String) -> CrashReport? {
        let parts = text.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
            let header = try? JSONValue.parse(Data(parts[0].utf8)),
            let body = try? JSONValue.parse(Data(parts[1].utf8))
        else { return nil }

        // System events such as SystemMemoryReset or JetsamEvent name no app.
        var report = CrashReport(
            app: header["app_name"]?.stringValue ?? header["name"]?.stringValue ?? body["procName"]?.stringValue
                ?? "System report (bug type \(header["bug_type"]?.stringValue ?? "unknown"))",
            bundleID: header["bundleID"]?.stringValue ?? "",
            version: [header["app_version"]?.stringValue, header["build_version"]?.stringValue.map { "(\($0))" }]
                .compactMap { $0 }.joined(separator: " "),
            date: header["timestamp"]?.stringValue ?? "",
            osVersion: header["os_version"]?.stringValue ?? "",
            exception: nil, reasons: [], frames: [])

        if let exception = body["exception"], let type = exception["type"]?.stringValue {
            var text = type
            if let signal = exception["signal"]?.stringValue { text += " (\(signal))" }
            if let subtype = exception["subtype"]?.stringValue { text += ", \(subtype)" }
            report.exception = text
        }
        if let termination = body["termination"] {
            let namespace = termination["namespace"]?.stringValue
            let indicator = termination["indicator"]?.stringValue
            let summary = [namespace.map { "Namespace \($0)" }, indicator].compactMap { $0 }.joined(separator: ", ")
            if !summary.isEmpty { report.reasons.append("Terminated: \(summary)") }
            for reason in termination["reasons"]?.arrayValue ?? [] {
                if let text = reason.stringValue { report.reasons.append(text) }
            }
        }
        if let reason = body["eventReason"]?.stringValue { report.reasons.append(reason) }
        if let largest = body["largestProcess"]?.stringValue { report.reasons.append("Largest process: \(largest)") }
        // Application Specific Information: fatalError(), precondition and abort() messages.
        for (_, messages) in body["asi"]?.objectValue?.sorted(by: { $0.key < $1.key }) ?? [] {
            for message in messages.arrayValue ?? [] {
                if let text = message.stringValue { report.reasons.append(text) }
            }
        }

        let images = body["usedImages"]?.arrayValue ?? []
        let threads = body["threads"]?.arrayValue ?? []
        let faulting = body["faultingThread"]?.doubleValue.map(Int.init)
        // An uncaught exception's backtrace says more than the thread that called abort().
        let frames =
            body["lastExceptionBacktrace"]?.arrayValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? faulting.flatMap { threads.indices.contains($0) ? threads[$0]["frames"]?.arrayValue : nil }
            ?? threads.first { $0["triggered"]?.boolValue == true }?["frames"]?.arrayValue
            ?? []
        report.frames = frames.prefix(30).enumerated().map { index, frame in
            describe(frame, index: index, images: images)
        }
        return report
    }

    /// "3  MyApp  0x0000000102a4f2c4  closure #2 in ContentView.body + 124". Without a symbol, the
    /// offset and the image's load address, which `atos -l <load address> <address>` needs.
    private static func describe(_ frame: JSONValue, index: Int, images: [JSONValue]) -> String {
        let imageIndex = frame["imageIndex"]?.doubleValue.map(Int.init) ?? -1
        let image = images.indices.contains(imageIndex) ? images[imageIndex] : nil
        let name = image?["name"]?.stringValue ?? "???"
        let offset = UInt64(max(0, frame["imageOffset"]?.doubleValue ?? 0))
        let base = UInt64(max(0, image?["base"]?.doubleValue ?? 0))
        var line = "\(index)  \(name)  " + String(format: "0x%016llx", base &+ offset)
        if let symbol = frame["symbol"]?.stringValue {
            line += "  \(symbol)"
            if let location = frame["symbolLocation"]?.doubleValue { line += " + \(Int(location))" }
        } else {
            line += "  (\(name) + \(offset), loaded at " + String(format: "0x%llx", base) + ")"
        }
        return line
    }

    public var summary: String {
        func join(_ parts: [String], _ separator: String) -> String {
            parts.filter { !$0.isEmpty }.joined(separator: separator)
        }
        var lines = [join([join([app, version], " "), bundleID], ", "), join([date, osVersion], ", ")]
        if let exception { lines.append("Exception: \(exception)") }
        lines += reasons
        if !frames.isEmpty {
            lines.append("Crashed thread:")
            lines += frames
        }
        return lines.joined(separator: "\n")
    }

    public var json: JSONValue {
        [
            "app": .string(app), "bundle_id": .string(bundleID), "version": .string(version), "date": .string(date),
            "os_version": .string(osVersion), "exception": exception.map(JSONValue.string) ?? .null,
            "reasons": .array(reasons.map(JSONValue.string)), "frames": .array(frames.map(JSONValue.string)),
        ]
    }
}
