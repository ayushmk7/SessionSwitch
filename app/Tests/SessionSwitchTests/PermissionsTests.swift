import ApplicationServices
import XCTest

@testable import SessionSwitch

/// Tests only the pure raw-code -> String mapping (per the brief: "the AE
/// call itself thin"). `automationStatus(for:)` itself shells out to a real
/// AppleEvent API and depends on which apps happen to be running/permitted
/// on the host, so it's exercised manually (see `app/README.md`'s manual
/// test checklist), not here.
final class PermissionsTests: XCTestCase {

    func testGrantedMapsToNoErr() {
        XCTAssertEqual(Permissions.statusString(forRawStatus: noErr), "granted")
    }

    func testNotPermittedMapsToDenied() {
        XCTAssertEqual(Permissions.statusString(forRawStatus: OSStatus(errAEEventNotPermitted)), "denied")
    }

    func testWouldRequireUserConsentMapsToNotDetermined() {
        XCTAssertEqual(
            Permissions.statusString(forRawStatus: OSStatus(errAEEventWouldRequireUserConsent)),
            "not determined"
        )
    }

    func testProcNotFoundMapsToNotRunningNote() {
        XCTAssertEqual(
            Permissions.statusString(forRawStatus: OSStatus(procNotFound)),
            "not running (will prompt on first use)"
        )
    }

    func testUnrecognizedRawStatusMapsToUnknownWithCode() {
        XCTAssertEqual(Permissions.statusString(forRawStatus: -1), "unknown (-1)")
    }

    func testKnownBundleIDConstants() {
        XCTAssertEqual(Permissions.terminalBundleID, "com.apple.Terminal")
        XCTAssertEqual(Permissions.iTerm2BundleID, "com.googlecode.iterm2")
    }
}
