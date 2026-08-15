import AppKit

// Keep a strong reference to the delegate for the lifetime of the run loop.
// NSApplication.delegate is weak; relying on a temporary delegate causes a
// headless process with neither a window nor a menu-bar item.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
