import XCTest

@testable import SessionSwitch

final class DomainTests: XCTestCase {

    // MARK: - ModelCatalog

    func testDefaultsContainFourModelsExactly() {
        let defaults = ModelCatalog.defaults
        XCTAssertEqual(defaults.count, 4)

        let fable = defaults.first { $0.alias == "fable" }
        XCTAssertEqual(fable?.id, "claude-fable-5")
        XCTAssertEqual(fable?.name, "Fable 5")
        XCTAssertEqual(fable?.efforts, ["low", "medium", "high", "max"])

        let opus = defaults.first { $0.alias == "opus" }
        XCTAssertEqual(opus?.id, "claude-opus-4-8")
        XCTAssertEqual(opus?.name, "Opus 4.8")
        XCTAssertEqual(opus?.efforts, ["low", "medium", "high"])

        let sonnet = defaults.first { $0.alias == "sonnet" }
        XCTAssertEqual(sonnet?.id, "claude-sonnet-5")
        XCTAssertEqual(sonnet?.name, "Sonnet 5")
        XCTAssertEqual(sonnet?.efforts, ["low", "medium", "high"])

        let haiku = defaults.first { $0.alias == "haiku" }
        XCTAssertEqual(haiku?.id, "claude-haiku-4-5")
        XCTAssertEqual(haiku?.name, "Haiku 4.5")
        XCTAssertEqual(haiku?.efforts, [])
    }

    func testModelLookupByExactID() {
        let model = ModelCatalog.model(idOrAlias: "claude-sonnet-5")
        XCTAssertEqual(model?.alias, "sonnet")
    }

    func testModelLookupByAlias() {
        let model = ModelCatalog.model(idOrAlias: "fable")
        XCTAssertEqual(model?.id, "claude-fable-5")
    }

    func testModelLookupByDatedIDPrefix() {
        // Verified ground truth: dated ids like claude-haiku-4-5-20251001 must
        // still resolve to the catalog entry via an id-prefix match.
        let model = ModelCatalog.model(idOrAlias: "claude-haiku-4-5-20251001")
        XCTAssertEqual(model?.alias, "haiku")
    }

    func testModelLookupUnknownReturnsNil() {
        XCTAssertNil(ModelCatalog.model(idOrAlias: "claude-nonexistent-1"))
    }

    func testModelLookupDoesNotMatchUnrelatedPrefixOverlap() {
        // "claude-opus-4-8" must not be picked up by a lookup for "claude-opus-4"
        // matching some *other* catalog entry that happens to share a shorter
        // prefix — guards against overly loose substring matching.
        XCTAssertNil(ModelCatalog.model(idOrAlias: "claude-opus-4"))
    }

    // MARK: - PresetStore

    func testPresetStoreSeedsDefaultsOnFirstRun() {
        let suiteName = "com.sessionswitch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PresetStore(defaults: defaults)
        let presets = store.presets

        XCTAssertEqual(presets.count, 3)
        XCTAssertEqual(presets[0].name, "Deep Work")
        XCTAssertEqual(presets[0].modelID, "claude-fable-5")
        XCTAssertEqual(presets[0].effort, "high")

        XCTAssertEqual(presets[1].name, "Balanced")
        XCTAssertEqual(presets[1].modelID, "claude-sonnet-5")
        XCTAssertEqual(presets[1].effort, "medium")

        XCTAssertEqual(presets[2].name, "Cheap & Fast")
        XCTAssertEqual(presets[2].modelID, "claude-haiku-4-5")
        XCTAssertNil(presets[2].effort)
    }

    func testPresetStoreRoundTripsThroughIsolatedUserDefaults() {
        let suiteName = "com.sessionswitch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PresetStore(defaults: defaults)
        var presets = store.presets
        presets[0].name = "Renamed Preset"
        store.save(presets)

        // A fresh store instance backed by the same suite must observe the save.
        let reloaded = PresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.presets.first?.name, "Renamed Preset")
    }

    func testPresetStoreResetRestoresSeedDefaults() {
        let suiteName = "com.sessionswitch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PresetStore(defaults: defaults)
        var presets = store.presets
        presets.removeAll()
        store.save(presets)
        XCTAssertTrue(store.presets.isEmpty)

        store.reset()
        XCTAssertEqual(store.presets.count, 3)
        XCTAssertEqual(store.presets[0].name, "Deep Work")
    }

    // MARK: - SessionInfo

    func testProjectNameDerivationHelperTakesLastPathComponent() {
        XCTAssertEqual(
            SessionInfo.projectName(fromPath: "/Volumes/ExtremePro/My Projects/SessionSwitch"),
            "SessionSwitch"
        )
        XCTAssertEqual(SessionInfo.projectName(fromPath: "/tmp/foo"), "foo")
        XCTAssertEqual(SessionInfo.projectName(fromPath: "/"), "/")
    }

    func testSessionInfoStoresDerivedProjectName() {
        let path = "/Volumes/ExtremePro/My Projects/SessionSwitch"
        let info = SessionInfo(
            id: 4242,
            projectPath: path,
            projectName: SessionInfo.projectName(fromPath: path),
            tty: "ttys003",
            terminalApp: "Terminal",
            model: "claude-sonnet-5",
            state: .working,
            readOnly: false,
            readOnlyReason: nil,
            pending: nil
        )

        XCTAssertEqual(info.projectName, "SessionSwitch")
        XCTAssertEqual(info.id, 4242)
    }

    func testSessionInfoEquatable() {
        let a = SessionInfo(
            id: 1, projectPath: "/tmp/foo", projectName: "foo", tty: nil,
            terminalApp: "Terminal (unknown)", model: nil, state: .idle,
            readOnly: true, readOnlyReason: "no controlling terminal", pending: nil
        )
        let b = a
        XCTAssertEqual(a, b)
    }
}
