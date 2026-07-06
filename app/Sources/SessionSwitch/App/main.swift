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
    } else if CommandLine.arguments.contains("--dump-sessions") {
        // QA/debug helper (Task 9): prints exactly what `SessionStore`
        // discovers on THIS machine, one line per session, then exits --
        // no menu bar, no run loop left spinning. Useful for verifying
        // Discovery/StateReaderV1 against real `claude` processes without
        // opening the actual menu bar UI. `refreshNow()` completes
        // asynchronously (it shells out to `ps`/`lsof` on a background
        // queue then republishes back on the main actor), so this process
        // -- which never calls `app.run()` -- has to keep servicing the
        // main run loop itself or that hop would never fire.
        let store = SessionStore()
        var didFinish = false
        store.onChange = { didFinish = true }
        store.refreshNow()

        let deadline = Date().addingTimeInterval(5)
        while !didFinish && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if store.sessions.isEmpty {
            print("(no sessions discovered)")
        }
        for session in store.sessions {
            let ttyText = session.tty ?? "-"
            let modelText = session.model ?? "-"
            let readOnlyText = session.readOnly ? " READONLY(\(session.readOnlyReason ?? "?"))" : ""
            print("pid=\(session.id) project=\(session.projectName) app=\(session.terminalApp) tty=\(ttyText) model=\(modelText) state=\(session.state.rawValue)\(readOnlyText)")
        }
        exit(0)
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
