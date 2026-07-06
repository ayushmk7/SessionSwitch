import ApplicationServices
import Foundation

/// Automation (AppleEvents) permission status for the two terminal apps
/// `Injector` can script -- lets `PreferencesWindow` show "will this actually
/// work" before the user ever triggers a real injection.
///
/// NB on the underlying API: the task brief that scoped this file named the
/// function `AEDeterminePermissionToAppleEvents`. No such symbol exists in
/// the macOS SDK (checked against
/// `.../AE.framework/Headers/AppleEvents.h`); the real, documented API for
/// exactly this "can I send AppleEvents to this app, without prompting"
/// check is `AEDeterminePermissionToAutomateTarget` (10.14+), which returns
/// the identical four raw codes the brief specified (`noErr`,
/// `errAEEventNotPermitted`, `errAEEventWouldRequireUserConsent`,
/// `procNotFound`), so this file implements against that real symbol.
enum Permissions {
    /// Terminal.app's bundle id -- one of `Injector`'s two scriptable targets.
    static let terminalBundleID = "com.apple.Terminal"
    /// iTerm2's bundle id -- `Injector`'s other scriptable target.
    static let iTerm2BundleID = "com.googlecode.iterm2"

    /// Pure mapping from a raw `AEDeterminePermissionToAutomateTarget`
    /// status to a display string. Kept free of any AppleEvent machinery so
    /// it's testable by feeding in the four documented raw codes directly
    /// (see `PermissionsTests`) -- the AE call itself (`automationStatus`)
    /// stays a thin wrapper around this.
    static func statusString(forRawStatus status: OSStatus) -> String {
        switch status {
        case noErr:
            return "granted"
        case OSStatus(errAEEventNotPermitted):
            return "denied"
        case OSStatus(errAEEventWouldRequireUserConsent):
            return "not determined"
        case OSStatus(procNotFound):
            // The target app isn't running at all, so macOS can't even
            // evaluate the automation relationship yet -- it will prompt
            // (or silently allow, if already granted) the first time
            // `Injector` actually scripts it.
            return "not running (will prompt on first use)"
        default:
            return "unknown (\(status))"
        }
    }

    /// Checks whether this app may currently send AppleEvents to `bundleID`,
    /// **without** prompting the user (`askUserIfNeeded: false`, per the
    /// brief -- this is a status check, not a permission request). Thin: all
    /// it does is build the AEAddressDesc target descriptor Apple's API
    /// requires and hand the raw result to `statusString`.
    static func automationStatus(for bundleID: String) -> String {
        statusString(forRawStatus: rawAutomationStatus(for: bundleID))
    }

    private static func rawAutomationStatus(for bundleID: String) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let createStatus: OSErr = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }

        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }
}
