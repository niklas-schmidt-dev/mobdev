import AppKit
import ImageIO
import MobdevCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The parts of a project in the sidebar, each a view of its own.
enum ProjectSection: String, CaseIterable, Identifiable {
    case overview, tests, flows, screenshots, map, recordings, runs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .tests: "Tests"
        case .flows: "Flows"
        case .screenshots: "Screenshots"
        case .map: "App Map"
        case .recordings: "Recordings"
        case .runs: "Runs"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tests: "checklist"
        case .flows: "point.topleft.down.to.point.bottomright.curvepath"
        case .screenshots: "photo.on.rectangle"
        case .map: "map"
        case .recordings: "video"
        case .runs: "clock.arrow.circlepath"
        }
    }
}

/// What a project holds on disk, read for its views. Everything is optional: a folder appears when
/// something is first saved there.
struct ProjectFiles {
    let folder: URL

    private func files(in relative: String, extensions: Set<String>, recursive: Bool = false) -> [URL] {
        let base = folder.appendingPathComponent(relative, isDirectory: true)
        let manager = FileManager.default
        if recursive {
            guard let walker = manager.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return [] }
            return walker.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return ((try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var flows: [URL] { files(in: TestProject.flowsFolderName, extensions: ["json", "yaml", "yml"]) }
    var screenshots: [URL] { files(in: TestProject.screenshotsFolderName, extensions: ["png", "jpg", "jpeg"], recursive: true) }
    var baselines: [URL] {
        files(in: TestProject.baselinesFolderName, extensions: ["png"], recursive: true)
            .filter { !$0.lastPathComponent.hasSuffix("-diff.png") && !$0.lastPathComponent.hasSuffix("-actual.png") }
    }

    /// Recordings and the videos of flows run from the app, newest first.
    var recordings: [URL] {
        let output = "\(TestProject.outputFolderName)/"
        return (files(in: output + ProjectOutput.recordings.rawValue, extensions: ["mp4", "mov"])
            + files(in: output + ProjectOutput.flowVideos.rawValue, extensions: ["mp4", "mov"]))
            .sorted { Self.modified($0) > Self.modified($1) }
    }

    /// Crawl folders, newest first.
    var crawls: [URL] {
        let base = folder.appendingPathComponent("\(TestProject.outputFolderName)/\(ProjectOutput.crawls.rawValue)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The maps crawl_app saved, one per app.
    var maps: [(file: URL, map: AppMap)] {
        files(in: TestProject.mapsFolderName, extensions: ["json"]).compactMap { file in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: file), let map = try? decoder.decode(AppMap.self, from: data) else { return nil }
            return (file, map)
        }
    }

    /// A map's crawl folder, where its screenshots are.
    func crawlFolder(of map: AppMap) -> URL? {
        guard let crawl = map.crawl else { return nil }
        return crawl.hasPrefix("/") ? URL(fileURLWithPath: crawl, isDirectory: true) : folder.appendingPathComponent(crawl, isDirectory: true)
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// "screenshots/de-DE/iphone-6.9" for a file in it, relative to the project.
    func group(of file: URL) -> String {
        let parent = ProjectList.normalized(file.deletingLastPathComponent()).path
        let base = ProjectList.normalized(folder).path
        return parent.hasPrefix(base + "/") ? String(parent.dropFirst(base.count + 1)) : parent
    }
}

// MARK: - Sidebar

/// One project in the sidebar: its row opens the overview and makes it active; the active project
/// shows its parts below.
struct ProjectSidebarRows: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var renaming = false

    private var isActive: Bool { model.isActiveProject(folder) }
    private var exists: Bool { TestProject.isProject(folder) }

    var body: some View {
        NavigationLink(value: Pane.project(folder.path, .overview)) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectName(folder)).lineLimit(1)
                    if !exists {
                        Text("Folder missing").font(.caption).foregroundStyle(.secondary)
                    } else if model.duplicateProjectName(folder) {
                        Text(folder.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                ProjectIconView(folder: folder, size: 16, active: isActive)
            }
            .opacity(exists ? 1 : 0.5)
        }
        .tag(Pane.project(folder.path, .overview))
        .accessibilityValue(isActive ? "Active project" : "")
        .modifier(ProjectRenameAlert(folder: folder, isPresented: $renaming))
        .contextMenu {
            Button("Rename…") { renaming = true }
                .disabled(!exists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                .disabled(!exists)
            Button("Open mobdev.json") { NSWorkspace.shared.open(folder.appendingPathComponent(TestProject.fileName)) }
                .disabled(!exists)
            Menu("Icon") { ProjectIconMenuItems(folder: folder) }
            Divider()
            Button("Remove from List") { model.removeProject(folder) }
        }
        if isActive && exists {
            ForEach(ProjectSection.allCases.dropFirst()) { section in
                NavigationLink(value: Pane.project(folder.path, section)) {
                    Label(section.title, systemImage: section.systemImage)
                        .padding(.leading, 14)
                }
                .badge(section == .tests && model.runningTests.contains(folder.path) ? Text("Running") : nil)
                .tag(Pane.project(folder.path, section))
            }
        }
    }
}

/// Rename… for a project: a field for its new name, which goes into its mobdev.json, so test
/// results and CI show it too.
struct ProjectRenameAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    let folder: URL
    @Binding var isPresented: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Project", isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name is saved in \(TestProject.fileName), so test results and CI show it too.")
            }
            .onChange(of: isPresented) { _, shown in
                if shown { name = model.projectName(folder) }
            }
    }

