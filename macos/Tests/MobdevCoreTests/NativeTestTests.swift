import Foundation
import Testing
@testable import MobdevCore

/// A simulator for the tools: a fake phone that says what it is.
final class FakeSimulatorDevice: FakePhone, Device, @unchecked Sendable {
    let id = "11111111-2222-3333-4444-555555555555"
    let name = "iPhone 17"
    var info: DeviceInfo? { nil }
    let kind = DeviceKind.simulator
    let activity = ActivityLog()
}

/// Plays xcodebuild, Gradle and xcresulttool: a started command prints its lines, does what
/// `onStart` says (such as writing the result bundle) and exits with `status`, at once or once
/// released; `run` answers xcresulttool from the canned JSON.
final class NativeCommands: CommandRunning, @unchecked Sendable {
    var lines: [String] = []
    var status: Int32 = 0
    var onStart: (@Sendable ([String]) -> Void)?
    var tests = ""
    var summary = ""
    var build = ""
    /// The manifest `export attachments` writes for a test, by its --test-id; each file it names is written too.
    var manifests: [String: String] = [:]
    /// Holds the started command until `release()`.
    var held = false
    let started = Locked<[[String]]>([])
    let ran = Locked<[[String]]>([])
    private let exit = Locked<(@Sendable (Int32) -> Void)?>(nil)
    let stops = Locked(0)

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        ran.withLock { $0.append(arguments) }
        let joined = arguments.joined(separator: " ")
        if joined.contains("test-results tests") { return CommandResult(status: 0, output: tests) }
        if joined.contains("test-results summary") { return CommandResult(status: 0, output: summary) }
        if joined.contains("build-results") { return CommandResult(status: 0, output: build) }
        if joined.contains("export attachments"), let index = arguments.firstIndex(of: "--output-path"),
            let test = arguments.firstIndex(of: "--test-id")
        {
            let folder = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = manifests[arguments[test + 1]] ?? "[]"
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
            for match in manifest.matches(of: /"exportedFileName": "([^"]+)"/) {
                try Data("x".utf8).write(to: folder.appendingPathComponent(String(match.1)))
            }
            return CommandResult(status: 0, output: "")
        }
        return CommandResult(status: 1, output: "unexpected \(joined)")
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        onStart?(arguments)
        for line in lines { onLine(line) }
        // Recorded after the lines, so a test that sees the start sees their progress too.
        started.withLock { $0.append([executable.path] + arguments) }
        let status = self.status
        if held {
            exit.set { _ in onExit(status) }
        } else {
            DispatchQueue.global().async { onExit(status) }
        }
        return Stopper(commands: self)
    }

    func release() { exit.get()?(status) }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (1, Data())
    }

    struct Stopper: RunningCommand {
        let commands: NativeCommands
        func stop() {
            commands.stops.withLock { $0 += 1 }
            commands.exit.get()?(137)
        }
    }

    /// Writes an empty result bundle where xcodebuild was told to.
    static let writeBundle: @Sendable ([String]) -> Void = { arguments in
        guard let index = arguments.firstIndex(of: "-resultBundlePath") else { return }
        try? FileManager.default.createDirectory(atPath: arguments[index + 1], withIntermediateDirectories: true)
    }
}

