import AppKit

/// A pure, `Equatable` description of the sessions menu's contents, produced
/// by `StatusItemController.buildMenuModel` independently of AppKit so it's
/// unit-testable headlessly (see `MenuBuildTests`). `StatusItemController`
/// maps this list onto real `NSMenuItem`s 1:1, in order.
enum MenuEntry: Equatable {
    /// Non-actionable per-session summary line (project, terminal/tty,
    /// state, read-only lock + reason).
    case sessionHeader(SessionHeaderEntry)
    /// "Model" submenu: one entry per `ModelCatalog.defaults` model, the
    /// session's current one flagged via `isCurrent`. The whole submenu is
    /// disabled when the session is readOnly.
    case modelSubmenu(pid: Int32, disabled: Bool, items: [ModelEntry])
    /// "Effort" submenu: the current model's effort levels. Empty (rendered
    /// as a disabled "—" placeholder) when readOnly, the model is unknown,
    /// or the model has no effort levels (e.g. Haiku).
    case effortSubmenu(pid: Int32, disabled: Bool, levels: [String])
    /// "Preset" submenu: one entry per stored preset. Disabled when readOnly.
    case presetSubmenu(pid: Int32, disabled: Bool, items: [PresetEntry])
    case separator
    case refreshNow
    /// Task 9 stub: a disabled no-op placeholder in v1.
    case preferences
    case quit
}

struct SessionHeaderEntry: Equatable {
    let pid: Int32
    let projectName: String
    let terminalApp: String
    let tty: String?
    let state: SessionState
    let readOnly: Bool
    let readOnlyReason: String?
}

struct ModelEntry: Equatable {
    let model: ClaudeModel
    let isCurrent: Bool
}

struct PresetEntry: Equatable {
    let preset: Preset
}

/// Owns the menu bar `NSStatusItem`: rebuilds its menu every time
/// `store.onChange` fires (sessions rescanned, a `pending` label set/
/// cleared, ...) and dispatches menu actions into `injector`.
///
/// Threading: `store`/`injector` are both `@MainActor`, and `NSStatusItem`/
/// `NSMenu` are AppKit main-thread-only types, so this whole controller is
/// `@MainActor` too -- no background work happens here. The one exception is
/// `buildMenuModel`, marked `nonisolated` because it's a pure function of its
/// arguments (no AppKit, no shared state) and needs to be callable headlessly
/// from plain (non-`@MainActor`) unit tests.
@MainActor
final class StatusItemController: NSObject {
    private let store: SessionStore
    private let injector: Injector
    private let presets: PresetStore

    private(set) var statusItem: NSStatusItem?
    private var flashResetWorkItem: DispatchWorkItem?

    /// End of the currently active ✓/✗ title-flash window, if any. While it
    /// lies in the future, `updateTitle` must not repaint the status button:
    /// `Injector.resolve()` fires `onResult` (which starts the flash) and
    /// then `setPending` on the very next line, which synchronously fires
    /// `store.onChange` -> our chained `rebuild()` -> `updateTitle()` in the
    /// SAME call frame -- without this guard the flash would be overwritten
    /// before AppKit ever draws it. Cleared by the flash's 2 s reset work
    /// item, which then repaints from current store state.
    private var flashDeadline: Date?

    init(store: SessionStore, injector: Injector, presets: PresetStore) {
        self.store = store
        self.injector = injector
        self.presets = presets
        super.init()

        // Binding directive 1: `store.onChange` is a single-slot closure that
        // Injector's init already claimed (to drain FIFOs / poll
        // verification once a session goes idle or its state refreshes).
        // Chain onto whatever's already there instead of overwriting it.
        let previous = store.onChange
        store.onChange = { [weak self] in
            previous?()
            self?.rebuild()
        }

        // Binding directive 2: never call back into
        // requestModel/requestEffort/applyPreset for the same pid from here.
        // This only flashes the status title; the *result itself* is picked
        // up by the next store.onChange-driven rebuild (e.g. setPending
        // clearing already triggers one).
        injector.onResult = { [weak self] pid, result in
            self?.handleResult(pid: pid, result: result)
        }
    }

