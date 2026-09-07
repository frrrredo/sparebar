import AppKit
import SwiftUI

// Reopening the app must work even when macOS has no room for its status item.
@MainActor final class AllowanceWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let readingChanged: (Bool) -> Void

    init<Content: View>(content: Content, readingChanged: @escaping (Bool) -> Void) {
        self.readingChanged = readingChanged
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentViewController: controller)
        super.init()
        window.title = "Sparebar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show() {
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        readingChanged(true)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { readingChanged(false) }
}
