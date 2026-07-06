import Foundation

/// A point-in-time read of a project's Claude Code CLI state, derived from
/// its newest `~/.claude/projects/<munged-cwd>/*.jsonl` session log.
struct SessionSnapshot: Equatable {
    var model: String?
    var state: SessionState
    var sessionFile: String?
}

/// Versioned adapter over Claude Code's on-disk jsonl state (PRD §9:
/// "versioned" because the CLI's on-disk format is undocumented/unstable, so
/// future format changes get a `StateReaderV2` rather than a breaking
/// rewrite of this one).
///
/// FR-37 privacy: this reader never parses or retains message content. It
/// only ever scans a bounded 256 KB tail window of the newest session file
/// for `"model":"…"` occurrences, and looks at filesystem mtimes -- nothing
/// else about a session's contents is read.
enum StateReaderV1 {

    /// Bounded tail-read window, per FR-37: only the final 256 KB of a
    /// session log is ever read off disk.
    private static let tailWindowBytes: UInt64 = 256 * 1024

    /// A session is considered "working" if its state file was modified
    /// within this many seconds of `now`.
    private static let workingThreshold: TimeInterval = 10

    /// Claude Code's on-disk munging rule for a project's state directory:
    /// every `/`, ` `, and `.` in the absolute cwd becomes `-`.
    /// Verified: `/Volumes/ExtremePro/My Projects/SessionSwitch` ->
    /// `-Volumes-ExtremePro-My-Projects-SessionSwitch`.
    static func mungedDir(for cwd: String) -> String {
        String(
            cwd.map { character -> Character in
                switch character {
                case "/", " ", ".": return "-"
                default: return character
                }
            }
        )
    }

    /// Reads the newest `*.jsonl` file in `projectsRoot/<munged(cwd)>/` and
    /// derives a snapshot from it. A missing directory, or a directory with
    /// no jsonl files, yields an empty snapshot (`nil`/`.idle`/`nil`) rather
    /// than throwing -- absence of Claude Code state is a normal, common
    /// case (e.g. a project that has never had a session).
    static func snapshot(cwd: String, projectsRoot: URL, now: Date = .init()) -> SessionSnapshot {
        let empty = SessionSnapshot(model: nil, state: .idle, sessionFile: nil)
        let dir = projectsRoot.appendingPathComponent(mungedDir(for: cwd))

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return empty
        }

        let jsonlFiles = entries.filter { $0.pathExtension == "jsonl" }
        guard let newest = newestFile(among: jsonlFiles) else {
            return empty
        }

        let model = lastModelInTailWindow(of: newest.url)
        let state: SessionState = abs(now.timeIntervalSince(newest.mtime)) < workingThreshold ? .working : .idle
        return SessionSnapshot(model: model, state: state, sessionFile: newest.url.path)
    }

    // MARK: - File selection

    private static func newestFile(among urls: [URL]) -> (url: URL, mtime: Date)? {
        var newest: (url: URL, mtime: Date)?
        for url in urls {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            else { continue }
            if newest == nil || mtime > newest!.mtime {
                newest = (url, mtime)
            }
        }
        return newest
    }

    // MARK: - Bounded tail scan (FR-37)

    private static func lastModelInTailWindow(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let windowStart = fileSize > tailWindowBytes ? fileSize - tailWindowBytes : 0

        do {
            try handle.seek(toOffset: windowStart)
            guard let tail = try handle.readToEnd() else { return nil }
            let text = String(decoding: tail, as: UTF8.self)
            return lastModelOccurrence(in: text)
        } catch {
            return nil
        }
    }

    /// Finds the value of the LAST `"model":"<value>"` occurrence in `text`.
    /// Deliberately a narrow, single-purpose scan (not a JSON parse) so it
    /// never touches message content beyond this one field.
    private static func lastModelOccurrence(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""model"\s*:\s*"([^"]*)""#) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard let last = matches.last, last.numberOfRanges > 1,
              let valueRange = Range(last.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }
}
