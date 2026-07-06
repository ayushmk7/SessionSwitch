import XCTest

@testable import SessionSwitch

/// Canned-response stand-in for `CommandRunning`, keyed by the shape of the
/// arguments so a single fake can serve `ps` (scan), `lsof` (cwd), and the
/// per-pid ancestry `ps -o ppid=,comm=` calls used by `terminalApp`.
final class FakeRunner: CommandRunning {
    var psScanOutput: String = ""
    var lsofOutputsByPID: [Int32: String] = [:]
    var ancestryOutputsByPID: [Int32: String] = [:]

    func run(_ launchPath: String, _ args: [String]) -> String {
        if args.contains("-axo") {
            return psScanOutput
        }
        if args.contains("cwd") {
            guard let pidIndex = args.firstIndex(of: "-p"),
                  args.indices.contains(pidIndex + 1),
                  let pid = Int32(args[pidIndex + 1])
            else { return "" }
            return lsofOutputsByPID[pid] ?? ""
        }
        if args.contains("ppid=,comm=") {
            guard let pidIndex = args.firstIndex(of: "-p"),
                  args.indices.contains(pidIndex + 1),
                  let pid = Int32(args[pidIndex + 1])
            else { return "" }
            return ancestryOutputsByPID[pid] ?? ""
        }
        return ""
    }
}

final class DiscoveryTests: XCTestCase {

    // MARK: - Discovery.scan

    func testScanKeepsRealTTYClaudeProcessAndParsesFields() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        111 ttys003  /usr/local/bin/claude --model sonnet
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertEqual(result, [
            RawClaudeProcess(pid: 111, tty: "ttys003", command: "/usr/local/bin/claude --model sonnet")
        ])
    }

    func testScanExcludesStreamJSONPipedRowEvenWithMatchingBasename() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        222 ??       /Users/x/.vscode/extensions/anthropic.claude-code-2.1.197-darwin-arm64/resources/native-binary/claude --output-format stream-json --input-format stream-json --verbose
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertTrue(result.isEmpty)
    }

    func testScanKeepsFullVSCodeExtensionPathWhenTTYPresentAndNotPiped() {
        // Same executable path as the excluded row above, but this one has a
        // real controlling tty and no --input-format stream-json flag, so it
        // must be kept: the basename-matches-"claude" rule is the same, only
        // the piping/tty distinguishes them.
        let runner = FakeRunner()
        runner.psScanOutput = """
        333 ttys005  /Users/x/.vscode/extensions/anthropic.claude-code-2.1.197-darwin-arm64/resources/native-binary/claude --model sonnet
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 333)
        XCTAssertEqual(result.first?.tty, "ttys005")
    }

    func testScanExcludesNonClaudeBasename() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        444 ttys007  /usr/bin/node /some/other/tool.js
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertTrue(result.isEmpty)
    }

    func testScanNormalizesQuestionMarkAndDashTTYToNil() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        555 -        /usr/local/bin/claude --version
        666 ??       /usr/local/bin/claude --version
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result[0].tty)
        XCTAssertNil(result[1].tty)
    }

    func testScanParsesMixedRowsTogether() {
        let runner = FakeRunner()
        runner.psScanOutput = """
        111 ttys003  /usr/local/bin/claude --model sonnet
        222 ??       /Users/x/.vscode/extensions/anthropic.claude-code-2.1.197-darwin-arm64/resources/native-binary/claude --output-format stream-json --input-format stream-json --verbose
        333 ttys005  /Users/x/.vscode/extensions/anthropic.claude-code-2.1.197-darwin-arm64/resources/native-binary/claude --model sonnet
        444 ttys007  /usr/bin/node /some/other/tool.js
        555 -        /usr/local/bin/claude --version
        """
        let result = Discovery.scan(runner: runner)
        XCTAssertEqual(result.map(\.pid), [111, 333, 555])
    }

    // MARK: - Discovery.cwd

    func testCwdExtractsPathFromLsofNLine() {
        let runner = FakeRunner()
        runner.lsofOutputsByPID[111] = "p111\nfcwd\nn/Volumes/ExtremePro/My Projects/SessionSwitch\n"
        XCTAssertEqual(
            Discovery.cwd(pid: 111, runner: runner),
            "/Volumes/ExtremePro/My Projects/SessionSwitch"
        )
    }

    func testCwdReturnsNilWhenNoNLinePresent() {
        let runner = FakeRunner()
        runner.lsofOutputsByPID[222] = "p222\nfcwd\n"
        XCTAssertNil(Discovery.cwd(pid: 222, runner: runner))
    }

    // MARK: - Discovery.terminalApp

    func testTerminalAppWalksAncestryAndMatchesITerm2AtHopThree() {
        let runner = FakeRunner()
        // hop 1: pid 100 itself (the claude process) -> ppid 50, comm "claude" (no match)
        runner.ancestryOutputsByPID[100] = "50 claude"
        // hop 2: shell -> ppid 20, comm "zsh" (no match)
        runner.ancestryOutputsByPID[50] = "20 zsh"
        // hop 3: iTerm2 -> match
        runner.ancestryOutputsByPID[20] = "5 iTerm2"

        XCTAssertEqual(Discovery.terminalApp(pid: 100, runner: runner), "iTerm2")
    }

    func testTerminalAppMatchesVSCodeCodeHelper() {
        let runner = FakeRunner()
        runner.ancestryOutputsByPID[100] = "50 claude"
        runner.ancestryOutputsByPID[50] = "20 Code Helper (Renderer)"

        XCTAssertEqual(Discovery.terminalApp(pid: 100, runner: runner), "Code")
    }

    func testTerminalAppTerminatesAtPidOneAsUnknown() {
        let runner = FakeRunner()
        runner.ancestryOutputsByPID[200] = "1 launchd"

        XCTAssertEqual(Discovery.terminalApp(pid: 200, runner: runner), "Terminal (unknown)")
    }

    func testTerminalAppStopsAfterTenHopsWhenUnresolved() {
        let runner = FakeRunner()
        // A chain of >10 hops that never matches a known terminal and never
        // reaches pid 1 must terminate as unknown rather than looping forever.
        var pid: Int32 = 1000
        for _ in 0..<15 {
            let parent = pid - 1
            runner.ancestryOutputsByPID[pid] = "\(parent) mystery-process"
            pid = parent
        }

        XCTAssertEqual(Discovery.terminalApp(pid: 1000, runner: runner), "Terminal (unknown)")
    }

    func testTerminalAppMissingAncestryDataReturnsUnknown() {
        let runner = FakeRunner()
        XCTAssertEqual(Discovery.terminalApp(pid: 999, runner: runner), "Terminal (unknown)")
    }

    // MARK: - Live sanity (Step 5)

    func testLiveScanDoesNotCrash() {
        let sessions = Discovery.scan(runner: ShellRunner())
        XCTAssertGreaterThanOrEqual(sessions.count, 0)
    }
}
