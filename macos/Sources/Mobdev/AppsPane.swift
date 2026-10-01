import AppKit
import MobdevCore
import SwiftUI
import UniformTypeIdentifiers

/// An app on the device as the Apps tab lists it, from `list_apps`.
struct DeviceApp: Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let developer: Bool

    init?(_ json: JSONValue) {
        guard let bundleID = json["bundle_id"]?.stringValue else { return nil }
        id = bundleID
        name = json["name"]?.stringValue ?? bundleID
        let parts = [json["version"]?.stringValue, json["build"]?.stringValue.map { "(\($0))" }]
        version = parts.compactMap { $0 }.filter { !$0.isEmpty && $0 != "()" }.joined(separator: " ")
        developer = json["developer"]?.boolValue ?? false
    }
}

/// The device's apps for the person at the Mac: install a build, launch, stop or remove apps,
/// open a link, and follow an app's output and crash reports. It runs the same tools agents use.
struct AppsPane: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var apps: [DeviceApp] = []
    @State private var showAll = false
    @State private var loading = false
    @State private var message: (text: String, failed: Bool)?
    @State private var link = ""
    @State private var selected: DeviceApp?
    @State private var dropping = false

    var body: some View {
        Group {
            if let selected {
                AppDetail(id: id, app: selected, back: { self.selected = nil }, report: report, reload: reload)
            } else {
                list
            }
        }
        .task(id: "\(id)-\(showAll)") { await reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apps").font(.headline)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Install…", systemImage: "arrow.down.app") { chooseBuild() }
                    .help("Install a build from this Mac. You can also drop it here.")
            }
            HStack {
                TextField("Deep link, e.g. myapp://settings", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openLink)
                Button("Open", action: openLink).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Show all apps", isOn: $showAll)
                .toggleStyle(.checkbox)
                .help("Include App Store and system apps, not only builds you installed.")
            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.failed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if apps.isEmpty, !loading, message == nil {
                Text("No apps installed for development yet. Drop a build here or click Install….")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
            List(apps) { app in
                Button { selected = app } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).lineLimit(1)
                            Text([app.id, app.version].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .contextMenu {
                    Button("Launch") { Task { await report(model.run("launch_app", on: id, ["bundle_id": .string(app.id)])) } }
                    Button("Stop") { Task { await report(model.run("stop_app", on: id, ["bundle_id": .string(app.id)])) } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(16)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            install(url)
            return true
        } isTargeted: { dropping = $0 }
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        let output = await model.run("list_apps", on: id, showAll ? ["all": true] : [:])
        loading = false
        apps = (output.data?.arrayValue ?? []).compactMap(DeviceApp.init)
        message = output.isError ? (output.text, true) : nil
    }

    private func report(_ output: ToolOutput) {
        message = (output.text, output.isError)
    }

    private func openLink() {
        let url = link.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        Task { report(await model.run("open_url", on: id, ["url": .string(url)])) }
    }

    private func install(_ url: URL) {
        message = ("Installing \(url.lastPathComponent)…", false)
        Task {
            let output = await model.run("install_app", on: id, ["path": .string(url.path)])
            report(output)
            if !output.isError { await reload() ; report(output) }
        }
    }

    /// An open panel for the builds this kind of device takes.
    private func chooseBuild() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        let kind = model.state(id)?.kind ?? .iPhone
        var types: [UTType] = []
        switch kind {
        case .iPhone:
            types = [.applicationBundle] + [UTType(filenameExtension: "ipa")].compactMap { $0 }
            panel.message = "Choose an .app or .ipa built for iPhone (Debug-iphoneos)."
        case .simulator:
            types = [.applicationBundle]
            panel.message = "Choose an .app built for the simulator (Debug-iphonesimulator)."
        case .android:
            types = [UTType(filenameExtension: "apk")].compactMap { $0 }
            panel.message = "Choose an .apk."
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }
}

/// One app: launch and stop it, its live output, and its crash reports.
private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let id: String
    let app: DeviceApp
    let back: () -> Void
    let report: (ToolOutput) -> Void
    let reload: () async -> Void
    @State private var lines: [String] = []
    @State private var status: String?
    @State private var filter = ""
    @State private var crashes: [(name: String, date: String)] = []
    @State private var crash: (text: String, file: String?)?
    @State private var confirmRemove = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Apps", systemImage: "chevron.left", action: back)
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text([app.id, app.version].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Launch", systemImage: "play.fill") { act("launch_app") }
                Button("Stop", systemImage: "stop.fill") { act("stop_app") }
                Spacer()
                if app.developer {
                    Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = true }
                        .labelStyle(.iconOnly)
                        .help("Remove the app and its data")
                }
            }
            .disabled(busy)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(status ?? "Launch the app here to follow its output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            console
            if !crashes.isEmpty {
                Text("Crash Reports").font(.subheadline.weight(.semibold))
                ForEach(crashes.prefix(5), id: \.name) { entry in
                    Button { open(entry.name) } label: {
                        Label(entry.date.isEmpty ? entry.name : entry.date, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .task(id: app.id) { await follow() }
        .task(id: app.id) { await loadCrashes() }
        .confirmationDialog("Remove \(app.name) and its data?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    let output = await model.run("uninstall_app", on: id, ["bundle_id": .string(app.id)])
                    report(output)
                    if !output.isError {
                        back()
                        await reload()
                        report(output)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { crash != nil }, set: { if !$0 { crash = nil } })) {
            CrashSheet(text: crash?.text ?? "", file: crash?.file) { crash = nil }
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.18), in: .rect(cornerRadius: 10))
            .onChange(of: shown.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private var shown: [String] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private var statusColor: Color {
        guard let status else { return .secondary }
        if status == "running" { return .green }
        return status.hasPrefix("crashed") ? .red : .orange
    }

    private func act(_ tool: String) {
        busy = true
        Task {
            report(await model.run(tool, on: id, ["bundle_id": .string(app.id)]))
            busy = false
            if tool == "launch_app" { lines = [] }
        }
    }

    /// Reads the captured output straight from the device, twice a second, without adding an
    /// activity entry for every look.
    private func follow() async {
        var cursor = 0
        while !Task.isCancelled {
            if let logs = model.device(id)?.apps?.logs {
                let page = logs.read(app: app.id, after: cursor, limit: 2000, contains: nil)
                if !page.lines.isEmpty {
                    lines.append(contentsOf: page.lines.map(\.text))
                    if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
                }
                cursor = page.cursor
                let current = logs.status(for: app.id)
                if current != status {
                    status = current
                    if current?.hasPrefix("crashed") == true {
                        try? await Task.sleep(for: .seconds(3))
                        await loadCrashes()
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func loadCrashes() async {
        let output = await model.run("crash_reports", on: id, ["app": .string(app.id), "limit": 5])
        crashes = (output.data?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return (name, entry["date"]?.stringValue ?? "")
        }
    }

    private func open(_ name: String) {
        Task {
            let output = await model.run("crash_reports", on: id, ["name": .string(name)])
            crash = (output.text, output.data?["file"]?.stringValue)
        }
    }
}

/// A crash report's summary: exception, reason and crashed thread.
private struct CrashSheet: View {
    let text: String
    let file: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crash Report").font(.title2.weight(.semibold))
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let file {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                    }
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
