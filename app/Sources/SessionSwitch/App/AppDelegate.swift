import AppKit

/// Owns the menu bar (`NSStatusItem`) presence for SessionSwitch.
///
/// Kept intentionally minimal for Task 1: later tasks (SessionStore, Injector,
/// StatusItemController) wire richer menu content in via `applicationDidFinishLaunching`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
    }

    /// Boot-sanity hook used by the `--smoke-test` CLI path (see `main.swift`).
    /// Exercises the same status item construction as a real launch, without
    /// requiring `NSApplication.run()` to be driving an event loop.
    func smokeTest() {
        configureStatusItem()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◐"

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        item.menu = menu

        statusItem = item
    }
}
