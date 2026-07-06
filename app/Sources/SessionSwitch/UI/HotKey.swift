import Carbon.HIToolbox
import Foundation

/// Thin Swift wrapper around the Carbon Event Manager's global-hotkey pair
/// (`RegisterEventHotKey` + `InstallEventHandler`) -- the only API that
/// delivers a system-wide keyboard shortcut to a menu-bar `.accessory` app
/// (no Dock icon, no regular window) without requiring Accessibility
/// permission. Works whether or not the app is frontmost.
///
/// Carbon's event handler is a C function pointer (`EventHandlerUPP`), which
/// cannot capture a Swift closure directly. Each registered `HotKey` instead
/// stashes its `handler` in a static registry keyed by a per-instance id, and
/// a single process-lifetime C callback (installed once, lazily) looks the
/// handler up there and calls it. Carbon delivers these events on the main
/// run loop, so `handler` always fires on the main thread -- callers that
/// need to touch `@MainActor` state (e.g. `AppDelegate`) are responsible for
/// hopping via `Task { @MainActor in ... }` themselves; `HotKey` stays
/// actor-agnostic so it has no concurrency-checking friction of its own.
final class HotKey {
    /// Default binding: Option+Command+M (`kVK_ANSI_M`).
    static let defaultKeyCode: UInt32 = 46
    static let defaultModifiers: UInt32 = UInt32(optionKey | cmdKey)

    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: () -> Void] = [:]
    private static var isHandlerInstalled = false

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// Registers a new global hotkey. Fails (returns `nil`) rather than
    /// crashing when `RegisterEventHotKey` can't claim the combo (e.g.
    /// another app already owns it, or -- relevant to `--smoke-test` -- the
    /// process has no WindowServer/Carbon Event Manager connection to
    /// register against): a hotkey conflict must never take down the whole
    /// menu-bar app, so callers should treat `nil` as "hotkey unavailable"
    /// and keep running (the picker is still reachable however the caller
    /// chooses to expose it, e.g. a menu item).
    init?(
        keyCode: UInt32 = HotKey.defaultKeyCode,
        modifiers: UInt32 = HotKey.defaultModifiers,
        handler: @escaping () -> Void
    ) {
        Self.installHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("ssw1"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }

        self.hotKeyID = id
        self.hotKeyRef = ref
        Self.registry[id] = handler
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.registry.removeValue(forKey: hotKeyID)
    }

    /// Installs the single process-lifetime Carbon event handler on first
    /// use. Never torn down (matches `HotKey`'s own "static registry"
    /// design): there's exactly one app-lifetime handler regardless of how
    /// many `HotKey` instances register/deregister over time.
    private static func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCarbonEventHandler, 1, &eventType, nil, nil)
    }

    /// Looks up and invokes the handler for a fired hotkey id. Called only
    /// from `hotKeyCarbonEventHandler` (main thread, per Carbon's delivery
    /// guarantee -- see the type doc above).
    fileprivate static func invoke(id: UInt32) {
        registry[id]?()
    }

    /// Packs up to 4 ASCII characters into the `FourCharCode`/`OSType`
    /// Carbon expects for an `EventHotKeyID.signature` (an app-chosen tag
    /// distinguishing this hotkey from ones registered by other processes).
    private static func fourCharCode(_ string: String) -> FourCharCode {
        string.unicodeScalars.prefix(4).reduce(FourCharCode(0)) { result, scalar in
            (result << 8) + FourCharCode(scalar.value)
        }
    }
}

/// The process-lifetime Carbon callback (see `HotKey.installHandlerIfNeeded`).
/// A global `let` closure with no captures, which Swift can hand to Carbon's
/// C-function-pointer-typed `InstallEventHandler` parameter directly.
private let hotKeyCarbonEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    HotKey.invoke(id: hotKeyID.id)
    return noErr
}
