import Foundation

/// Coarse activity state for a discovered session, derived from state-file
/// mtime freshness (see StateReaderV1 in Task 4).
enum SessionState: String {
    case working
    case idle
}

/// A single discovered, running Claude Code CLI session, combining process
/// discovery (Task 3) with jsonl state (Task 4).
struct SessionInfo: Identifiable, Equatable {
    let id: Int32
    var projectPath: String
    var projectName: String
    var tty: String?
    var terminalApp: String
    var model: String?
    var state: SessionState
    var readOnly: Bool
    var readOnlyReason: String?
    var pending: String?

    /// Derives a display name for a project path: its last path component.
    static func projectName(fromPath path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
