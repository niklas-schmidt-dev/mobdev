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

    @Test func reloadKeepsTheNewestAndCompactsTheFile() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = ActivityLog(limit: 2, file: file)
        for index in 0..<12 { log.record(source: "local", tool: "tap", summary: "\(index)", failed: false) }
        #expect(log.all.map(\.summary) == ["11", "10"])

        let reloaded = ActivityLog(limit: 2, file: file)
        #expect(reloaded.all.map(\.summary) == ["11", "10"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
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

@Suite struct DeviceToolsTests {
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