    private func rename() {
        do {
            try model.renameProject(folder, to: name)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Rename the Project"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }
}

/// New Project… and Open Project…, under the projects in the sidebar and in the File menu.
struct ProjectActions {
    /// Opens a project folder, or a repository with a mobdev/ folder, and shows it. A folder
    /// without a project, such as an app's repository, can get one right away.
    @MainActor static func open(_ model: AppModel, show: (Pane) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a project: a folder with mobdev.json, or the app's repository with a mobdev folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folder = try model.openProject(url)
            show(.project(folder.path, .overview))
        } catch {
            let alert = NSAlert()
            alert.messageText = "No Project in \(url.lastPathComponent)"
            alert.informativeText =
                "\(url.path) has no mobdev.json, and no mobdev folder with one. Create a project there to keep the app's tests, flows and screenshots with its code."
            alert.addButton(withTitle: "Create Project Here…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { model.showNewProject(in: url) }
        }
    }
}

// MARK: - Detail

/// A project's part, chosen in the sidebar.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    let section: ProjectSection

    var body: some View {
        Group {
            if !TestProject.isProject(folder) {
                ContentUnavailableView {
                    Label("Project Folder Missing", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("\(folder.path) has no mobdev.json any more. It may be on a disk that is not connected, or it was moved.")
                } actions: {
                    Button("Remove from List") { model.removeProject(folder) }
                }
            } else {
                switch section {
                case .overview: ProjectOverview(folder: folder)
                case .tests: ProjectTestsView(folder: folder)
                case .flows: ProjectFlowsView(folder: folder)
                case .screenshots: ProjectScreenshotsView(folder: folder)
                case .map: ProjectMapView(folder: folder)
                case .recordings: ProjectRecordingsView(folder: folder)
                case .runs: ProjectRunsView(folder: folder)
                }
            }
        }
        .navigationTitle(model.projectName(folder))
        .navigationSubtitle(section == .overview ? folder.path : section.title)
    }
}

/// Before any project exists: what a project is, and the two ways to get one.
struct NoProjectView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedPane") private var storedPane = Pane.overview.rawValue

    var body: some View {
        ContentUnavailableView {
            Label("No Project", systemImage: "folder.badge.plus")
        } description: {
            Text(
                "A project is a folder in your app's repository, usually mobdev/. It holds the app's tests, flows, screenshots and map, versioned with your code, and keeps runs and recordings in an ignored output folder. Agents save into it too."
            )
        } actions: {
            Button("New Project…") { model.showNewProject() }
                .buttonStyle(.glassProminent)
            Button("Open Project…") { ProjectActions.open(model) { storedPane = $0.rawValue } }
        }
        .navigationTitle("Projects")
    }
}

/// A device picker for a project's actions, in the content: the toolbar shows no picker titles.
/// It shows the chosen device while it is ready, else the first ready one, which is the device
/// `AppModel.readyDevice` gives the actions.
private struct DevicePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var deviceID: String

