import Foundation
import IOKit

/// How an iPhone sits on the USB bus. For screen capture, macOS switches it into a configuration
/// that has a vendor interface with subclass 42 (Apple's "Valeria" screen stream). When macOS's
/// capture helper is stuck, the iPhone stays in a configuration without it.
public struct USBScreenState: Sendable, Equatable {
    /// The active USB configuration, e.g. 7 with the screen interface or 6 without.
    public var configuration: Int
    public var hasScreenInterface: Bool
}

public enum USBProbe {
    /// The USB state of the iPhone or iPad with this UDID, or nil when it is not on USB.
    public static func screenState(udid: String) -> USBScreenState? {
        let serial = udid.replacingOccurrences(of: "-", with: "").uppercased()
        var devices: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &devices)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(devices) }
        while case let device = IOIteratorNext(devices), device != 0 {
            defer { IOObjectRelease(device) }
            guard (property(device, "USB Serial Number") as? String)?.uppercased() == serial else { continue }
            let configuration = (property(device, "kUSBCurrentConfiguration") as? NSNumber)?.intValue ?? 0
            return USBScreenState(configuration: configuration, hasScreenInterface: hasScreenInterface(device))
        }
        return nil
    }

    private static func hasScreenInterface(_ device: io_object_t) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children)
            == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            let interfaceClass = (property(child, "bInterfaceClass") as? NSNumber)?.intValue
            let subclass = (property(child, "bInterfaceSubClass") as? NSNumber)?.intValue
            if interfaceClass == 255, subclass == 42 { return true }
        }
        return false
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
