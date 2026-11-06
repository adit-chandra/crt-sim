import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--demo` opens the bundled test clip at launch instead of an empty screen.
    private var opensDemo = CommandLine.arguments.contains("--demo")

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = DocumentController() // The first one created becomes NSDocumentController.shared.
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    /// Launching (or clicking the Dock icon) with nothing open shows a dark,
    /// empty screen; the next video opened or dropped on it plays there.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if opensDemo, let demo = Bundle.main.url(forResource: "Demo", withExtension: "mp4") {
            opensDemo = false
            NSDocumentController.shared.openDocument(withContentsOf: demo, display: true) { _, _, _ in }
        } else {
            PlayerWindowController.showEmptyScreen()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