    var body: some View {
        let ready = model.devices.filter(\.isReady)
        Picker("Device", selection: Binding(get: { model.readyDevice(deviceID) ?? "" }, set: { deviceID = $0 })) {
            if ready.isEmpty { Text("No Device Ready").tag("") }
            ForEach(ready) { device in Text(device.name).tag(device.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

extension AppModel {
    /// The device chosen in a project's view while it is ready, else the first ready one.
    func readyDevice(_ id: String) -> String? {
        let ready = devices.filter(\.isReady)
        return (ready.first { $0.id == id } ?? ready.first)?.id
    }
}

// MARK: Overview

private struct ProjectOverview: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedPane") private var storedPane = Pane.overview.rawValue
    let folder: URL
    @State private var project: TestProject?
    @State private var stats: [ProjectSection: Stat] = [:]
    @State private var deviceID = ""
    @State private var crawling = false
    @State private var message: String?
    @State private var renaming = false

    /// A part of the project at a glance: how many there are, and one line on what stands out.
    struct Stat {
        var value: String
        var caption: String
        var tint: Color?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                ProjectGettingStarted(folder: folder, project: project, runTests: model.readyDevice(deviceID).map { _ in runAllTests })
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(ProjectSection.allCases.dropFirst()) { section in
                        tile(section)
                    }
                }
                actions
                ProjectAgentPrompts(folder: folder, project: project)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar { moreMenu }
        .modifier(ProjectRenameAlert(folder: folder, isPresented: $renaming))
        .task(id: "\(folder.path) \(model.projectRevision(folder)) \(model.testResults[folder.path]?.started.timeIntervalSince1970 ?? 0)") {
            load()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Menu {
                ProjectIconMenuItems(folder: folder)
            } label: {
                ProjectIconView(folder: folder, size: 64)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the project's icon")
            .accessibilityLabel("Project icon")
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project?.name ?? folder.lastPathComponent).font(.largeTitle.weight(.semibold))
                    if model.isActiveProject(folder) {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: .capsule)
                            .help("What agents and the app save without a path goes into this project")
                    }
                }
                Text(project?.app.bundleID ?? "No app in mobdev.json yet").font(.title3).foregroundStyle(.secondary)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout).foregroundStyle(.tertiary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The project's less frequent actions, in the toolbar as in Finder and Xcode.
    private var moreMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Rename…") { renaming = true }
                Menu("Icon") { ProjectIconMenuItems(folder: folder) }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Button("Open mobdev.json") { NSWorkspace.shared.open(folder.appendingPathComponent(TestProject.fileName)) }
                Divider()
                Button("Remove from List") { model.removeProject(folder) }
            } label: {
                Label("Project", systemImage: "ellipsis")
            }
            .help("Rename, icon, Finder and more")
        }
    }

