import AppKit
import SwiftUI

@MainActor final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore(demo: CommandLine.arguments.contains("--demo"))
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
            NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            })
        {
            DistributedNotificationCenter.default().postNotificationName(.init("Sparebar.show"), object: nil)
            NSApp.terminate(nil)
            return
        }
        installMenu()
        if CommandLine.arguments.contains("--demo-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        status = NSStatusBar.system.statusItem(withLength: 144)
        if let button = status.button {
            let host = PassthroughHostingView(rootView: StatusContent(store: store))
            host.frame = NSRect(x: 0, y: 0, width: 144, height: button.bounds.height)
            host.autoresizingMask = [.width, .height]
            button.addSubview(host)
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let content = NSHostingController(
            rootView: PopoverContent(
                store: store, showSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            )
            .preferredColorScheme(CommandLine.arguments.contains("--demo-light") ? .light : nil))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        store.statusChanged = { [weak self] in self?.updateAccessibility() }
        observeWorkspace(NSWorkspace.willSleepNotification) { $0.store.sleep() }
        observeWorkspace(NSWorkspace.didWakeNotification) { $0.store.wake() }
        observeWorkspace(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.store.accessibilityChanged()
        }
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: .init("Sparebar.show"), object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.showPopover() } })
        store.start()
        updateAccessibility()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "onboarded")
        if firstLaunch || CommandLine.arguments.contains("--show") {
            showPopover()
            UserDefaults.standard.set(true, forKey: "onboarded")
        }
    }
    private func observeWorkspace(
        _ name: Notification.Name, action: @escaping @MainActor (AppDelegate) -> Void
    ) {
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in if let self { action(self) } }
            })
    }
    private func installMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        main.addItem(application)
        let menu = NSMenu(title: "Sparebar")
        application.submenu = menu
        menu.addItem(
            withTitle: "About Sparebar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sparebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
    private func updateAccessibility() {
        let label =
            store.current.map { provider in
                let value =
                    store.valid(provider)
                    ? "\(store.value(provider)) \(store.showRemaining ? "remaining" : "used")"
                    : "allowance unavailable"
                return
                    "Sparebar. \(provider.name), \(store.meter(provider)?.label ?? "allowance"), \(value). \(store.warningText)"
            } ?? "Sparebar. Open settings to choose a tool."
        status?.button?.setAccessibilityLabel(label)
        status?.button?.toolTip = label
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = status?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        store.popoverOpen = true
        if let content = popover.contentViewController {
            content.view.layoutSubtreeIfNeeded()
            popover.contentSize = content.view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ notification: Notification) { store.popoverOpen = false }
    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 510, height: 650),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Sparebar Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsContent(store: store))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await store.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main struct Sparebar {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
