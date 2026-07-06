import Foundation

/// Where an AppleScript injection is delivered: a specific tty inside either
/// Terminal.app or iTerm2 -- the only two `terminalApp` values `SessionStore`
/// ever marks as non-`readOnly` in v1. Built from a `SessionInfo`'s
/// `terminalApp`/`tty` by `Injector`.
enum InjectionTarget: Equatable {
    case terminalApp(tty: String)
    case iTerm2(tty: String)
}

/// Builds the literal AppleScript source (and the Claude Code slash commands
/// it carries) `Injector` sends into a session's terminal tab.
enum ScriptBuilder {

    /// Builds the AppleScript that locates `target`'s tty and delivers
    /// `command` into it. Both apps' AppleScript tty properties return the
    /// FULL device path (verified live against Terminal.app:
    /// `tty of front window` -> "/dev/ttys000"; iTerm2 likewise), so both
    /// branches compare against "/dev/<tty>".
    static func script(for target: InjectionTarget, command: String) -> String {
        let escaped = escapeForAppleScriptLiteral(command)
        switch target {
        case .terminalApp(let tty):
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "/dev/\(tty)" then do script "\(escaped)" in t
                    end repeat
                end repeat
            end tell
            """
        case .iTerm2(let tty):
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with s in sessions of tb
                            if tty of s is "/dev/\(tty)" then tell s to write text "\(escaped)"
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        }
    }

    static func slashCommand(model: ClaudeModel) -> String {
        "/model \(model.alias)"
    }

    static func slashCommand(effort: String) -> String {
        "/effort \(effort)"
    }

    /// Escapes backslashes and double quotes for embedding `raw` inside an
    /// AppleScript string literal. Backslashes are escaped first so the
    /// backslashes just inserted for quote-escaping aren't themselves
    /// re-escaped.
    private static func escapeForAppleScriptLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Delivers `/model`/`/effort` slash commands into a session's terminal tab
/// via AppleScript, queuing requests against busy (`.working`) sessions and
/// verifying model switches against `StateReaderV1`'s jsonl-derived state.
///
/// Request lifecycle (all per-pid, strictly FIFO):
/// 1. `enqueue`: readOnly -> `.rejected` immediately; otherwise appended to
///    that pid's FIFO and reflected as `session.pending`.
/// 2. `pump`: while nothing is in flight for the pid and the store reports it
///    idle, the FIFO head is injected. A second request arriving while the
///    first is queued/executing/verifying simply appends -- it never
///    overwrites (`applyPreset` relies on this: its model request must not be
///    dropped when its effort request lands `presetGap` later).
/// 3. `execute` runs on a background queue -- the real `osascript` can block
///    for seconds behind a first-run Automation consent prompt, which must
///    never freeze the menu bar. All state mutation happens back on MainActor.
/// 4. Resolution: model requests poll the store (up to `pollTimeout`) for the
///    model change -> `.verified`/`.unverified`; effort requests resolve
///    `.assumed` right after delivery (no state source to check). Only after
///    a request delivers its `onResult` does the pid's next FIFO entry start.
@MainActor
final class Injector {

    enum InjectionResult: Equatable {
        case verified(String)
        case assumed(String)
        case unverified(String)
        case rejected(String)
    }

    /// Fired once per resolved request (rejected / assumed / verified /
    /// unverified), keyed by the session's pid.
    var onResult: ((Int32, InjectionResult) -> Void)?

    private let store: SessionStore
    private let execute: (String) -> String?
    private let pollInterval: TimeInterval
    private let pollTimeout: TimeInterval
    private let presetGap: TimeInterval

    /// Serial background queue for `execute` calls (see lifecycle note 3).
    private let executeQueue = DispatchQueue(label: "SessionSwitch.Injector.execute", qos: .userInitiated)

    private enum RequestKind {
        case model(ClaudeModel)
        case effort(String)

        var command: String {
            switch self {
            case .model(let model): return ScriptBuilder.slashCommand(model: model)
            case .effort(let level): return ScriptBuilder.slashCommand(effort: level)
            }
        }
    }

    /// The single in-flight request for a pid: dispatched to the execute
    /// queue, or awaiting model verification.
    private enum ActivePhase {
        case executing
        case verifying(model: ClaudeModel, deadline: Date)
    }

    /// Waiting requests per pid, strictly FIFO. Only ever popped by `pump`,
    /// and only when `active[pid] == nil` and the session is idle.
    private var queues: [Int32: [RequestKind]] = [:]

    /// In-flight request per pid (at most one; the FIFO holds the rest).
    private var active: [Int32: ActivePhase] = [:]

    /// Drives queue-draining and verification polling: ticks
    /// `store.refreshNow()` at `pollInterval` while any queue or in-flight
    /// request exists, and is torn down once everything resolves.
    private var pollTimer: Timer?

    init(
        store: SessionStore,
        execute: @escaping (String) -> String? = Injector.osascript,
        pollInterval: TimeInterval = 0.5,
        pollTimeout: TimeInterval = 5.0,
        presetGap: TimeInterval = 0.5
    ) {
        self.store = store
        self.execute = execute
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.presetGap = presetGap

        // Injector owns `store.onChange`: it's the mechanism both for
        // draining queued requests once a session goes idle, and for
        // noticing verification results as refreshes land. (Composing this
        // with any other `onChange` observer -- e.g. a future menu
        // controller -- is the composing code's job; see Task 5/6 report.)
        store.onChange = { [weak self] in self?.handleStoreChange() }
    }

    deinit {
        pollTimer?.invalidate()
    }

    func requestModel(_ model: ClaudeModel, for session: SessionInfo) {
        enqueue(.model(model), for: session)
    }

    func requestEffort(_ level: String, for session: SessionInfo) {
        enqueue(.effort(level), for: session)
    }

    /// Applies a preset's model immediately (subject to the normal
    /// queue/inject rules), then its effort `presetGap` seconds later if the
    /// preset has one. Because requests append to a per-pid FIFO, the effort
    /// request queues behind the model request even when the session is busy
    /// or the model request is still verifying.
    func applyPreset(_ preset: Preset, for session: SessionInfo) {
        guard let model = ModelCatalog.model(idOrAlias: preset.modelID) else { return }
        requestModel(model, for: session)

        guard let effort = preset.effort else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + presetGap) { [weak self] in
            Task { @MainActor in
                self?.requestEffort(effort, for: session)
            }
        }
    }

    // MARK: - Enqueue + per-pid FIFO pump

    private func enqueue(_ kind: RequestKind, for session: SessionInfo) {
        guard !session.readOnly else {
            onResult?(session.id, .rejected(session.readOnlyReason ?? "read-only"))
            return
        }

        queues[session.id, default: []].append(kind)
        store.setPending(kind.command, forPID: session.id)
        pump(pid: session.id)
        updatePollTimer()
    }

    /// Starts the next queued request for `pid` if nothing is in flight and
    /// the store currently reports the session idle. Reads the session fresh
    /// from the store (not a possibly stale caller snapshot) so state/tty
    /// reflect the latest scan.
    private func pump(pid: Int32) {
        guard active[pid] == nil else { return }
        guard let fifo = queues[pid], !fifo.isEmpty else { return }
        guard let session = store.sessions.first(where: { $0.id == pid }) else {
            // Session vanished: nothing to inject into; drop its queue.
            queues.removeValue(forKey: pid)
            return
        }
        guard session.state == .idle else { return }

        var remaining = fifo
        let kind = remaining.removeFirst()
        if remaining.isEmpty {
            queues.removeValue(forKey: pid)
        } else {
            queues[pid] = remaining
        }
        inject(kind, session: session)
    }

    private func inject(_ kind: RequestKind, session: SessionInfo) {
        guard let target = Self.injectionTarget(for: session) else {
            // Shouldn't happen (readOnly gating catches these at enqueue),
            // but resolve rather than wedge the pid's FIFO.
            resolve(pid: session.id, result: .rejected(session.readOnlyReason ?? "not scriptable"))
            return
        }

        active[session.id] = .executing
        let script = ScriptBuilder.script(for: target, command: kind.command)
        let execute = self.execute
        let pid = session.id
        executeQueue.async {
            _ = execute(script)
            Task { @MainActor [weak self] in
                self?.didExecute(kind, pid: pid)
            }
        }
    }

    /// Back on MainActor after `execute` returned on the background queue.
    private func didExecute(_ kind: RequestKind, pid: Int32) {
        switch kind {
        case .model(let model):
            active[pid] = .verifying(model: model, deadline: Date().addingTimeInterval(pollTimeout))
        case .effort:
            resolve(pid: pid, result: .assumed("effort applied (unverifiable)"))
        }
        updatePollTimer()
    }

    /// Delivers a request's final result, then (and only then) lets the pid's
    /// next queued request start.
    private func resolve(pid: Int32, result: InjectionResult) {
        active.removeValue(forKey: pid)
        onResult?(pid, result)
        store.setPending(queues[pid]?.first?.command, forPID: pid)
        pump(pid: pid)
        updatePollTimer()
    }

    private static func injectionTarget(for session: SessionInfo) -> InjectionTarget? {
        guard let tty = session.tty else { return nil }
        switch session.terminalApp {
        case "Terminal": return .terminalApp(tty: tty)
        case "iTerm2": return .iTerm2(tty: tty)
        default: return nil
        }
    }

    // MARK: - Reacting to store refreshes: pump queues, check verifications

    private func handleStoreChange() {
        for pid in Array(queues.keys) {
            pump(pid: pid)
        }
        checkVerifications()
        updatePollTimer()
    }

    private func checkVerifications() {
        let now = Date()
        // Iterate over a key snapshot but re-read `active` fresh per pid:
        // resolve() can reenter handleStoreChange (via setPending's onChange)
        // and mutate `active` while this loop runs.
        for pid in Array(active.keys) {
            guard case .verifying(let model, let deadline)? = active[pid] else { continue }
            guard let session = store.sessions.first(where: { $0.id == pid }) else {
                // Session vanished mid-verification: drop it (and anything
                // queued behind it) silently -- there is no terminal left to
                // deliver to or notify about.
                active.removeValue(forKey: pid)
                queues.removeValue(forKey: pid)
                continue
            }

            if Self.modelMatches(session.model, model) {
                resolve(pid: pid, result: .verified("model changed"))
            } else if now >= deadline {
                resolve(pid: pid, result: .unverified("state file unchanged"))
            }
        }
    }

    /// Resolves `actual` through `ModelCatalog` (so dated ids like
    /// `claude-sonnet-5-20251001` still match) before comparing catalog ids.
    private static func modelMatches(_ actual: String?, _ expected: ClaudeModel) -> Bool {
        guard let actual else { return false }
        return ModelCatalog.model(idOrAlias: actual)?.id == expected.id
    }

    private func updatePollTimer() {
        if queues.isEmpty && active.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.store.refreshNow()
                }
            }
        }
    }

    // MARK: - Default execute: shell out to osascript

    /// Default `execute` implementation: runs `osascript -e <script>` via
    /// `Process`. Bounded by a timeout (mirroring `ShellRunner`'s pattern) so
    /// a hung/unresponsive target app can't hang the (background) execute
    /// queue forever. Returns stderr text on failure, `nil` on success.
    nonisolated static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }

        var stderrData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitGroup.leave()
        }

        if exitGroup.wait(timeout: .now() + 5.0) == .timedOut {
            process.terminate()
            exitGroup.wait()
        }
        readGroup.wait()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            return message.isEmpty ? "osascript failed" : message
        }
        return nil
    }
}
