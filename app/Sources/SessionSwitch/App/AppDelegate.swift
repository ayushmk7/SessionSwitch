import AppKit

/// Owns the menu bar presence for SessionSwitch. On launch, wires the full
/// stack (`SessionStore` -> `Injector` -> `PresetStore` ->
/// `StatusItemController`) and starts the live refresh loop.
///
/// `@MainActor`: `SessionStore`/`Injector`/`StatusItemController` are all
/// main-actor-isolated, and `NSApplicationDelegate` callbacks already run on
/// the main thread, so this just makes that explicit to the compiler.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore?
    private var injector: Injector?
    private var presetStore: PresetStore?
    private(set) var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireStack(startRefreshLoop: true)
    }

    /// Boot-sanity hook used by the `--smoke-test` CLI path (see `main.swift`).
    /// Constructs the exact same store/injector/presets/controller stack as a
    /// real launch and renders the first menu, but deliberately never calls
    /// `store.start()` -- that would spin a repeating scan `Timer` (shelling
    /// out to `ps`/`lsof`) with no run loop driving the test to service it.
    func smokeTest() {
        wireStack(startRefreshLoop: false)
    }

    private func wireStack(startRefreshLoop: Bool) {
        let store = SessionStore()
        let injector = Injector(store: store)
        let presetStore = PresetStore()
        let controller = StatusItemController(store: store, injector: injector, presets: presetStore)
        controller.start()

        self.store = store
        self.injector = injector
        self.presetStore = presetStore
        self.controller = controller

        if startRefreshLoop {
            store.start()
        }
    }
}
