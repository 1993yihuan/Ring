import AppKit
import RingCore

let application = NSApplication.shared
// Captured before anything else runs. The updater has to prove that the bundle on disk is still
// this one, and a reference point read later would already be the replacement.
let launchBundle = BundleIdentity(app: Bundle.main.bundleURL)
let coordinator = AppCoordinator()
application.delegate = coordinator
application.run()
