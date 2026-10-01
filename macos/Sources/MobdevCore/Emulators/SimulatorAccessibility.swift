import AppKit
import Foundation
import ObjectiveC

/// The accessibility tree of a simulator's frontmost app, read the way idb and AXe read it:
/// AccessibilityPlatformTranslation turns iOS accessibility into macOS elements and fetches each
/// piece through a token delegate, which forwards the request to the simulator in CoreSimulator.
final class SimulatorAccessibility: @unchecked Sendable {
    static let shared: Result<SimulatorAccessibility, any Error> = Result { try SimulatorAccessibility() }

    private typealias Frontmost = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?

    private let translator: NSObject
    private let bridge = Bridge()
    /// One tree at a time: the translator and its caches are shared.
    private let lock = NSLock()
    private static let maxElements = 1500

    private init() throws {
        let path =
            "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        guard dlopen(path, RTLD_NOW) != nil else {
            throw DeveloperError("Could not load the accessibility translation: \(String(cString: dlerror()))")
        }
        guard let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type,
            let translator = translatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
                as? NSObject,
            translator.responds(to: NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:"))
        else { throw DeveloperError("This macOS cannot read simulator accessibility.") }
        if let helper = objc_getProtocol("AXPTranslationTokenDelegateHelper") { class_addProtocol(Bridge.self, helper) }
        translator.setValue(bridge, forKey: "bridgeTokenDelegate")
        translator.setValue(true, forKey: "supportsDelegateTokens")
        translator.setValue(true, forKey: "accessibilityEnabled")
        self.translator = translator
    }

    /// The frontmost app's elements with frames as fractions of the screen. Blocks for a few seconds.
    func elements(of device: NSObject, udid: String) throws -> [UIElement] {
        lock.lock()
        defer { lock.unlock() }
        let token = udid as NSString
        bridge.register(device, token: token)
        let selector = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard let method = class_getMethodImplementation(object_getClass(translator), selector),
            let translation = unsafeBitCast(method, to: Frontmost.self)(translator, selector, 0, token) as? NSObject
        else { throw DeveloperError("The simulator did not say which app is in front.") }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        guard
            let root = translator.perform(NSSelectorFromString("macPlatformElementFromTranslation:"), with: translation)?
                .takeUnretainedValue() as? NSAccessibilityElement
        else { throw DeveloperError("The simulator's app has no accessibility element.") }
        // The application element covers the screen in points; every frame is relative to it.
        let screen = root.accessibilityFrame()
        guard screen.width > 0, screen.height > 0 else { throw DeveloperError("The simulator's app has no size yet.") }
        var elements: [UIElement] = []
        let deadline = Date().addingTimeInterval(20)
        func walk(_ element: NSAccessibilityElement, depth: Int) {
            guard elements.count < Self.maxElements, depth < 64, Date() < deadline else { return }
            for case let child as NSAccessibilityElement in element.accessibilityChildren() ?? [] {
                (child.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
                if let found = Self.element(child, in: screen) { elements.append(found) }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return elements
    }

    /// Roles someone taps, as the translation names them without their "AX" prefix.
    private static let tappableRoles: Set<String> = [
        "Button", "Link", "TextField", "SecureTextField", "SearchField", "TextArea", "Cell", "CheckBox", "Switch",
        "Slider", "PopUpButton", "MenuButton", "MenuItem", "RadioButton", "Tab", "ComboBox", "Incrementor",
        "DisclosureTriangle", "Toggle",
    ]

    private static func element(_ element: NSAccessibilityElement, in screen: CGRect) -> UIElement? {
        let frame = element.accessibilityFrame()
        guard frame.width > 0, frame.height > 0 else { return nil }
        var role = element.accessibilityRole()?.rawValue ?? "Element"
        if role.hasPrefix("AX") { role.removeFirst(2) }
        var value = ""
        switch element.accessibilityValue() {
        case let text as String: value = text
        case let number as NSNumber:
            value = role == "CheckBox" || role == "Switch" || role == "Toggle"
                ? (number.boolValue ? "on" : "off") : number.stringValue
        default: break
        }
        return UIElement(
            role: role, label: element.accessibilityLabel() ?? "", identifier: element.accessibilityIdentifier() ?? "",
            value: value,
            frame: CGRect(
                x: (frame.minX - screen.minX) / screen.width, y: (frame.minY - screen.minY) / screen.height,
                width: frame.width / screen.width, height: frame.height / screen.height),
            enabled: element.isAccessibilityEnabled(), tappable: tappableRoles.contains(role))
    }
}

/// The translator's token delegate: answers each request by asking the simulator the token names,
/// through SimDevice's `sendAccessibilityRequestAsync:completionQueue:completionHandler:`.
private final class Bridge: NSObject, @unchecked Sendable {
    private typealias Send = @convention(c) (
        AnyObject, Selector, AnyObject, DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void
    ) -> Void

    private let devices = Locked<[NSString: NSObject]>([:])
    /// Answers arrive here while the asking thread waits.
    private let queue = DispatchQueue(label: "sh.mobdev.simulator-accessibility")

    func register(_ device: NSObject, token: NSString) { devices.withLock { $0[token] = device } }

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func callback(token: NSString) -> Any {
        let device = devices.get()[token]
        let queue = self.queue
        let answer: @convention(block) (AnyObject) -> AnyObject? = { request in
            let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
            guard let device, let method = class_getMethodImplementation(object_getClass(device), selector) else {
                return nil
            }
            let done = DispatchSemaphore(value: 0)
            let response = Locked<AnyObject?>(nil)
            unsafeBitCast(method, to: Send.self)(device, selector, request, queue) { answer in
                response.set(answer)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
            return response.get()
        }
        return answer
    }

    /// Frames stay in the simulator's points.
    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convert(_ rect: CGRect, token: NSString) -> CGRect { rect }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(token: NSString) -> AnyObject? { nil }
}