    /// Creates the `NSStatusItem` and renders the first menu. Deliberately
    /// does not start `store`'s refresh loop -- callers (`AppDelegate`) do
    /// that separately, so `--smoke-test` can exercise this without spinning
    /// a live scan timer.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        rebuild()
    }

    // MARK: - Pure menu model (headlessly testable; see MenuBuildTests)

    nonisolated static func buildMenuModel(sessions: [SessionInfo], presets: [Preset]) -> [MenuEntry] {
        var entries: [MenuEntry] = []

        for session in sessions {
            entries.append(.sessionHeader(SessionHeaderEntry(
                pid: session.id,
                projectName: session.projectName,
                terminalApp: session.terminalApp,
                tty: session.tty,
                state: session.state,
                readOnly: session.readOnly,
                readOnlyReason: session.readOnlyReason
            )))

            let currentModel = session.model.flatMap { ModelCatalog.model(idOrAlias: $0) }

            let modelItems = ModelCatalog.defaults.map { model in
                ModelEntry(model: model, isCurrent: model.id == currentModel?.id)
            }
            entries.append(.modelSubmenu(pid: session.id, disabled: session.readOnly, items: modelItems))

            let levels = currentModel?.efforts ?? []
            let effortDisabled = session.readOnly || levels.isEmpty
            entries.append(.effortSubmenu(pid: session.id, disabled: effortDisabled, levels: levels))

            let presetItems = presets.map(PresetEntry.init)
            entries.append(.presetSubmenu(pid: session.id, disabled: session.readOnly, items: presetItems))

            entries.append(.separator)
        }

        entries.append(.refreshNow)
        entries.append(.preferences)
        entries.append(.quit)
        return entries
    }

    // MARK: - NSMenu construction (1:1 mapping of buildMenuModel's output)

    private func rebuild() {
        guard let statusItem else { return }
        let sessions = store.sessions
        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let entries = Self.buildMenuModel(sessions: sessions, presets: presets.presets)

        let menu = NSMenu()
        for entry in entries {
            menu.addItem(menuItem(for: entry, sessionsByPID: sessionsByPID))
        }
        statusItem.menu = menu

        updateTitle(sessions: sessions)
    }

    private func menuItem(for entry: MenuEntry, sessionsByPID: [Int32: SessionInfo]) -> NSMenuItem {
        switch entry {
        case .sessionHeader(let header):
            return headerItem(header)
        case .modelSubmenu(let pid, let disabled, let items):
            return modelSubmenuItem(pid: pid, disabled: disabled, items: items, sessionsByPID: sessionsByPID)
        case .effortSubmenu(let pid, let disabled, let levels):
            return effortSubmenuItem(pid: pid, disabled: disabled, levels: levels, sessionsByPID: sessionsByPID)
        case .presetSubmenu(let pid, let disabled, let items):
            return presetSubmenuItem(pid: pid, disabled: disabled, items: items, sessionsByPID: sessionsByPID)
        case .separator:
            return .separator()
        case .refreshNow:
            return actionItem(title: "Refresh Now") { [weak self] in self?.store.refreshNow() }
        case .preferences:
            let item = NSMenuItem(title: "Preferences…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .quit:
            // No explicit target: resolves via the responder chain, exactly
            // like the pre-Task-7 AppDelegate's Quit item did.
            return NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    private func headerItem(_ header: SessionHeaderEntry) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = header.projectName
        item.isEnabled = false

        let text = NSMutableAttributedString()
        let dotColor = header.state == .working ? Theme.cyan : Theme.idleGray
        text.append(NSAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: dotColor]))
        text.append(NSAttributedString(
            string: header.projectName,
            attributes: [.foregroundColor: Theme.ink, .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        ))

        var detail = "  \(header.terminalApp)"
        if let tty = header.tty { detail += " (\(tty))" }
        if header.readOnly { detail += "  \u{1F512} \(header.readOnlyReason ?? "read-only")" }
        text.append(NSAttributedString(
            string: detail,
            attributes: [.foregroundColor: Theme.dim, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        ))

        item.attributedTitle = text
        return item
    }

    private func modelSubmenuItem(
        pid: Int32,
        disabled: Bool,
        items: [ModelEntry],
        sessionsByPID: [Int32: SessionInfo]
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        parent.isEnabled = !disabled

        let submenu = NSMenu()
        for entry in items {
            let item = NSMenuItem(title: entry.model.name, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = !disabled
            item.state = entry.isCurrent ? .on : .off
            if entry.isCurrent {
                item.attributedTitle = NSAttributedString(
                    string: entry.model.name,
                    attributes: [.foregroundColor: Theme.cyan]
                )
            }
            let model = entry.model
            item.representedObject = MenuAction { [weak self] in
                guard let self, let session = sessionsByPID[pid] else { return }
                self.injector.requestModel(model, for: session)
            }
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func effortSubmenuItem(
        pid: Int32,
        disabled: Bool,
        levels: [String],
        sessionsByPID: [Int32: SessionInfo]
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Effort", action: nil, keyEquivalent: "")
        parent.isEnabled = !disabled

        let submenu = NSMenu()
        if levels.isEmpty {
            let placeholder = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
        } else {
            for level in levels {
                let item = NSMenuItem(title: level.capitalized, action: #selector(performAction(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = !disabled
                item.representedObject = MenuAction { [weak self] in
                    guard let self, let session = sessionsByPID[pid] else { return }
                    self.injector.requestEffort(level, for: session)
                }
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        return parent
    }

    private func presetSubmenuItem(
        pid: Int32,
        disabled: Bool,
        items: [PresetEntry],
        sessionsByPID: [Int32: SessionInfo]
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        parent.isEnabled = !disabled

        let submenu = NSMenu()
        for entry in items {
            let item = NSMenuItem(title: entry.preset.name, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = !disabled
            let preset = entry.preset
            item.representedObject = MenuAction { [weak self] in
                guard let self, let session = sessionsByPID[pid] else { return }
                self.injector.applyPreset(preset, for: session)
            }
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func actionItem(title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(handler)
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.handler()
    }

    // MARK: - Status title: "◐ N" (+ amber "!" when any session pending)

    /// Pure decision: may the status title be repainted at `now`, given the
    /// active flash window ending at `flashDeadline` (nil = no flash)?
    /// Extracted (nonisolated, no AppKit) so the guard is headlessly
    /// testable -- see MenuBuildTests' title-paint-guard cases.
    nonisolated static func shouldPaintTitle(now: Date, flashDeadline: Date?) -> Bool {
        guard let flashDeadline else { return true }
        return now >= flashDeadline
    }

    private func updateTitle(sessions: [SessionInfo]) {
        guard Self.shouldPaintTitle(now: Date(), flashDeadline: flashDeadline) else { return }
        guard let button = statusItem?.button else { return }
        let text = NSMutableAttributedString(
            string: "\u{25D0} \(sessions.count)",
            attributes: [.foregroundColor: Theme.ink, .font: NSFont.menuBarFont(ofSize: 0)]
        )
        if sessions.contains(where: { $0.pending != nil }) {
            text.append(NSAttributedString(
                string: "!",
                attributes: [.foregroundColor: Theme.amber, .font: NSFont.menuBarFont(ofSize: 0)]
            ))
        }
        button.attributedTitle = text
    }

    // MARK: - Transient result flash (no notification center; binding directive 2)

    private func handleResult(pid: Int32, result: Injector.InjectionResult) {
        switch result {
        case .verified, .assumed:
            flash(symbol: "\u{2713}", color: Theme.cyan)
        case .unverified, .rejected:
            flash(symbol: "\u{2717}", color: Theme.red)
        }
    }

    private func flash(symbol: String, color: NSColor) {
        guard let button = statusItem?.button else { return }
        // Overlapping results: a second flash cancels the prior reset work
        // item and restarts the full 2 s window from now.
        flashResetWorkItem?.cancel()
        flashDeadline = Date().addingTimeInterval(2.0)

        button.attributedTitle = NSAttributedString(
            string: symbol,
            attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)]
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Clear the window BEFORE repainting, or updateTitle's own
            // shouldPaintTitle guard would suppress this very repaint.
            self.flashDeadline = nil
            self.flashResetWorkItem = nil
            self.updateTitle(sessions: self.store.sessions)
        }
        flashResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
}

/// Wraps a closure so it can ride as an `NSMenuItem.representedObject`
/// (AppKit menu actions are target/selector-based, not closure-based).
private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}
