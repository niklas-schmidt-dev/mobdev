import AppKit
import MobdevCore
import SwiftUI

/// A simulator's or Android device's screen: pictures taken as fast as the device gives them, a
/// click taps, a drag swipes, and typing goes to the device while the screen has focus.
struct EmulatorStage: View {
    @Environment(AppModel.self) private var model
    let id: String
    let frameSize: CGSize
    /// Whether the panel is shown beside the screen.
    let panel: Bool
    /// Whether the element inspector lies over the screen instead of clicks reaching the device.
    let inspecting: Bool
    @State private var image: CGImage?
    @State private var dragStarted: Date?
    /// Where the pointer is over the screen, in its points, and the size it is shown at.
    @State private var hover: (point: CGPoint, screen: CGSize)?
    /// A two-finger scroll in progress: where it started and how far the fingers moved.
    @State private var scroll: (start: CGPoint, moved: CGSize, started: Date, screen: CGSize)?
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GeometryReader { proxy in
            let frame = ScreenFrame(form: model.state(id)?.info?.formFactor)
            let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? frameSize
            let screen = frame.fit(size, in: DeviceScreenView.room(in: proxy.size, panel: panel))
            let radius = frame.corner(for: screen)
            let bezel = frame.bezel(for: screen)

            VStack(spacing: 16) {
                picture
                    .frame(width: screen.width, height: screen.height)
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                    .contentShape(.rect)
                    .gesture(touch(in: screen))
                    .onContinuousHover { phase in
                        if case .active(let point) = phase { hover = (point, screen) } else { hover = nil }
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: .down, action: key)
                    .overlay {
                        if inspecting { ElementInspector(id: id, screen: screen, frameSize: size) }
                    }
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
                    .padding(bezel)
                    .background {
                        RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                            .fill(.black)
                            .overlay {
                                RoundedRectangle(cornerRadius: radius + bezel, style: .continuous)
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1.5)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                    }
                    .overlay {
                        if focused {
                            RoundedRectangle(cornerRadius: radius + bezel + 4, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 3)
                                .padding(-4)
                        }
                    }
                    .accessibilityLabel("\(model.state(id)?.kind.label ?? "Device") screen")
                    .accessibilityHint("Click to tap, drag to swipe, type while focused")

                Text(
                    inspecting
                        ? "Inspecting: point at an element to see it · click to copy the step that taps it"
                        : focused ? "Typing goes to the device. ⌘V types the Mac clipboard." : "Click to tap · drag to swipe · click, then type")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: focused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: id) { await refresh() }
        .onAppear {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                trackpadScroll(event) ? nil : event
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
    }

    /// Two fingers on the trackpad over the screen swipe the device the way they moved, sideways
    /// too, once they lift. Simulators and adb take a swipe as one command, so it is not played
    /// along live as on an iPhone. True when the event was used.
    private func trackpadScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.momentumPhase != [] { return scroll != nil || hover != nil }
        if scroll == nil {
            guard let hover, event.phase.contains(.began) || event.phase.contains(.changed) else { return false }
            scroll = (hover.point, .zero, .now, hover.screen)
        }
        guard var current = scroll else { return false }
        // With natural scrolling the deltas follow the fingers; otherwise they are reversed.
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        current.moved.width += direction * event.scrollingDeltaX
        current.moved.height += direction * event.scrollingDeltaY
        scroll = current
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else { return true }
        scroll = nil
        let end = CGPoint(x: current.start.x + current.moved.width, y: current.start.y + current.moved.height)
        guard hypot(current.moved.width, current.moved.height) >= 6 else { return true }
        func normalized(_ point: CGPoint) -> NormalizedPoint {
            NormalizedPoint(
                x: min(max(point.x / current.screen.width, 0), 1), y: min(max(point.y / current.screen.height, 0), 1))
        }
        model.swipe(
            id, from: normalized(current.start), to: normalized(end), duration: min(Date.now.timeIntervalSince(current.started), 0.5))
        return true
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                Color.black
                ProgressView().controlSize(.large)
            }
        }
    }

    /// A click taps where it lands; a drag of a few points or more swipes along it in the time it took.
    private func touch(in screen: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if dragStarted == nil { dragStarted = .now }
                focused = true
            }
            .onEnded { value in
                let started = dragStarted ?? .now
                dragStarted = nil
                func normalized(_ point: CGPoint) -> NormalizedPoint {
                    NormalizedPoint(
                        x: min(max(point.x / screen.width, 0), 1), y: min(max(point.y / screen.height, 0), 1))
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance < 6 {
                    model.tap(id, at: normalized(value.startLocation))
                } else {
                    model.swipe(
                        id, from: normalized(value.startLocation), to: normalized(value.location),
                        duration: Date.now.timeIntervalSince(started))
                }
            }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            guard press.characters == "v", let text = NSPasteboard.general.string(forType: .string) else { return .ignored }
            model.type(text, on: id)
            return .handled
        }
        let special: [KeyEquivalent: UInt8] = [
            .return: 0x28, .escape: 0x29, .delete: 0x2A, .tab: 0x2B, .deleteForward: 0x4C,
            .rightArrow: 0x4F, .leftArrow: 0x50, .downArrow: 0x51, .upArrow: 0x52,
        ]
        if let usage = special[press.key] {
            model.pressKey(KeyStroke(usage), on: id)
            return .handled
        }
        guard !press.characters.isEmpty, press.characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
            return .ignored
        }
        model.type(press.characters, on: id)
        return .handled
    }

    /// About ten pictures a second from a simulator's framebuffer, twenty from an Android device
    /// while scrcpy streams it (its newest picture costs nothing to ask for). Without scrcpy an
    /// Android screenshot is 10 MB or more over adb, so those come about three times a second at
    /// most. Behind other windows, one a second at most.
    private func refresh() async {
        while !Task.isCancelled {
            guard let device = model.device(id) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let started = Date.now
            if let frame = await Task.detached(priority: .userInitiated, operation: { device.frame() }).value {
                image = frame
            }
            let streaming = (device as? AndroidDevice)?.isStreaming == true
            var interval = device.kind == .android ? (streaming ? 0.05 : 0.3) : 0.1
            if !appearsActive { interval = max(interval, 1) }
            try? await Task.sleep(for: .seconds(max(interval - Date.now.timeIntervalSince(started), 0.03)))
        }
    }
}
