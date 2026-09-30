import Foundation
import Testing
@testable import MobdevCore

@Suite struct DeviceModelTests {
    @Test func knownModelsHaveNamesAndFronts() {
        let info = DeviceInfo(
            id: "00008120-000639440C13C01E", name: "iPhone von Niklas", productType: "iPhone15,2", osVersion: "27.0",
            buildVersion: "24A437", deviceClass: "iPhone", colorCode: "1")
        #expect(info.modelName == "iPhone 14 Pro")
        #expect(info.formFactor == .dynamicIsland)
        #expect(info.systemName == "iOS 27.0")
        #expect(!info.isLightColor)
        #expect(DeviceModels.formFactor(for: "iPhone14,6", deviceClass: "iPhone") == .homeButton)
        #expect(DeviceModels.formFactor(for: "iPhone13,2", deviceClass: "iPhone") == .notch)
    }

    @Test func unknownModelsFallBackGracefully() {
        let future = DeviceInfo(
            id: "x", name: "New", productType: "iPhone99,1", osVersion: "30.0", buildVersion: "", deviceClass: "iPhone")
        #expect(future.modelName == "iPhone99,1")
        #expect(future.formFactor == .dynamicIsland)
        #expect(DeviceModels.formFactor(for: "iPad99,1", deviceClass: "iPad") == .iPad)
    }
}

@Suite struct ActivityPersistenceTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-activity-\(UUID().uuidString)")
            .appendingPathComponent("device.jsonl")
    }

    @Test func entriesSurviveAReload() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = ActivityLog(limit: 10, file: file)
        log.record(source: "local", tool: "tap", summary: "Tapped (1, 2).", failed: false)
        log.record(source: "relay", tool: "type_text", summary: "Typed 3 characters.", failed: false)

        let reloaded = ActivityLog(limit: 10, file: file)
        #expect(reloaded.all.map(\.tool) == ["type_text", "tap"])
        #expect(reloaded.all.first?.source == "relay")
        #expect(reloaded.all == log.all)
    }

    @Test func reloadKeepsTheNewestInMemoryAndOlderOnesOnDisk() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = ActivityLog(limit: 2, file: file)
        for index in 0..<12 {
            log.record(source: "local", tool: "tap", summary: "\(index)", failed: false)
            Thread.sleep(forTimeInterval: 0.002)  // distinct milliseconds
        }
        #expect(log.all.map(\.summary) == ["11", "10"])

        let reloaded = ActivityLog(limit: 2, file: file)
        #expect(reloaded.all.map(\.summary) == ["11", "10"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 12)

        // Paging further back continues where memory ends.
        let oldest = try #require(reloaded.all.last)
        #expect(reloaded.older(than: oldest.date, limit: 3).map(\.summary) == ["9", "8", "7"])
        let page = reloaded.older(than: oldest.date, limit: 100)
        #expect(page.map(\.summary) == (0...9).reversed().map(String.init))
        #expect(reloaded.older(than: try #require(page.last).date, limit: 5).isEmpty)
    }

    @Test func clearEmptiesTheFile() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = ActivityLog(limit: 10, file: file)
        log.record(source: "local", tool: "home", summary: "Went home.", failed: false)
        log.clear()
        #expect(ActivityLog(limit: 10, file: file).all.isEmpty)
    }
}

@Suite struct DeviceMatchingTests {
    typealias Key = DeviceHub.DeviceKey
    let keys = [
        Key(id: "00008120-000639440C13C01E", captureID: "cap-a", name: "iPhone", connected: true),
        Key(id: "00008120-000639440C13C01F", captureID: "cap-b", name: "iPhone", connected: true),
        Key(id: "00008030-001A2B3C4D5E6F70", captureID: "cap-c", name: "Test iPad", connected: false),
    ]

    @Test func exactIDsWin() {
        #expect(DeviceHub.matches("00008120-000639440C13C01F", in: keys) == [1])
        #expect(DeviceHub.matches("cap-c", in: keys) == [2])
    }

    /// Two phones with one name, or one prefix: both are candidates, so neither is picked.
    @Test func ambiguousNamesAndPrefixesMatchSeveral() {
        #expect(DeviceHub.matches("iphone", in: keys) == [0, 1])
        #expect(DeviceHub.matches("00008120", in: keys) == [0, 1])
        #expect(DeviceHub.matches("test ipad", in: keys) == [2])
        #expect(DeviceHub.matches("00008030", in: keys) == [2])
        #expect(DeviceHub.matches("00008", in: keys) == [])  // Prefixes need six characters.
    }

    @Test func withoutAQueryOnlyAConnectedDeviceIsPicked() {
        #expect(DeviceHub.matches(nil, in: keys) == [0, 1])
        #expect(DeviceHub.matches(nil, in: [keys[2]]) == [0])
        #expect(DeviceHub.matches(" ", in: [keys[0], keys[2]]) == [0])
    }
}

@Suite struct DeviceToolsTests {
    /// A `device` that is not a string must not fall back to picking a phone automatically.
    @Test func malformedDeviceSelectorsAreRefused() async throws {
        let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, settleDelay: 0)
        for device: JSONValue in [5, true, ["a"], ["id": "x"], "", "  "] {
            let output = try await tools.call(
                "home", arguments: ["device": device, "screenshot": false], source: "test", screenshotByDefault: false)
            #expect(output.isError)
            #expect(output.text.contains("device must be a device id or name"), "\(device): \(output.text)")
        }
        #expect(throws: (any Error).self) { try tools.phone(for: "") }
        let missing = try await tools.call("home", arguments: ["device": .null], source: "test", screenshotByDefault: false)
        #expect(missing.text.contains("No iPhone is connected"))
    }

    @Test func everyToolTakesADeviceAndListDevicesExists() {
        let names = DeviceTools.definitions.map(\.name)
        #expect(names.first == "list_devices")
        #expect(Set(names) == Set(PhoneTools.definitions.map(\.name) + ["list_devices"]))
        for definition in DeviceTools.definitions where definition.name != "list_devices" {
            #expect(definition.inputSchema["properties"]?["device"]?["type"] == "string", "\(definition.name)")
        }
    }

    @Test func summaryUsesTheRelayFrameKeys() throws {
        let summary = DeviceSummary(
            id: "abc", name: "iPhone", model: "iPhone15,2", modelName: "iPhone 14 Pro", osVersion: "27.0",
            deviceClass: "iPhone", screen: true, bluetooth: false, ready: false)
        let json = try JSONValue.parse(JSONEncoder().encode(summary))
        #expect(json["model_name"] == "iPhone 14 Pro")
        #expect(json["os_version"] == "27.0")
        #expect(json["device_class"] == "iPhone")
        #expect(json["screen"] == true)
        #expect(json["ready"] == false)
    }
}
