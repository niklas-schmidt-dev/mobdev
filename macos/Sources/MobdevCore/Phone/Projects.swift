import Foundation

/// What a project produces that is not versioned with it, each in its own folder under
/// `output/`: test runs, screen recordings, crawls, the files of failed screenshot checks and the
/// videos of flows run from the app.
public enum ProjectOutput: String, Sendable, CaseIterable {
    case runs, recordings, crawls, checks
    case flowVideos = "flow-videos"
}

/// A project is a folder in the app's repository with a mobdev.json:
///
///     mobdev/
///       mobdev.json      the app, its builds and what every test starts with
///       tests/           tests, versioned
///       flows/           saved flows, versioned
///       baselines/       assert_screenshot's reference pictures, versioned
///       screenshots/     save_screenshot's pictures, such as store screenshots, versioned
///       maps/            crawl_app's map of each app, versioned
///       output/          runs, recordings, crawls and check files; ignored by its own .gitignore
///
/// Only mobdev.json makes a folder a project; every other folder appears when something is
/// saved there, and `output/` only when the first output is written, never by reading.
extension TestProject {
    public static let flowsFolderName = "flows"
    public static let baselinesFolderName = "baselines"
    public static let screenshotsFolderName = "screenshots"
    public static let mapsFolderName = "maps"
    public static let outputFolderName = "output"
    /// The folder `create_project` makes inside a repository.
    public static let defaultFolderName = "mobdev"

