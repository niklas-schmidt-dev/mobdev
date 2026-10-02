import AVFoundation
import Carbon.HIToolbox
import MobdevCore
import SwiftUI

/// The live iPhone screen. Click to tap, drag to swipe, scroll to scroll, and type while it
/// has focus. ⌘V types the Mac clipboard. After a drag, `onDrag` gets where it started, so the
/// app can check whether the pointer snapped and turned it into a tap.
struct PhoneMirrorView: NSViewRepresentable {
    let id: String
    let session: AVCaptureSession?
    let input: HIDInput?
    let layout: KeyboardLayout
    @Binding var focused: Bool
    var onDrag: ((NormalizedPoint) -> Void)?
    /// What the mirror sent, for a flow being recorded.
    var onInput: ((MirrorInput) -> Void)?

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView.view(for: id)
        view.onFocusChange = { focused in DispatchQueue.main.async { self.focused = focused } }
        return view
    }

    func updateNSView(_ view: MirrorNSView, context: Context) {
        view.input = input
        view.keyboardLayout = layout
        view.onDrag = onDrag
        view.onInput = onInput
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }
}

enum MirrorInput {
    case tap(NormalizedPoint)
    case swipe(from: NormalizedPoint, to: NormalizedPoint, duration: TimeInterval)
    case text(String)
    case key(KeyStroke)
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
    var onDrag: ((NormalizedPoint) -> Void)?
    var onInput: ((MirrorInput) -> Void)?
    private var lastMove = Date.distantPast
    private var dragStart: NormalizedPoint?
    private var dragStarted = Date()
    private var dragged = false
    private var scrollAccumulator: CGFloat = 0
    private var panAccumulator: CGFloat = 0
    /// A two-finger scroll on the trackpad, played on the iPhone as a touch that moves along.
    private var scrollTouch: (start: NormalizedPoint, current: NormalizedPoint, started: Date)?
    /// Whether that touch is down on the iPhone yet.
    private var touchDown = false

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

    /// While the mouse is over the mirror, Bluetooth stays awake, so a click is not delayed.
    private var awake: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        input?.stayAwake()
        awake?.invalidate()
        awake = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAwake() }
        }
    }

    override func mouseExited(with event: NSEvent) { stopKeepingAwake() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopKeepingAwake() }
    }

    /// Only while the mouse is still over the mirror in the active app: leaving the app or hiding
    /// the pane does not always send `mouseExited`.
    private func keepAwake() {
        guard NSApp.isActive, let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
            bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        else { return stopKeepingAwake() }
        input?.stayAwake()
    }

    private func stopKeepingAwake() {
        awake?.invalidate()
        awake = nil
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
        let point = normalized(event)
        dragStart = point
        dragStarted = Date()
        dragged = false
        input?.pointerDown(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        // BLE carries a report every 15-30 ms; more would only queue up.
        guard Date().timeIntervalSince(lastMove) > 0.025 else { return }
        lastMove = Date()
        let point = normalized(event)
        if let start = dragStart, hypot(point.x - start.x, point.y - start.y) > 0.02 { dragged = true }
        input?.pointerMove(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = normalized(event)
        input?.pointerUp(at: point)
        if dragged, let start = dragStart {
            onDrag?(start)
            onInput?(.swipe(from: start, to: point, duration: Date().timeIntervalSince(dragStarted)))
        } else if let start = dragStart {
            onInput?(.tap(start))
        }
        dragStart = nil
        dragged = false
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas, event.phase != [] || event.momentumPhase != [] {
            trackpadScroll(event)
            return
        }
        // Positive ticks reveal content further down or right; on the Mac that is a negative delta.
        // A sideways wheel, or Shift with a plain wheel, scrolls sideways.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.1 : 1
        scrollAccumulator -= event.scrollingDeltaY * scale
        panAccumulator -= event.scrollingDeltaX * scale
        let ticks = Int(scrollAccumulator), pan = Int(panAccumulator)
        scrollAccumulator -= CGFloat(ticks)
        panAccumulator -= CGFloat(pan)
        guard let input, ticks != 0 || pan != 0 else { return }
        let point = normalized(event)
        Task {
            if ticks != 0 { try? await input.scroll(at: point, ticks: ticks) }
            if pan != 0 { try? await input.pan(at: point, ticks: pan) }
        }
    }

    /// Two fingers on the trackpad move a touch on the iPhone the same way and as far, sideways too,
    /// and lifting them lets iOS fling the content as after a swipe. The wheel scrolled only up and
    /// down, in small steps, which made sideways scrolling impossible (2026-10-01). The scroll's
    /// momentum after the fingers lift is left to iOS.
    private func trackpadScroll(_ event: NSEvent) {
        guard let input, event.momentumPhase == [] else { return }
        // Fingers resting on the trackpad send "may begin", then "cancelled": that is no touch.
        if event.phase.contains(.began) {
            let point = normalized(event)
            scrollTouch = (point, point, Date())
            touchDown = false
        }
        guard var touch = scrollTouch else { return }
        // With natural scrolling the deltas follow the fingers; otherwise they are reversed.
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if bounds.width > 0, bounds.height > 0 {
            touch.current = NormalizedPoint(
                x: min(max(touch.current.x + direction * event.scrollingDeltaX / bounds.width, 0), 1),
                y: min(max(touch.current.y + direction * event.scrollingDeltaY / bounds.height, 0), 1))
        }
        scrollTouch = touch
        // Down once the fingers have moved a little, so a short brush is not a tap.
        if !touchDown, hypot(touch.current.x - touch.start.x, touch.current.y - touch.start.y) > 0.01 {
            input.pointerDown(at: touch.start)
            touchDown = true
            lastMove = .distantPast
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollTouch = nil
            guard touchDown else { return }
            touchDown = false
            input.pointerUp(at: touch.current)
            if hypot(touch.current.x - touch.start.x, touch.current.y - touch.start.y) > 0.02 {
                onDrag?(touch.start)
                onInput?(.swipe(from: touch.start, to: touch.current, duration: Date().timeIntervalSince(touch.started)))
            }
            return
        }
        // BLE carries a report every 15-30 ms; more would only queue up.
        guard touchDown, Date().timeIntervalSince(lastMove) > 0.025 else { return }
        lastMove = Date()
        input.pointerMove(to: touch.current)
    }

    override func keyDown(with event: NSEvent) {
        guard let input else { return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "v" {
            if let text = NSPasteboard.general.string(forType: .string),
                let strokes = try? keyboardLayout.strokes(typing: text)
            {
                onInput?(.text(text))
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
        let stroke = KeyStroke(usage, modifiers)
        if FlowRecorder.keyName(usage: usage) != nil || flags.contains(.command) || flags.contains(.control) {
            onInput?(.key(stroke))
        } else if let characters = event.characters, !characters.isEmpty {
            onInput?(.text(characters))
        }
        input.pressLive(stroke)
    }
}
