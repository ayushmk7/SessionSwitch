import Combine
import Foundation

/// Composes `Discovery` (Task 3) + `StateReaderV1` (Task 4) into the live
/// `[SessionInfo]` list the menu bar UI renders, on a periodic refresh loop.
///
/// Threading: `Discovery`/`StateReaderV1` shell out to `ps`/`lsof` and hit the
/// filesystem, each of which can block for up to `ShellRunner`'s 2 s timeout,
/// several times per refresh. Every scan therefore runs on a background
/// queue; only the final publish of `sessions` (and the `onChange` callback)
/// happens back on the main actor. `refreshNow()` is reentrancy-guarded so a
/// slow scan can never pile up overlapping work if the timer (or an external
/// caller, e.g. `Injector`'s verification polling) fires again before the
/// previous scan finished.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []

    /// AppKit menu rebuild hook (NSMenu isn't SwiftUI): fired on the main
    /// actor every time `sessions` finishes republishing, whether from the
    /// timer, an explicit `refreshNow()`, or `setPending`.
    var onChange: (() -> Void)?

    private let runner: CommandRunning
    private let projectsRoot: URL
    private let refreshInterval: TimeInterval

    private var timer: Timer?
    private var isRefreshing = false

    /// Carries `pending` labels forward across refreshes, keyed by pid, since
    /// a fresh scan has no memory of in-flight `Injector` requests on its own.
    private var pendingByPID: [Int32: String] = [:]

    nonisolated static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    init(
        runner: CommandRunning = ShellRunner(),
        projectsRoot: URL = SessionStore.defaultProjectsRoot,
        refreshInterval: TimeInterval = 2
    ) {
        self.runner = runner
        self.projectsRoot = projectsRoot
        self.refreshInterval = refreshInterval
    }

    /// Starts the periodic refresh loop: an immediate first refresh, then a
    /// repeating main-thread `Timer` every `refreshInterval` seconds.
    func start() {
        timer?.invalidate()
        refreshNow()
        // Added to `.common` run-loop modes (not just `.default`) so this
        // keeps ticking while an `NSMenu` is tracking (`.eventTracking`
        // mode) -- otherwise the refresh loop would silently stall for as
        // long as the status menu stays open.
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Kicks off one scan-and-publish cycle. No-ops if a previous refresh is
    /// still in flight (reentrancy guard) so overlapping ticks never queue up
    /// concurrent background scans.
    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let runner = self.runner
        let projectsRoot = self.projectsRoot

        DispatchQueue.global(qos: .utility).async {
            let computed = Self.scanAndBuild(runner: runner, projectsRoot: projectsRoot)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Apply pending labels at PUBLISH time, from the live
                // MainActor-side map -- never from a snapshot captured when
                // the scan started, or a setPending() landing mid-scan would
                // be silently reverted by this publish.
                let livePIDs = Set(computed.map(\.id))
                self.pendingByPID = self.pendingByPID.filter { livePIDs.contains($0.key) }
                var published = computed
                for index in published.indices {
                    published[index].pending = self.pendingByPID[published[index].id]
                }
                self.sessions = published
                self.isRefreshing = false
                self.onChange?()
            }
        }
    }

    /// Sets (or clears, when `label` is `nil`) the `pending` label for the
    /// session with the given pid, and republishes immediately. Used by
    /// `Injector` to reflect a queued/in-flight model or effort request
    /// before the next scan would otherwise pick it up.
    func setPending(_ label: String?, forPID pid: Int32) {
        pendingByPID[pid] = label
        guard let index = sessions.firstIndex(where: { $0.id == pid }) else { return }
        sessions[index].pending = label
        onChange?()
    }

    // MARK: - Off-main-actor scan (no access to instance state)

    /// Runs entirely off the main actor: pure function of its arguments, safe
    /// to execute on a background queue. Builds sessions with `pending: nil`;
    /// pending labels are applied at publish time on the main actor (see
    /// `refreshNow()`).
    nonisolated private static func scanAndBuild(
        runner: CommandRunning,
        projectsRoot: URL
    ) -> [SessionInfo] {
        let raws = Discovery.scan(runner: runner)

        let infos: [SessionInfo] = raws.map { raw in
            let cwd = Discovery.cwd(pid: raw.pid, runner: runner) ?? ""
            let terminalApp = Discovery.terminalApp(pid: raw.pid, runner: runner)
            let snapshot = StateReaderV1.snapshot(cwd: cwd, projectsRoot: projectsRoot)

            var readOnly = false
            var readOnlyReason: String?
            if raw.tty == nil {
                readOnly = true
                readOnlyReason = "no controlling terminal"
            } else if terminalApp != "Terminal" && terminalApp != "iTerm2" {
                readOnly = true
                readOnlyReason = "\(terminalApp) not scriptable in v1"
            }

            return SessionInfo(
                id: raw.pid,
                projectPath: cwd,
                projectName: SessionInfo.projectName(fromPath: cwd),
                tty: raw.tty,
                terminalApp: terminalApp,
                model: snapshot.model,
                state: snapshot.state,
                readOnly: readOnly,
                readOnlyReason: readOnlyReason,
                pending: nil
            )
        }

        // Tiebreak on `id` (pid) when `projectName`s collide (e.g. two
        // sessions on the same project) so row order is stable across
        // refreshes instead of depending on `ps`'s (unstable) scan order.
        return infos.sorted {
            $0.projectName == $1.projectName ? $0.id < $1.id : $0.projectName < $1.projectName
        }
    }
}
