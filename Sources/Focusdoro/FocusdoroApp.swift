import AppKit
import FocusdoroCore

/// Menu-bar-only lifecycle: no SwiftUI `App` scene, no window, no Dock icon.
/// `.accessory` is set before `run()` so the Dock never briefly shows the app.
@main
enum FocusdoroApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let coordinator = AppLifecycleCoordinator()
        application.delegate = coordinator
        application.setActivationPolicy(.accessory)
        application.run()
        // `run()` never returns; the strong reference keeps the delegate alive.
        _ = coordinator
    }
}