/// Serialized: runs register in one place for the whole process, and quitting stops them all.
@Suite(.serialized) struct NativeTestTests {
    /// What `xcrun xcresulttool get test-results tests` printed for a scheme with an XCTest and a
    /// Swift Testing unit test failing and a UI test passing (Xcode 27, iPhone 17 simulator).
    static let testsJSON = #"""
{
  "devices" : [
    {
      "architecture" : "arm64",
      "deviceId" : "693A1753-BDE8-4C18-A0A0-887913D27473",
      "deviceName" : "mobdev-wp3",
      "modelName" : "iPhone 17",
      "osBuildNumber" : "24A434",
      "osVersion" : "27.0",
      "platform" : "iOS Simulator"
    }
  ],
  "testNodes" : [
    {
      "children" : [
        {
          "children" : [
            {
              "duration" : "0,00066s",
              "durationInSeconds" : 0.0006568431854248047,
              "name" : "addingWorks()",
              "nodeIdentifier" : "addingWorks()",
              "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests/addingWorks()",
              "nodeType" : "Test Case",
              "result" : "Passed"
            },
            {
              "children" : [
                {
                  "name" : "Expectation failed: add(3, 4) == 8\nadd(3, 4) → 7",
                  "nodeType" : "Failure Message",
                  "sourceLocation" : {
                    "filePath" : "/Users/dev/Sample/SampleTests/SwiftTestingTests.swift",
                    "lineNumber" : 9
                  }
                }
              ],
              "duration" : "0,007s",
              "durationInSeconds" : 0.006978034973144531,
              "name" : "addingBreaks()",
              "nodeIdentifier" : "addingBreaks()",
              "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests/addingBreaks()",
              "nodeType" : "Test Case",
              "result" : "Failed"
            },
            {
              "children" : [
                {
                  "children" : [
                    {
                      "name" : "XCTAssertEqual failed: (\"4\") is not equal to (\"5\") - two and two",
                      "nodeType" : "Failure Message",
                      "sourceLocation" : {
                        "filePath" : "/Users/dev/Sample/SampleTests/SampleTests.swift",
                        "lineNumber" : 10
                      }
                    }
                  ],
                  "duration" : "1s",
                  "durationInSeconds" : 1.3689420223236084,
                  "name" : "testAddFails()",
                  "nodeIdentifier" : "SampleTests/testAddFails()",
                  "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests/SampleTests/testAddFails",
                  "nodeType" : "Test Case",
                  "result" : "Failed"
                },
                {
                  "duration" : "0,00042s",
                  "durationInSeconds" : 0.00041604042053222656,
                  "name" : "testAddPasses()",
                  "nodeIdentifier" : "SampleTests/testAddPasses()",
                  "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests/SampleTests/testAddPasses",
                  "nodeType" : "Test Case",
                  "result" : "Passed"
                }
              ],
              "name" : "SampleTests",
              "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests/SampleTests",
              "nodeType" : "Test Suite",
              "result" : "Failed"
            }
          ],
          "name" : "SampleTests",
          "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleTests",
          "nodeType" : "Unit test bundle",
          "result" : "Failed"
        },
        {
          "children" : [
            {
              "children" : [
                {
                  "duration" : "47s",
                  "durationInSeconds" : 47.0356730222702,
                  "name" : "testGreetingShows()",
                  "nodeIdentifier" : "SampleUITests/testGreetingShows()",
                  "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleUITests/SampleUITests/testGreetingShows",
                  "nodeType" : "Test Case",
                  "result" : "Passed"
                }
              ],
              "name" : "SampleUITests",
              "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleUITests/SampleUITests",
              "nodeType" : "Test Suite",
              "result" : "Passed"
            }
          ],
          "name" : "SampleUITests",
          "nodeIdentifierURL" : "test://com.apple.xcode/Sample/SampleUITests",
          "nodeType" : "UI test bundle",
          "result" : "Passed"
        }
      ],
      "name" : "Sample",
      "nodeType" : "Test Plan",
      "result" : "Failed"
    }
  ],
  "testPlanConfigurations" : [
    {
      "configurationId" : "1",
      "configurationName" : "Test Scheme Action"
    }
  ]
}
"""#

    static let summaryJSON = #"""
{"devicesAndConfigurations":[],"environmentDescription":"Sample","expectedFailures":0,"failedTests":2,"finishTime":1793203158.332,"passedTests":3,"result":"Failed","runtimeWarnings":[],"skippedTests":0,"startTime":1793202758.115,"statistics":[],"testFailures":[],"title":"Test - Sample","topInsights":[],"totalTestCount":5}
"""#

    /// `get build-results` of the same scheme while a test did not compile.
    static let buildJSON = #"""
{
  "actionTitle" : "Testing project Sample with scheme Sample",
  "analyzerWarningCount" : 0,
  "analyzerWarnings" : [

  ],
  "destination" : {
    "architecture" : "arm64",
    "deviceId" : "693A1753-BDE8-4C18-A0A0-887913D27473",
    "deviceName" : "mobdev-wp3",
    "modelName" : "iPhone 17",
    "osBuildNumber" : "24A434",
    "osVersion" : "27.0",
    "platform" : "iOS Simulator"
  },
  "endTime" : 1793202241.235,
  "errorCount" : 3,
  "errors" : [
    {
      "issueType" : "Uncategorized",
      "message" : "Testing cancelled because the build failed."
    },
    {
      "className" : "DVTTextDocumentLocation",
      "issueType" : "Swift Compiler Error",
      "message" : "Use of 'add' refers to instance method rather than global function 'add' in module 'Sample'",
      "sourceURL" : "file:///Users/dev/Sample/SampleTests/SampleTests.swift#EndingColumnNumber=23&EndingLineNumber=5&StartingColumnNumber=23&StartingLineNumber=5&Timestamp=814895027.412418"
    },
    {
      "className" : "DVTTextDocumentLocation",
      "issueType" : "Swift Compiler Error",
      "message" : "Use of 'add' refers to instance method rather than global function 'add' in module 'Sample'",
      "sourceURL" : "file:///Users/dev/Sample/SampleTests/SampleTests.swift#EndingColumnNumber=23&EndingLineNumber=9&StartingColumnNumber=23&StartingLineNumber=9&Timestamp=814895027.412418"
    }
  ],
  "startTime" : 1793202227.337,
  "status" : "failed",
  "warningCount" : 0,
  "warnings" : [

  ]
}
"""#

    /// A test report as Gradle writes it for connectedDebugAndroidTest.
    static let instrumentedXML = """
        <?xml version='1.0' encoding='UTF-8' ?>
        <testsuite name="com.example.app.LoginTest" tests="3" failures="1" errors="0" skipped="1" time="4.211" timestamp="2026-10-28T15:00:00" hostname="localhost">
          <properties>
            <property name="device" value="Pixel_9_Pro(AVD) - 16" />
            <property name="project" value=":app" />
          </properties>
          <testcase name="signIn" classname="com.example.app.LoginTest" time="2.1" />
          <testcase name="wrongPassword" classname="com.example.app.LoginTest" time="1.9">
            <failure>java.lang.AssertionError: expected:&lt;Welcome&gt; but was:&lt;Error&gt;
        \tat org.junit.Assert.fail(Assert.java:89)
        \tat org.junit.Assert.failNotEquals(Assert.java:835)
        \tat com.example.app.LoginTest.wrongPassword(LoginTest.kt:42)
        \tat java.lang.reflect.Method.invoke(Native Method)</failure>
          </testcase>
          <testcase name="later" classname="com.example.app.LoginTest" time="0.0">
            <skipped />
          </testcase>
        </testsuite>
        """

    /// A unit-test report as Gradle writes it for testDebugUnitTest.
    static let unitXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="com.example.app.MathTest" tests="2" skipped="0" failures="1" errors="0" timestamp="2026-10-28T15:01:02" hostname="mac" time="0.012">
          <properties/>
          <testcase name="adds" classname="com.example.app.MathTest" time="0.001"/>
          <testcase name="divides" classname="com.example.app.MathTest" time="0.004">
            <failure message="java.lang.AssertionError: expected:&lt;2&gt; but was:&lt;3&gt;" type="java.lang.AssertionError">java.lang.AssertionError: expected:&lt;2&gt; but was:&lt;3&gt;
        \tat org.junit.Assert.fail(Assert.java:89)
        \tat com.example.app.MathTest$Nested.helper(MathTest.kt:30)
        \tat com.example.app.MathTest.divides(MathTest.kt:17)
        </failure>
          </testcase>
          <system-out><![CDATA[]]></system-out>
        </testsuite>
        """

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ProjectList.normalized(url)
    }

    /// A repository with an Xcode project of two shared schemes, one with tests, and an Android
    /// folder with a Gradle wrapper; the project in mobdev/ names what `json` says.
    func repository(native: String? = nil) throws -> (repo: URL, project: TestProject) {
        let repo = try folder()
        let files = FileManager.default
        try files.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let schemes = repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
        try files.createDirectory(at: schemes, withIntermediateDirectories: true)
        try Data("<Scheme><TestAction><Testables><TestableReference/></Testables></TestAction></Scheme>".utf8)
            .write(to: schemes.appendingPathComponent("App.xcscheme"))
        try Data("<Scheme><TestAction/></Scheme>".utf8).write(to: schemes.appendingPathComponent("Widget.xcscheme"))
        let android = repo.appendingPathComponent("android")
        try files.createDirectory(at: android, withIntermediateDirectories: true)
        files.createFile(atPath: android.appendingPathComponent("gradlew").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let folder = repo.appendingPathComponent("mobdev")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = native.map { #"{"name": "App", "native_tests": \#($0)}"# } ?? #"{"name": "App"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("mobdev.json"))
        return (repo, try TestProject.load(folder))
    }

    static let simulator = TestRunResult.Device(id: "SIM-UDID", name: "iPhone 17", kind: "simulator")
    static let iPhone = TestRunResult.Device(id: "00008120-0001", name: "iPhone", kind: "iPhone")
    static let emulator = TestRunResult.Device(id: "emulator-5554", name: "Pixel", kind: "android")

    // MARK: mobdev.json

    @Test func readsAndWritesTheNativeTestsSection() throws {
        let (_, project) = try repository(
            native: #"{"ios": {"project": "../App.xcodeproj", "scheme": "App", "test_plan": "Unit"}, "android": {"gradle_root": "../android", "module": "app", "task": "testDebugUnitTest"}}"#)
        #expect(project.nativeTests?.ios == .init(project: "../App.xcodeproj", scheme: "App", testPlan: "Unit"))
        #expect(project.nativeTests?.android == .init(gradleRoot: "../android", task: "testDebugUnitTest", module: "app"))
        // Writing the file back keeps the section.
        let again = try TestProject.parse(try JSONValue.parse(project.encoded()), folder: project.folder)
        #expect(again.nativeTests == project.nativeTests)
        #expect(project.json["native_tests"]?["ios"]?["scheme"]?.stringValue == "App")
    }

    @Test func oldProjectsStayValidAndMistakesAreNamed() throws {
        let (_, project) = try repository()
        #expect(project.nativeTests == nil)
        let folder = project.folder
        func problem(_ native: String) -> String {
            do {
                _ = try TestProject.parse(try JSONValue.parse(Data(#"{"native_tests": \#(native)}"#.utf8)), folder: folder)
                return ""
            } catch {
                return String(describing: error)
            }
        }
        #expect(problem(#"{"ios": {"workspace": "a.xcworkspace", "project": "b.xcodeproj"}}"#).contains("not both"))
        #expect(problem(#"{"ios": {"schema": "App"}}"#).contains("unknown key \"schema\""))
        #expect(problem(#"{"windows": {}}"#).contains("unknown key \"windows\""))
        #expect(problem(#"{"android": {"task": 3}}"#).contains("must be a non-empty string"))
    }

    // MARK: Finding the suite

    @Test func findsTheProjectSchemeWithTestsAndTheGradleWrapper() throws {
        let (repo, project) = try repository()
        let ios = try NativeTestPlan.resolve(project, platform: .ios)
        #expect(ios.suite == .xcode(container: repo.appendingPathComponent("App.xcodeproj"), scheme: "App", testPlan: nil))
        #expect(ios.title == "scheme App of App.xcodeproj")
        let android = try NativeTestPlan.resolve(project, platform: .android)
        #expect(android.suite == .gradle(root: repo.appendingPathComponent("android"), task: "connectedDebugAndroidTest", module: nil))
        #expect(android.needsDevice)

        // A workspace next to the project wins; its own schemes count with its projects'.
        let workspace = repo.appendingPathComponent("App.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(#"<Workspace version="1.0"><FileRef location = "group:App.xcodeproj"></FileRef></Workspace>"#.utf8)
            .write(to: workspace.appendingPathComponent("contents.xcworkspacedata"))
        let found = try NativeTestPlan.resolve(project, platform: .ios)
        #expect(found.suite == .xcode(container: URL(fileURLWithPath: workspace.path), scheme: "App", testPlan: nil))
    }

    @Test func argumentsOverTheFileOverTheRepository() throws {
        let (repo, project) = try repository(
            native: #"{"ios": {"scheme": "Widget"}, "android": {"gradle_root": "../android", "module": "app"}}"#)
        #expect(try NativeTestPlan.resolve(project, platform: .ios).suite
            == .xcode(container: repo.appendingPathComponent("App.xcodeproj"), scheme: "Widget", testPlan: nil))
        let plan = try NativeTestPlan.resolve(
            project, platform: .ios, overrides: .init(project: "../App.xcodeproj", scheme: "App", testPlan: "Smoke"),
            only: ["AppTests/LoginTests/testSignIn"], build: false)
        #expect(plan.suite == .xcode(container: repo.appendingPathComponent("App.xcodeproj"), scheme: "App", testPlan: "Smoke"))
        #expect(plan.only == ["AppTests/LoginTests/testSignIn"] && !plan.build)

        let instrumented = try NativeTestPlan.resolve(project, platform: .android)
        #expect(instrumented.gradleTask == ":app:connectedDebugAndroidTest")
        let unit = try NativeTestPlan.resolve(project, platform: .android, overrides: .init(task: "testDebugUnitTest"))
        #expect(unit.gradleTask == ":app:testDebugUnitTest")
        #expect(!unit.needsDevice)

        #expect(throws: (any Error).self) {
            try NativeTestPlan.resolve(project, platform: .ios, overrides: .init(workspace: "../Missing.xcworkspace"))
        }
        #expect(throws: (any Error).self) { try NativeTestPlan.resolve(project, platform: .android, overrides: .init(task: "-x")) }
    }

    @Test func severalSchemesWithTestsAreAChoice() throws {
        let (repo, project) = try repository()
        try Data("<Scheme><TestableReference/></Scheme>".utf8)
            .write(to: repo.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes/Widget.xcscheme"))
        #expect {
            try NativeTestPlan.resolve(project, platform: .ios)
        } throws: { String(describing: $0).contains("several schemes with tests: App, Widget") }
    }

    // MARK: Commands

    @Test func xcodebuildRunsOnTheChosenDeviceIntoTheRunFolder() throws {
        let runner = NativeTestRunner(commands: NativeCommands(), environment: [:])
        let container = URL(fileURLWithPath: "/repo/App.xcworkspace")
        let output = URL(fileURLWithPath: "/repo/mobdev/output/native-runs/run")
        let plan = NativeTestPlan(
            suite: .xcode(container: container, scheme: "App", testPlan: "Unit"),
            only: ["AppTests/LoginTests/testSignIn", "AppTests/adding()"])
        let (tool, arguments) = try runner.command(plan, device: Self.simulator, output: output)
        #expect(tool.path == "/usr/bin/xcodebuild")
        #expect(arguments == [
            "test", "-workspace", "/repo/App.xcworkspace", "-scheme", "App", "-testPlan", "Unit", "-destination", "id=SIM-UDID",
            "-resultBundlePath", "/repo/mobdev/output/native-runs/run/Tests.xcresult", "-collect-test-diagnostics", "never",
            "-only-testing:AppTests/LoginTests/testSignIn", "-only-testing:AppTests/adding()",
        ])
        // An iPhone lets Xcode renew its profile; test-without-building reuses the last build.
        var again = NativeTestPlan(suite: .xcode(container: URL(fileURLWithPath: "/repo/App.xcodeproj"), scheme: "App", testPlan: nil))
        again.build = false
        let (_, onPhone) = try runner.command(again, device: Self.iPhone, output: output)
        #expect(onPhone.prefix(5) == ["test-without-building", "-project", "/repo/App.xcodeproj", "-scheme", "App"])
        #expect(onPhone.contains("-allowProvisioningUpdates"))
        #expect(throws: (any Error).self) { try runner.command(plan, device: Self.emulator, output: output) }
        #expect(throws: (any Error).self) { try runner.command(plan, device: nil, output: output) }
    }

    @Test func gradleNamesTheDeviceAndTheTests() throws {
        let runner = NativeTestRunner(commands: NativeCommands(), environment: ["JAVA_HOME": "/jdk"])
        let root = URL(fileURLWithPath: "/repo/android")
        let output = URL(fileURLWithPath: "/out")
        let connected = NativeTestPlan(
            suite: .gradle(root: root, task: "connectedDebugAndroidTest", module: "app"),
            only: ["com.example.LoginTest#signIn", "com.example.HomeTest"])
        let (tool, arguments) = try runner.command(connected, device: Self.emulator, output: output)
        #expect(tool.path == "/usr/bin/env")
        #expect(arguments == [
            "JAVA_HOME=/jdk", "ANDROID_SERIAL=emulator-5554", "/repo/android/gradlew", "-p", "/repo/android", "--console=plain",
            ":app:connectedDebugAndroidTest",
            "-Pandroid.testInstrumentationRunnerArguments.class=com.example.LoginTest#signIn,com.example.HomeTest",
        ])
        let unit = NativeTestPlan(suite: .gradle(root: root, task: "testDebugUnitTest", module: nil), only: ["com.example.MathTest#adds"])
        let (_, onMac) = try runner.command(unit, device: nil, output: output)
        #expect(onMac == [
            "JAVA_HOME=/jdk", "/repo/android/gradlew", "-p", "/repo/android", "--console=plain", "testDebugUnitTest", "--tests",
            "com.example.MathTest.adds",
        ])
        #expect(throws: (any Error).self) { try runner.command(connected, device: Self.simulator, output: output) }
        #expect(throws: (any Error).self) { try runner.command(connected, device: nil, output: output) }
    }

    @Test func outputLinesCountFinishedTests() {
        let ios: (String) -> NativeTestRunner.ProgressEvent? = { NativeTestRunner.progressEvent($0, platform: .ios) }
        #expect(ios("Test Case '-[SampleTests.SampleTests testAddFails]' failed (1.369 seconds).") == .finished(failed: true))
        #expect(ios("Test Case '-[SampleTests.SampleTests testAddPasses]' passed (0.000 seconds).") == .finished(failed: false))
        #expect(ios("Test Case '-[SampleTests.SampleTests testAddPasses]' started.") == nil)
        #expect(ios("✔ Test addingWorks() passed after 0.001 seconds.") == .finished(failed: false))
        #expect(ios("✘ Test addingBreaks() failed after 0.007 seconds with 1 issue.") == .finished(failed: true))
        #expect(ios("✘ Test addingBreaks() recorded an issue at SwiftTestingTests.swift:9:5: Expectation failed") == nil)
        #expect(ios("✘ Test run with 2 tests in 0 suites failed after 0.008 seconds with 1 issue.") == nil)
        #expect(ios("◇ Test run started.") == .testing)
        let android: (String) -> NativeTestRunner.ProgressEvent? = { NativeTestRunner.progressEvent($0, platform: .android) }
        #expect(android("> Task :app:connectedDebugAndroidTest") == .testing)
        #expect(android("com.example.LoginTest > wrongPassword[Pixel_9_Pro(AVD) - 16] FAILED") == .finished(failed: true))
        #expect(android("> Task :app:compileDebugKotlin") == nil)
    }

    // MARK: Reading results

    @Test func readsXcodesTestsWithFailuresAndPlaces() throws {
        let tests = try XCResultReader.tests(Data(Self.testsJSON.utf8))
        #expect(tests.map(\.name) == ["addingWorks()", "addingBreaks()", "testAddFails()", "testAddPasses()", "testGreetingShows()"])
        #expect(tests.map(\.status) == [.passed, .failed, .failed, .passed, .passed])
        #expect(tests.map(\.identifier) == [
            "SampleTests/addingWorks()", "SampleTests/addingBreaks()", "SampleTests/SampleTests/testAddFails",
            "SampleTests/SampleTests/testAddPasses", "SampleUITests/SampleUITests/testGreetingShows",
        ])
        #expect(tests[2].suite == "SampleTests/SampleTests")
        #expect(tests[2].failures == [
            .init(message: #"XCTAssertEqual failed: ("4") is not equal to ("5") - two and two"#, file: "/Users/dev/Sample/SampleTests/SampleTests.swift", line: 10)
        ])
        #expect(tests[2].failures[0].location == "SampleTests.swift:10")
        #expect(tests[1].failures[0].text == "SwiftTestingTests.swift:9: Expectation failed: add(3, 4) == 8\nadd(3, 4) → 7")
        #expect(abs(tests[4].seconds - 47.0356730222702) < 0.001)
        #expect(XCResultReader.duration(summary: Data(Self.summaryJSON.utf8)).map { Int($0) } == 400)
    }

    @Test func readsCompilerErrorsWithTheirLines() {
        let errors = XCResultReader.buildErrors(Data(Self.buildJSON.utf8))
        #expect(errors.count == 2)
        #expect(errors.map(\.line) == [6, 10])
        #expect(errors[0].location == "SampleTests.swift:6")
        #expect(errors[0].message.hasPrefix("Use of 'add' refers to instance method"))
    }

    /// What `export attachments --test-id` wrote for a failed UI test on Xcode 27: none of it is
    /// marked as associated with the failure.
    static let manifestJSON = #"""
        [{"attachments": [
          {"configurationName": "Test Scheme Action", "deviceId": "SIM", "deviceName": "mobdev", "exportedFileName": "2AB6F026.txt", "isAssociatedWithFailure": false, "suggestedHumanReadableName": "App UI hierarchy for dev.mobdev.Sample", "timestamp": 1793206808.116},
          {"configurationName": "Test Scheme Action", "deviceId": "SIM", "deviceName": "mobdev", "exportedFileName": "9F08B873", "isAssociatedWithFailure": false, "suggestedHumanReadableName": "UI Snapshot 2026-10-28 at 06.00.08 PM", "timestamp": 1793206808.116},
          {"configurationName": "Test Scheme Action", "deviceId": "SIM", "deviceName": "mobdev", "exportedFileName": "AFB93861.mp4", "isAssociatedWithFailure": false, "suggestedHumanReadableName": "Screen Recording 2026-10-28 at 05.56.15 PM.mp4", "timestamp": 1793206575.0},
          {"configurationName": "Test Scheme Action", "deviceId": "SIM", "deviceName": "mobdev", "exportedFileName": "B1.txt", "isAssociatedWithFailure": false, "suggestedHumanReadableName": "Debug description for `missing`/Button: 1", "timestamp": 1793206808.0}],
          "testIdentifier": "SampleUIFailingTests/testMissingButton()",
          "testIdentifierURL": "test://com.apple.xcode/Sample/SampleUITests/SampleUIFailingTests/testMissingButton"}]
        """#

    @Test func attachmentsGetTheirReadableNames() throws {
        let folder = try folder()
        for name in ["2AB6F026.txt", "9F08B873", "AFB93861.mp4", "B1.txt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let files = XCResultReader.readableAttachments(manifest: Data(Self.manifestJSON.utf8), folder: folder)
        #expect(files.map { ($0 as NSString).lastPathComponent } == [
            "App UI hierarchy for dev.mobdev.Sample.txt", "UI Snapshot 2026-10-28 at 06.00.08 PM",
            "Screen Recording 2026-10-28 at 05.56.15 PM.mp4", "Debug description for `missing`-Button- 1.txt",
        ])
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        let urls = XCResultReader.identifierURLs(Data(Self.testsJSON.utf8))
        #expect(urls["SampleTests/addingBreaks()"] == "test://com.apple.xcode/Sample/SampleTests/addingBreaks()")
        #expect(urls["SampleTests/SampleTests/testAddFails"] == "test://com.apple.xcode/Sample/SampleTests/SampleTests/testAddFails")
    }

    @Test func readsGradlesJUnitReports() throws {
        let instrumented = try JUnitReader.tests(Data(Self.instrumentedXML.utf8))
        #expect(instrumented.map(\.name) == ["signIn", "wrongPassword", "later"])
        #expect(instrumented.map(\.status) == [.passed, .failed, .skipped])
        #expect(instrumented[1].identifier == "com.example.app.LoginTest#wrongPassword")
        #expect(instrumented[1].failures.count == 1)
        #expect(instrumented[1].failures[0].message.hasPrefix("java.lang.AssertionError: expected:<Welcome> but was:<Error>\n"))
        #expect(instrumented[1].failures[0].location == "LoginTest.kt:42")

        let unit = try JUnitReader.tests(Data(Self.unitXML.utf8))
        #expect(unit.map(\.status) == [.passed, .failed])
        // The stack trace repeats the message; it says it once, and the place is the test's own frame.
        #expect(unit[1].failures[0].message.components(separatedBy: "expected:<2> but was:<3>").count == 2)
        #expect(unit[1].failures[0].line == 30)
        #expect(JUnitReader.place(in: "at com.example.app.MathTest.divides(MathTest.kt:17)", className: "com.example.app.MathTest")?.line == 17)
        #expect(throws: (any Error).self) { try JUnitReader.tests(Data("not xml <".utf8)) }
    }

    @Test func gradlesReasonForFailing() {
        let log = """
            > Task :app:compileDebugKotlin FAILED

            FAILURE: Build failed with an exception.

            * What went wrong:
            Execution failed for task ':app:compileDebugKotlin'.
            > Compilation error. See log for more details

            * Try:
            > Run with --stacktrace option to get the stack trace.
            """
        #expect(NativeTestRunner.gradleFailure(log) == "Execution failed for task ':app:compileDebugKotlin'. > Compilation error. See log for more details")
        #expect(NativeTestRunner.gradleFailure("nothing") == nil)
    }

    @Test func resultsWriteJUnitAndMarkdown() throws {
        let (_, project) = try repository()
        let output = try folder()
        let plan = NativeTestPlan(suite: .xcode(container: URL(fileURLWithPath: "/repo/App.xcodeproj"), scheme: "App", testPlan: nil))
        var result = NativeTestResult(project: project, plan: plan, device: Self.simulator, output: output)
        // results.json keeps whole seconds.
        result.started = Date(timeIntervalSince1970: 1_793_202_758)
        result.progress = nil
        result.seconds = 12
        result.tests = try XCResultReader.tests(Data(Self.testsJSON.utf8))
        try result.write()
        let loaded = try NativeTestResult.load(output)
        #expect(loaded == result)
        #expect(!loaded.passed && loaded.counts == (3, 2, 0))
        let junit = try String(contentsOf: output.appendingPathComponent("junit.xml"), encoding: .utf8)
        #expect(junit.contains(#"<testsuites name="App scheme App of App.xcodeproj" tests="5" failures="2" errors="0" skipped="0""#))
        #expect(junit.contains(#"<testcase name="testAddFails()" classname="SampleTests/SampleTests" time="1.369" file="/Users/dev/Sample/SampleTests/SampleTests.swift" line="10">"#))
        #expect(junit.contains("is not equal to (&quot;5&quot;)"))
        let markdown = try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(markdown.contains("| SampleTests/SampleTests testAddFails() | SampleTests.swift:10 |"))
        #expect(result.summaryLine == "Native tests \"App\" (scheme App of App.xcodeproj) on iPhone 17: 3 passed, 2 failed in 12.0 s.")
    }

    // MARK: Running

    /// A project whose mobdev.json names its Xcode project, and a runner with scripted commands.
    func xcodeSetup() throws -> (TestProject, NativeCommands, NativeTestRunner) {
        let (_, project) = try repository(native: #"{"ios": {"project": "../App.xcodeproj", "scheme": "App"}}"#)
        let commands = NativeCommands()
        commands.tests = Self.testsJSON
        commands.summary = "warning: something first\n" + Self.summaryJSON
        commands.build = Self.buildJSON
        commands.status = 65
        commands.onStart = NativeCommands.writeBundle
        commands.lines = [
            "Test Suite 'All tests' started at 2026-10-28 16:57:41.346.",
            "Test Case '-[SampleTests.SampleTests testAddFails]' failed (1.369 seconds).",
            "✔ Test addingWorks() passed after 0.001 seconds.",
        ]
        return (project, commands, NativeTestRunner(commands: commands, environment: [:]))
    }

    @Test func aRunReadsTheResultBundleAndKeepsTheFiles() async throws {
        let (project, commands, runner) = try xcodeSetup()
        commands.manifests = [
            "test://com.apple.xcode/Sample/SampleTests/SampleTests/testAddFails":
                #"[{"testIdentifier": "SampleTests/testAddFails()", "attachments": [{"exportedFileName": "A1.png", "suggestedHumanReadableName": "Screenshot"}]}]"#
        ]
        let plan = try NativeTestPlan.resolve(project, platform: .ios)
        let output = try NativeTestRuns.newRunFolder(for: project)
        #expect(output.path.hasPrefix(project.folder.path + "/output/native-runs/"))
        let (run, started) = runner.start(plan, project: project, device: Self.simulator, output: output, source: "test")
        #expect(started)
        let result = await run.wait(timeout: 10)
        #expect(!result.running)
        #expect(result.counts == (3, 2, 0))
        #expect(result.error == nil)
        #expect(Int(result.seconds) == 400)
        #expect(result.resultBundle == output.appendingPathComponent("Tests.xcresult").path)
        #expect(result.tests[2].attachments == [output.appendingPathComponent("attachments/2-sampletests-sampletests-testaddfails/Screenshot.png").path])
        #expect(result.tests[1].attachments == nil)
        // One export per failed test, by its identifier URL.
        let exports = commands.ran.get().filter { $0.contains("attachments") }
        #expect(exports.compactMap { call in call.firstIndex(of: "--test-id").map { call[$0 + 1] } } == [
            "test://com.apple.xcode/Sample/SampleTests/addingBreaks()", "test://com.apple.xcode/Sample/SampleTests/SampleTests/testAddFails",
        ])
        #expect(result.command.first == "/usr/bin/xcodebuild")
        let log = try String(contentsOf: URL(fileURLWithPath: result.log), encoding: .utf8)
        #expect(log.contains("testAddFails]' failed"))
        #expect(NativeTestRuns.result(for: project)?.tests == result.tests)
        #expect(NativeTestRuns.result(for: project)?.output == output.path)
        #expect(NativeTestRuns.running(for: project.folder) == nil)
        // The build errors are only asked for when no test ran.
        #expect(!commands.ran.get().contains { $0.contains("build-results") })
    }

    @Test func aBuildThatFailsSaysWhereAndAMissingBundleSaysWhy() async throws {
        let (project, commands, runner) = try xcodeSetup()
        commands.tests = #"{"devices": [], "testNodes": [], "testPlanConfigurations": []}"#
        let plan = try NativeTestPlan.resolve(project, platform: .ios)
        let (run, _) = runner.start(plan, project: project, device: Self.simulator, output: try NativeTestRuns.newRunFolder(for: project), source: "test")
        let failed = await run.wait(timeout: 10)
        #expect(failed.buildErrors.count == 2)
        #expect(failed.error?.hasPrefix("The build failed: SampleTests.swift:6: Use of 'add'") == true)
        #expect(!failed.passed)
        #expect(try String(contentsOf: URL(fileURLWithPath: failed.output).appendingPathComponent("junit.xml"), encoding: .utf8)
            .contains(#"<error message="The build failed"#))

        commands.onStart = nil
        commands.status = 70
        commands.lines = [
            "xcodebuild: error: Unable to find a device matching the provided destination specifier:",
            "\t\t{ id:SIM-UDID }",
        ]
        let (missing, _) = runner.start(plan, project: project, device: Self.simulator, output: try NativeTestRuns.newRunFolder(for: project), source: "test")
        let none = await missing.wait(timeout: 10)
        #expect(none.error?.contains("Unable to find a device matching the provided destination specifier") == true)
        #expect(none.resultBundle == nil)
    }

    @Test func gradleReadsTheReportsItWroteAndElseNotesAnUpToDateTask() async throws {
        let (repo, project) = try repository(native: #"{"android": {"gradle_root": "../android", "module": "app", "task": "testDebugUnitTest"}}"#)
        let reports = repo.appendingPathComponent("android/app/build/test-results/testDebugUnitTest")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        // A report of another, older run that must not count.
        let stale = repo.appendingPathComponent("android/app/build/outputs/androidTest-results/connected/TEST-old.xml")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.instrumentedXML.utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: stale.path)
        let commands = NativeCommands()
        commands.status = 1
        let xml = Self.unitXML
        commands.onStart = { _ in try? Data(xml.utf8).write(to: reports.appendingPathComponent("TEST-com.example.app.MathTest.xml")) }
        commands.lines = ["> Task :app:testDebugUnitTest", "MathTest > divides FAILED", "* What went wrong:", "Execution failed for task ':app:testDebugUnitTest'."]
        let runner = NativeTestRunner(commands: commands, environment: [:])
        let plan = try NativeTestPlan.resolve(project, platform: .android)
        let (run, _) = runner.start(plan, project: project, device: nil, output: try NativeTestRuns.newRunFolder(for: project), source: "test")
        let result = await run.wait(timeout: 10)
        #expect(result.device == nil)
        #expect(result.tests.map(\.name) == ["adds", "divides"])
        #expect(result.error == nil)
        #expect(result.note == nil)
        #expect(result.summaryLine.contains("on this Mac: 1 passed, 1 failed"))
        #expect(!commands.started.get()[0].contains { $0.hasPrefix("ANDROID_SERIAL=") })

        // Gradle ran nothing: the task's own newest reports stand, with a note. An instrumented
        // run's report from after them belongs to another task.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: reports.appendingPathComponent("TEST-com.example.app.MathTest.xml").path)
        let other = repo.appendingPathComponent("android/app/build/outputs/androidTest-results/connected/debug/TEST-new.xml")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.instrumentedXML.utf8).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: other.path)
        commands.onStart = nil
        commands.status = 0
        commands.lines = ["> Task :app:testDebugUnitTest UP-TO-DATE"]
        let (again, _) = runner.start(plan, project: project, device: nil, output: try NativeTestRuns.newRunFolder(for: project), source: "test")
        let upToDate = await again.wait(timeout: 10)
        #expect(upToDate.tests.map(\.name) == ["adds", "divides"])
        #expect(upToDate.note?.hasPrefix("Gradle found the task up to date") == true)
    }

    @Test func onlyTestTasksRunAndOnlyRunFoldersArePruned() throws {
        let (_, project) = try repository(native: #"{"android": {"gradle_root": "../android", "task": "publish"}}"#)
        #expect(throws: ToolFailure.self) { try NativeTestPlan.resolve(project, platform: .android) }
        var overrides = NativeTestPlan.Overrides()
        overrides.task = ":app:testDebugUnitTest"
        #expect(try NativeTestPlan.resolve(project, platform: .android, overrides: overrides).gradleTask == ":app:testDebugUnitTest")
        #expect(NativeTestRuns.isRunName("2026-10-28 18.04.12"))
        #expect(NativeTestRuns.isRunName("2026-10-28 18.04.12 (2)"))
        #expect(!NativeTestRuns.isRunName("baseline"))
        #expect(!NativeTestRuns.isRunName("2026-10-28 notes"))
    }

    @Test func quittingStopsRunsGoingOn() async throws {
        let (project, commands, runner) = try xcodeSetup()
        commands.held = true
        let (run, started) = runner.start(
            try NativeTestPlan.resolve(project, platform: .ios), project: project,
            device: TestRunResult.Device(id: "SIM", name: "iPhone 17", kind: "simulator"),
            output: try NativeTestRuns.newRunFolder(for: project), source: "test")
        #expect(started)
        while commands.started.get().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        NativeTestRuns.cancelAll()
        let result = await run.wait(timeout: 10)
        #expect(commands.stops.get() == 1)
        #expect(result.progress == nil)
        #expect(NativeTestRuns.running(for: project.folder) == nil)
    }

    @Test func theToolRunsInTheBackgroundHoldingTheDevice() async throws {
        let (project, commands, runner) = try xcodeSetup()
        commands.held = true
        let device = FakeSimulatorDevice(lines: [])
        let tools = PhoneTools(phone: device, activity: ActivityLog(), settleDelay: 0) { _, _ in [] }
        let projects = ProjectList()
        try await NativeTestRunner.$current.withValue(runner) {
            let arguments: JSONValue = ["project": .string(project.folder.path), "wait": 0]
            let first = try await tools.call("run_native_tests", arguments: arguments, source: "agent", screenshotByDefault: false)
            #expect(!first.isError)
            #expect(first.text.hasPrefix("Started native tests of App: scheme App of App.xcodeproj on iPhone 17."))
            #expect(first.data?["running"]?.boolValue == true)
            for _ in 0..<100 where commands.started.get().isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(commands.started.get().first?.contains("id=\(device.id)") == true)

            // Others get "Busy" until it ends; a second run of the project reports the first.
            let tap = try await tools.call("home", arguments: [:], source: "relay", screenshotByDefault: false)
            #expect(tap.isError && tap.text.hasPrefix("Busy: a native test run from agent"))
            let second = try await tools.call("run_native_tests", arguments: arguments, source: "app", screenshotByDefault: false)
            #expect(second.text.contains("Busy") || second.text.contains("already has native tests running"))
            let reading = try ProjectTools.call("native_test_result", Arguments(["project": .string(project.folder.path)]), projects: projects)
            #expect(reading.text.contains("Still running"))
            #expect(reading.data?["progress"]?["finished"]?.doubleValue == 2)

            commands.release()
            var finished: NativeTestResult?
            for _ in 0..<100 {
                if let result = NativeTestRuns.result(for: project), NativeTestRuns.running(for: project.folder) == nil {
                    finished = result
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(finished.map { $0.counts == (3, 2, 0) } == true)
            let done = try ProjectTools.call("native_test_result", Arguments(["project": .string(project.folder.path)]), projects: projects)
            #expect(done.text.contains("✗ SampleTests/SampleTests testAddFails() (1.4 s): SampleTests.swift:10: XCTAssertEqual failed"))
            // The device is free again, and the end shows in the activity.
            for _ in 0..<50 where tools.hold.get() != nil { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(tools.hold.get() == nil)
            #expect(tools.activity.all.contains { $0.tool == "run_native_tests" && $0.summary.contains("3 passed, 2 failed") })
        }
    }

    @Test func theToolWaitsForTheEndWhenAsked() async throws {
        let (project, _, runner) = try xcodeSetup()
        let tools = PhoneTools(phone: FakeSimulatorDevice(lines: []), activity: ActivityLog(), settleDelay: 0) { _, _ in [] }
        try await NativeTestRunner.$current.withValue(runner) {
            let arguments: JSONValue = ["project": .string(project.folder.path), "only": ["SampleTests/SampleTests/testAddFails"]]
            let output = try await tools.call("run_native_tests", arguments: arguments, source: "agent", screenshotByDefault: false)
            #expect(output.isError)
            #expect(output.text.hasPrefix("Native tests \"App\" (scheme App of App.xcodeproj) on iPhone 17: 3 passed, 2 failed"))
            #expect(output.data?["counts"]?["failed"]?.doubleValue == 2)
            #expect(tools.hold.get() == nil)
        }
        // An Android suite on a simulator says so before starting anything.
        let android: JSONValue = ["project": .string(project.folder.path), "platform": "android", "task": "connectedDebugAndroidTest"]
        let wrong = try await tools.call("run_native_tests", arguments: android, source: "agent", screenshotByDefault: false)
        #expect(wrong.isError)
    }

    @Test func listTestsNamesTheNativeSuites() throws {
        let (_, project) = try repository(native: #"{"ios": {"project": "../App.xcodeproj", "scheme": "App"}, "android": {"module": "app"}}"#)
        let output = try ProjectTools.call("list_tests", Arguments(["project": .string(project.folder.path)]), projects: ProjectList())
        #expect(output.text.contains("Native iOS tests: ../App.xcodeproj, scheme App"))
        #expect(output.text.contains("Native Android tests: module app, task connectedDebugAndroidTest"))
    }
}

/// `Mobdev test --native`: its options and exit codes.
@Suite struct NativeTestCommandTests {
    @Test func parsesTheNativeOptions() throws {
        let options = try NativeTestCommand.parse([
            "mobdev/", "--native", "--simulator", "iPhone 17", "--scheme", "App", "--test-plan", "Unit", "--test",
            "AppTests/LoginTests/testSignIn", "--no-build", "--artifacts", "out", "--wait", "30",
        ])
        #expect(options.project == "mobdev/")
        #expect(options.platform == .ios)
        #expect(options.simulator == "iPhone 17")
        #expect(options.overrides == .init(scheme: "App", testPlan: "Unit"))
        #expect(options.only == ["AppTests/LoginTests/testSignIn"])
        #expect(!options.build && options.artifacts == "out" && options.wait == 30)
        let android = try NativeTestCommand.parse(["p", "--native", "--emulator", "Pixel_9_Pro", "--module", "app", "--task", "connectedDebugAndroidTest"])
        #expect(android.platform == .android && android.overrides == .init(task: "connectedDebugAndroidTest", module: "app"))
        let unit = try NativeTestCommand.parse(["p", "--native", "--platform", "android", "--task", "testDebugUnitTest"])
        #expect(unit.platform == .android && unit.device == nil)

        func problem(_ arguments: [String]) -> String {
            do {
                _ = try NativeTestCommand.parse(arguments)
                return ""
            } catch {
                return String(describing: error)
            }
        }
        #expect(problem(["p", "--native", "--var", "A=b"]).contains("not for --native"))
        #expect(problem(["p", "--native", "--device", "x", "--simulator", "iPhone 17"]).contains("one device"))
        #expect(problem(["p", "--native", "--platform", "android", "--simulator", "iPhone 17"]).contains("--simulator runs iOS"))
        #expect(problem(["p", "--native", "--platform", "windows"]).contains("ios or android"))
        #expect(problem(["--native"]).contains("Which project"))
    }

    @Test func exitCodesSayPassedFailedOrCouldNotRun() throws {
        let project = TestProject(folder: URL(fileURLWithPath: "/tmp/p"), name: "P")
        let plan = NativeTestPlan(suite: .gradle(root: URL(fileURLWithPath: "/tmp/a"), task: "testDebugUnitTest", module: nil))
        var result = NativeTestResult(project: project, plan: plan, device: nil, output: URL(fileURLWithPath: "/tmp/out"))
        result.progress = nil
        result.tests = [.init(name: "a", suite: "S", identifier: "S#a", status: .passed, seconds: 0)]
        #expect(NativeTestCommand.exitCode(result) == 0)
        result.tests.append(.init(name: "b", suite: "S", identifier: "S#b", status: .failed, seconds: 0, failures: [.init(message: "x")]))
        #expect(NativeTestCommand.exitCode(result) == 1)
        result.error = "The build failed"
        #expect(NativeTestCommand.exitCode(result) == 2)
        result.error = nil
        result.tests = []
        #expect(NativeTestCommand.exitCode(result) == 1)
    }

    @Test func aMissingSuiteCannotRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-native-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data(#"{"name": "Empty"}"#.utf8).write(to: folder.appendingPathComponent("mobdev.json"))
        let lines = Locked<[String]>([])
        let code = await NativeTestCommand.execute(
            [folder.path, "--native", "--platform", "android", "--task", "testDebugUnitTest"], output: { line in lines.withLock { $0.append(line) } })
        #expect(code == 2)
        #expect(lines.get().joined().contains("No Gradle wrapper"))
    }
}
