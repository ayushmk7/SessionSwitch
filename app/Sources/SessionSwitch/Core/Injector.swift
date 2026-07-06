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
    /// `command` into it. Terminal.app compares tty verbatim (its own AppleScript
    /// `tty of t` property has no `/dev/` prefix); iTerm2 compares against
    /// `/dev/<tty>` (its `tty of s` property does carry that prefix).
    static func script(for target: InjectionTarget, command: String) -> String {
        let escaped = escapeForAppleScriptLiteral(command)
        switch target {
        case .terminalApp(let tty):
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then do script "\(escaped)" in t
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
/// Threading: like `SessionStore`, this is `@MainActor`. Unlike `SessionStore`,
/// `execute` is a synchronous call (AppleScript delivery is expected to be
/// near-instant -- it's posting keystrokes, not fetching data) so it runs
/// directly on the main actor; the default `osascript` implementation still
/// bounds itself with a timeout so a hung target app can't hang the caller
/// forever (mirroring `ShellRunner`'s defensive pattern).
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

    private struct PendingVerification {
        let model: ClaudeModel
        let deadline: Date
    }

    /// Requests deferred because their session was `.working` at request
    /// time, keyed by pid. Drained the moment `store` reports that pid idle.
    private var queue: [Int32: RequestKind] = [:]

    /// In-flight model-change verifications, keyed by pid.
    private var verifications: [Int32: PendingVerification] = [:]

    /// Drives both queue-draining and verification polling: ticks
    /// `store.refreshNow()` at `pollInterval` while `queue` or
    /// `verifications` is non-empty, and is torn down once both drain.
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

    func requestModel(_ model: ClaudeModel, for session: SessionInfo) {
        perform(.model(model), for: session)
    }

    func requestEffort(_ level: String, for session: SessionInfo) {
        perform(.effort(level), for: session)
    }

    /// Applies a preset's model immediately (subject to the normal
    /// enqueue/inject rules), then its effort `presetGap` seconds later if
    /// the preset has one.
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

    // MARK: - Core request handling

    private func perform(_ kind: RequestKind, for session: SessionInfo) {
        guard !session.readOnly else {
            onResult?(session.id, .rejected(session.readOnlyReason ?? "read-only"))
            return
        }

        store.setPending(kind.command, forPID: session.id)

        if session.state == .working {
            queue[session.id] = kind
        } else {
            inject(kind, session: session)
        }
        updatePollTimer()
    }

    private func inject(_ kind: RequestKind, session: SessionInfo) {
        guard let target = Self.injectionTarget(for: session) else {
            store.setPending(nil, forPID: session.id)
            onResult?(session.id, .rejected(session.readOnlyReason ?? "not scriptable"))
            return
        }

        let script = ScriptBuilder.script(for: target, command: kind.command)
        _ = execute(script)

        switch kind {
        case .model(let model):
            verifications[session.id] = PendingVerification(
                model: model,
                deadline: Date().addingTimeInterval(pollTimeout)
            )
        case .effort:
            store.setPending(nil, forPID: session.id)
            onResult?(session.id, .assumed("effort applied (unverifiable)"))
        }
    }

    private static func injectionTarget(for session: SessionInfo) -> InjectionTarget? {
        guard let tty = session.tty else { return nil }
        switch session.terminalApp {
        case "Terminal": return .terminalApp(tty: tty)
        case "iTerm2": return .iTerm2(tty: tty)
        default: return nil
        }
    }

    // MARK: - Reacting to store refreshes: drain queue, check verifications

    private func handleStoreChange() {
        drainQueue()
        checkVerifications()
        updatePollTimer()
    }

    private func drainQueue() {
        for pid in Array(queue.keys) {
            guard let session = store.sessions.first(where: { $0.id == pid }) else {
                queue.removeValue(forKey: pid)
                continue
            }
            guard session.state == .idle else { continue }
            guard let kind = queue.removeValue(forKey: pid) else { continue }
            inject(kind, session: session)
        }
    }

    private func checkVerifications() {
        let now = Date()
        for pid in Array(verifications.keys) {
            guard let pending = verifications[pid] else { continue }
            guard let session = store.sessions.first(where: { $0.id == pid }) else {
                verifications.removeValue(forKey: pid)
                continue
            }

            if Self.modelMatches(session.model, pending.model) {
                verifications.removeValue(forKey: pid)
                store.setPending(nil, forPID: pid)
                onResult?(pid, .verified("model changed"))
            } else if now >= pending.deadline {
                verifications.removeValue(forKey: pid)
                store.setPending(nil, forPID: pid)
                onResult?(pid, .unverified("state file unchanged"))
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
        if queue.isEmpty && verifications.isEmpty {
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
    /// a hung/unresponsive target app can't hang the caller forever. Returns
    /// stderr text on failure, `nil` on success.
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