    private func tile(_ section: ProjectSection) -> some View {
        let stat = stats[section] ?? Stat(value: "–", caption: " ")
        return Button { storedPane = Pane.project(folder.path, section).rawValue } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(section.title, systemImage: section.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(stat.value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(stat.caption)
                    .font(.callout)
                    .foregroundStyle(stat.tint ?? .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.title): \(stat.value), \(stat.caption)")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                DevicePicker(deviceID: $deviceID)
                Spacer()
                Button(crawling ? "Crawling…" : "Crawl App", systemImage: "map") { crawl() }
                    .buttonStyle(.glass)
                    .disabled(model.readyDevice(deviceID) == nil || project?.app.bundleID == nil || crawling)
                    .help(project?.app.bundleID == nil ? "Set the app's bundle_id in mobdev.json first" : "Explore the app by itself and map its screens")
                Button("Run Tests", systemImage: "play.fill", action: runAllTests)
                    .buttonStyle(.glassProminent)
                    .disabled(
                        model.readyDevice(deviceID) == nil || project?.tests.isEmpty != false || model.runningTests.contains(folder.path))
            }
            .controlSize(.large)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    /// Runs the project's tests on the chosen device and shows them.
    private func runAllTests() {
        guard let project, let device = model.readyDevice(deviceID) else { return }
        model.runTests(project, on: device)
        storedPane = Pane.project(folder.path, .tests).rawValue
    }

    private func crawl() {
        guard let bundleID = project?.app.bundleID, let device = model.readyDevice(deviceID) else { return }
        crawling = true
        message = "Crawling \(bundleID) for up to two minutes…"
        Task {
            let output = await model.run("crawl_app", on: device, ["bundle_id": .string(bundleID)])
            crawling = false
            message = output.text.split(separator: "\n").first.map(String.init)
            load()
        }
    }

    private func load() {
        project = try? TestProject.load(folder)
        let files = ProjectFiles(folder: folder)
        var stats: [ProjectSection: Stat] = [:]
        let tests = project?.tests.count ?? 0
        if let last = model.testResults[folder.path] ?? project.flatMap({ TestRuns.result(for: $0) }) {
            let (_, failed, _) = last.counts
            stats[.tests] = failed > 0
                ? Stat(value: "\(tests)", caption: "\(failed) failed in the last run", tint: .red)
                : Stat(value: "\(tests)", caption: "All passed in the last run", tint: .green)
        } else {
            stats[.tests] = Stat(value: "\(tests)", caption: tests == 0 ? "None yet" : "Not run yet")
        }
        let flows = files.flows.count
        stats[.flows] = Stat(value: "\(flows)", caption: flows == 0 ? "None yet" : "Ready to replay")
        let baselines = files.baselines.count
        stats[.screenshots] = Stat(value: "\(files.screenshots.count)", caption: Self.count(baselines, "baseline", "baselines"))
        let maps = files.maps
        let screens = maps.reduce(0) { $0 + $1.map.screens.count }
        let crashes = maps.reduce(0) { $0 + $1.map.crashes.count }
        stats[.map] = maps.isEmpty
            ? Stat(value: "–", caption: "Not crawled yet")
            : Stat(
                value: "\(screens)", caption: crashes > 0 ? Self.count(crashes, "crash", "crashes") : "\(screens == 1 ? "Screen" : "Screens"), no crashes",
                tint: crashes > 0 ? .red : nil)
        let recordings = files.recordings
        stats[.recordings] = Stat(
            value: "\(recordings.count)",
            caption: recordings.first.map { "Newest \(ProjectFiles.modified($0).relativeText)" } ?? "None yet")
        let runs = project.map { TestRuns.runs(for: $0).count } ?? 0
        stats[.runs] = Stat(value: "\(runs)", caption: Self.count(files.crawls.count, "crawl", "crawls"))
        self.stats = stats
    }

    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        number == 0 ? "No \(many)" : number == 1 ? "1 \(one)" : "\(number) \(many)"
    }
}

// MARK: Flows

private struct ProjectFlowsView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var flows: [URL] = []
    @State private var deviceID = ""
    @State private var running: URL?
    @State private var result: FlowRun?

