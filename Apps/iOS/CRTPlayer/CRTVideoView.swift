import CRTCore
import CRTPreferences
import MetalKit
import SwiftUI

struct CRTVideoView: UIViewRepresentable {
    let renderer: CRTRenderer
    let store: CRTSettingsStore
    var isActive: Bool

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        renderer.settings = store.settings
        renderer.isEnabled = store.isEnabled
        view.isPaused = !isActive
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}
