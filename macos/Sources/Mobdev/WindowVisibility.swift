import AppKit
import SwiftUI

/// Tells `changed` whether the window around it can be seen, with an identifier for the window.
/// macOS counts a window as occluded while it is closed, minimized, entirely covered or on another
/// Space, while the app is hidden, and while the screen is locked or asleep.
struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (ObjectIdentifier, Bool) -> Void

    func makeNSView(context: Context) -> Reporter { Reporter(changed: changed) }

    func updateNSView(_ view: Reporter, context: Context) { view.changed = changed }

    static func dismantleNSView(_ view: Reporter, coordinator: ()) { view.report(false) }

    final class Reporter: NSView {
        var changed: @MainActor (ObjectIdentifier, Bool) -> Void
        private var reported: Bool?

        init(changed: @escaping @MainActor (ObjectIdentifier, Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            let center = NotificationCenter.default
            let name = NSWindow.didChangeOcclusionStateNotification
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow { center.addObserver(self, selector: #selector(occlusionChanged), name: name, object: newWindow) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            occlusionChanged()
        }

        /// Clicks go to the window's content.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @objc private func occlusionChanged() { report(window?.occlusionState.contains(.visible) == true) }

        func report(_ visible: Bool) {
            guard visible != reported else { return }
            reported = visible
            changed(ObjectIdentifier(self), visible)
        }
    }
}
