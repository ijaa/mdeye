import AppKit

// Programmatic AppKit entry (no storyboard / no @main on the delegate).
// Guarantees: shared NSApplication, regular activation policy, and a running event loop.

let argv = CommandLine.arguments

// Headless self-check mode for CI (no GUI login / WindowServer required).
//   mdeye --selftest <path-to.md>
// Drives the reader render pipeline offscreen and exits; see SelfTest.swift.
if argv.count >= 3, argv[1] == "--selftest" {
    let app = NSApplication.shared
    // selfTest stays retained for the lifetime of app.run() (top-level scope).
    let selfTest = SelfTest(path: argv[2])
    selfTest.run()
    app.setActivationPolicy(.accessory)
    app.run()
    exit(1) // unreachable: SelfTest calls exit() on success/failure
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
