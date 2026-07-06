import AppKit
import SwiftUI

/// What `PickerModel.apply()`/`commit()` hand back for the caller to route
/// into `Injector` (`AppDelegate` maps each case onto `requestModel`/
/// `requestEffort`/`applyPreset`, exactly like `StatusItemController`'s menu
/// actions do).
enum PickerAction: Equatable {
    case model(ClaudeModel)
    case effort(String)
    case preset(Preset)
}

/// One row in the current mode's option list -- pure display data, no AppKit.
struct PickerOption: Equatable, Identifiable {
    let id: String
    let title: String
    let isCurrent: Bool
}

/// Pure, headlessly-testable state machine backing `PickerView`'s SwiftUI
/// `TextField` + option list (see `PickerModelTests`). Owns no AppKit/SwiftUI
/// types.
///
/// `sessions`/`presets` are captured once at init: `QuickPicker` builds a
/// fresh `PickerModel` from a live snapshot of the store/preset state every
/// time the panel opens (see `QuickPicker.show`), so an instance never needs
/// to react to store changes mid-session -- it only reacts to the user's own
/// query/mode/arrow input.
@MainActor
final class PickerModel: ObservableObject {
    /// Mirrors the menu's three per-session switches (`StatusItemController`'s
    /// Model/Effort/Preset submenus), cycled via Tab.
    enum Mode: CaseIterable, Equatable {
        case model
        case effort
        case preset
    }

    @Published var query: String = "" {
        didSet { optionIdx = 0 }
    }
    @Published var mode: Mode = .model {
        didSet { optionIdx = 0 }
    }
    /// Arrow-navigated index into `options`. Clamped to `options`' bounds on
    /// every assignment (including direct sets, not just `moveSelection`), so
    /// it can never point past whatever the current mode/session offers.
    @Published var optionIdx: Int = 0 {
        didSet {
            let clamped = Self.clamp(optionIdx, count: options.count)
            if clamped != optionIdx { optionIdx = clamped }
        }
    }

    let sessions: [SessionInfo]
    let presets: [Preset]

    /// Fired by `commit()` with a valid `apply()` result. `QuickPicker` wires
    /// this to route the action into `Injector` and then close the panel.
    var onCommit: ((SessionInfo, PickerAction) -> Void)?
    /// Fired by `cancel()` (Esc). `QuickPicker` wires this to close the panel.
    var onCancel: (() -> Void)?

    init(sessions: [SessionInfo], presets: [Preset]) {
        self.sessions = sessions
        self.presets = presets
    }

    // MARK: - Filtering + session selection

