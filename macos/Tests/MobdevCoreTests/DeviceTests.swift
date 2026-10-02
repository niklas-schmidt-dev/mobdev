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
        let iPad = DeviceInfo(
            id: "x", name: "iPad", productType: "iPad16,10", osVersion: "27.0", buildVersion: "", deviceClass: "iPad")
        #expect(iPad.modelName == "iPad Air 13-inch (M4)")
        #expect(iPad.formFactor == .iPad)
        #expect(iPad.systemName == "iPadOS 27.0")
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

    /// Polling status adds one entry with a count, and the file keeps one line for it.
    @Test func identicalCallsInARowCollapse() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = ActivityLog(limit: 10, file: file)
        log.record(source: "local", tool: "tap", summary: "Tapped (1, 2).", failed: false)
        for _ in 0..<3 { log.record(source: "local", tool: "status", summary: "Ready.", failed: false, collapsing: true) }
        #expect(log.all.map(\.tool) == ["status", "tap"])
        #expect(log.all.first?.count == 3)
        // A different summary, source or tool in between starts a new entry.
        log.record(source: "local", tool: "status", summary: "Not ready.", failed: false, collapsing: true)
        log.record(source: "relay", tool: "status", summary: "Not ready.", failed: false, collapsing: true)
        log.record(source: "relay", tool: "status", summary: "Not ready.", failed: false, collapsing: true)
        #expect(log.all.map(\.count) == [2, 1, 3, 1])
        // Without collapsing, repeats stay separate.
        log.record(source: "relay", tool: "tap", summary: "Tapped (1, 2).", failed: false)
        log.record(source: "relay", tool: "tap", summary: "Tapped (1, 2).", failed: false)
        #expect(log.all.count == 6)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 6)
        let reloaded = ActivityLog(limit: 10, file: file)
        #expect(reloaded.all == log.all)
    }

    /// After a relaunch the log did not write the last line itself, so it appends the newer
    /// version; reading keeps only the newest line per entry.
    @Test func aCollapsedEntryAppendedAfterAReloadIsReadOnce() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = ActivityLog(limit: 10, file: file)
        first.record(source: "local", tool: "tap", summary: "Tapped (1, 2).", failed: false)
        Thread.sleep(forTimeInterval: 0.002)
        first.record(source: "local", tool: "status", summary: "Ready.", failed: false, collapsing: true)
        Thread.sleep(forTimeInterval: 0.002)
        let second = ActivityLog(limit: 10, file: file)
        second.record(source: "local", tool: "status", summary: "Ready.", failed: false, collapsing: true)
        #expect(second.all.map(\.count) == [2, 1])
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 3)
        #expect(ActivityLog(limit: 10, file: file).all == second.all)
        // Paging back from the tap finds nothing older, and never the status entry's old version.
        let tap = try #require(second.all.last)
        #expect(second.older(than: tap.date, limit: 10).isEmpty)
        #expect(second.older(than: Date.distantFuture, limit: 10).map(\.count) == [2, 1])
    }

    @Test func linesWithoutACountReadAsOne() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":1790000000000,"source":"local","tool":"home","summary":"Went home.","failed":false}"#
        try Data((line + "\n").utf8).write(to: file)
        #expect(ActivityLog(limit: 10, file: file).all.first?.count == 1)
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

    /// An iPad showing an iPhone's picture and an iPhone showing an iPad's have them crossed.
    @Test func crossedPicturesArePairedByShape() {
        let ipadShowingPhone: (isTablet: Bool, showsTablet: Bool?) = (true, false)
        let phoneShowingIPad: (isTablet: Bool, showsTablet: Bool?) = (false, true)
        let phone: (isTablet: Bool, showsTablet: Bool?) = (false, false)
        let blankPhone: (isTablet: Bool, showsTablet: Bool?) = (false, nil)
        let blankIPad: (isTablet: Bool, showsTablet: Bool?) = (true, nil)
        let crossed = DeviceHub.crossedScreens([ipadShowingPhone, phone, nil, phoneShowingIPad])
        #expect(crossed.map { [$0.0, $0.1] } == [[0, 3]])
        // A mismatch without a counterpart has nothing to exchange with.
        #expect(DeviceHub.crossedScreens([ipadShowingPhone, phone]).isEmpty)
        #expect(DeviceHub.crossedScreens([phone, phone]).isEmpty)
        // The iPhone that got a sleeping iPad's capture shows nothing.
        #expect(DeviceHub.crossedScreens([ipadShowingPhone, blankPhone]).map { [$0.0, $0.1] } == [[0, 1]])
        // With two such iPhones it is unclear which one; and a sleeping iPad crossed nothing.
        #expect(DeviceHub.crossedScreens([ipadShowingPhone, blankPhone, blankPhone]).isEmpty)
        #expect(DeviceHub.crossedScreens([blankIPad, blankPhone]).isEmpty)
        // A phone showing an iPad comes before one without a picture.
        #expect(DeviceHub.crossedScreens([blankPhone, ipadShowingPhone, phoneShowingIPad]).map { [$0.0, $0.1] } == [[1, 2]])
    }

    @Test func aScreenStateTakesTheDevicesName() {
        let state = ScreenState.connected(name: "iPad", width: 1180, height: 2556)
        #expect(state.named("iPhone") == .connected(name: "iPhone", width: 1180, height: 2556))
        #expect(ScreenState.locked(name: "iPad").named("iPhone") == .locked(name: "iPhone"))
        #expect(ScreenState.searching.named("iPhone") == .searching)
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
        #expect(missing.text.contains("No device is connected"))
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
