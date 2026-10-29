import SwiftUI

/// AppKit owns menu tracking, so playback redraws cannot replace an open menu.
struct TrackMenuButton: NSViewRepresentable {
    let symbol: String
    let title: String
    var isEnabled = true
    let showMenu: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(showMenu: showMenu) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                              target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.82)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = isEnabled
        context.coordinator.showMenu = showMenu
    }

    final class Coordinator: NSObject {
        var showMenu: (NSView) -> Void
        init(showMenu: @escaping (NSView) -> Void) { self.showMenu = showMenu }
        @objc func open(_ sender: NSButton) { showMenu(sender) }
    }
}