    var body: some View {
        Group {
            if flows.isEmpty {
                ContentUnavailableView {
                    Label("No Flows Yet", systemImage: ProjectSection.flows.systemImage)
                } description: {
                    Text("Record a flow on a device (Record Flow in its activity) and save it, or let an agent save one with save_flow. Flows land in flows/ and replay with Run Flow, run_flow or Mobdev flow.")
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        DevicePicker(deviceID: $deviceID)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    List(flows, id: \.self) { flow in
                        ProjectRow(
                            systemImage: Self.isMaestro(flow) ? "doc.text" : "point.topleft.down.to.point.bottomright.curvepath",
                            title: flow.deletingPathExtension().lastPathComponent, subtitle: Self.subtitle(flow)
                        ) {
                            if running == flow {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Run", systemImage: "play.fill") { Task { await run(flow) } }
                                    .buttonStyle(.glass)
                                    .disabled(model.readyDevice(deviceID) == nil || running != nil)
                                    .help("Replay this flow on the device and keep a video")
                            }
                        }
                        .contextMenu {
                            Button("Run") { Task { await run(flow) } }.disabled(model.readyDevice(deviceID) == nil || running != nil)
                            Button("Open") { NSWorkspace.shared.open(flow) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([flow]) }
                        }
                    }
                }
            }
        }
        .task(id: "\(folder.path) \(model.projectRevision(folder))") { flows = ProjectFiles(folder: folder).flows }
        .sheet(item: $result) { run in
            FlowResultSheet(run: run) {
                result = nil
                Task { await self.run(run.file) }
            }
        }
    }

    static func isMaestro(_ url: URL) -> Bool { ["yaml", "yml"].contains(url.pathExtension.lowercased()) }

    /// "3 steps · Modified 2 hours ago", or that it is a Maestro flow.
    static func subtitle(_ flow: URL) -> String {
        let modified = "Modified \(ProjectFiles.modified(flow).relativeText)"
        if isMaestro(flow) { return "Maestro flow · \(modified)" }
        guard let steps = try? Flow.load(flow).steps.count else { return modified }
        return "\(steps == 1 ? "1 step" : "\(steps) steps") · \(modified)"
    }

