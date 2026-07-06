import AppKit
import XCTest

@testable import SessionSwitch

@MainActor
final class SmokeTests: XCTestCase {
    func testAppDelegateConstructs() {
        // Constructing the delegate must not touch NSApp.run() or otherwise
        // block/crash the test runner.
        let delegate = AppDelegate()
        XCTAssertNotNil(delegate)
    }
}
