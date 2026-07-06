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
    private(set) var quickPicker: QuickPicker?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wireStack(startRefreshLoop: true)
        registerHotKey()
    }

    /// Boot-sanity hook used by the `--smoke-test` CLI path (see `main.swift`).
    /// Constructs the exact same store/injector/presets/controller/picker
    /// stack as a real launch and renders the first menu, but deliberately
    /// never calls `store.start()` -- that would spin a repeating scan
    /// `Timer` (shelling out to `ps`/`lsof`) with no run loop driving the
    /// test to service it. Also deliberately never registers the global
    /// hotkey (see `registerHotKey`'s doc) -- the `--smoke-test` CLI process
    /// has no run loop/WindowServer connection driving it, and proving the
    /// stack wires correctly doesn't require exercising Carbon.
    func smokeTest() {
        wireStack(startRefreshLoop: false)
    }

    private func wireStack(startRefreshLoop: Bool) {
        let store = SessionStore()
        let injector = Injector(store: store)
        let presetStore = PresetStore()
        let controller = StatusItemController(store: store, injector: injector, presets: presetStore)
        controller.start()

        let quickPicker = QuickPicker()
        quickPicker.onApply = { [weak injector] session, action in
            guard let injector else { return }
            switch action {
            case .model(let model): injector.requestModel(model, for: session)
            case .effort(let level): injector.requestEffort(level, for: session)
            case .preset(let preset): injector.applyPreset(preset, for: session)
            }
        }

        self.store = store
        self.injector = injector
        self.presetStore = presetStore
        self.controller = controller
        self.quickPicker = quickPicker

        if startRefreshLoop {
            store.start()
        }
    }

    /// Registers the global ⌥⌘M hotkey to toggle the quick picker.
    /// Deliberately only called from `applicationDidFinishLaunching` (never
    /// from `smokeTest()`/`wireStack`): `RegisterEventHotKey`/
    /// `InstallEventHandler` touch the Carbon Event Manager, which a headless
    /// `--smoke-test` run shouldn't have to exercise, and `HotKey`'s
    /// failable init already tolerates registration failure gracefully (see
    /// its doc) for the real-launch path too.
    private func registerHotKey() {
        hotKey = HotKey(keyCode: HotKey.defaultKeyCode, modifiers: HotKey.defaultModifiers) { [weak self] in
            Task { @MainActor in
                self?.togglePicker()
            }
        }
    }

    private func togglePicker() {
        guard let store, let presetStore, let quickPicker else { return }
        quickPicker.toggle(sessions: store.sessions, presets: presetStore.presets)
    }
}
