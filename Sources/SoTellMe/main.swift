import AppKit

Log.installCrashHandlers()

// main.swift's top-level code runs on the main thread but isn't inferred as
// @MainActor-isolated by the compiler; this asserts what's already true.
let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
