import AppKit

if CommandLine.arguments.contains("--smoke-test") {
    let delegate = AppDelegate()
    delegate.smokeTest()
    print("SMOKE OK")
    exit(0)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
