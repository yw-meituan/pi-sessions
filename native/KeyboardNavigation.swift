import AppKit
import SwiftUI

struct SessionKeyboardSelection {
    var id: String?

    func resolved(in ids: [String]) -> String? {
        if let id, ids.contains(id) { return id }
        return ids.first
    }

    mutating func move(_ offset: Int, in ids: [String]) {
        guard let current = resolved(in: ids), let index = ids.firstIndex(of: current) else { id = nil; return }
        id = ids[min(max(index + offset, 0), ids.count - 1)]
    }
}

// Local to this window and active only in search; no global keyboard permission.
struct SearchArrowKeys: NSViewRepresentable {
    let enabled: Bool
    let onMove: (Int) -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.enabled = enabled
        view.onMove = onMove
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var enabled = false
        var onMove: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      window.isKeyWindow, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      !editor.hasMarkedText() else { return event }
                switch event.keyCode {
                case 125: self.onMove?(1)
                case 126: self.onMove?(-1)
                default: return event
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        deinit { stop() }
    }
}
