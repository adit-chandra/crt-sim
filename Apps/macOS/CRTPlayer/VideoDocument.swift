import AppKit
import MediaPlayback

/// A read-only movie document. NSDocument gives us the open panel, Open Recent,
/// Finder "Open With", and one window per file for free.
@objc(VideoDocument)
final class VideoDocument: NSDocument {
    nonisolated override class var autosavesInPlace: Bool { false }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        // Nothing to load up front; the playback engine streams the file.
    }

    override func makeWindowControllers() {
        guard let fileURL else { return }
        addWindowController(PlayerWindowController.playing(PlayerModel(url: fileURL)))
    }
}
