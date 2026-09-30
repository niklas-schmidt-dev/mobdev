import Foundation

/// What Mobdev knows about an iPhone or iPad, read over USB from lockdownd without pairing.
public struct DeviceInfo: Sendable, Equatable, Codable, Identifiable {
    /// The UDID, e.g. "00008120-000639440C13C01E".
    public let id: String
    public var name: String
    /// The product type, e.g. "iPhone15,2".
    public var productType: String
    public var osVersion: String
    public var buildVersion: String
    /// "iPhone" or "iPad".
    public var deviceClass: String
    /// lockdownd's `DeviceColor`: "1" for dark enclosures, "2" for light ones on most models.
    public var colorCode: String?

    public init(
        id: String, name: String, productType: String, osVersion: String, buildVersion: String,
        deviceClass: String, colorCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.productType = productType
        self.osVersion = osVersion
        self.buildVersion = buildVersion
        self.deviceClass = deviceClass
        self.colorCode = colorCode
    }

    /// "iPhone 14 Pro", or the product type for models this table does not know yet.
    public var modelName: String { DeviceModels.name(for: productType) ?? (productType.isEmpty ? deviceClass : productType) }
    public var formFactor: FormFactor { DeviceModels.formFactor(for: productType, deviceClass: deviceClass) }
    public var isLightColor: Bool { colorCode == "2" || colorCode?.lowercased() == "white" }
    /// "iOS 27.0", "iPadOS 27.0" or "Android 16".
    public var systemName: String {
        let system = switch deviceClass {
        case "iPad": "iPadOS"
        case "Android": "Android"
        default: "iOS"
        }
        return "\(system) \(osVersion)"
    }
}

/// The front of the device, for drawing it.
public enum FormFactor: String, Sendable, Codable {
    /// `android` is a phone with a round camera hole.
    case dynamicIsland, notch, homeButton, iPad, android
}

/// Marketing names and front designs by product type.
public enum DeviceModels {
    private static let models: [String: (String, FormFactor)] = {
        var table: [String: (String, FormFactor)] = [:]
        func add(_ types: [String], _ name: String, _ form: FormFactor) {
            for type in types { table[type] = (name, form) }
        }
        add(["iPhone10,1", "iPhone10,4"], "iPhone 8", .homeButton)
        add(["iPhone10,2", "iPhone10,5"], "iPhone 8 Plus", .homeButton)
        add(["iPhone10,3", "iPhone10,6"], "iPhone X", .notch)
        add(["iPhone11,2"], "iPhone XS", .notch)
        add(["iPhone11,4", "iPhone11,6"], "iPhone XS Max", .notch)
        add(["iPhone11,8"], "iPhone XR", .notch)
        add(["iPhone12,1"], "iPhone 11", .notch)
        add(["iPhone12,3"], "iPhone 11 Pro", .notch)
        add(["iPhone12,5"], "iPhone 11 Pro Max", .notch)
        add(["iPhone12,8"], "iPhone SE (2nd generation)", .homeButton)
        add(["iPhone13,1"], "iPhone 12 mini", .notch)
        add(["iPhone13,2"], "iPhone 12", .notch)
        add(["iPhone13,3"], "iPhone 12 Pro", .notch)
        add(["iPhone13,4"], "iPhone 12 Pro Max", .notch)
        add(["iPhone14,4"], "iPhone 13 mini", .notch)
        add(["iPhone14,5"], "iPhone 13", .notch)
        add(["iPhone14,2"], "iPhone 13 Pro", .notch)
        add(["iPhone14,3"], "iPhone 13 Pro Max", .notch)
        add(["iPhone14,6"], "iPhone SE (3rd generation)", .homeButton)
        add(["iPhone14,7"], "iPhone 14", .notch)
        add(["iPhone14,8"], "iPhone 14 Plus", .notch)
        add(["iPhone15,2"], "iPhone 14 Pro", .dynamicIsland)
        add(["iPhone15,3"], "iPhone 14 Pro Max", .dynamicIsland)
        add(["iPhone15,4"], "iPhone 15", .dynamicIsland)
        add(["iPhone15,5"], "iPhone 15 Plus", .dynamicIsland)
        add(["iPhone16,1"], "iPhone 15 Pro", .dynamicIsland)
        add(["iPhone16,2"], "iPhone 15 Pro Max", .dynamicIsland)
        add(["iPhone17,1"], "iPhone 16 Pro", .dynamicIsland)
        add(["iPhone17,2"], "iPhone 16 Pro Max", .dynamicIsland)
        add(["iPhone17,3"], "iPhone 16", .dynamicIsland)
        add(["iPhone17,4"], "iPhone 16 Plus", .dynamicIsland)
        add(["iPhone17,5"], "iPhone 16e", .notch)
        add(["iPhone18,1"], "iPhone 17 Pro", .dynamicIsland)
        add(["iPhone18,2"], "iPhone 17 Pro Max", .dynamicIsland)
        add(["iPhone18,3"], "iPhone 17", .dynamicIsland)
        add(["iPhone18,4"], "iPhone Air", .dynamicIsland)
        return table
    }()

    public static func name(for productType: String) -> String? { models[productType]?.0 }

    public static func formFactor(for productType: String, deviceClass: String) -> FormFactor {
        if let form = models[productType]?.1 { return form }
        if deviceClass == "Android" { return .android }
        if deviceClass == "iPad" || productType.hasPrefix("iPad") { return .iPad }
        // Models newer than the table all have a Dynamic Island.
        return .dynamicIsland
    }
}
