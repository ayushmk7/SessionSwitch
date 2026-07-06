import AppKit

// Top-level `main.swift` code isn't main-actor-isolated by default, but this
// process's startup is always single-threaded on the main thread (nothing
// runs concurrently with it before `app.run()`/`exit(0)`), so
// `assumeIsolated` is sound here -- it's what lets `AppDelegate` (and the
// main-actor stack it wires) be constructed synchronously.
MainActor.assumeIsolated {
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
}