    private func run(_ file: URL) async {
        guard let device = model.readyDevice(deviceID) else { return }
        running = file
        var arguments: [String: JSONValue] = ["path": .string(file.path)]
        let video = FlowVideos.newFile(for: file, project: folder)
        if let video { arguments["video"] = .string(video.path) }
        let output = await model.run("run_flow", on: device, arguments)
        running = nil
        result = FlowRun(
            file: file, text: output.text, passed: !output.isError,
            video: video.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }
}

// MARK: Screenshots

private struct ProjectScreenshotsView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var groups: [(section: String, title: String, files: [URL])] = []
    @State private var preview: URL?

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Screenshots Yet", systemImage: ProjectSection.screenshots.systemImage)
                } description: {
                    Text("save_screenshot saves the screen at full resolution into screenshots/, e.g. for App Store screenshots per language. assert_screenshot keeps its baselines in baselines/. Both are versioned with your code.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            VStack(alignment: .leading, spacing: 10) {
                                if index == 0 || groups[index - 1].section != group.section {
                                    Text(group.section).font(.title2.weight(.semibold))
                                        .padding(.top, index == 0 ? 0 : 10)
                                }
                                if !group.title.isEmpty {
                                    Text(group.title).font(.headline).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], spacing: 14) {
                                    ForEach(group.files, id: \.self) { file in
                                        Button { preview = file } label: {
                                            VStack(spacing: 4) {
                                                FileThumbnail(url: file).frame(height: 200)
                                                Text(file.deletingPathExtension().lastPathComponent)
                                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .quickLookPreview($preview)
        .task(id: "\(folder.path) \(model.projectRevision(folder))") { load() }
    }

    private func load() {
        let files = ProjectFiles(folder: folder)
        var groups: [(section: String, title: String, files: [URL])] = []
        for (section, list) in [("Screenshots", files.screenshots), ("Baselines", files.baselines)] where !list.isEmpty {
            let byFolder = Dictionary(grouping: list) { files.group(of: $0) }
            for key in byFolder.keys.sorted() {
                // "screenshots/de-DE/iphone-6.3" is shown as "de-DE · iphone-6.3" under Screenshots.
                let title = key.split(separator: "/").dropFirst().joined(separator: " · ")
                groups.append((section, title, byFolder[key] ?? []))
            }
        }
        self.groups = groups
    }
}

/// A picture file's thumbnail, made off the main thread.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
        }
        .task(id: url) {
            let url = url
            let data = await Task.detached { Self.thumbnail(url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }

    /// PNG data of a thumbnail at most 400 px on its long edge.
    nonisolated static func thumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
        else { return nil }
        return ImageTools.encode(thumb, png: true)?.data
    }
}

// MARK: App map

private struct ProjectMapView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var maps: [(file: URL, map: AppMap)] = []
    @State private var preview: URL?
    @State private var saved: String?

    var body: some View {
        Group {
            if maps.isEmpty {
                ContentUnavailableView {
                    Label("No App Map Yet", systemImage: ProjectSection.map.systemImage)
                } description: {
                    Text("crawl_app explores the app by itself and maps its screens into maps/; navigate_to then goes straight to a screen. Start one with Crawl App in the overview, or let an agent call crawl_app.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(maps, id: \.file) { entry in mapSection(entry.map) }
                        if let saved { Text(saved).font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .quickLookPreview($preview)
        .task(id: "\(folder.path) \(model.projectRevision(folder))") { maps = ProjectFiles(folder: folder).maps }
    }

    @ViewBuilder private func mapSection(_ map: AppMap) -> some View {
        let crawl = ProjectFiles(folder: folder).crawlFolder(of: map)
        VStack(alignment: .leading, spacing: 10) {
            Text(map.app).font(.title3.weight(.semibold))
            Text("\(ProjectOverview.count(map.screens.count, "screen", "screens")), \(ProjectOverview.count(map.actions, "tap", "taps")), \(ProjectOverview.count(map.crashes.count, "crash", "crashes")) on \(map.device), \(map.started.shortText). \(map.ended)")
                .font(.callout).foregroundStyle(.secondary)
            if !map.crashes.isEmpty {
                ForEach(Array(map.crashes.enumerated()), id: \.offset) { index, crash in
                    HStack {
                        Label(crash.status, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                        Spacer()
                        if let flow = crash.flow, let crawl {
                            Button("Save Flow to flows/") { saveCrashFlow(crawl.appendingPathComponent(flow), app: map.app, index: index) }
                                .help("Keep the steps that crash the app as a flow, to replay after a fix")
                        }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 14)], spacing: 14) {
                ForEach(map.screens, id: \.id) { screen in
                    VStack(spacing: 4) {
                        if let crawl, let shot = screen.screenshot {
                            let file = crawl.appendingPathComponent(shot)
                            Button { preview = file } label: { FileThumbnail(url: file).frame(height: 190) }
                                .buttonStyle(.plain)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 190)
                        }
                        Text(screen.title.isEmpty ? screen.id : screen.title).font(.caption).lineLimit(1)
                    }
                    .help("\(screen.id), \(screen.depth) taps from launch")
                }
            }
        }
    }

    private func saveCrashFlow(_ file: URL, app: String, index: Int) {
        let flows = folder.appendingPathComponent(TestProject.flowsFolderName, isDirectory: true)
        let target = flows.appendingPathComponent("crash-\(TestProject.slug(app))-\(index + 1).json")
        do {
            try FileManager.default.createDirectory(at: flows, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: file, to: target)
            saved = "Saved \(target.path)."
        } catch {
            saved = "Could not save the flow: \(error.localizedDescription)"
        }
    }
}

// MARK: Recordings

private struct ProjectRecordingsView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var recordings: [URL] = []

    var body: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings Yet", systemImage: ProjectSection.recordings.systemImage)
                } description: {
                    Text("start_recording and stop_recording keep a video of the screen in output/recordings, and Run Flow keeps one of each run. The output folder is not versioned.")
                }
            } else {
                List(recordings, id: \.self) { video in
                    ProjectRow(
                        systemImage: "film", title: video.deletingPathExtension().lastPathComponent,
                        subtitle: "\(ProjectFiles.modified(video).shortText) · \(Self.size(video))"
                    ) {
                        Button("Play", systemImage: "play.fill") { FlowVideos.play(video) }
                            .buttonStyle(.glass)
                            .help("Play in QuickTime Player")
                    }
                    .contextMenu {
                        Button("Play") { FlowVideos.play(video) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video]) }
                    }
                }
            }
        }
        .task(id: "\(folder.path) \(model.projectRevision(folder))") { recordings = ProjectFiles(folder: folder).recordings }
    }

    static func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: Runs

