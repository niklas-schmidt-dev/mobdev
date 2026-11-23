import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

@Suite struct RelayTypingTests {
    func phone(_ input: InputRoute) -> FakePhone {
        let phone = FakePhone(lines: [])
        phone.route.set((input, input == .runner ? .running : nil))
        return phone
    }

    func type(_ phone: FakePhone, _ text: String, from source: String) async throws -> ToolOutput {
        try await PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
            .call("type_text", arguments: ["text": .string(text)], source: source, screenshotByDefault: false)
    }

    /// Mobdev Runner types about ten characters a second: 1000 would outlast the relay's 90 seconds.
    @Test func throughARelayMobdevRunnerTakes500CharactersPerCall() async throws {
        let runner = phone(.runner)
        let refused = try await type(runner, String(repeating: "a", count: 501), from: "relay")
        #expect(refused.isError)
        #expect(refused.text.contains("at most 500 characters of this text"))
        #expect(refused.text.contains("Send it in parts of up to 500 characters"))
        #expect(runner.events.get().isEmpty)

        #expect(try await !type(runner, String(repeating: "a", count: 500), from: "relay").isError)
        // From this Mac, as before.
        #expect(try await !type(runner, String(repeating: "a", count: 1000), from: "local").isError)
        #expect(runner.events.get().count == 2)
    }

    /// 60 ms a key, 120 ms with Shift: 1000 small letters fit, 625 capitals do.
    @Test func overBluetoothItDependsOnTheKeys() async throws {
        let bluetooth = phone(.bluetooth)
        #expect(try await !type(bluetooth, String(repeating: "a", count: 1000), from: "relay").isError)
        #expect(try await !type(bluetooth, String(repeating: "A", count: 625), from: "relay").isError)
        let capitals = try await type(bluetooth, String(repeating: "A", count: 626), from: "relay")
        #expect(capitals.isError)
        #expect(capitals.text.contains("at most 625 characters"))
        #expect(capitals.text.contains("Bluetooth keyboard"))
        // Accents are two keys, the first with Option: 180 ms.
        let accents = try await type(bluetooth, String(repeating: "é", count: 500), from: "relay")
        #expect(accents.text.contains("at most 416 characters"))
        // An accented capital: Option, then Shift: 240 ms.
        let capitalAccents = try await type(bluetooth, String(repeating: "Á", count: 313), from: "relay")
        #expect(capitalAccents.text.contains("at most 312 characters"))
        #expect(bluetooth.events.get().count == 2)
    }

    @Test func simulatorsAndAndroidTypeAsBefore() async throws {
        for route in [InputRoute.direct("Simulator"), .direct("scrcpy"), .direct("adb")] {
            let device = phone(route)
            #expect(try await !type(device, String(repeating: "a", count: 1000), from: "relay").isError)
            let tooLong = try await type(device, String(repeating: "a", count: 1001), from: "relay")
            #expect(tooLong.text.contains("at most 1000 per call"))
        }
    }

    @Test func aFlowsStepsAreNotCallsOfTheirOwn() async throws {
        let runner = phone(.runner)
        let text = String(repeating: "a", count: 600)
        let output = try await PhoneTools(phone: runner, activity: ActivityLog(), settleDelay: 0).call(
            "run_flow", arguments: ["steps": [["type_text": ["text": .string(text)]]]], source: "relay",
            screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(runner.events.get() == [.text(text)])
    }
}
