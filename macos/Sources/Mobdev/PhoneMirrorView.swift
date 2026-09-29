import AVFoundation
import Carbon.HIToolbox
import MobdevCore
import SwiftUI

/// The live iPhone screen. Click to tap, drag to swipe, scroll to scroll, and type while it
/// has focus. ⌘V types the Mac clipboard.
struct PhoneMirrorView: NSViewRepresentable {
    let id: String
    let session: AVCaptureSession?
    let input: HIDInput?
    let layout: KeyboardLayout
    @Binding var focused: Bool

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView.view(for: id)
        view.onFocusChange = { focused in DispatchQueue.main.async { self.focused = focused } }
        return view
    }

    func updateNSView(_ view: MirrorNSView, context: Context) {
        view.input = input
        view.keyboardLayout = layout
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }
}

final class MirrorNSView: NSView {
    /// One mirror per device for the app's lifetime. Adding or removing a preview layer makes the
    /// capture session tear down and rebuild its graph on the main thread, which stalled every
    /// switch to and from the phone pane, so each layer stays attached while other panes are shown.
    private static var views: [String: MirrorNSView] = [:]

    static func view(for id: String) -> MirrorNSView {
        if let existing = views[id] { return existing }
        let view = MirrorNSView()
        views[id] = view
        return view
    }

    let previewLayer = AVCaptureVideoPreviewLayer()
    var input: HIDInput?
    var keyboardLayout: KeyboardLayout = .us
    var onFocusChange: ((Bool) -> Void)?
    private var lastMove = Date.distantPast
    private var scrollAccumulator: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    private func normalized(_ event: NSEvent) -> NormalizedPoint {
        let point = convert(event.locationInWindow, from: nil)
        let x = bounds.width > 0 ? point.x / bounds.width : 0
        let y = bounds.height > 0 ? point.y / bounds.height : 0
        return NormalizedPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        input?.pointerDown(at: normalized(event))
    }

    override func mouseDragged(with event: NSEvent) {
        // BLE carries a report every 15-30 ms; more would only queue up.
        guard Date().timeIntervalSince(lastMove) > 0.025 else { return }
        lastMove = Date()
        input?.pointerMove(to: normalized(event))
    }

    override func mouseUp(with event: NSEvent) {
        input?.pointerUp(at: normalized(event))
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.1 : 1)
        let ticks = Int(scrollAccumulator)
        guard ticks != 0, let input else { return }
        scrollAccumulator -= CGFloat(ticks)
        let point = normalized(event)
        Task { try? await input.scroll(at: point, ticks: ticks) }
    }

    override func keyDown(with event: NSEvent) {
        guard let input else { return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string),
                let strokes = try? keyboardLayout.strokes(typing: text)
            {
                Task { try? await input.type(strokes) }
            } else {
                NSSound.beep()
            }
            return
        }
        let isISO = KBGetLayoutType(Int16(LMGetKbdType())) == UInt32(kKeyboardISO)
        guard let usage = MacKeyCodes.hidUsage(forKeyCode: event.keyCode, isISO: isISO) else {
            super.keyDown(with: event)
            return
        }
        var modifiers: UInt8 = 0
        if flags.contains(.shift) { modifiers |= KeyStroke.shift }
        if flags.contains(.control) { modifiers |= KeyStroke.control }
        if flags.contains(.option) { modifiers |= KeyStroke.option }
        if flags.contains(.command) { modifiers |= KeyStroke.command }
        input.pressLive(KeyStroke(usage, modifiers))
    }
}
