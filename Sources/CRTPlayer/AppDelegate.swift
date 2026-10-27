import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--demo` opens the bundled test clip at launch instead of the Open panel.
    private var opensDemo = CommandLine.arguments.contains("--demo")

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = DocumentController() // The first one created becomes NSDocumentController.shared.
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    /// Like QuickTime Player: launching (or clicking the Dock icon) with nothing
    /// open shows the Open panel instead of an empty window.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        let controller = NSDocumentController.shared
        if opensDemo, let demo = Bundle.main.url(forResource: "Demo", withExtension: "mp4") {
            opensDemo = false
            controller.openDocument(withContentsOf: demo, display: true) { _, _, _ in }
        } else {
            controller.openDocument(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
