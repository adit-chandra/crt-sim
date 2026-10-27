import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// Root view of a player window: hosts the Metal view and overlays, tracks the
/// pointer for auto-hiding chrome, drags the window, and accepts dropped files.
final class PlayerContentView: NSView {
    var onPointerActivity: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onDropURLs: (([URL]) -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }

    override func mouseDown(with event: NSEvent) {
        onPointerActivity?()
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        movieURLs(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = movieURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDropURLs?(urls)
        return true
    }

    private func movieURLs(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.audiovisualContent.identifier],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// Metal view that lets clicks fall through to the content view.
final class CRTMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosting view for decorations that should never take mouse events.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dark fade behind the title bar so the title stays legible over bright video.
final class TitleShadeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        // AppKit layer space is bottom-up, so y = 1 is the top edge.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer = gradient
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
