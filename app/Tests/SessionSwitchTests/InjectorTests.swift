import XCTest

@testable import SessionSwitch

/// Thread-safe recorder for the injected `execute` closure: `execute` runs on
/// a background queue in production (osascript can block for seconds behind
/// an Automation prompt), so the fake must tolerate off-main recording.
private final class ExecuteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var scriptsStorage: [String] = []
    private var mainThreadFlags: [Bool] = []

    func record(_ script: String) {
        lock.lock()
        scriptsStorage.append(script)
        mainThreadFlags.append(Thread.isMainThread)
        lock.unlock()
    }

    var scripts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return scriptsStorage
    }

    var ranOnMainThread: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadFlags
    }
}

@MainActor
final class InjectorTests: XCTestCase {

    // MARK: - Fixture helpers (mirrors StateReaderTests'/SessionStoreTests' pattern)

    private var tempRoots: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for root in tempRoots {
            try? fm.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    private func makeProjectsRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectorTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    @discardableResult
    private func writeSessionFile(root: URL, cwd: String, model: String?, mtime: Date) -> URL {
        let dir = root.appendingPathComponent(StateReaderV1.mungedDir(for: cwd))
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        let modelField = model.map { #"{"type":"assistant","message":{"model":"\#($0)"}}"# } ?? "{}"
        try! Data(modelField.utf8).write(to: file)
        try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        return file
    }

    /// Configures `runner`'s ancestry chain so `Discovery.terminalApp(pid:)`
    /// resolves to `appComm` two hops up (same trick as SessionStoreTests).
    private func configureAncestry(_ runner: FakeRunner, pid: Int32, appComm: String) {
        let shellPid = pid + 10_000
        let appPid = pid + 20_000
        runner.ancestryOutputsByPID[pid] = "\(shellPid) claude"
        runner.ancestryOutputsByPID[shellPid] = "\(appPid) \(appComm)"
    }

    /// Builds a `SessionStore` with one claude process (pid/tty/cwd/app given)
    /// and refreshes it once synchronously, returning the store plus the
    /// FakeRunner (so its scripted psScanOutput can be mutated later to
    /// simulate a working->idle transition) and the projects root (so its
    /// jsonl fixture can be mutated to simulate a model change).
    private func makeStoreWithOneSession(
        pid: Int32,
        tty: String?,
        appComm: String,
        cwd: String,
        model: String?,
        mtime: Date
    ) -> (store: SessionStore, runner: FakeRunner, root: URL) {
        let runner = FakeRunner()
        let ttyToken = tty ?? "??"
        runner.psScanOutput = "\(pid) \(ttyToken)  /usr/local/bin/claude"
        runner.lsofOutputsByPID = [pid: "n\(cwd)\n"]
        configureAncestry(runner, pid: pid, appComm: appComm)

        let root = makeProjectsRoot()
        writeSessionFile(root: root, cwd: cwd, model: model, mtime: mtime)

        let store = SessionStore(runner: runner, projectsRoot: root, refreshInterval: 999)
        let refreshed = expectation(description: "initial refresh")
        store.onChange = { refreshed.fulfill() }
        store.refreshNow()
        wait(for: [refreshed], timeout: 2.0)

        return (store, runner, root)
    }

    /// Spins the main run loop until `condition` becomes true (polled every
    /// 20 ms) or `timeout` elapses, then asserts it. Needed because `execute`
    /// runs asynchronously off the main thread.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) {
        let exp = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline {
                exp.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
        wait(for: [exp], timeout: timeout + 1.0)
        XCTAssertTrue(condition(), description)
    }

    private let sonnet = ModelCatalog.model(idOrAlias: "sonnet")!

    // MARK: - ScriptBuilder: Terminal.app / iTerm2 exact strings + escaping

    func testScriptBuilderBuildsExactTerminalAppScript() {
        // NB: real Terminal.app's AppleScript `tty of t` returns the FULL
        // device path (verified live: `osascript -e 'tell application
        // "Terminal" to tty of front window'` -> /dev/ttys000), so the
        // comparison must be against "/dev/<tty>" just like iTerm2's.
        let script = ScriptBuilder.script(for: .terminalApp(tty: "ttys003"), command: "/model sonnet")
        XCTAssertEqual(script, """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/ttys003" then do script "/model sonnet" in t
                end repeat
            end repeat
        end tell
        """)
    }

    func testScriptBuilderBuildsExactITerm2Script() {
        let script = ScriptBuilder.script(for: .iTerm2(tty: "ttys004"), command: "/effort high")
        XCTAssertEqual(script, """
        tell application "iTerm2"
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with s in sessions of tb
                        if tty of s is "/dev/ttys004" then tell s to write text "/effort high"
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    func testScriptBuilderEscapesBackslashesAndDoubleQuotesInCommand() {
        let command = #"say "hello" \ world"#
        let script = ScriptBuilder.script(for: .terminalApp(tty: "ttys005"), command: command)
        XCTAssertEqual(script, """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/ttys005" then do script "say \\"hello\\" \\\\ world" in t
                end repeat
            end repeat
        end tell
        """)
    }

    // MARK: - slashCommand builders

    func testSlashCommandForModel() {
        XCTAssertEqual(ScriptBuilder.slashCommand(model: sonnet), "/model sonnet")
        let haiku = ModelCatalog.model(idOrAlias: "haiku")!
        XCTAssertEqual(ScriptBuilder.slashCommand(model: haiku), "/model haiku")
    }

    func testSlashCommandForEffort() {
        XCTAssertEqual(ScriptBuilder.slashCommand(effort: "high"), "/effort high")
        XCTAssertEqual(ScriptBuilder.slashCommand(effort: "low"), "/effort low")
    }

    // MARK: - readOnly -> rejected

    func testRequestModelOnReadOnlySessionIsRejectedWithoutExecutingOrQueuing() {
        let (store, _, _) = makeStoreWithOneSession(
            pid: 111, tty: nil, appComm: "Terminal", cwd: "/tmp/inj-readonly", model: nil, mtime: Date()
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil })
        var results: [(Int32, Injector.InjectionResult)] = []
        injector.onResult = { pid, result in results.append((pid, result)) }

        let session = store.sessions.first { $0.id == 111 }!
        XCTAssertTrue(session.readOnly)

        injector.requestModel(sonnet, for: session)

        XCTAssertTrue(recorder.scripts.isEmpty)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.0, 111)
        XCTAssertEqual(results.first?.1, .rejected("no controlling terminal"))
        XCTAssertNil(store.sessions.first { $0.id == 111 }?.pending)
    }

    // MARK: - Off-main execute (osascript can block up to 5 s: Automation prompt)

    func testExecuteRunsOffTheMainThread() {
        let oldMtime = Date().addingTimeInterval(-60)
        let (store, _, _) = makeStoreWithOneSession(
            pid: 888, tty: "ttys888", appComm: "Terminal", cwd: "/tmp/inj-offmain",
            model: "claude-haiku-4-5", mtime: oldMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil }, pollInterval: 0.02, pollTimeout: 0.1)
        injector.onResult = { _, _ in }

        let session = store.sessions.first { $0.id == 888 }!
        injector.requestModel(sonnet, for: session)

        waitUntil("script executed") { recorder.scripts.count == 1 }
        XCTAssertEqual(
            recorder.ranOnMainThread, [false],
            "execute must run off the main thread (a first-run Automation prompt can block osascript for seconds)"
        )
    }

    // MARK: - Queue: working -> enqueue + pending, drains on idle

    func testRequestModelOnWorkingSessionEnqueuesAndSetsPendingThenDrainsWhenIdle() {
        let recentMtime = Date() // within the 10s working threshold
        let (store, runner, root) = makeStoreWithOneSession(
            pid: 222, tty: "ttys222", appComm: "Terminal", cwd: "/tmp/inj-working",
            model: "claude-haiku-4-5", mtime: recentMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil }, pollInterval: 0.02, pollTimeout: 0.2)
        injector.onResult = { _, _ in }

        let workingSession = store.sessions.first { $0.id == 222 }!
        XCTAssertEqual(workingSession.state, .working)

        injector.requestModel(sonnet, for: workingSession)

        // Working: must not inject yet, but must be queued + reflected as pending.
        XCTAssertTrue(recorder.scripts.isEmpty)
        XCTAssertEqual(store.sessions.first { $0.id == 222 }?.pending, "/model sonnet")

        // Flip the session to idle (old mtime) and trigger a refresh -- the
        // queued request must drain automatically.
        let oldMtime = Date().addingTimeInterval(-60)
        writeSessionFile(root: root, cwd: "/tmp/inj-working", model: "claude-haiku-4-5", mtime: oldMtime)
        runner.psScanOutput = "222 ttys222  /usr/local/bin/claude"

        // NOTE: deliberately do NOT reassign `store.onChange` here -- Injector
        // owns that single slot (assigned in its init) to react to this exact
        // refresh. Just trigger the refresh and wait for the drain.
        store.refreshNow()

        waitUntil("queued request drained") { recorder.scripts.count == 1 }
        XCTAssertEqual(recorder.scripts, [ScriptBuilder.script(for: .terminalApp(tty: "ttys222"), command: "/model sonnet")])
    }

    // MARK: - Per-pid FIFO: a second request must not drop the first

    func testApplyPresetOnWorkingSessionQueuesBothAndDrainsInOrderWithTwoResults() {
        let recentMtime = Date() // working
        let (store, _, root) = makeStoreWithOneSession(
            pid: 777, tty: "ttys777", appComm: "Terminal", cwd: "/tmp/inj-preset-queue",
            model: "claude-haiku-4-5", mtime: recentMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil }, pollInterval: 0.02, pollTimeout: 0.15, presetGap: 0.05)
        var results: [(Int32, Injector.InjectionResult)] = []
        injector.onResult = { pid, result in results.append((pid, result)) }

        let session = store.sessions.first { $0.id == 777 }!
        XCTAssertEqual(session.state, .working)
        let preset = Preset(id: "p", name: "P", modelID: "claude-sonnet-5", effort: "high")

        injector.applyPreset(preset, for: session)

        // Wait past presetGap so BOTH requests have been enqueued against the
        // still-working session -- the effort request must append behind the
        // model request, not overwrite it.
        let gapPassed = expectation(description: "preset gap passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { gapPassed.fulfill() }
        wait(for: [gapPassed], timeout: 1.0)
        XCTAssertTrue(recorder.scripts.isEmpty, "nothing may inject while the session is working")

        // Flip idle and refresh: both queued requests must drain strictly in
        // order (effort only after the model request delivered its result).
        let oldMtime = Date().addingTimeInterval(-60)
        writeSessionFile(root: root, cwd: "/tmp/inj-preset-queue", model: "claude-haiku-4-5", mtime: oldMtime)
        store.refreshNow()

        waitUntil("both requests drained with two results", timeout: 3.0) {
            recorder.scripts.count == 2 && results.count == 2
        }

        XCTAssertEqual(recorder.scripts, [
            ScriptBuilder.script(for: .terminalApp(tty: "ttys777"), command: "/model sonnet"),
            ScriptBuilder.script(for: .terminalApp(tty: "ttys777"), command: "/effort high"),
        ])
        XCTAssertEqual(results.map(\.0), [777, 777])
        XCTAssertEqual(results.first?.1, .unverified("state file unchanged"), "model never changes in this fixture")
        XCTAssertEqual(results.last?.1, .assumed("effort applied (unverifiable)"))
        XCTAssertNil(store.sessions.first { $0.id == 777 }?.pending)
    }

    // MARK: - Verify: model change observed -> .verified

    func testRequestModelOnIdleSessionInjectsThenVerifiesOnModelChange() {
        let oldMtime = Date().addingTimeInterval(-60)
        let (store, _, root) = makeStoreWithOneSession(
            pid: 333, tty: "ttys333", appComm: "Terminal", cwd: "/tmp/inj-verify",
            model: "claude-haiku-4-5", mtime: oldMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil }, pollInterval: 0.02, pollTimeout: 1.0)
        var results: [(Int32, Injector.InjectionResult)] = []
        let verifiedExpectation = expectation(description: "verified")
        injector.onResult = { pid, result in
            results.append((pid, result))
            if case .verified = result { verifiedExpectation.fulfill() }
        }

        let session = store.sessions.first { $0.id == 333 }!
        XCTAssertEqual(session.state, .idle)

        injector.requestModel(sonnet, for: session)

        // Pending reflects the request synchronously; the script lands
        // asynchronously (execute runs off-main).
        XCTAssertEqual(store.sessions.first { $0.id == 333 }?.pending, "/model sonnet")
        waitUntil("script executed") { recorder.scripts.count == 1 }
        XCTAssertEqual(recorder.scripts, [ScriptBuilder.script(for: .terminalApp(tty: "ttys333"), command: "/model sonnet")])

        // Simulate the CLI having actually switched models.
        writeSessionFile(root: root, cwd: "/tmp/inj-verify", model: "claude-sonnet-5", mtime: oldMtime)

        wait(for: [verifiedExpectation], timeout: 3.0)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.1, .verified("model changed"))
        XCTAssertNil(store.sessions.first { $0.id == 333 }?.pending, "pending must clear once verified")
    }

    // MARK: - Verify: timeout -> .unverified

    func testRequestModelVerificationTimesOutWhenModelNeverChanges() {
        let oldMtime = Date().addingTimeInterval(-60)
        let (store, _, _) = makeStoreWithOneSession(
            pid: 444, tty: "ttys444", appComm: "Terminal", cwd: "/tmp/inj-timeout",
            model: "claude-haiku-4-5", mtime: oldMtime
        )
        let injector = Injector(store: store, execute: { _ in nil }, pollInterval: 0.02, pollTimeout: 0.1)
        var results: [(Int32, Injector.InjectionResult)] = []
        let unverifiedExpectation = expectation(description: "unverified")
        injector.onResult = { pid, result in
            results.append((pid, result))
            if case .unverified = result { unverifiedExpectation.fulfill() }
        }

        let session = store.sessions.first { $0.id == 444 }!
        injector.requestModel(sonnet, for: session)

        wait(for: [unverifiedExpectation], timeout: 3.0)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.1, .unverified("state file unchanged"))
        XCTAssertNil(store.sessions.first { $0.id == 444 }?.pending)
    }

    // MARK: - Effort -> .assumed (no state source)

    func testRequestEffortResolvesAssumedAfterInjecting() {
        let oldMtime = Date().addingTimeInterval(-60)
        let (store, _, _) = makeStoreWithOneSession(
            pid: 555, tty: "ttys555", appComm: "iTerm2", cwd: "/tmp/inj-effort",
            model: "claude-sonnet-5", mtime: oldMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil })
        var results: [(Int32, Injector.InjectionResult)] = []
        let assumedExpectation = expectation(description: "assumed")
        injector.onResult = { pid, result in
            results.append((pid, result))
            if case .assumed = result { assumedExpectation.fulfill() }
        }

        let session = store.sessions.first { $0.id == 555 }!
        injector.requestEffort("high", for: session)

        wait(for: [assumedExpectation], timeout: 3.0)

        XCTAssertEqual(recorder.scripts, [ScriptBuilder.script(for: .iTerm2(tty: "ttys555"), command: "/effort high")])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.1, .assumed("effort applied (unverifiable)"))
        XCTAssertNil(store.sessions.first { $0.id == 555 }?.pending)
    }

    // MARK: - applyPreset on idle session: model first, then effort, in order

    func testApplyPresetOnIdleSessionSendsModelFirstThenEffortInOrder() {
        let oldMtime = Date().addingTimeInterval(-60)
        let (store, _, _) = makeStoreWithOneSession(
            pid: 666, tty: "ttys666", appComm: "Terminal", cwd: "/tmp/inj-preset",
            model: "claude-haiku-4-5", mtime: oldMtime
        )
        let recorder = ExecuteRecorder()
        let injector = Injector(store: store, execute: { recorder.record($0); return nil }, pollInterval: 0.02, pollTimeout: 0.2, presetGap: 0.05)
        injector.onResult = { _, _ in }

        let session = store.sessions.first { $0.id == 666 }!
        let preset = Preset(id: "p", name: "P", modelID: "claude-sonnet-5", effort: "high")

        injector.applyPreset(preset, for: session)

        // The model script must land first, alone (the effort request waits
        // behind the model's verification in the per-pid FIFO).
        waitUntil("model script executed first") { recorder.scripts.count >= 1 }
        XCTAssertEqual(recorder.scripts.first, ScriptBuilder.script(for: .terminalApp(tty: "ttys666"), command: "/model sonnet"))

        waitUntil("effort script executed second", timeout: 3.0) { recorder.scripts.count == 2 }
        XCTAssertEqual(recorder.scripts, [
            ScriptBuilder.script(for: .terminalApp(tty: "ttys666"), command: "/model sonnet"),
            ScriptBuilder.script(for: .terminalApp(tty: "ttys666"), command: "/effort high"),
        ])
    }
}