    /// Sessions whose `projectName` contains `query` (case-insensitive);
    /// unfiltered when `query` is empty.
    var filteredSessions: [SessionInfo] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.projectName.localizedCaseInsensitiveContains(query) }
    }

    /// The frontmost session to act on: the first non-readOnly match, so the
    /// picker doesn't open onto a disabled option list purely because a
    /// readOnly session happens to sort first. Falls back to the very first
    /// match when every match is readOnly, so there's still something to
    /// show a reason for.
    var selectedSession: SessionInfo? {
        let filtered = filteredSessions
        return filtered.first(where: { !$0.readOnly }) ?? filtered.first
    }

    // MARK: - Tab cycling

    func cycleMode() {
        let all = Mode.allCases
        let idx = all.firstIndex(of: mode) ?? 0
        mode = all[(idx + 1) % all.count]
    }

    // MARK: - Arrow navigation

    func moveSelection(by delta: Int) {
        optionIdx += delta
    }

    // MARK: - Options per mode

    /// The selected session's current model, resolved through
    /// `ModelCatalog`'s dated-id prefix rule (mirrors
    /// `StatusItemController.buildMenuModel`'s `currentModel`).
    var currentModel: ClaudeModel? {
        selectedSession?.model.flatMap { ModelCatalog.model(idOrAlias: $0) }
    }

    /// Empty (with `readOnlyReason` set) when the selected session is
    /// readOnly, whatever the mode -- otherwise the catalog models / current
    /// model's efforts / stored presets, mirroring the menu's rules exactly.
    var options: [PickerOption] {
        guard let session = selectedSession, !session.readOnly else { return [] }
        switch mode {
        case .model:
            return ModelCatalog.defaults.map {
                PickerOption(id: $0.id, title: $0.name, isCurrent: $0.id == currentModel?.id)
            }
        case .effort:
            guard let efforts = currentModel?.efforts, !efforts.isEmpty else { return [] }
            return efforts.map { PickerOption(id: $0, title: $0.capitalized, isCurrent: false) }
        case .preset:
            return presets.map { PickerOption(id: $0.id, title: $0.name, isCurrent: false) }
        }
    }

    var readOnlyReason: String? {
        guard let session = selectedSession, session.readOnly else { return nil }
        return session.readOnlyReason ?? "read-only"
    }

    // MARK: - Apply

    /// Resolves the currently-selected option into the pair the caller
    /// routes to `Injector`: `nil` when the session is readOnly, unmatched,
    /// or the mode has no valid options to choose from.
    func apply() -> (SessionInfo, PickerAction)? {
        guard let session = selectedSession, !session.readOnly else { return nil }
        let options = self.options
        guard optionIdx >= 0, optionIdx < options.count else { return nil }
        let option = options[optionIdx]
        switch mode {
        case .model:
            guard let model = ModelCatalog.defaults.first(where: { $0.id == option.id }) else { return nil }
            return (session, .model(model))
        case .effort:
            return (session, .effort(option.id))
        case .preset:
            guard let preset = presets.first(where: { $0.id == option.id }) else { return nil }
            return (session, .preset(preset))
        }
    }

    func commit() {
        guard let (session, action) = apply() else { return }
        onCommit?(session, action)
    }

    func cancel() {
        onCancel?()
    }

    private static func clamp(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(value, 0), count - 1)
    }
}

// MARK: - Panel

/// Borderless `NSPanel` subclass that can still become key: AppKit's default
/// `canBecomeKey` for a borderless panel is `false`, which would leave the
/// picker's `TextField` unable to receive keystrokes. Deliberately NOT
/// `.nonactivatingPanel` (per the brief) -- that style would fight the
/// explicit `NSApp.activate` + `makeKeyAndOrderFront` sequence `QuickPicker`
/// uses to actually pull keyboard focus onto the panel from a background
/// accessory app.
final class QuickPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the quick-picker panel's lifecycle. `AppDelegate` holds one instance
/// for the app's lifetime and calls `toggle(sessions:presets:)` from the
/// global hotkey handler; a fresh `PickerModel` (and hence a fresh
/// `sessions`/`presets` snapshot) is built every time the panel opens.
@MainActor
final class QuickPicker: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 560, height: 400)

    private var panel: QuickPickerPanel?
    private var model: PickerModel?

    /// Whichever app was frontmost right before `show()` activated
    /// SessionSwitch to pull keyboard focus onto the panel -- almost always
    /// the user's terminal. Captured so `hide()` can hand focus back to it;
    /// without this, using the picker leaves the user's terminal window
    /// visually in front but no longer key, silently eating their next
    /// keystrokes.
    private var previousApp: NSRunningApplication?

    /// Fired when the user commits a choice (Enter): `(session, action)` for
    /// the caller to route into `Injector`. The panel closes itself right
    /// after invoking this (see `show`'s `onCommit` wiring) -- callers must
    /// not call `hide()` themselves as well.
    var onApply: ((SessionInfo, PickerAction) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Hides the panel if visible, otherwise shows it with a fresh snapshot.
    /// This is what the global hotkey calls.
    func toggle(sessions: [SessionInfo], presets: [Preset]) {
        if isVisible {
            hide()
        } else {
            show(sessions: sessions, presets: presets)
        }
    }

    func show(sessions: [SessionInfo], presets: [Preset]) {
        let model = PickerModel(sessions: sessions, presets: presets)
        model.onCommit = { [weak self] session, action in
            self?.onApply?(session, action)
            self?.hide()
        }
        model.onCancel = { [weak self] in self?.hide() }
        self.model = model

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: PickerView(model: model))
        center(panel)

        // Capture whatever's frontmost BEFORE activating SessionSwitch (an
        // `.accessory` app with no Dock icon/window otherwise) so `hide()`
        // can hand focus back to it. Skip capturing SessionSwitch itself
        // (e.g. a second toggle while already frontmost for some other
        // reason) -- reactivating ourselves on hide would be a no-op at
        // best and would discard the *real* previously-captured app at
        // worst.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)

        // Hand focus back to whatever was frontmost before the picker
        // activated SessionSwitch -- otherwise the user's terminal is left
        // visually in front but not key, silently swallowing their next
        // keystrokes. `activate()` (no options) is the modern macOS 14+
        // replacement for the now-deprecated `activate(options:)`; since
        // this package's deployment target is macOS 14 (`Package.swift`),
        // every build/run of this code has it available, so there's no
        // deprecated fallback to reach for here (and no reason to keep one
        // around just to trip the compiler's deprecation warning).
        previousApp?.activate()
        previousApp = nil
    }

    private func makePanel() -> QuickPickerPanel {
        let panel = QuickPickerPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.midY - Self.size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }

    // MARK: - NSWindowDelegate: click-away hides the panel

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

