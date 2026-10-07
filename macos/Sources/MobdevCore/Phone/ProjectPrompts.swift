import Foundation

/// A prompt to paste into a coding agent that has Mobdev's MCP server, filled in with a project's
/// folder, app and device, and the skill that does the job.
public struct ProjectPrompt: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// What the agent does, in one line.
    public let summary: String
    /// The skill the prompt names, from skills/ (`npx skills add niklas-schmidt-dev/mobdev`).
    public let skill: String?
    public let systemImage: String
    public let text: String
}

/// The prompts a new project starts with, so "and now what?" has an answer: write the first
/// tests, map the app, check changes, reproduce a bug, store screenshots, audit the onboarding and
/// run the tests in CI.
public enum ProjectPrompts {
    public struct Context: Sendable {
        /// The project's folder, such as ~/code/shop/mobdev.
        public var folder: URL
        /// The project's folder relative to its repository, such as mobdev or apps/mobile/mobdev.
        public var relativeFolder: String
        public var bundleID: String?
        /// The device to use, by name; nil when none is ready.
        public var device: String?

        public init(folder: URL, relativeFolder: String, bundleID: String?, device: String?) {
            self.folder = folder
            self.relativeFolder = relativeFolder
            self.bundleID = bundleID
            self.device = device
        }

        /// For a project, with its repository found the way its icon is.
        public init(project folder: URL, bundleID: String?, device: String?) {
            let repository = ProjectIcons.repository(of: folder)
            let relative = ProjectIcons.relativePath(ProjectList.normalized(folder), in: repository) ?? folder.lastPathComponent
            self.init(folder: folder, relativeFolder: relative, bundleID: bundleID, device: device)
        }
    }

    public static func all(_ context: Context) -> [ProjectPrompt] {
        [
            firstTests(context), mapApp(context), devLoop(context), reproduceBug(context), storeScreenshots(context),
            onboardingAudit(context), continuousIntegration(context),
        ]
    }

    public static func firstTests(_ context: Context) -> ProjectPrompt {
        let setup =
            context.bundleID == nil
            ? "First find the app's bundle ID (or Android package) and how to build it for the simulator, and put them into \(context.folder.path)/mobdev.json as app.bundle_id and app.builds. "
            : ""
        return ProjectPrompt(
            id: "first-tests", title: "Write the first tests",
            summary: "The agent explores the app and saves its most important paths as tests.",
            skill: "mobdev-smoke-test", systemImage: "checklist",
            text: """
                Use Mobdev (its MCP tools) and the mobdev-smoke-test skill. The Mobdev project for this app is \
                \(context.folder.path). \(setup)Launch \(app(context)) \(device(context)), explore its main screens and \
                find the 3 to 5 paths users depend on most, such as signing in or the app's main task. Save each one \
                as a test with save_test: use tap_element and wait_for_element rather than coordinates, and end each \
                test with a wait that proves the result. Run them with run_tests and fix every test that fails \
                because of the test, not the app. Then tell me which tests you saved and anything that looked broken.
                """)
    }

    static func mapApp(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "map-app", title: "Map the app and find crashes",
            summary: "crawl_app taps through every screen; crashes become flows to replay.",
            skill: nil, systemImage: "map",
            text: """
                Use Mobdev's crawl_app to explore \(app(context)) \(device(context)) by itself. Then show me its map: \
                the screens it found and every crash. Save each crash's steps as a flow with save_flow so I can \
                replay it, and suggest which screens deserve a test. The Mobdev project is \(context.folder.path).
                """)
    }

    static func devLoop(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "dev-loop", title: "Check every change on a device",
            summary: "The agent builds, installs and looks at each change before calling it done.",
            skill: "mobdev-dev-loop", systemImage: "hammer",
            text: """
                Use Mobdev and the mobdev-dev-loop skill while you work on this app: after each change, build it, \
                install it \(device(context)), check the change on the screen and run the tests in \
                \(context.folder.path) with run_tests. Before you say a fix is done, record it working with \
                start_recording and stop_recording and give me the video's path.
                """)
    }

    static func reproduceBug(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "reproduce-bug", title: "Reproduce a bug",
            summary: "The agent follows a report, records it and keeps it as a failing test.",
            skill: "mobdev-bug-repro", systemImage: "ladybug",
            text: """
                Use Mobdev and the mobdev-bug-repro skill to reproduce this bug of \(app(context)) \
                \(device(context)): <describe the bug, the steps and what should happen instead>. Record it, find the \
                fewest steps that still show it, and save them as a test in \(context.folder.path) that fails while \
                the bug is there.
                """)
    }

    static func storeScreenshots(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "store-screenshots", title: "Make store screenshots",
            summary: "Screenshots in every language, saved in the project and made again by a test.",
            skill: "mobdev-store-screenshots", systemImage: "photo.on.rectangle",
            text: """
                Use Mobdev and the mobdev-store-screenshots skill to make App Store and Google Play screenshots of \
                \(app(context)) in English and German (change the languages as you need). Save them with \
                save_screenshot into \(context.folder.path)/screenshots, and keep the steps as a test named Store \
                screenshots, so Mobdev test with --language makes them again for the next release.
                """)
    }

    static func onboardingAudit(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "onboarding-audit", title: "Audit the onboarding",
            summary: "Every first-run screen with its friction, from install to first value.",
            skill: "mobdev-onboarding-audit", systemImage: "figure.walk",
            text: """
                Use Mobdev and the mobdev-onboarding-audit skill to walk the first-run onboarding of \(app(context)) \
                \(device(context)), from a fresh install to the first moment of value. Capture every screen, note \
                friction, unclear copy and accessibility issues, and save the path as a test in \
                \(context.folder.path).
                """)
    }

    public static func continuousIntegration(_ context: Context) -> ProjectPrompt {
        ProjectPrompt(
            id: "ci", title: "Run the tests in CI",
            summary: "A GitHub Actions workflow that runs the project's tests on every pull request.",
            skill: nil, systemImage: "arrow.triangle.branch",
            text: """
                Add a GitHub Actions workflow to this repository that builds the app for the iOS simulator and runs \
                the Mobdev tests in \(context.relativeFolder) on every pull request with the Mobdev action \
                (uses: niklas-schmidt-dev/mobdev/actions/test@main, with project: \(context.relativeFolder)) on a \
                macos-26 runner. Point app.builds.simulator in \(context.relativeFolder)/mobdev.json at the build.
                """)
    }

    private static func app(_ context: Context) -> String { context.bundleID.map { "the app \($0)" } ?? "the app" }

    private static func device(_ context: Context) -> String {
        context.device.map { "on \($0)" } ?? "on a booted iOS simulator or Android emulator"
    }

    /// Whether a repository runs Mobdev in a GitHub Actions workflow.
    public static func runsInCI(_ repository: URL) -> Bool {
        let folder = repository.appendingPathComponent(".github/workflows", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard ["yml", "yaml"].contains(file.pathExtension.lowercased()),
                let text = try? String(contentsOf: file, encoding: .utf8).lowercased()
            else { return false }
            return text.contains("mobdev/actions/test") || text.contains("mobdev test")
        }
    }
}
