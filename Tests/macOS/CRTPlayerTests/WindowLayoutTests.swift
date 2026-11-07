import AppKit
import CRTPreferences
import MediaPlayback
import SwiftUI
import Testing
@testable import CRTPlayer

@Suite(.serialized)
struct WindowLayoutTests {
    @Test(arguments: [false, true])
    func resizingBelowPreferredControlWidthPreservesWindowGeometry(glassPane: Bool) async throws {
        _ = NSApplication.shared
        let store = CRTSettingsStore.shared
        let originalGlassPane = store.glassPane
        store.glassPane = glassPane
        defer { store.glassPane = originalGlassPane }

        let url = try #require(Bundle.module.url(forResource: "tracks", withExtension: "mp4", subdirectory: "Fixtures"))
        let model = PlayerModel(url: url, subtitleSettings: .init(defaults: nil))
        let controller = PlayerWindowController.playing(model)
        let window = try #require(controller.window)
        defer { window.close(); model.invalidate() }
        for _ in 0..<100 where !model.isLoaded {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.isLoaded)
        #expect(model.loadError == nil)
        // Allow the controller's load and size observations to finish fitting the window.
        try await Task.sleep(for: .milliseconds(250))
        model.pause()

        let root = try #require(window.contentView)
        let content = try #require((root as? PlayerContentView)
            ?? root.subviews.compactMap { $0 as? PlayerContentView }.first)
        let metal = try #require(content.subviews.compactMap { $0 as? CRTMetalView }.first)
        let controls = try #require(content.subviews.compactMap { $0 as? NSHostingView<ControlBar?> }.first)

        for anchoredAtRight in [false, true] {
            for width: CGFloat in [960, 640, 532, 500, 450, 400, 360, 640, 960] {
                // Model shrinking from either edge, keeping the opposite edge fixed.
                let frame = NSRect(x: anchoredAtRight ? 1100 - width : 100, y: 100,
                                   width: width, height: ceil(width * 9 / 16))
                window.setFrame(frame, display: false)
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))

                #expect(window.frame == frame, "Controls must not enlarge or displace the requested window")
                #expect(metal.frame == content.bounds)
                #expect(content.bounds.size == frame.size)
                #expect(abs(metal.bounds.width - metal.bounds.height * 16 / 9) < 2,
                        "Resizing must not create pillarboxing")
                #expect(abs(controls.frame.width - min(500, width - 32)) < 1)
                #expect(controls.frame.height >= 60)
                #expect(controls.frame.minX >= 16)
                #expect(controls.frame.maxX <= content.bounds.maxX - 16)
            }
        }

        // A moved bar should clamp its position before sacrificing its preferred width.
        controls.rootView?.onDrag(CGSize(width: 1000, height: 0))
        controls.rootView?.onDrag(nil)
        window.setFrame(NSRect(x: 100, y: 100, width: 640, height: 360), display: false)
        root.layoutSubtreeIfNeeded()
        #expect(controls.frame.width == 500)
        #expect(controls.frame.maxX <= content.bounds.maxX - 16)
    }
}