    /// A folder with a mobdev.json.
    public static func isProject(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    /// The nearest folder at or above `url` that is a project, stopping at a repository's root.
    public static func enclosingProject(of url: URL) -> URL? {
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        var folder = exists && isFolder.boolValue ? url : url.deletingLastPathComponent()
        while folder.path != "/" {
            if isProject(folder) { return ProjectList.normalized(folder) }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return nil }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// The project an agent working in `folder` means: the project the folder lies in, else a
    /// mobdev/ project next to it or in a folder above, up to the repository's root. So an agent
    /// in apps/ios of a repository with mobdev/ at its root finds that project.
    public static func project(forWorkingFolder folder: URL) -> URL? {
        var folder = folder.standardizedFileURL
        while folder.path != "/" {
            if isProject(folder) { return ProjectList.normalized(folder) }
            let nested = folder.appendingPathComponent(defaultFolderName, isDirectory: true)
            if isProject(nested) { return ProjectList.normalized(nested) }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return nil }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// Writes mobdev.json into `folder`, creating the folder in an existing parent. Refuses a
    /// folder that already is a project.
    public static func create(at folder: URL, name: String?, bundleID: String?, builds: [String: String] = [:]) throws
        -> TestProject
    {
        let files = FileManager.default
        let file = folder.appendingPathComponent(fileName)
        guard !files.fileExists(atPath: file.path) else {
            throw ToolFailure("\(folder.path) already is a project. Open it with open_project.")
        }
        let parent = folder.deletingLastPathComponent()
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ToolFailure("\(parent.path) does not exist. Create the project inside an existing folder, such as the app's repository.")
        }
        if files.fileExists(atPath: folder.path, isDirectory: &isFolder), !isFolder.boolValue {
            throw ToolFailure("\(folder.path) is a file, not a folder.")
        }
        for platform in builds.keys where !buildPlatforms.contains(platform) {
            throw ToolFailure("builds takes \(buildPlatforms.joined(separator: ", ")), not \(platform).")
        }
        // "mobdev" says nothing about the app; the repository's folder usually does.
        let fallback = folder.lastPathComponent == defaultFolderName ? parent.lastPathComponent : folder.lastPathComponent
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = TestProject(
            folder: folder, name: trimmed.isEmpty ? fallback : trimmed,
            app: App(bundleID: bundleID.flatMap { $0.isEmpty ? nil : $0 }, builds: builds))
        do {
            try files.createDirectory(at: folder.appendingPathComponent(testsFolderName, isDirectory: true), withIntermediateDirectories: true)
            try project.encoded().write(to: file, options: .withoutOverwriting)
        } catch {
            throw ToolFailure("Could not create \(file.path): \(error.localizedDescription)")
        }
        return try load(folder)
    }

    /// Gives a project another name. Only the name in its mobdev.json changes: the rest of the file
    /// stays as it is written, and a file without a name gets one at the top.
    @discardableResult
    public static func rename(_ folder: URL, to name: String) throws -> TestProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolFailure("A project needs a name.") }
        guard trimmed.count <= 200 else { throw ToolFailure("A project's name has at most 200 characters.") }
        let file = folder.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ToolFailure("Could not read \(file.path).")
        }
        _ = try load(folder)
        let value = JSONValue.string(trimmed).compactString
        var updated = text
        if let range = topLevelValue(of: "name", in: text) {
            updated.replaceSubrange(range, with: value)
        } else if let brace = text.firstIndex(of: "{") {
            let rest = text[text.index(after: brace)...]
            let empty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
            let lines = text.contains("\n")
            updated = String(text[...brace]) + (lines ? "\n  " : "") + "\"name\": \(value)" + (empty ? (lines ? "\n" : "") : ",") + rest
        }
        do {
            try Data(updated.utf8).write(to: file, options: .atomic)
            let project = try load(folder)
            guard project.name == trimmed else { throw ToolFailure("\(fileName) did not take the new name.") }
            return project
        } catch {
            try? Data(text.utf8).write(to: file, options: .atomic)
            throw error as? ToolFailure ?? ToolFailure("Could not write \(file.path): \(error.localizedDescription)")
        }
    }

    /// Where the value of a key of the outermost object is in a JSON text; nil without the key.
    static func topLevelValue(of key: String, in text: String) -> Range<String.Index>? {
        var depth = 0
        var expectsKey = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let end = stringEnd(in: text, from: index)
                if depth == 1, expectsKey {
                    expectsKey = false
                    let content = text[text.index(after: index)..<text.index(before: end)]
                    if content == key {
                        guard let colon = text[end...].firstIndex(where: { !$0.isWhitespace }), text[colon] == ":",
                            let start = text[text.index(after: colon)...].firstIndex(where: { !$0.isWhitespace })
                        else { return nil }
                        return start..<valueEnd(in: text, from: start)
                    }
                }
                index = end
                continue
            }
            switch character {
            case "{", "[":
                depth += 1
                expectsKey = character == "{" && depth == 1
            case "}", "]":
                depth -= 1
            case "," where depth == 1:
                expectsKey = true
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The index after the string that starts with the quote at `start`.
    private static func stringEnd(in text: String, from start: String.Index) -> String.Index {
        var index = text.index(after: start)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index] == "\"" { return text.index(after: index) }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    /// The end of the JSON value that starts at `start`, without the space after it.
    private static func valueEnd(in text: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        var last = start
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                index = stringEnd(in: text, from: index)
                last = index
                if depth == 0 { return index }
                continue
            }
            switch character {
            case "{", "[":
                depth += 1
            case "}", "]":
                if depth == 0 { return last }
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            case "," where depth == 0:
                return last
            default:
                break
            }
            index = text.index(after: index)
            if !character.isWhitespace { last = index }
        }
        return last
    }

    /// The folder for outputs of `kind`, created with `output/.gitignore` the first time.
    public static func output(_ kind: ProjectOutput, in project: URL) throws -> URL {
        let output = project.appendingPathComponent(outputFolderName, isDirectory: true)
        let folder = output.appendingPathComponent(kind.rawValue, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = output.appendingPathComponent(".gitignore")
        if !files.fileExists(atPath: ignore.path) {
            // Ignores the folder and itself, so the repository's own .gitignore stays untouched.
            try? Data("# Mobdev's runs, recordings and crawls: not for version control.\n*\n".utf8).write(to: ignore)
        }
        return folder
    }

    /// Removes all but the newest `kept` entries of a folder whose names sort by time.
    static func trim(_ folder: URL, keeping kept: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        for name in names.sorted(by: >).dropFirst(kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// The project of the agent behind a call: `Mobdev mcp` and `Mobdev call` send the project of
/// their working folder (or MOBDEV_PROJECT) in a header, and the app uses it for that call
/// instead of the active project, so agents in different repositories or worktrees do not save
/// into each other's projects.
public enum AgentProject {
    public static let header = "X-Mobdev-Project"

    /// MOBDEV_PROJECT, else the project of the working folder.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingFolder: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let value = environment["MOBDEV_PROJECT"], !value.isEmpty {
            let url = ProjectList.normalized(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
            if TestProject.isProject(url) { return url }
            let nested = url.appendingPathComponent(TestProject.defaultFolderName, isDirectory: true)
            return TestProject.isProject(nested) ? ProjectList.normalized(nested) : nil
        }
        // An app started from Finder or launchd works in "/", which is no project.
        guard workingFolder != "/" else { return nil }
        return TestProject.project(forWorkingFolder: URL(fileURLWithPath: workingFolder))
    }

    /// The project a request names, if it is one: an absolute path to a folder with mobdev.json.
    static func project(from value: String?) -> URL? {
        guard let value = value?.removingPercentEncoding ?? value, value.hasPrefix("/") else { return nil }
        let url = ProjectList.normalized(URL(fileURLWithPath: value))
        return TestProject.isProject(url) ? url : nil
    }

    /// The header's value: the path, with what HTTP headers cannot carry percent-encoded.
    static func headerValue(_ project: URL) -> String {
        project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project.path
    }
}

/// The project a run belongs to, fixed for the run's whole task: steps of a test run or a flow
/// file land in that project, also when another one becomes active meanwhile. An agent's working
/// folder pins its project for each of its calls the same way.
public enum ProjectScope {
    @TaskLocal public static var pinned: URL?
}

/// The projects this process knows and the active one: in the app the list in its settings, in
/// `Mobdev call --local` the project given by --project or MOBDEV_PROJECT. Shared by every
/// device's tools; the app observes it through `onChange`.
public final class ProjectList: Sendable {
    private struct State {
        var known: [URL]
        var active: URL?
    }

    private let state: Locked<State>
    private let changeHandler = Locked<(@Sendable () -> Void)?>(nil)
    private let outputHandler = Locked<(@Sendable (URL, ProjectOutput?) -> Void)?>(nil)

    public init(known: [URL] = [], active: URL? = nil) {
        var unique: [URL] = []
        for folder in known.map(Self.normalized) where !unique.contains(folder) { unique.append(folder) }
        state = Locked(State(known: unique, active: active.map(Self.normalized)))
    }

    /// Called after the list or the active project changed, on any thread.
    public func onChange(_ handler: @escaping @Sendable () -> Void) { changeHandler.set(handler) }

    /// Called when a tool saved something into a project, with the kind of output if it is one.
    public func onOutput(_ handler: @escaping @Sendable (URL, ProjectOutput?) -> Void) { outputHandler.set(handler) }

    public var known: [URL] { state.get().known }
    public var active: URL? { state.get().active }

    /// Adds a project at the top of the list, and makes it active when asked or when none is.
    public func add(_ folder: URL, activate: Bool) {
        let folder = Self.normalized(folder)
        state.withLock { state in
            state.known.removeAll { $0 == folder }
            state.known.insert(folder, at: 0)
            if activate || state.active == nil { state.active = folder }
        }
        changeHandler.get()?()
    }

    /// Makes a known project active; nil leaves none active.
    public func setActive(_ folder: URL?) {
        let folder = folder.map(Self.normalized)
        let changed = state.withLock { state -> Bool in
            if let folder, !state.known.contains(folder) { state.known.insert(folder, at: 0) }
            guard state.active != folder else { return false }
            state.active = folder
            return true
        }
        if changed { changeHandler.get()?() }
    }

    /// Opens the project at `url`: its folder, its mobdev.json, or a repository with a mobdev/
    /// folder. Adds it, makes it active and returns its folder.
    @discardableResult
    public func open(_ url: URL) throws -> URL {
        var folder = url
        if folder.lastPathComponent == TestProject.fileName { folder.deleteLastPathComponent() }
        if !TestProject.isProject(folder) {
            let nested = folder.appendingPathComponent(TestProject.defaultFolderName, isDirectory: true)
            guard TestProject.isProject(nested) else {
                throw ToolFailure("\(folder.path) has no mobdev.json, and no mobdev folder with one. Create a project there instead.")
            }
            folder = nested
        }
        _ = try TestProject.load(folder)
        add(folder, activate: true)
        return Self.normalized(folder)
    }

    /// Forgets a project; its folder stays as it is.
    public func remove(_ folder: URL) {
        let folder = Self.normalized(folder)
        state.withLock { state in
            state.known.removeAll { $0 == folder }
            if state.active == folder { state.active = state.known.first }
        }
        changeHandler.get()?()
    }

    /// The project for a call that names none: the run's or the agent's, else the active one while
    /// its folder is still a project.
    public func current() -> URL? {
        if let pinned = ProjectScope.pinned { return pinned }
        guard let active = state.get().active, TestProject.isProject(active) else { return nil }
        return active
    }

    /// The project a tool's `project` argument names: a folder, its mobdev.json, a repository
    /// with a mobdev/ folder, or the name of a known project. Without the argument the current
    /// project; nil when there is none and it is not required.
    func resolve(_ args: Arguments, required: Bool) throws -> URL? {
        guard args.has("project") else {
            if let current = current() { return current }
            guard required else { return nil }
            throw ToolFailure(missingProject)
        }
        let value = try args.string("project")
        if let match = known.first(where: { Self.name(of: $0).caseInsensitiveCompare(value) == .orderedSame }) {
            return match
        }
        let path = (value as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw ToolFailure(
                "project must be an absolute path on the Mac that runs Mobdev, like ~/code/my-app/mobdev, or the name of a known project (list_projects).")
        }
        var url = URL(fileURLWithPath: path)
        if url.lastPathComponent == TestProject.fileName { url.deleteLastPathComponent() }
        if TestProject.isProject(url) { return Self.normalized(url) }
        let nested = url.appendingPathComponent(TestProject.defaultFolderName, isDirectory: true)
        if TestProject.isProject(nested) { return Self.normalized(nested) }
        return Self.normalized(url)
    }

    /// "No project is open…", naming the known ones.
    var missingProject: String {
        let names = known.map { "\(Self.name(of: $0)) (\($0.path))" }
        return "No project is active. "
            + (names.isEmpty
                ? "Create one with create_project in the app's repository, e.g. ~/code/my-app/mobdev."
                : "Open one with open_project: \(names.joined(separator: ", ")); or create one with create_project.")
    }

    func notifyOutput(_ project: URL, _ kind: ProjectOutput?) { outputHandler.get()?(project, kind) }

    /// A project's name from its mobdev.json, else its folder's.
    public static func name(of folder: URL) -> String {
        (try? TestProject.load(folder).name) ?? folder.lastPathComponent
    }

    /// The same folder always as the same URL: tilde expanded, symlinks resolved, no trailing slash.
    public static func normalized(_ url: URL) -> URL {
        let path = (url.path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }
}

extension PhoneTools {
    /// A file `path` inside one of the project's folders: relative to `base`, or absolute. A
    /// relative path must not leave `base`.
    static func file(_ path: String, in base: URL, fileExtension: String) throws -> URL {
        var path = (path as NSString).expandingTildeInPath
        if !path.lowercased().hasSuffix(".\(fileExtension)") { path += ".\(fileExtension)" }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        let resolvedBase = ProjectList.normalized(base)
        let url = resolvedBase.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(resolvedBase.path + "/") else {
            throw ToolFailure("path must stay inside \(base.lastPathComponent)/; pass an absolute path to save elsewhere.")
        }
        return url
    }
}