// MARK: - View

/// Mono Glass quick-picker UI: dark translucent panel, ink text, cyan
/// active-row highlight, amber pending badge, red readOnly reason, mono font
/// for tty/model ids.
///
/// Keyboard: a focused `TextField` drives `query`; ↑/↓/Tab/Enter are handled
/// via `.onKeyPress` (macOS 14 API) attached to the whole view rather than an
/// `NSEvent` local monitor -- it's SwiftUI-native, scoped to this view's
/// focus, and needs no manual add/remove lifecycle. Esc is handled via
/// SwiftUI's `.onExitCommand`; click-away is handled separately by
/// `QuickPicker`'s `NSWindowDelegate.windowDidResignKey`.
struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            queryField
            if let session = model.selectedSession {
                sessionSummary(session)
                modeTabs
                if let reason = model.readOnlyReason {
                    Text("\u{1F512} \(reason)")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: Theme.red))
                } else {
                    optionsList
                }
            } else {
                Text("No matching sessions")
                    .foregroundColor(Color(nsColor: Theme.dim))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 560, height: 400, alignment: .topLeading)
        .background(VisualEffectBlur())
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.tab) { model.cycleMode(); return .handled }
        .onKeyPress(.return) { model.commit(); return .handled }
        .onExitCommand { model.cancel() }
        .onAppear { queryFocused = true }
    }

    private var queryField: some View {
        TextField("Search sessions…", text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(Color(nsColor: Theme.ink))
            .focused($queryFocused)
    }

    private func sessionSummary(_ session: SessionInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: session.state == .working ? Theme.cyan : Theme.idleGray))
                .frame(width: 8, height: 8)
            Text(session.projectName)
                .foregroundColor(Color(nsColor: Theme.ink))
            Text(session.terminalApp + (session.tty.map { " (\($0))" } ?? ""))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: Theme.dim))
            if let pending = session.pending {
                Text(pending)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: Theme.amber).opacity(0.25))
                    .foregroundColor(Color(nsColor: Theme.amber))
                    .clipShape(Capsule())
            }
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 16) {
            modeLabel("Model", .model)
            modeLabel("Effort", .effort)
            modeLabel("Preset", .preset)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private func modeLabel(_ title: String, _ mode: PickerModel.Mode) -> some View {
        Text(title)
            .foregroundColor(self.model.mode == mode ? Color(nsColor: Theme.cyan) : Color(nsColor: Theme.dim))
    }

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                HStack {
                    Text(option.title)
                        .font(.system(size: 14, design: model.mode == .model ? .monospaced : .default))
                        .foregroundColor(Color(nsColor: Theme.ink))
                    if option.isCurrent {
                        Text("current")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Theme.cyan))
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index == model.optionIdx ? Color(nsColor: Theme.cyan).opacity(0.18) : Color.clear)
                )
            }
        }
    }
}

/// Dark translucent background material (Mono Glass): `NSVisualEffectView`
/// with `.hudWindow` (a dark-appearance material regardless of system
/// appearance, matching the palette's fixed dark ink-on-black design).
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
