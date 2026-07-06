import XCTest

@testable import SessionSwitch

/// `CommandRunning` wrapper that sleeps before delegating, standing in for a
/// slow/blocking `ps`/`lsof` shell-out so refresh-loop threading and
/// reentrancy behavior can be exercised deterministically.
private final class SlowFakeRunner: CommandRunning {
    private let inner: CommandRunning
    private let delay: TimeInterval

    init(inner: CommandRunning, delay: TimeInterval) {
        self.inner = inner
        self.delay = delay
    }

    func run(_ launchPath: String, _ args: [String]) -> String {
        Thread.sleep(forTimeInterval: delay)
        return inner.run(launchPath, args)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {

    // MARK: - Fixture helpers (mirrors StateReaderTests' pattern)

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
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    /// Configures `runner`'s ancestry chain so `Discovery.terminalApp(pid:)`
    /// resolves to `appComm` two hops up: `pid`'s own comm is "claude" (no
    /// match), its parent's comm is `appComm` (the match).
    private func configureAncestry(_ runner: FakeRunner, pid: Int32, appComm: String) {
        let shellPid = pid + 10_000
        let appPid = pid + 20_000
        runner.ancestryOutputsByPID[pid] = "\(shellPid) claude"
        runner.ancestryOutputsByPID[shellPid] = "\(appPid) \(appComm)"
    }

    // MARK: - Mapping + readOnly reasons

    func testMapsRawProcessesToSessionInfoWithReadOnlyReasonsAndInjectableFlags() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        100 ??       /usr/local/bin/claude --model sonnet
        200 ttys002  /usr/local/bin/claude --model sonnet
        300 ttys003  /usr/local/bin/claude --model sonnet
        400 ttys004  /usr/local/bin/claude --model sonnet
        """
        runner.lsofOutputsByPID = [
            100: "p100\nfcwd\nn/tmp/delta-project\n",
            200: "p200\nfcwd\nn/tmp/beta-project\n",
            300: "p300\nfcwd\nn/tmp/gamma-project\n",
            400: "p400\nfcwd\nn/tmp/alpha-project\n",
        ]
        // pid 100 (no tty): ancestry irrelevant, leave unset -> "Terminal (unknown)".
        configureAncestry(runner, pid: 200, appComm: "Code Helper (Renderer)")
        configureAncestry(runner, pid: 300, appComm: "Terminal")
        configureAncestry(runner, pid: 400, appComm: "iTerm2")

        let store = SessionStore(runner: runner, projectsRoot: makeProjectsRoot(), refreshInterval: 999)
        let refreshed = expectation(description: "refresh completes")
        store.onChange = { refreshed.fulfill() }
        store.refreshNow()
        wait(for: [refreshed], timeout: 2.0)

        XCTAssertEqual(store.sessions.map(\.id), [400, 200, 100, 300])
        XCTAssertEqual(store.sessions.map(\.projectName), ["alpha-project", "beta-project", "delta-project", "gamma-project"])

        let noTTY = store.sessions.first { $0.id == 100 }
        XCTAssertEqual(noTTY?.tty, nil)
        XCTAssertEqual(noTTY?.readOnly, true)
        XCTAssertEqual(noTTY?.readOnlyReason, "no controlling terminal")

        let vsCode = store.sessions.first { $0.id == 200 }
        XCTAssertEqual(vsCode?.terminalApp, "Code")
        XCTAssertEqual(vsCode?.readOnly, true)
        XCTAssertEqual(vsCode?.readOnlyReason, "Code not scriptable in v1")

        let terminal = store.sessions.first { $0.id == 300 }
        XCTAssertEqual(terminal?.terminalApp, "Terminal")
        XCTAssertEqual(terminal?.readOnly, false)
        XCTAssertNil(terminal?.readOnlyReason)

        let iterm = store.sessions.first { $0.id == 400 }
        XCTAssertEqual(iterm?.terminalApp, "iTerm2")
        XCTAssertEqual(iterm?.readOnly, false)
        XCTAssertNil(iterm?.readOnlyReason)
    }

    func testSessionsAreSortedByProjectNameRegardlessOfScanOrder() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        10 ttys010  /usr/local/bin/claude
        20 ttys020  /usr/local/bin/claude
        30 ttys030  /usr/local/bin/claude
        """
        runner.lsofOutputsByPID = [
            10: "n/tmp/zulu\n",
            20: "n/tmp/mike\n",
            30: "n/tmp/alpha\n",
        ]
        configureAncestry(runner, pid: 10, appComm: "Terminal")
        configureAncestry(runner, pid: 20, appComm: "Terminal")
        configureAncestry(runner, pid: 30, appComm: "Terminal")

        let store = SessionStore(runner: runner, projectsRoot: makeProjectsRoot(), refreshInterval: 999)
        let refreshed = expectation(description: "refresh completes")
        store.onChange = { refreshed.fulfill() }
        store.refreshNow()
        wait(for: [refreshed], timeout: 2.0)

        XCTAssertEqual(store.sessions.map(\.projectName), ["alpha", "mike", "zulu"])
    }

    // MARK: - Pending preserved across refreshes

    func testPendingLabelIsPreservedAcrossRefreshesForSamePID() {
        let runner = FakeRunner()
        runner.psScanOutput = "999 ttys009  /usr/local/bin/claude"
        runner.lsofOutputsByPID = [999: "n/tmp/proj-pending\n"]
        configureAncestry(runner, pid: 999, appComm: "Terminal")

        let store = SessionStore(runner: runner, projectsRoot: makeProjectsRoot(), refreshInterval: 999)

        let first = expectation(description: "first refresh")
        store.onChange = { first.fulfill() }
        store.refreshNow()
        wait(for: [first], timeout: 2.0)
        XCTAssertNil(store.sessions.first?.pending)

        // `setPending` republishes immediately (so the menu can show a
        // pending badge without waiting for the next tick) -- clear the
        // first expectation's callback so that immediate republish doesn't
        // double-fulfill it.
        store.onChange = nil
        store.setPending("/model sonnet", forPID: 999)
        XCTAssertEqual(store.sessions.first?.pending, "/model sonnet")

        let second = expectation(description: "second refresh")
        store.onChange = { second.fulfill() }
        store.refreshNow()
        wait(for: [second], timeout: 2.0)

        XCTAssertEqual(store.sessions.first?.pending, "/model sonnet", "pending label must survive a refresh for the same pid")
    }

    // MARK: - Threading + reentrancy (CRITICAL directive)

    func testRefreshNowIsReentrancyGuardedAndPublishesOnMainThread() {
        let slow = SlowFakeRunner(inner: FakeRunner(), delay: 0.3)
        let store = SessionStore(runner: slow, projectsRoot: makeProjectsRoot(), refreshInterval: 999)

        let firedOnce = expectation(description: "onChange fires exactly once for two overlapping refreshNow() calls")
        firedOnce.assertForOverFulfill = true
        var sawMainThread = false
        store.onChange = {
            sawMainThread = Thread.isMainThread
            firedOnce.fulfill()
        }

        store.refreshNow()
        store.refreshNow() // must be skipped: previous refresh still in flight

        wait(for: [firedOnce], timeout: 2.0)
        XCTAssertTrue(sawMainThread, "onChange must be invoked back on the main thread/MainActor")
    }

    func testRefreshNowAllowsANewRefreshAfterThePreviousOneCompletes() {
        let runner = FakeRunner()
        let store = SessionStore(runner: runner, projectsRoot: makeProjectsRoot(), refreshInterval: 999)

        let first = expectation(description: "first refresh")
        store.onChange = { first.fulfill() }
        store.refreshNow()
        wait(for: [first], timeout: 2.0)

        let second = expectation(description: "second refresh")
        store.onChange = { second.fulfill() }
        store.refreshNow()
        wait(for: [second], timeout: 2.0)
    }

    // MARK: - start()/stop()

    func testStartPerformsImmediateRefreshThenTicksOnInterval() {
        let runner = FakeRunner()
        let store = SessionStore(runner: runner, projectsRoot: makeProjectsRoot(), refreshInterval: 0.05)

        var count = 0
        let atLeastTwo = expectation(description: "at least two refreshes observed")
        store.onChange = {
            count += 1
            if count == 2 { atLeastTwo.fulfill() }
        }
        store.start()
        wait(for: [atLeastTwo], timeout: 2.0)
        store.stop()

        XCTAssertGreaterThanOrEqual(count, 2)
    }
}
