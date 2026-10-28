import Foundation
import Testing
@testable import MobdevCore

/// Secrets live in a temporary folder here, never in the app's data. Serialized, because the
/// folder is the same for the whole process.
@Suite(.serialized) struct SecretTests {
    func withSecrets(_ body: () async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-secrets-\(UUID().uuidString)")
        TypedSecrets.folderOverride.set(folder)
        defer {
            TypedSecrets.folderOverride.set(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        try await body()
    }

    func tools(_ phone: FakePhone = FakePhone(lines: [])) -> (tools: PhoneTools, log: ActivityLog) {
        let log = ActivityLog()
        return (PhoneTools(phone: phone, activity: log, settleDelay: 0), log)
    }

    @Test func secretsAreTypedWithoutShowingThem() async throws {
        try await withSecrets {
            try TypedSecrets.set("test-password", value: "hunter2", relay: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: TypedSecrets.file.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            let phone = FakePhone(lines: [])
            let (tools, log) = tools(phone)
            tools.recorder.start()
            let typed = try await tools.call(
                "type_secret", arguments: ["name": "test-password", "submit": true], source: "local",
                screenshotByDefault: false)
            #expect(typed.text == "Typed the secret \"test-password\" and pressed Return.")
            #expect(phone.events.get() == [.type(try KeyboardLayout.us.strokes(typing: "hunter2") + [KeyStroke(0x28)])])
            #expect(log.all.first?.summary == "typed the secret test-password")
            #expect(tools.recorder.stop() == [Flow.Step("type_secret", ["name": "test-password", "submit": true])])
            let recent = try await tools.call("recent_steps", arguments: [:], source: "local", screenshotByDefault: false)
            #expect(recent.text.contains("type_secret"))
            #expect(!recent.text.contains("hunter2"))

            let relayed = try await tools.call(
                "type_secret", arguments: ["name": "test-password"], source: "relay", screenshotByDefault: false)
            #expect(relayed.isError)
            #expect(relayed.text.contains("for agents on this Mac only"))
            try TypedSecrets.setRelay("test-password", true)
            let allowed = try await tools.call(
                "type_secret", arguments: ["name": "test-password"], source: "relay", screenshotByDefault: false)
            #expect(!allowed.isError)

            let unknown = try await tools.call(
                "type_secret", arguments: ["name": "pin"], source: "local", screenshotByDefault: false)
            #expect(unknown.text.hasPrefix("No secret \"pin\". Secrets: test-password."))
        }
    }

    @Test func flowsTypeSecretsByName() async throws {
        try await withSecrets {
            try TypedSecrets.set("otp", value: "123456", relay: false)
            let phone = FakePhone(lines: [])
            let (tools, log) = tools(phone)
            let result = await tools.run(Flow(name: "Sign in", steps: [Flow.Step("type_secret", ["name": "otp"])]), source: "local")
            #expect(result.passed)
            #expect(phone.events.get() == [.type(try KeyboardLayout.us.strokes(typing: "123456"))])
            #expect(!log.all.contains { $0.summary.contains("123456") })
        }
    }

    @Test func secretsThatCannotBeTypedDoNotLeak() async throws {
        try await withSecrets {
            try TypedSecrets.set("emoji", value: "pass🙂word", relay: false)
            let (tools, _) = tools()
            let output = try await tools.call("type_secret", arguments: ["name": "emoji"], source: "local", screenshotByDefault: false)
            #expect(output.isError)
            #expect(!output.text.contains("🙂"))
            #expect(output.text.contains("has a character this device cannot type"))
            #expect(throws: (any Error).self) { try TypedSecrets.set("bad name", value: "x", relay: false) }
        }
    }

    @Test func namesAreListedWithoutADevice() async throws {
        try await withSecrets {
            let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0)
            let none = try await tools.call("list_secrets", arguments: nil, source: "relay", screenshotByDefault: false)
            #expect(none.text.hasPrefix("No secrets yet."))
            try TypedSecrets.set("test-password", value: "hunter2", relay: false)
            try TypedSecrets.set("otp", value: "123456", relay: true)
            let listed = try await tools.call("list_secrets", arguments: nil, source: "relay", screenshotByDefault: false)
            #expect(listed.text == "otp\ntest-password (this Mac only)")
            #expect(listed.data == [["name": "otp", "relay": true], ["name": "test-password", "relay": false]])
        }
    }

    @Test func secretCommandSetsListsAndRemoves() async throws {
        try await withSecrets {
            var lines: [String] = []
            #expect(SecretCommand.execute(["set", "otp", "--relay"], value: { "123456" }, output: { lines.append($0) }) == 0)
            #expect(SecretCommand.execute(["set", "pin"], value: { "0000" }, output: { lines.append($0) }) == 0)
            #expect(SecretCommand.execute(["list"], value: { nil }, output: { lines.append($0) }) == 0)
            #expect(lines.last == "otp  (also through the relay)\npin")
            #expect(SecretCommand.execute(["remove", "pin"], value: { nil }, output: { lines.append($0) }) == 0)
            #expect(TypedSecrets.list().map(\.name) == ["otp"])
            #expect(SecretCommand.execute(["set"], value: { nil }, output: { lines.append($0) }) == 2)
            #expect(lines.last?.hasPrefix("Usage: Mobdev secret set") == true)
            #expect(!lines.joined().contains("123456"))
        }
    }

    /// A secret that mobdev.json names comes from the stored ones when the run and the environment
    /// leave it out, so an agent can run a sign-in test without knowing the password.
    @Test func testProjectsTakeStoredSecrets() async throws {
        try await withSecrets {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-project-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
            try Data("{\"secrets\": [\"PASSWORD\"]}".utf8).write(to: root.appendingPathComponent("mobdev.json"))
            try Data("{\"steps\": [{\"type_text\": {\"text\": \"${PASSWORD}\"}}]}".utf8)
                .write(to: root.appendingPathComponent("tests/sign-in.json"))
            let project = try TestProject.load(root)
            try TypedSecrets.set("PASSWORD", value: "hunter2", relay: false)

            let phone = FakePhone(lines: [])
            let deviceTools = tools(phone).tools
            deviceTools.recorder.start()
            let local = await deviceTools.runTests(
                project, options: TestRunOptions(output: root.appendingPathComponent("out"), video: false), source: "local")
            #expect(local.tests.first?.status == .passed)
            // What an agent can read back of the run keeps the name, not the value.
            let recent = try await deviceTools.call("recent_steps", arguments: [:], source: "relay", screenshotByDefault: false)
            #expect(recent.text.contains("${PASSWORD}"), "\(recent.text)")
            #expect(!recent.text.contains("hunter2"))
            #expect(deviceTools.recorder.stop() == [Flow.Step("type_text", ["text": "${PASSWORD}"])])
            #expect(phone.events.get() == [.type(try KeyboardLayout.us.strokes(typing: "hunter2"))])
            let saved = try String(contentsOf: root.appendingPathComponent("out/results.json"), encoding: .utf8)
            #expect(saved.contains("${PASSWORD}"))
            #expect(!saved.contains("hunter2"))

            // Through the relay only when the secret allows it.
            let relayed = await tools().tools.runTests(
                project, options: TestRunOptions(output: root.appendingPathComponent("out2"), video: false), source: "relay")
            #expect(relayed.tests.first?.status == .failed)
            #expect(relayed.tests.first?.message.contains("Variable PASSWORD is not set. Store it in Mobdev's Settings › Secrets") == true)
        }
    }
}
