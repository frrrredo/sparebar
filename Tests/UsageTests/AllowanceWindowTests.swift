import AppKit
import SwiftUI
import Testing

@testable import UsageApp

@MainActor struct AllowanceWindowTests {
    @Test func reopenWorksWithoutAStatusItemAndReadingEndsOnClose() {
        _ = NSApplication.shared
        var reading = false
        let panel = AllowanceWindow(
            content: Text("Sample allowances").frame(width: 332, height: 240),
            readingChanged: { reading = $0 })
        defer { panel.close() }

        // No status item or menu bar anchor exists in this regression case.
        panel.show()
        #expect(panel.window.isVisible)
        #expect(reading)
        #expect(panel.window.contentView?.frame.size == NSSize(width: 332, height: 240))

        panel.close()
        #expect(!panel.window.isVisible)
        #expect(!reading)

        // Finder/Spotlight can reopen the same window after it was closed.
        panel.show()
        #expect(panel.window.isVisible)
        #expect(reading)
        panel.close()
        #expect(!reading)
    }
}
