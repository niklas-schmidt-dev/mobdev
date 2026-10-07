import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// Projects: a folder with mobdev.json in the app's repository that holds tests, flows,
/// baselines, screenshots and maps, with what Mobdev produces in its ignored output/.
@Suite struct ProjectTests {
    /// A repository with a .git folder, removed by the caller.
    func repository() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return ProjectList.normalized(url)
    }

    /// A project in `folder` with one test, made without the tools.
    func project(in folder: URL, name: String = "App", test: String? = nil) throws -> URL {
        let project = try TestProject.create(at: folder, name: name, bundleID: "dev.mobdev.fixture")
        if let test { try Data(test.utf8).write(to: folder.appendingPathComponent("tests/one.json")) }
        return ProjectList.normalized(project.folder)
    }

    func files(_ projects: ProjectList) -> DeviceTools {
        DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0, projects: projects)
    }

    func call(_ tools: some ToolCalling, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: The list

    @Test func theListKeepsEachFolderOnceAndSaysWhatChanged() throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = try project(in: repo.appendingPathComponent("a"))
        let b = try project(in: repo.appendingPathComponent("b"))
        let link = repo.appendingPathComponent("link-to-a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)

        let list = ProjectList(known: [a, URL(fileURLWithPath: a.path + "/"), link], active: link)
        #expect(list.known == [a])
        #expect(list.active == a)
        let changes = Locked(0)
        let outputs = Locked<[ProjectOutput?]>([])
        list.onChange { changes.withLock { $0 += 1 } }
        list.onOutput { _, kind in outputs.withLock { $0.append(kind) } }

        list.add(b, activate: false)
        #expect(list.known == [b, a])
        #expect(list.active == a)
        list.add(a, activate: true)
        #expect(list.known == [a, b])
        list.setActive(b)
        #expect(list.active == b)
        list.setActive(b)  // No change, no call.
        #expect(changes.get() == 3)
        list.notifyOutput(b, .runs)
        #expect(outputs.get() == [.runs])

        // The active project counts while its folder is a project; a pinned one always wins.
        #expect(list.current() == b)
        ProjectScope.$pinned.withValue(a) { #expect(list.current() == a) }
        try FileManager.default.removeItem(at: b.appendingPathComponent(TestProject.fileName))
        #expect(list.current() == nil)
        list.remove(b)
        #expect(list.known == [a])
        #expect(list.active == a)
        #expect(changes.get() == 4)
    }

    @Test func outputAppearsWhenSomethingIsWrittenNeverWhenReading() throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"), test: #"{"steps": ["home"]}"#)
        _ = try TestProject.load(folder)
        _ = TestRuns.runs(for: try TestProject.load(folder))
        _ = TestRuns.result(for: try TestProject.load(folder))
        #expect(!exists(folder.appendingPathComponent("output")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["mobdev.json", "tests"])

        let runs = try TestProject.output(.runs, in: folder)
        #expect(runs.path == folder.appendingPathComponent("output/runs").path)
        let ignore = folder.appendingPathComponent("output/.gitignore")
        #expect(String(decoding: try Data(contentsOf: ignore), as: UTF8.self).hasSuffix("\n*\n"))
        _ = try TestProject.output(.checks, in: folder)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("output").path)) == [".gitignore", "runs", "checks"])
    }

    @Test func agentsFindTheProjectOfTheirWorkingFolder() throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let nested = repo.appendingPathComponent("apps/ios/Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(AgentProject.discover(environment: [:], workingFolder: repo.path) == folder)
        #expect(AgentProject.discover(environment: [:], workingFolder: nested.path) == folder)
        #expect(AgentProject.discover(environment: [:], workingFolder: folder.appendingPathComponent("tests").path) == folder)
        #expect(AgentProject.discover(environment: [:], workingFolder: "/") == nil)
        #expect(AgentProject.discover(environment: ["MOBDEV_PROJECT": repo.path], workingFolder: "/") == folder)
        #expect(AgentProject.discover(environment: ["MOBDEV_PROJECT": folder.path], workingFolder: "/") == folder)
        #expect(AgentProject.discover(environment: ["MOBDEV_PROJECT": "/nowhere"], workingFolder: repo.path) == nil)

        // The search stops at the repository's root.
        let other = try repository()
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(AgentProject.discover(environment: [:], workingFolder: other.path) == nil)

        // The header carries any path; only an absolute one to a project counts.
        let spaced = try project(in: repo.appendingPathComponent("with space ü"))
        #expect(AgentProject.project(from: AgentProject.headerValue(spaced)) == spaced)
        #expect(AgentProject.project(from: "mobdev") == nil)
        #expect(AgentProject.project(from: repo.path) == nil)
        #expect(AgentProject.project(from: nil) == nil)
    }

    @Test func theAgentsProjectCountsForLocalCallsOnly() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let active = try project(in: repo.appendingPathComponent("active"))
        let agents = try project(in: repo.appendingPathComponent("agents"))
        let tools = files(ProjectList(known: [active, agents], active: active))
        let router = APIRouter(tools: tools, token: { "secret" }, port: { 4686 })

        func current(_ header: String?, from origin: APIRouter.Origin) async throws -> JSONValue? {
            var headers = ["Authorization": "Bearer secret"]
            if let header { headers[AgentProject.header] = header }
            let response = await router.handle(HTTPRequest(method: "POST", path: "/v1/tools/list_projects", headers: headers), from: origin)
            #expect(response.status == 200)
            return try JSONValue.parse(response.body)["data"]?["current"]
        }
        #expect(try await current(AgentProject.headerValue(agents), from: .socket) == .string(agents.path))
        #expect(try await current(nil, from: .socket) == .string(active.path))
        #expect(try await current("relative/mobdev", from: .socket) == .string(active.path))
        #expect(try await current(repo.path, from: .socket) == .string(active.path))
        // A remote agent's paths mean nothing on this Mac.
        #expect(try await current(AgentProject.headerValue(agents), from: .relay) == .string(active.path))
    }

    // MARK: Project tools

    @Test func createOpenAndListProjects() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let list = ProjectList()
        let tools = files(list)

        let none = try await call(tools, "list_projects")
        #expect(none.text.hasPrefix("No projects yet. No project is active. Create one with create_project"))
        let missing = try await call(tools, "list_tests")
        #expect(missing.isError)
        #expect(missing.text.contains("No project is active"))

        let created = try await call(
            tools, "create_project", ["path": .string(repo.appendingPathComponent("mobdev").path), "bundle_id": "dev.mobdev.fixture"])
        #expect(!created.isError, "\(created.text)")
        let folder = repo.appendingPathComponent("mobdev")
        #expect(created.text.hasPrefix("Created the project \(repo.lastPathComponent) in \(folder.path) and made it active."))
        #expect(list.active == folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["mobdev.json", "tests"])
        #expect(try TestProject.load(folder).app.bundleID == "dev.mobdev.fixture")

        #expect(try await call(tools, "create_project", ["path": .string(folder.path)]).text.contains("already is a project"))
        #expect(try await call(tools, "create_project", ["path": "relative/mobdev"]).isError)
        #expect(try await call(tools, "create_project", ["path": .string(repo.path + "/no/such/mobdev")]).text.contains("does not exist"))

        let second = try await call(tools, "create_project", ["path": .string(repo.appendingPathComponent("other").path), "name": "Other"])
        #expect(!second.isError)
        #expect(list.active?.lastPathComponent == "other")
        // A repository, a project's name or its mobdev.json open the same project.
        let opened = try await call(tools, "open_project", ["project": .string(repo.path)])
        #expect(opened.text == "\(repo.lastPathComponent) (\(folder.path)) is the active project now, instead of Other.")
        #expect(list.active == folder)
        _ = try await call(tools, "open_project", ["project": "other"])
        #expect(list.active?.lastPathComponent == "other")
        _ = try await call(tools, "open_project", ["project": .string(folder.appendingPathComponent("mobdev.json").path)])
        #expect(list.active == folder)
        #expect(try await call(tools, "open_project", ["project": .string(repo.appendingPathComponent(".git").path)]).isError)

        let listed = try await call(tools, "list_projects")
        #expect(listed.text.contains("\(repo.lastPathComponent): \(folder.path). active. app dev.mobdev.fixture. 0 tests"))
        #expect(listed.text.contains("Other: \(repo.appendingPathComponent("other").path). 0 tests"))
        #expect(listed.data?["projects"]?.arrayValue?.count == 2)
        #expect(listed.data?["active"] == .string(folder.path))
    }

    @Test func testsAndFlowsGoToTheActiveProject() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let list = ProjectList(known: [folder], active: folder)
        let saved = Locked<[URL]>([])
        list.onOutput { project, _ in saved.withLock { $0.append(project) } }
        let tools = files(list)

        let test = try await call(tools, "save_test", ["name": "Goes home", "steps": ["home"]])
        #expect(!test.isError, "\(test.text)")
        #expect(exists(folder.appendingPathComponent("tests/goes-home.json")))
        let listed = try await call(tools, "list_tests")
        #expect(listed.text.contains("goes-home: Goes home, 1 steps"))

        let flow = try await call(
            tools, "save_flow", ["name": "Open settings", "steps": [["tap_element": ["id": "settings"]], "wait_for_idle"]])
        #expect(!flow.isError, "\(flow.text)")
        let file = folder.appendingPathComponent("flows/open-settings.json")
        #expect(flow.text == "Saved \(file.path) with 2 steps. Replay it with run_flow and path.")
        #expect(try Flow.load(file).steps.count == 2)
        let replaced = try await call(tools, "save_flow", ["name": "Open settings", "file": "open-settings", "steps": ["home"]])
        #expect(replaced.text.hasPrefix("Replaced "))
        #expect(try await call(tools, "save_flow", ["name": "Bad", "steps": [["run_tests": [:]]]]).isError)
        #expect(saved.get() == [folder, folder, folder])

        // Without an active project the tools name what to do.
        list.setActive(nil)
        let homeless = try await call(tools, "save_flow", ["name": "Lost", "steps": ["home"]])
        #expect(homeless.isError)
        #expect(homeless.text.contains("Open one with open_project: App (\(folder.path))"))
        // A pinned project, such as an agent's, still works.
        let pinned = try await ProjectScope.$pinned.withValue(folder) {
            try await call(tools, "save_flow", ["name": "Pinned", "steps": ["home"]])
        }
        #expect(!pinned.isError)
        #expect(exists(folder.appendingPathComponent("flows/pinned.json")))
    }

    @Test func screenshotsAreSavedAtFullSizeInsideTheProject() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let list = ProjectList(known: [folder], active: folder)
        let tools = PhoneTools(phone: CanvasPhone(Canvas.signIn()), activity: ActivityLog(), settleDelay: 0, projects: list)

        let saved = try await call(tools, "save_screenshot", ["path": "de-DE/iphone-6.9/01-home"])
        #expect(!saved.isError, "\(saved.text)")
        let file = folder.appendingPathComponent("screenshots/de-DE/iphone-6.9/01-home.png")
        #expect(saved.text == "Saved \(file.path) (1179×2556 px).")
        let image = try #require(CGImage.load(file))
        #expect(image.width == 1179 && image.height == 2556)

        for escape in ["../escape", "a/../../escape", "/../.."] {
            #expect(try await call(tools, "save_screenshot", ["path": .string(escape)]).isError, "\(escape)")
        }
        #expect(!exists(folder.appendingPathComponent("escape.png")))

        let elsewhere = repo.appendingPathComponent("elsewhere/shot.png")
        list.setActive(nil)
        let noProject = try await call(tools, "save_screenshot", ["path": "02-settings"])
        #expect(noProject.isError)
        #expect(noProject.text.contains("Or pass an absolute path."))
        #expect(!(try await call(tools, "save_screenshot", ["path": .string(elsewhere.path)])).isError)
        #expect(exists(elsewhere))
    }

    // MARK: Runs, checks, recordings and crawls

    @Test func runsLiveInTheProjectAndOlderRunsAreStillRead() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"), test: #"{"steps": ["home"]}"#)
        let project = try TestProject.load(folder)
        let legacy = TestRuns.projectFolder(project).appendingPathComponent("2001-01-01 00.00.00", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: TestRuns.projectFolder(project)) }

        // Ten runs at once, as on several devices, each get a folder of their own.
        let folders = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<10 { group.addTask { try TestRuns.newRunFolder(for: project) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(folders).count == 10)
        #expect(folders.allSatisfy { $0.deletingLastPathComponent().path == folder.appendingPathComponent("output/runs").path })
        let runs = TestRuns.runs(for: project)
        #expect(runs.count == 11)
        #expect(runs.last == legacy)

        // Twenty are kept over both places, so the old place empties itself.
        for _ in 0..<15 { _ = try TestRuns.newRunFolder(for: project) }
        #expect(TestRuns.runs(for: project).count == TestRuns.kept)
        #expect(!exists(legacy))
    }

    @Test func aRunStaysInItsProjectWhateverBecomesActive() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let first = try project(
            in: repo.appendingPathComponent("first"),
            test: #"{"steps": [{"save_screenshot": {"path": "start"}}, {"assert_screenshot": {"name": "start"}}]}"#)
        let second = try project(in: repo.appendingPathComponent("second"))
        let list = ProjectList(known: [first, second], active: second)
        let outputs = Locked<[String]>([])
        list.onOutput { project, kind in outputs.withLock { $0.append("\(project.lastPathComponent) \(kind?.rawValue ?? "-")") } }
        let tools = PhoneTools(phone: CanvasPhone(Canvas.signIn()), activity: ActivityLog(), settleDelay: 0, projects: list)

        let result = try await call(tools, "run_tests", ["project": .string(first.path), "video": false])
        #expect(!result.isError, "\(result.text)")
        #expect(exists(first.appendingPathComponent("screenshots/start.png")))
        #expect(exists(first.appendingPathComponent("baselines/ios/1179x2556/start.png")))
        #expect(!exists(second.appendingPathComponent("screenshots")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("output/runs").path).count == 1)
        #expect(outputs.get() == ["first -", "first runs"])
        #expect(list.active == second)
    }

    @Test func aProjectsBaselinesAreVersionedAndFailuresGoToOutput() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let list = ProjectList(known: [folder], active: folder)
        let phone = CanvasPhone(Canvas.signIn())
        let tools = PhoneTools(
            phone: phone, activity: ActivityLog(), settleDelay: 0, judge: FakeJudge(.failure(ToolFailure("no judge"))), projects: list
        ) { _, _ in [] }

        let recorded = try await call(tools, "assert_screenshot", ["name": "home"])
        let baselines = folder.appendingPathComponent("baselines/ios/1179x2556")
        #expect(recorded.text.hasPrefix("Recorded a new baseline \(baselines.path)/home.png"))
        #expect(!exists(folder.appendingPathComponent("output")))

        phone.screen.set(Canvas.signIn(title: "Something else"))
        let failed = try await call(tools, "assert_screenshot", ["name": "home"])
        #expect(failed.isError)
        let checks = folder.appendingPathComponent("output/checks")
        #expect(exists(checks.appendingPathComponent("home-diff.png")))
        #expect(exists(checks.appendingPathComponent("home-actual.png")))
        #expect(exists(folder.appendingPathComponent("output/.gitignore")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: baselines.path) == ["home.png"])

        phone.screen.set(Canvas.signIn())
        #expect(!(try await call(tools, "assert_screenshot", ["name": "home"])).isError)
        #expect(!exists(checks.appendingPathComponent("home-diff.png")))

        // A flow in the project's flows/ uses the project's baselines, not a folder next to it.
        let flows = folder.appendingPathComponent("flows")
        try FileManager.default.createDirectory(at: flows, withIntermediateDirectories: true)
        try Data(#"{"steps": [{"assert_screenshot": {"name": "home"}}, {"assert_screenshot": {"name": "start"}}]}"#.utf8)
            .write(to: flows.appendingPathComponent("look.json"))
        list.setActive(nil)
        let ran = try await call(tools, "run_flow", ["path": .string(flows.appendingPathComponent("look.json").path)])
        #expect(!ran.isError, "\(ran.text)")
        #expect(exists(baselines.appendingPathComponent("start.png")))
        #expect(!exists(flows.appendingPathComponent("baselines")))
    }

    @Test func recordingsWithoutAPathGoToTheProject() throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let url = try PhoneTools.newRecordingURL(in: folder)
        #expect(url.deletingLastPathComponent().path == folder.appendingPathComponent("output/recordings").path)
        #expect(url.lastPathComponent.hasPrefix("recording-") && url.pathExtension == "mp4")
        #expect(exists(folder.appendingPathComponent("output/.gitignore")))
        #expect(try PhoneTools.newRecordingURL().path.hasPrefix(MobdevPaths.home.appendingPathComponent("recordings").path))
    }

    @Test func aCrawlKeepsItsMapInTheProject() async throws {
        let repo = try repository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = try project(in: repo.appendingPathComponent("mobdev"))
        let list = ProjectList(known: [folder], active: folder)
        let phone = CrawlPhone()
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0, projects: list)

        let crawled = try await call(tools, "crawl_app", ["bundle_id": "dev.mobdev.crawl", "seconds": 120])
        #expect(!crawled.isError, "\(crawled.text)")
        let crawls = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("output/crawls").path)
            .filter { !$0.hasPrefix(".") }
        #expect(crawls.count == 1)
        #expect(crawls.first?.hasSuffix("-dev.mobdev.crawl") == true)
        let mapFile = folder.appendingPathComponent("maps/dev.mobdev.crawl.json")
        let map = try #require(PhoneTools.savedMap("dev.mobdev.crawl", file: mapFile))
        #expect(map.completed)
        #expect(map.crawl == "output/crawls/\(crawls[0])")

        // navigate_to reads the project's map before the one in Mobdev's folder: a title only the
        // project's map has is found.
        var renamed = map
        renamed.screens = map.screens.map { screen in
            var screen = screen
            if screen.title == "About" { screen.title = "Imprint" }
            return screen
        }
        try PhoneTools.encode(renamed).write(to: mapFile)
        let navigated = try await call(tools, "navigate_to", ["bundle_id": "dev.mobdev.crawl", "screen": "Imprint"])
        #expect(!navigated.isError, "\(navigated.text)")
        #expect(phone.current.get() == "about")

        // A crawl that broke off keeps the map it would replace.
        var broken = map
        broken.ended = "\(AppMap.errorPrefix): the app quit"
        #expect(!broken.completed)
    }

    // MARK: Settings and the test home

    @Test func settingsMoveTheOldTestProjects() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4686, "testProjects": ["/a", "/b"]}"#.utf8))
        #expect(old.projects == ["/a", "/b"])
        #expect(old.activeProject == nil)
        var settings = old
        settings.activeProject = "/b"
        let encoded = try JSONValue.parse(JSONEncoder().encode(settings))
        #expect(encoded["projects"] == ["/a", "/b"])
        #expect(encoded["activeProject"] == "/b")
        #expect(encoded["testProjects"] == nil)
        let both = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"projects": ["/c"], "testProjects": ["/a"], "activeProject": "/c"}"#.utf8))
        #expect(both.projects == ["/c"])
        #expect(both.activeProject == "/c")
    }

    @Test func testsNeverWriteIntoTheInstalledAppsFolder() {
        #expect(MobdevPaths.isRunningTests)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if ProcessInfo.processInfo.environment["MOBDEV_HOME"] == nil {
            #expect(!MobdevPaths.home.path.hasPrefix(support.path))
            #expect(MobdevPaths.home.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        }
    }
}
