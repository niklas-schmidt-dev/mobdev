import AppKit
import MobdevCore
import SwiftUI

/// Lies over a device's screen while inspecting: the element under the pointer is outlined with its
/// role, label and identifier, and a click copies the flow step that taps it instead of tapping the
/// device, so a test can be written without guessing identifiers. Reads the UI tree about once a
/// second, every few seconds on Android, where a read takes about two.
struct ElementInspector: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// The size the screen is shown at.
    let screen: CGSize
    /// The device's screen in pixels, for the step's coordinates when no element names the point.
    let frameSize: CGSize
    @State private var tree: [UIElement]?
    @State private var problem: String?
    @State private var hover: CGPoint?
    @State private var copied: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.08)
            if let element = hovered { outline(element) }
        }
        .frame(width: screen.width, height: screen.height)
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active(let point) = phase { hover = point } else { hover = nil }
        }
        .onTapGesture(coordinateSpace: .local) { copyStep(at: $0) }
        .overlay(alignment: .bottom) { note.padding(10) }
        .task(id: id) { await load() }
        .accessibilityLabel("Element inspector")
        .accessibilityHint("Shows the element under the pointer; click copies the step that taps it")
    }

    private func normalized(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(point.x / max(screen.width, 1), 0), 1), y: min(max(point.y / max(screen.height, 1), 0), 1))
    }

    /// The smallest element under the pointer that has something to say or to tap.
    private var hovered: UIElement? {
        guard let hover, let tree else { return nil }
        let point = normalized(hover)
        return tree.filter { element in
            (!element.label.isEmpty || !element.identifier.isEmpty || element.tappable)
                && element.frame.contains(CGPoint(x: point.x, y: point.y))
        }
        .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func outline(_ element: UIElement) -> some View {
        let rect = CGRect(
            x: element.frame.minX * screen.width, y: element.frame.minY * screen.height,
            width: element.frame.width * screen.width, height: element.frame.height * screen.height)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.15))
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                .offset(x: rect.minX, y: rect.minY)
            Text(Self.describe(element))
                .font(.caption.monospaced())
                .lineLimit(2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .rect(cornerRadius: 6))
                .frame(maxWidth: screen.width - 16, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                // Above the element, or below it near the top of the screen.
                .offset(x: min(max(rect.minX, 8), screen.width * 0.4), y: rect.minY > 44 ? rect.minY - 40 : rect.maxY + 6)
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: rect)
    }

    /// `Button "Sign in" id=login value=…`.
    static func describe(_ element: UIElement) -> String {
        var parts = [element.role]
        if !element.label.isEmpty { parts.append("\"\(element.label)\"") }
        if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
        if !element.value.isEmpty, element.value != element.label { parts.append("value=\(element.value)") }
        if !element.enabled { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private var note: some View {
        let text = copied.map { "Copied \($0)" } ?? problem
            ?? (tree == nil ? "Reading the UI tree…" : "Click an element to copy the step that taps it")
        Text(text)
            .font(.callout)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .contentTransition(.opacity)
            .animation(.smooth, value: text)
    }

    /// tap_element by a unique identifier or label, as Record saves it, else tap at the point in
    /// screenshot pixels.
    private func copyStep(at location: CGPoint) {
        let point = normalized(location)
        let step: JSONValue
        if let tree, let arguments = FlowRecorder.element(at: point, in: tree) {
            step = ["tap_element": .object(arguments)]
        } else {
            let size = ScreenGeometry.screenshotSize(forFrameWidth: Int(frameSize.width), height: Int(frameSize.height))
            step = [
                "tap": [
                    "x": .number((point.x * Double(size.width)).rounded()),
                    "y": .number((point.y * Double(size.height)).rounded()),
                ]
            ]
        }
        let text = step.compactString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if copied == text { copied = nil }
        }
    }

    private func load() async {
        while !Task.isCancelled {
            guard let device = model.device(id) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            do {
                if let elements = try await device.uiTree() {
                    tree = elements
                    problem = nil
                } else {
                    problem = "This iPhone has no UI tree yet: turn it on under Info › UI Tree."
                }
            } catch {
                // A tree that cannot be read for a moment, as while an app launches, keeps the last one.
                if tree == nil { problem = "The UI tree cannot be read right now." }
            }
            try? await Task.sleep(for: .seconds(device.kind == .android ? 3 : 1))
        }
    }
}
