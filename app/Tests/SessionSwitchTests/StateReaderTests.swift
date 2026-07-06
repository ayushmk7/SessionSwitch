import XCTest

@testable import SessionSwitch

final class StateReaderTests: XCTestCase {

    // MARK: - Fixture helpers

    private var tempRoots: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for root in tempRoots {
            try? fm.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// Fresh scratch "projectsRoot" directory (stands in for `~/.claude/projects`).
    private func makeProjectsRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateReaderTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    /// Creates `<root>/<munged(cwd)>/` and writes `contents` to `<name>` inside
    /// it, then stamps the file's mtime, returning the file's URL.
    @discardableResult
    private func writeSessionFile(
        root: URL,
        cwd: String,
        name: String,
        contents: Data,
        mtime: Date
    ) -> URL {
        let dir = root.appendingPathComponent(StateReaderV1.mungedDir(for: cwd))
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try! contents.write(to: file)
        try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        return file
    }

    // MARK: - mungedDir

    func testMungedDirReplacesSlashesSpacesAndDotsWithHyphens() {
        XCTAssertEqual(
            StateReaderV1.mungedDir(for: "/Volumes/ExtremePro/My Projects/SessionSwitch"),
            "-Volumes-ExtremePro-My-Projects-SessionSwitch"
        )
    }

    func testMungedDirHandlesDotsInNestedPaths() {
        XCTAssertEqual(
            StateReaderV1.mungedDir(for: "/Users/dev/repo.v2/sub.dir"),
            "-Users-dev-repo-v2-sub-dir"
        )
    }

    func testMungedDirHandlesRootPath() {
        XCTAssertEqual(StateReaderV1.mungedDir(for: "/"), "-")
    }

    // MARK: - snapshot: model extraction (last occurrence wins)

    func testSnapshotReturnsLastOfThreeModelMentions() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-a"
        let jsonl = """
        {"type":"assistant","message":{"model":"claude-haiku-4-5"}}
        {"type":"assistant","message":{"model":"claude-sonnet-5"}}
        {"type":"assistant","message":{"model":"claude-opus-4-8"}}
        """
        writeSessionFile(
            root: root, cwd: cwd, name: "session.jsonl",
            contents: Data(jsonl.utf8), mtime: Date()
        )

        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root)
        XCTAssertEqual(snapshot.model, "claude-opus-4-8")
    }

    func testSnapshotPicksNewestJSONLFileByMTime() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-b"
        let older = Date().addingTimeInterval(-120)
        let newer = Date().addingTimeInterval(-1)

        writeSessionFile(
            root: root, cwd: cwd, name: "old-session.jsonl",
            contents: Data(#"{"model":"claude-haiku-4-5"}"#.utf8), mtime: older
        )
        writeSessionFile(
            root: root, cwd: cwd, name: "new-session.jsonl",
            contents: Data(#"{"model":"claude-sonnet-5"}"#.utf8), mtime: newer
        )

        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root, now: newer)
        XCTAssertEqual(snapshot.model, "claude-sonnet-5")
        // Compare by suffix rather than exact path: `contentsOfDirectory`
        // returns symlink-resolved URLs (e.g. /private/var/... vs. the
        // /var/... the temp directory was created under), which is a
        // filesystem quirk unrelated to what's under test here.
        XCTAssertEqual(
            (snapshot.sessionFile as NSString?)?.lastPathComponent,
            "new-session.jsonl"
        )
        XCTAssertTrue(snapshot.sessionFile?.contains(StateReaderV1.mungedDir(for: cwd)) == true)
    }

    // MARK: - snapshot: 256 KB tail bound (FR-37)

    func testSnapshotDoesNotFindModelMentionOutsideTailWindow() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-c"

        // An early model mention, followed by > 256 KB of filler so that it
        // falls outside the bounded tail-read window.
        var contents = Data(#"{"type":"assistant","message":{"model":"claude-early-only"}}\n"#.utf8)
        let filler = Data(repeating: UInt8(ascii: "x"), count: 300 * 1024)
        contents.append(filler)

        writeSessionFile(root: root, cwd: cwd, name: "session.jsonl", contents: contents, mtime: Date())

        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root)
        XCTAssertNil(snapshot.model, "model mention before the 256 KB tail window must not be found")
    }

    func testSnapshotFindsModelMentionInsideTailWindow() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-d"

        // Filler first, then a model mention near the end -- well within the
        // last 256 KB -- must still be found.
        var contents = Data(repeating: UInt8(ascii: "x"), count: 300 * 1024)
        contents.append(Data(#"{"type":"assistant","message":{"model":"claude-late-model"}}"#.utf8))

        writeSessionFile(root: root, cwd: cwd, name: "session.jsonl", contents: contents, mtime: Date())

        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root)
        XCTAssertEqual(snapshot.model, "claude-late-model")
    }

    // MARK: - snapshot: mtime freshness -> working/idle

    func testSnapshotIsWorkingWhenMTimeWithinTenSeconds() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-e"
        let mtime = Date(timeIntervalSince1970: 1_800_000_000)
        writeSessionFile(
            root: root, cwd: cwd, name: "session.jsonl",
            contents: Data(#"{"model":"claude-sonnet-5"}"#.utf8), mtime: mtime
        )

        let now = mtime.addingTimeInterval(5)
        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root, now: now)
        XCTAssertEqual(snapshot.state, .working)
    }

    func testSnapshotIsIdleWhenMTimeOlderThanTenSeconds() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-f"
        let mtime = Date(timeIntervalSince1970: 1_800_000_000)
        writeSessionFile(
            root: root, cwd: cwd, name: "session.jsonl",
            contents: Data(#"{"model":"claude-sonnet-5"}"#.utf8), mtime: mtime
        )

        let now = mtime.addingTimeInterval(60)
        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root, now: now)
        XCTAssertEqual(snapshot.state, .idle)
    }

    // MARK: - snapshot: absent dir -> empty snapshot

    func testSnapshotAbsentDirectoryReturnsEmptySnapshot() {
        let root = makeProjectsRoot()
        let snapshot = StateReaderV1.snapshot(cwd: "/tmp/does-not-exist-anywhere", projectsRoot: root)
        XCTAssertEqual(snapshot, SessionSnapshot(model: nil, state: .idle, sessionFile: nil))
    }

    func testSnapshotDirectoryWithNoJSONLFilesReturnsEmptySnapshot() {
        let root = makeProjectsRoot()
        let cwd = "/tmp/project-g"
        let dir = root.appendingPathComponent(StateReaderV1.mungedDir(for: cwd))
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data("not jsonl".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: root)
        XCTAssertEqual(snapshot, SessionSnapshot(model: nil, state: .idle, sessionFile: nil))
    }

    // MARK: - Live sanity (Step 5)

    func testLiveSnapshotAgainstRealStateDir() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsRoot = home.appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            throw XCTSkip("~/.claude/projects does not exist on this machine")
        }

        let cwd = FileManager.default.currentDirectoryPath
        let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: projectsRoot)
        // Just must not crash; state is always one of the two valid cases.
        XCTAssertTrue(snapshot.state == .working || snapshot.state == .idle)
    }
}
