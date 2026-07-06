import AppKit

/// Mono Glass palette tokens (binding, per the Task 7 brief's Global
/// Constraints). `NSMenu` is system-styled -- these are applied via
/// `NSAttributedString` colors on item/button titles and custom views where
/// reasonable, not a full replacement UI (Task 8's picker panel owns the
/// full glass treatment).
enum Theme {
    /// Primary text.
    static let ink = NSColor(srgbRed: 0.949, green: 0.949, blue: 0.949, alpha: 1) // #f2f2f2
    /// Secondary/detail text (terminal/tty, read-only reason).
    static let dim = NSColor(srgbRed: 0.604, green: 0.604, blue: 0.604, alpha: 1) // #9a9a9a
    /// Idle-state indicator dot.
    static let idleGray = NSColor(srgbRed: 0.431, green: 0.431, blue: 0.451, alpha: 1) // #6e6e73
    /// Pending/attention accent (status title "!" suffix).
    static let amber = NSColor(srgbRed: 1.0, green: 0.690, blue: 0.0, alpha: 1) // #ffb000
    /// Verified/active/working accent.
    static let cyan = NSColor(srgbRed: 0.0, green: 0.898, blue: 1.0, alpha: 1) // #00e5ff
    /// Rejected/error accent.
    static let red = NSColor(srgbRed: 1.0, green: 0.231, blue: 0.231, alpha: 1) // #ff3b3b
    /// Panel background (reserved for Task 8's picker; exposed here since
    /// Theme is the single source of truth for the palette).
    static let panel = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 0.85)
}