private struct ProjectRunsView: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var runs: [(folder: URL, result: TestRunResult?)] = []
    @State private var crawls: [(folder: URL, map: AppMap?)] = []

    var body: some View {
        Group {
            if runs.isEmpty && crawls.isEmpty {
                ContentUnavailableView {
                    Label("No Runs Yet", systemImage: ProjectSection.runs.systemImage)
                } description: {
                    Text("Test runs from the app and run_tests, and crawls, keep their results, videos and screenshots in output/. The newest 20 runs and 10 crawls stay.")
                }
            } else {
                List {
                    if !runs.isEmpty {
                        Section("Test Runs") {
                            ForEach(runs, id: \.folder) { run in
                                runRow(run.folder, run.result)
                            }
                        }
                    }
                    if !crawls.isEmpty {
                        Section("Crawls") {
                            ForEach(crawls, id: \.folder) { crawl in
                                crawlRow(crawl.folder, crawl.map)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(folder.path) \(model.projectRevision(folder)) \(model.runningTests.contains(folder.path))") { load() }
    }

    private func runRow(_ run: URL, _ result: TestRunResult?) -> some View {
        let (passed, failed, skipped) = result?.counts ?? (0, 0, 0)
        var parts = ["\(passed) passed"]
        if failed > 0 { parts.append("\(failed) failed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let subtitle = result.map {
            "\($0.device.name) · \($0.started.shortText) · \(String(format: "%.1f", $0.seconds)) s"
        } ?? run.lastPathComponent
        return ProjectRow(
            systemImage: result == nil ? "questionmark.circle" : result?.passed == true ? "checkmark.circle.fill" : "xmark.circle.fill",
            tint: result == nil ? .secondary : result?.passed == true ? .green : .red,
            title: result == nil ? "No results" : parts.joined(separator: ", "), subtitle: subtitle
        ) {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([run]) }
                .buttonStyle(.borderless).labelStyle(.iconOnly)
                .help("Show the run's results, videos and screenshots in Finder")
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([run]) }
        }
    }

    private func crawlRow(_ crawl: URL, _ map: AppMap?) -> some View {
        let crashes = map?.crashes.count ?? 0
        let title = map.map {
            "\(ProjectOverview.count($0.screens.count, "screen", "screens")), \(crashes == 0 ? "no crashes" : crashes == 1 ? "1 crash" : "\(crashes) crashes")"
        }
            ?? crawl.lastPathComponent
        let subtitle = [map?.app, ProjectFiles.modified(crawl).shortText].compactMap { $0 }
            .joined(separator: " · ")
        return ProjectRow(systemImage: "map", tint: crashes > 0 ? .red : .accentColor, title: title, subtitle: subtitle) {
            Button("Report", systemImage: "doc.text") { NSWorkspace.shared.open(crawl.appendingPathComponent("report.md")) }
                .buttonStyle(.borderless).labelStyle(.iconOnly)
                .help("Open the crawl's report")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([crawl]) }
                .buttonStyle(.borderless).labelStyle(.iconOnly)
                .help("Show the crawl's screenshots and flows in Finder")
        }
        .contextMenu {
            Button("Open Report") { NSWorkspace.shared.open(crawl.appendingPathComponent("report.md")) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([crawl]) }
        }
    }

    private func load() {
        if let project = try? TestProject.load(folder) {
            runs = TestRuns.runs(for: project).map { ($0, try? TestRunResult.load($0)) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        crawls = ProjectFiles(folder: folder).crawls.map { folder in
            (folder, (try? Data(contentsOf: folder.appendingPathComponent("crawl.json"))).flatMap { try? decoder.decode(AppMap.self, from: $0) })
        }
    }
}

/// A row of a project's list, as Finder and Xcode's organizer show files: an icon, a title, a
/// line below it, and the row's actions at its end.
struct ProjectRow<Trailing: View>: View {
    let systemImage: String
    var tint: Color = .accentColor
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 5)
    }
}

// MARK: - New project

/// Creates a project in a repository: the folder (usually mobdev/) with its mobdev.json.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: (URL) -> Void
    @State private var repository: URL?
    @State private var folderName = TestProject.defaultFolderName
    @State private var name = ""
    @State private var bundleID = ""
    @State private var problem: String?
    /// Bundle IDs and package names the repository declares, the likeliest first.
    @State private var found: [AppIdentifiers.Found] = []
    @State private var searching = false

    private var target: URL? {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard let repository, !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        return repository.appendingPathComponent(trimmed, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Repository") {
                        HStack {
                            Text(repository?.path ?? "None chosen").foregroundStyle(repository == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.head)
                            Button("Choose…") { choose() }
                        }
                    }
                    TextField("Folder", text: $folderName, prompt: Text(TestProject.defaultFolderName))
                    TextField("Name", text: $name, prompt: Text(repository?.lastPathComponent ?? "My App"))
                    LabeledContent("Bundle ID") {
                        HStack(spacing: 6) {
                            TextField("Bundle ID", text: $bundleID, prompt: Text(searching ? "Looking in the repository…" : "com.example.MyApp (optional)"))
                                .labelsHidden()
                            if !found.isEmpty {
                                Menu {
                                    ForEach(found, id: \.id) { item in
                                        Button("\(item.id) – \(item.platforms.joined(separator: ", "))") { bundleID = item.id }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Bundle IDs and package names found in the repository")
                                .accessibilityLabel("Found bundle IDs")
                            }
                        }
                    }
                } header: {
                    Text("New Project")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let origin = bundleIDOrigin { Text(origin) }
                        Text(
                            target.map { "Creates \($0.appendingPathComponent(TestProject.fileName).path). Tests, flows, screenshots and the app map go next to it and are versioned with your code; runs and recordings go to an ignored output folder." }
                                ?? "Choose the app's repository. The project goes into a folder in it, usually mobdev."
                        )
                    }
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .task(id: repository) { await findBundleIDs() }
            .onAppear {
                if let start = model.newProjectRepository {
                    repository = start
                    model.newProjectRepository = nil
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose your app's repository. The project is created in a folder inside it."
        if panel.runModal() == .OK { repository = panel.url }
    }

    /// Where the bundle ID in the field comes from, when the repository declares it: "The bundle ID
    /// of iOS and Android in apps/mobile/app.json."
    private var bundleIDOrigin: String? {
        guard let item = found.first(where: { $0.id == bundleID.trimmingCharacters(in: .whitespaces) }),
            let source = item.sources.first, let colon = source.firstIndex(of: ":")
        else { return nil }
        let path = source[source.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // The app is in English, so not ListFormatter, which follows the Mac's language.
        let platforms = item.platforms.count > 1
            ? item.platforms.dropLast().joined(separator: ", ") + " and " + (item.platforms.last ?? "")
            : item.platforms.joined()
        return "The bundle ID of \(platforms) in \(path)" + (found.count > 1 ? "; the menu has \(found.count - 1) more found in the repository." : ".")
    }

    /// Fills in the likeliest bundle ID of the chosen repository, unless one was typed.
    private func findBundleIDs() async {
        found = []
        guard let repository else { return }
        searching = true
        let result = await Task.detached(priority: .userInitiated) { AppIdentifiers.find(in: repository) }.value
        searching = false
        guard repository == self.repository else { return }
        found = result
        if bundleID.trimmingCharacters(in: .whitespaces).isEmpty, let first = result.first { bundleID = first.id }
    }

    private func create() {
        guard let target else { return }
        do {
            let folder = try model.createProject(
                in: target, name: name.trimmingCharacters(in: .whitespaces), bundleID: bundleID.trimmingCharacters(in: .whitespaces))
            dismiss()
            created(folder)
        } catch {
            problem = String(describing: error)
        }
    }
}
