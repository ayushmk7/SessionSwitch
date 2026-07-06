import Darwin
import Foundation

/// Abstraction over "run a command, get its stdout back as a string" so
/// `Discovery` can be driven by canned fixtures in tests and by real
/// `ps`/`lsof` invocations at runtime.
protocol CommandRunning {
    func run(_ launchPath: String, _ args: [String]) -> String
}

/// Real `CommandRunning` implementation: spawns `Process`, drains its pipes
/// on background queues (to avoid the classic deadlock where the child fills
/// its stdout buffer while nobody is reading it), and enforces a 2 s ceiling
/// so a hung/misbehaving child can never block the caller indefinitely.
struct ShellRunner: CommandRunning {
    private static let timeout: TimeInterval = 2.0

    func run(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ""
        }

        // Drain stderr on its own queue so it can never fill up and block
        // the child even though we don't care about its contents.
        DispatchQueue.global(qos: .utility).async {
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Read stdout to EOF on a background queue.
        var outputData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // Wait for the process to exit, but only up to the timeout; if it's
        // still running past that, terminate it. Waiting happens on a
        // background queue so this can't deadlock against the stdout reader.
        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitGroup.leave()
        }

        if exitGroup.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            // SIGTERM isn't guaranteed to be honored by every child;
            // escalate to SIGKILL if it's still alive after a further ~2s
            // grace window, then move on regardless -- this may never
            // block forever waiting on an unresponsive/hung `ps`/`lsof`.
            if exitGroup.wait(timeout: .now() + 2.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        readGroup.wait()
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

/// A single row surviving `Discovery.scan`: an interactive-or-not `claude`
/// CLI process as reported by `ps`.
struct RawClaudeProcess: Equatable {
    let pid: Int32
    let tty: String?
    let command: String
}

/// Process/tty/cwd/terminal-app discovery for running Claude Code CLI
/// sessions, built entirely on `ps`/`lsof` shell-outs (no private APIs, no
/// dependencies).
enum Discovery {

    /// Ancestor process names known to house a terminal/editor session,
    /// matched case-insensitively as substrings of `ps`'s `comm` field.
    /// Order matters: more specific needles are checked before shorter ones
    /// they could otherwise be conflated with (e.g. "warpterminal" before
    /// the generic "terminal").
    private static let knownTerminalAncestors: [(needle: String, name: String)] = [
        ("warpterminal", "WarpTerminal"),
        ("iterm2", "iTerm2"),
        ("terminal", "Terminal"),
        ("code", "Code"),
        ("idea", "JetBrains"),
        ("ghostty", "ghostty"),
        ("wezterm", "wezterm"),
        ("alacritty", "alacritty"),
        ("kitty", "kitty"),
    ]

    /// Parses `ps -axo pid=,tty=,command=` and keeps only rows that look
    /// like an interactive Claude Code CLI process:
    /// - the first whitespace-separated token of `command`'s last path
    ///   component must be exactly "claude";
    /// - rows containing `--input-format stream-json` are excluded (an
    ///   IDE/extension talking to `claude` over a pipe, not a human at a
    ///   terminal).
    /// A `tty` of `"??"` or `"-"` is normalized to `nil`.
    static func scan(runner: CommandRunning) -> [RawClaudeProcess] {
        let output = runner.run("/bin/ps", ["-axo", "pid=,tty=,command="])
        var results: [RawClaudeProcess] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (pidToken, ttyToken, command) = takeTwoTokensAndRemainder(line) else { continue }
            guard let pid = Int32(pidToken) else { continue }

            guard commandBasenameIsClaude(command) else { continue }
            guard !command.contains("--input-format stream-json") else { continue }

            let tty: String? = (ttyToken == "??" || ttyToken == "-") ? nil : ttyToken
            results.append(RawClaudeProcess(pid: pid, tty: tty, command: command))
        }

        return results
    }

    /// Resolves a pid's current working directory via
    /// `lsof -a -p PID -d cwd -Fn`: the first output line starting with "n"
    /// carries the path (with that leading marker stripped).
    static func cwd(pid: Int32, runner: CommandRunning) -> String? {
        let output = runner.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if rawLine.hasPrefix("n") {
                return String(rawLine.dropFirst())
            }
        }
        return nil
    }

    /// Walks the `ppid` chain starting at `pid` (via repeated
    /// `ps -o ppid=,comm= -p <pid>` calls), up to 10 hops, looking for an
    /// ancestor whose `comm` matches a known terminal/editor app. Reaching
    /// `launchd`/pid 1, running out of hops, or missing ancestry data all
    /// terminate the walk as unknown.
    static func terminalApp(pid: Int32, runner: CommandRunning) -> String {
        let unknown = "Terminal (unknown)"
        var currentPid = pid

        for _ in 0..<10 {
            guard currentPid > 1 else { return unknown }

            let output = runner.run("/bin/ps", ["-o", "ppid=,comm=", "-p", String(currentPid)])
            guard let (ppid, comm) = parsePpidComm(output) else { return unknown }

            if let match = knownTerminalAncestors.first(where: { comm.lowercased().contains($0.needle) }) {
                return match.name
            }

            guard ppid > 1 else { return unknown }
            currentPid = ppid
        }

        return unknown
    }

    // MARK: - Parsing helpers

    private static func commandBasenameIsClaude(_ command: String) -> Bool {
        guard let firstToken = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        else { return false }
        let basename = (String(firstToken) as NSString).lastPathComponent
        return basename == "claude"
    }

    private static func parsePpidComm(_ output: String) -> (ppid: Int32, comm: String)? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard let (ppidToken, comm) = takeTokenAndRemainder(line) else { return nil }
        guard let ppid = Int32(ppidToken) else { return nil }
        return (ppid, comm)
    }

    /// Splits `line` into its first whitespace-separated token and the
    /// (whitespace-trimmed) remainder. Unlike `String.split(maxSplits:)`,
    /// this correctly handles runs of multiple separator characters (as
    /// `ps`'s fixed-width column padding produces) without leaving stray
    /// leading whitespace in the remainder.
    private static func takeTokenAndRemainder(_ line: String) -> (token: String, remainder: String)? {
        var remainder = Substring(line).drop { $0 == " " }
        guard let spaceIndex = remainder.firstIndex(of: " ") else {
            return remainder.isEmpty ? nil : (String(remainder), "")
        }
        let token = remainder[..<spaceIndex]
        guard !token.isEmpty else { return nil }
        remainder = remainder[spaceIndex...].drop { $0 == " " }
        return (String(token), String(remainder))
    }

    /// Same idea as `takeTokenAndRemainder`, but pulls two leading tokens
    /// (pid, tty) off `line` and returns whatever whitespace-trimmed text is
    /// left as the third value (the full command, which may itself contain
    /// single spaces between its arguments).
    private static func takeTwoTokensAndRemainder(_ line: String) -> (String, String, String)? {
        guard let (first, afterFirst) = takeTokenAndRemainder(line) else { return nil }
        guard let (second, afterSecond) = takeTokenAndRemainder(afterFirst) else { return nil }
        guard !afterSecond.isEmpty else { return nil }
        return (first, second, afterSecond)
    }
}
