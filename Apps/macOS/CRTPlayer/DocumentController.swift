import AppKit

/// Launching starts fresh (an empty screen, or the demo with `--demo`): window
/// restoration doesn't reopen and replay whatever was open last time.
///
/// Requests to open files that don't exist are dropped quietly too. AppKit can
/// read a launch argument's value (the "YES" in `-SomeFlag YES`) as a file to
/// open, which otherwise shows up as "The document “YES” could not be opened."
final class DocumentController: NSDocumentController {
    override func reopenDocument(
        for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        completionHandler(nil, false, CocoaError(.userCancelled))
    }

    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            completionHandler(nil, false, CocoaError(.userCancelled))
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }
}
