import AppKit

/// Launching starts fresh (the Open panel, or the demo with `--demo`): window
/// restoration doesn't reopen and replay whatever was open last time.
final class DocumentController: NSDocumentController {
    override func reopenDocument(
        for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        completionHandler(nil, false, CocoaError(.userCancelled))
    }
}
