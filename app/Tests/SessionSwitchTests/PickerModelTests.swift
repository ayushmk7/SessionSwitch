import XCTest

@testable import SessionSwitch

/// Exercises `PickerModel` headlessly: it's a pure state machine (query
/// filtering, mode cycling, arrow navigation, per-mode option lists, apply())
/// with no AppKit/SwiftUI dependency, the same way `MenuBuildTests` exercises
/// `StatusItemController.buildMenuModel`. `QuickPicker`/`PickerView`/`HotKey`
/// (the AppKit/SwiftUI/Carbon wiring) are covered by build success + the
/// `--smoke-test`/live-smoke checks instead, matching how `StatusItemController`
/// itself is only indirectly exercised.
@MainActor
final class PickerModelTests: XCTestCase {

    private func makeSession(
        pid: Int32,
        projectName: String,
        model: String? = "claude-sonnet-5",
        readOnly: Bool = false,
        readOnlyReason: String? = nil,
        pending: String? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: pid,
            projectPath: "/tmp/\(projectName)",
            projectName: projectName,
            tty: "ttys00\(pid)",
            terminalApp: "Terminal",
            model: model,
            state: .idle,
            readOnly: readOnly,
            readOnlyReason: readOnlyReason,
            pending: pending
        )
    }

    private let presets = [
        Preset(id: "deep-work", name: "Deep Work", modelID: "claude-fable-5", effort: "high"),
        Preset(id: "balanced", name: "Balanced", modelID: "claude-sonnet-5", effort: "medium"),
    ]

    // MARK: - Query filters sessions by projectName substring (case-insensitive)

    func testQueryFiltersSessionsByProjectNameSubstringCaseInsensitive() {
        let a = makeSession(pid: 1, projectName: "SessionSwitch")
        let b = makeSession(pid: 2, projectName: "otherproj")
        let model = PickerModel(sessions: [a, b], presets: [])

        model.query = "session"
        XCTAssertEqual(model.filteredSessions.map(\.id), [1])

        model.query = "OTHER"
        XCTAssertEqual(model.filteredSessions.map(\.id), [2])

        model.query = ""
        XCTAssertEqual(model.filteredSessions.map(\.id), [1, 2])
    }

    // MARK: - Initial selectedSession = first non-readOnly

    func testInitialSelectedSessionSkipsLeadingReadOnlySession() {
        let ro = makeSession(pid: 1, projectName: "locked", readOnly: true, readOnlyReason: "no controlling terminal")
        let actionable = makeSession(pid: 2, projectName: "workable")
        let model = PickerModel(sessions: [ro, actionable], presets: [])

        XCTAssertEqual(model.selectedSession?.id, 2)
    }

    func testSelectedSessionFallsBackToFirstWhenAllSessionsAreReadOnly() {
        let ro1 = makeSession(pid: 1, projectName: "locked1", readOnly: true, readOnlyReason: "x")
        let ro2 = makeSession(pid: 2, projectName: "locked2", readOnly: true, readOnlyReason: "y")
        let model = PickerModel(sessions: [ro1, ro2], presets: [])

        XCTAssertEqual(model.selectedSession?.id, 1)
    }

    func testSelectedSessionIsNilWhenThereAreNoSessions() {
        let model = PickerModel(sessions: [], presets: [])
        XCTAssertNil(model.selectedSession)
    }

    // MARK: - Tab cycles .model -> .effort -> .preset -> .model

    func testTabCyclesModelEffortPresetThenBackToModel() {
        let model = PickerModel(sessions: [makeSession(pid: 1, projectName: "a")], presets: [])
        XCTAssertEqual(model.mode, .model)

        model.cycleMode()
        XCTAssertEqual(model.mode, .effort)

        model.cycleMode()
        XCTAssertEqual(model.mode, .preset)

        model.cycleMode()
        XCTAssertEqual(model.mode, .model)
    }

    // MARK: - optionIdx: clamped to options bounds, reset on mode/session change

    func testOptionIdxClampsToOptionsBounds() {
        // Model mode always has exactly the 4 catalog models as options.
        let session = makeSession(pid: 1, projectName: "a", model: "claude-fable-5")
        let model = PickerModel(sessions: [session], presets: [])
        XCTAssertEqual(model.options.count, 4)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.optionIdx, 0, "must not go below zero")

        model.moveSelection(by: 100)
        XCTAssertEqual(model.optionIdx, 3, "must clamp to the last valid index")
    }

    func testOptionIdxClampsToZeroWhenOptionsBecomeEmpty() {
        let ro = makeSession(pid: 1, projectName: "locked", readOnly: true, readOnlyReason: "x")
        let model = PickerModel(sessions: [ro], presets: [])
        XCTAssertEqual(model.options, [])

        model.moveSelection(by: 3)
        XCTAssertEqual(model.optionIdx, 0)
    }

    func testOptionIdxResetsToZeroWhenModeChanges() {
        let session = makeSession(pid: 1, projectName: "a", model: "claude-fable-5")
        let model = PickerModel(sessions: [session], presets: [])
        model.moveSelection(by: 2)
        XCTAssertEqual(model.optionIdx, 2)

        model.cycleMode()
        XCTAssertEqual(model.optionIdx, 0, "changing mode must reset arrow navigation")
    }

    func testOptionIdxResetsToZeroWhenSelectedSessionChangesViaQuery() {
        let a = makeSession(pid: 1, projectName: "alpha", model: "claude-fable-5")
        let b = makeSession(pid: 2, projectName: "beta", model: "claude-sonnet-5")
        let model = PickerModel(sessions: [a, b], presets: [])
        model.moveSelection(by: 1)
        XCTAssertEqual(model.optionIdx, 1)

        model.query = "beta"
        XCTAssertEqual(model.optionIdx, 0, "filtering to a different frontmost session must reset arrow navigation")
    }

    // MARK: - Options per mode

    func testModelModeOptionsAreCatalogModelsWithCurrentModelFlagged() {
        // Dated id, same ground truth as ModelCatalog/StatusItemController tests.
        let session = makeSession(pid: 1, projectName: "a", model: "claude-sonnet-5-20251001")
        let model = PickerModel(sessions: [session], presets: [])

        XCTAssertEqual(model.options.map(\.id), ModelCatalog.defaults.map(\.id))
        XCTAssertEqual(model.options.map(\.isCurrent), [false, false, true, false])
    }

    func testEffortModeOptionsAreCurrentModelEffortsResolvedViaDatedIDLookup() {
        let session = makeSession(pid: 1, projectName: "a", model: "claude-fable-5-20251001")
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .effort

        XCTAssertEqual(model.options.map(\.id), ["low", "medium", "high", "max"])
    }

    func testEffortModeOptionsEmptyWhenCurrentModelHasNoEfforts() {
        let session = makeSession(pid: 1, projectName: "a", model: "claude-haiku-4-5")
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .effort

        XCTAssertEqual(model.options, [])
    }

    func testEffortModeOptionsEmptyWhenSessionHasNoModelYet() {
        let session = makeSession(pid: 1, projectName: "a", model: nil)
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .effort

        XCTAssertEqual(model.options, [])
    }

    func testPresetModeOptionsMirrorProvidedPresetsInOrder() {
        let session = makeSession(pid: 1, projectName: "a")
        let model = PickerModel(sessions: [session], presets: presets)
        model.mode = .preset

        XCTAssertEqual(model.options.map(\.id), ["deep-work", "balanced"])
        XCTAssertEqual(model.options.map(\.title), ["Deep Work", "Balanced"])
    }

    func testReadOnlySessionHasEmptyOptionsInEveryModeAndExposesReason() {
        let session = makeSession(
            pid: 1, projectName: "a", model: "claude-sonnet-5",
            readOnly: true, readOnlyReason: "VS Code not scriptable in v1"
        )
        let model = PickerModel(sessions: [session], presets: presets)

        XCTAssertEqual(model.options, [])
        model.mode = .effort
        XCTAssertEqual(model.options, [])
        model.mode = .preset
        XCTAssertEqual(model.options, [])
        XCTAssertEqual(model.readOnlyReason, "VS Code not scriptable in v1")
    }

    func testReadOnlyReasonIsNilForActionableSession() {
        let session = makeSession(pid: 1, projectName: "a")
        let model = PickerModel(sessions: [session], presets: [])
        XCTAssertNil(model.readOnlyReason)
    }

    // MARK: - apply()

    func testApplyInModelModeReturnsSessionAndChosenModel() {
        let session = makeSession(pid: 7, projectName: "a", model: "claude-haiku-4-5")
        let model = PickerModel(sessions: [session], presets: [])
        model.moveSelection(by: 1) // opus is index 1 in the catalog

        guard let (resultSession, action) = model.apply() else {
            return XCTFail("expected a valid apply() result")
        }
        XCTAssertEqual(resultSession.id, 7)
        XCTAssertEqual(action, .model(ModelCatalog.defaults[1]))
    }

    func testApplyInEffortModeReturnsSessionAndChosenEffort() {
        let session = makeSession(pid: 7, projectName: "a", model: "claude-fable-5")
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .effort
        model.moveSelection(by: 2) // "high"

        guard let (resultSession, action) = model.apply() else {
            return XCTFail("expected a valid apply() result")
        }
        XCTAssertEqual(resultSession.id, 7)
        XCTAssertEqual(action, .effort("high"))
    }

    func testApplyInPresetModeReturnsSessionAndChosenPreset() {
        let session = makeSession(pid: 7, projectName: "a")
        let model = PickerModel(sessions: [session], presets: presets)
        model.mode = .preset
        model.moveSelection(by: 1)

        guard let (resultSession, action) = model.apply() else {
            return XCTFail("expected a valid apply() result")
        }
        XCTAssertEqual(resultSession.id, 7)
        XCTAssertEqual(action, .preset(presets[1]))
    }

    func testApplyReturnsNilWhenSelectedSessionIsReadOnly() {
        let session = makeSession(pid: 1, projectName: "a", readOnly: true, readOnlyReason: "x")
        let model = PickerModel(sessions: [session], presets: [])
        XCTAssertNil(model.apply())
    }

    func testApplyReturnsNilWhenThereAreNoSessions() {
        let model = PickerModel(sessions: [], presets: [])
        XCTAssertNil(model.apply())
    }

    func testApplyReturnsNilInEffortModeWhenCurrentModelHasNoEfforts() {
        let session = makeSession(pid: 1, projectName: "a", model: "claude-haiku-4-5")
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .effort

        XCTAssertNil(model.apply())
    }

    func testApplyReturnsNilInPresetModeWhenNoPresetsExist() {
        let session = makeSession(pid: 1, projectName: "a")
        let model = PickerModel(sessions: [session], presets: [])
        model.mode = .preset

        XCTAssertNil(model.apply())
    }

    // MARK: - commit()/cancel() closures (thin wiring PickerView relies on)

    func testCommitInvokesOnCommitWithApplyResultWhenValid() {
        let session = makeSession(pid: 9, projectName: "a", model: "claude-haiku-4-5")
        let model = PickerModel(sessions: [session], presets: [])
        var committed: (SessionInfo, PickerAction)?
        model.onCommit = { committed = ($0, $1) }

        model.commit()

        XCTAssertEqual(committed?.0.id, 9)
        XCTAssertEqual(committed?.1, .model(ModelCatalog.defaults[0]))
    }

    func testCommitDoesNotInvokeOnCommitWhenApplyIsNil() {
        let model = PickerModel(sessions: [], presets: [])
        var invoked = false
        model.onCommit = { _, _ in invoked = true }

        model.commit()

        XCTAssertFalse(invoked)
    }

    func testCancelInvokesOnCancel() {
        let model = PickerModel(sessions: [], presets: [])
        var invoked = false
        model.onCancel = { invoked = true }

        model.cancel()

        XCTAssertTrue(invoked)
    }
}
