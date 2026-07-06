import XCTest

@testable import SessionSwitch

/// Exercises `StatusItemController.buildMenuModel` headlessly: it's a pure
/// function of `[SessionInfo]` + `[Preset]` (no AppKit, no `@MainActor`), so
/// these tests construct fixtures directly and assert on the `[MenuEntry]`
/// tree, the same way `DomainTests` exercises `ModelCatalog`/`PresetStore`.
final class MenuBuildTests: XCTestCase {

    private func makeSession(
        pid: Int32 = 1,
        projectName: String = "demo",
        terminalApp: String = "Terminal",
        tty: String? = "ttys000",
        model: String? = nil,
        state: SessionState = .idle,
        readOnly: Bool = false,
        readOnlyReason: String? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: pid,
            projectPath: "/tmp/\(projectName)",
            projectName: projectName,
            tty: tty,
            terminalApp: terminalApp,
            model: model,
            state: state,
            readOnly: readOnly,
            readOnlyReason: readOnlyReason,
            pending: nil
        )
    }

    // MARK: - Session header

    func testSessionHeaderReflectsSessionFields() {
        let session = makeSession(
            projectName: "SessionSwitch", terminalApp: "iTerm2", tty: "ttys004",
            model: nil, state: .working, readOnly: true, readOnlyReason: "no controlling terminal"
        )
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .sessionHeader(let header) = entries[0] else {
            return XCTFail("expected sessionHeader at index 0")
        }
        XCTAssertEqual(header.pid, session.id)
        XCTAssertEqual(header.projectName, "SessionSwitch")
        XCTAssertEqual(header.terminalApp, "iTerm2")
        XCTAssertEqual(header.tty, "ttys004")
        XCTAssertEqual(header.state, .working)
        XCTAssertTrue(header.readOnly)
        XCTAssertEqual(header.readOnlyReason, "no controlling terminal")
    }

    // MARK: - Injectable vs read-only: disabled flags on all three submenus

    func testInjectableSessionSubmenusAreEnabledWhenNotReadOnly() {
        let session = makeSession(model: "claude-sonnet-5", readOnly: false)
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .modelSubmenu(let pid, let modelDisabled, _) = entries[1] else {
            return XCTFail("expected modelSubmenu at index 1")
        }
        XCTAssertEqual(pid, session.id)
        XCTAssertFalse(modelDisabled)

        guard case .effortSubmenu(_, let effortDisabled, let levels) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertFalse(effortDisabled)
        XCTAssertEqual(levels, ["low", "medium", "high"])

        guard case .presetSubmenu(_, let presetDisabled, _) = entries[3] else {
            return XCTFail("expected presetSubmenu at index 3")
        }
        XCTAssertFalse(presetDisabled)
    }

    func testReadOnlySessionSubmenusAreAllDisabled() {
        let session = makeSession(model: "claude-sonnet-5", readOnly: true, readOnlyReason: "no controlling terminal")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .modelSubmenu(_, let modelDisabled, _) = entries[1] else {
            return XCTFail("expected modelSubmenu at index 1")
        }
        XCTAssertTrue(modelDisabled)

        guard case .effortSubmenu(_, let effortDisabled, _) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertTrue(effortDisabled)

        guard case .presetSubmenu(_, let presetDisabled, _) = entries[3] else {
            return XCTFail("expected presetSubmenu at index 3")
        }
        XCTAssertTrue(presetDisabled)
    }

    // MARK: - Model submenu: checkmark on current model, dated-id prefix rule

    func testModelSubmenuChecksCurrentModelResolvedFromDatedID() {
        // Verified ground truth (DomainTests): dated ids like
        // claude-sonnet-5-20251001 must resolve via ModelCatalog's id-prefix rule.
        let session = makeSession(model: "claude-sonnet-5-20251001")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .modelSubmenu(_, _, let items) = entries[1] else {
            return XCTFail("expected modelSubmenu at index 1")
        }
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map(\.model.alias), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(items.map(\.isCurrent), [false, false, true, false])
    }

    func testModelSubmenuHasNoCheckmarkWhenModelUnknown() {
        let session = makeSession(model: "claude-nonexistent-1")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .modelSubmenu(_, _, let items) = entries[1] else {
            return XCTFail("expected modelSubmenu at index 1")
        }
        XCTAssertTrue(items.allSatisfy { !$0.isCurrent })
    }

    // MARK: - Effort submenu contents per model

    func testEffortSubmenuForHaikuIsEmptyAndDisabled() {
        let session = makeSession(model: "claude-haiku-4-5")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .effortSubmenu(_, let disabled, let levels) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertTrue(disabled)
        XCTAssertTrue(levels.isEmpty)
    }

    func testEffortSubmenuForUnknownModelIsEmptyAndDisabled() {
        let session = makeSession(model: "claude-nonexistent-1")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .effortSubmenu(_, let disabled, let levels) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertTrue(disabled)
        XCTAssertTrue(levels.isEmpty)
    }

    func testEffortSubmenuWhenSessionHasNoModelYetIsEmptyAndDisabled() {
        let session = makeSession(model: nil)
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .effortSubmenu(_, let disabled, let levels) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertTrue(disabled)
        XCTAssertTrue(levels.isEmpty)
    }

    func testEffortSubmenuForFableListsAllFourLevels() {
        let session = makeSession(model: "claude-fable-5")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])

        guard case .effortSubmenu(_, let disabled, let levels) = entries[2] else {
            return XCTFail("expected effortSubmenu at index 2")
        }
        XCTAssertFalse(disabled)
        XCTAssertEqual(levels, ["low", "medium", "high", "max"])
    }

    // MARK: - Preset submenu

    func testPresetSubmenuListsAllProvidedPresetsInOrder() {
        let session = makeSession(model: "claude-sonnet-5")
        let presets = [
            Preset(id: "deep-work", name: "Deep Work", modelID: "claude-fable-5", effort: "high"),
            Preset(id: "balanced", name: "Balanced", modelID: "claude-sonnet-5", effort: "medium"),
            Preset(id: "cheap-fast", name: "Cheap & Fast", modelID: "claude-haiku-4-5", effort: nil),
        ]
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: presets)

        guard case .presetSubmenu(_, let disabled, let items) = entries[3] else {
            return XCTFail("expected presetSubmenu at index 3")
        }
        XCTAssertFalse(disabled)
        XCTAssertEqual(items.map(\.preset), presets)
    }

    // MARK: - Per-session block shape + footer

    func testSeparatorFollowsEachSessionBlock() {
        let session = makeSession()
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])
        XCTAssertEqual(entries[4], .separator)
    }

    func testSingleSessionProducesExactlyFiveEntriesPlusFooter() {
        let session = makeSession(model: "claude-sonnet-5")
        let entries = StatusItemController.buildMenuModel(sessions: [session], presets: [])
        // header, model, effort, preset, separator, + refreshNow/preferences/quit
        XCTAssertEqual(entries.count, 8)
    }

    func testFooterEntriesPresentInOrderEvenWithNoSessions() {
        let entries = StatusItemController.buildMenuModel(sessions: [], presets: [])
        XCTAssertEqual(entries, [.refreshNow, .preferences, .quit])
    }

    func testFooterEntriesFollowAllSessionBlocksInOrder() {
        let a = makeSession(pid: 1, projectName: "a")
        let b = makeSession(pid: 2, projectName: "b")
        let entries = StatusItemController.buildMenuModel(sessions: [a, b], presets: [])

        XCTAssertEqual(entries.count, 5 * 2 + 3)
        XCTAssertEqual(Array(entries.suffix(3)), [.refreshNow, .preferences, .quit])
    }

    // MARK: - Status title paint guard while a result flash is active
    //
    // Regression (T7 review, Critical): Injector.resolve() fires onResult
    // (which flashes ✓/✗ onto the status button) and then calls setPending on
    // the very next line, which synchronously fires store.onChange -> the
    // controller's chained rebuild() -> updateTitle() -- overwriting the
    // flash in the same call frame, before any redraw. Title repaints must
    // therefore be suppressed while a flash window is open, and resume once
    // it expires.

    func testTitlePaintsWhenNoFlashIsActive() {
        XCTAssertTrue(StatusItemController.shouldPaintTitle(now: Date(), flashDeadline: nil))
    }

    func testTitlePaintSuppressedDuringActiveFlashWindow() {
        let now = Date()
        XCTAssertFalse(
            StatusItemController.shouldPaintTitle(now: now, flashDeadline: now.addingTimeInterval(2.0)),
            "a rebuild landing inside the 2 s flash window must not repaint the title over the flash"
        )
        XCTAssertFalse(
            StatusItemController.shouldPaintTitle(
                now: now.addingTimeInterval(1.999),
                flashDeadline: now.addingTimeInterval(2.0)
            ),
            "still inside the window just before expiry"
        )
    }

    func testTitlePaintResumesOnceFlashDeadlinePasses() {
        let now = Date()
        XCTAssertTrue(
            StatusItemController.shouldPaintTitle(now: now, flashDeadline: now),
            "at the deadline the flash is over; painting resumes"
        )
        XCTAssertTrue(
            StatusItemController.shouldPaintTitle(
                now: now.addingTimeInterval(2.5),
                flashDeadline: now.addingTimeInterval(2.0)
            )
        )
    }
}
