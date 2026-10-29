import AppKit
import MediaPlayback
import SwiftUI

struct SubtitleSettingsView: View {
    @Bindable var store: SubtitleSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Subtitle Appearance").font(.headline)
                Spacer()
                Button("Reset") { store.settings = SubtitleSettings() }
                    .controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Size")
                    HStack {
                        Slider(value: $store.settings.scale, in: 0.5...2.5, step: 0.05)
                            .accessibilityLabel("Subtitle size")
                        Text("\(Int((store.settings.scale * 100).rounded()))%")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("Font")
                    Picker("Font", selection: $store.settings.font) {
                        Text("Default Sans Serif").tag("sans-serif")
                        ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Style")
                    HStack {
                        Toggle("Bold", isOn: $store.settings.bold)
                        Toggle("Italic", isOn: $store.settings.italic)
                    }
                }
                GridRow {
                    Text("Text color")
                    ColorPicker("Text color", selection: color(\.color), supportsOpacity: false)
                        .labelsHidden()
                }
                GridRow {
                    Text("Outline")
                    HStack {
                        Slider(value: $store.settings.outlineSize, in: 0...5, step: 0.1)
                            .accessibilityLabel("Outline thickness")
                        ColorPicker("Outline color", selection: color(\.outlineColor), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                GridRow {
                    Text("Background")
                    HStack {
                        Slider(value: $store.settings.backgroundOpacity, in: 0...1, step: 0.05)
                            .accessibilityLabel("Background opacity")
                        Text("\(Int((store.settings.backgroundOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Toggle("Drop shadow", isOn: $store.settings.shadow)
                .disabled(store.settings.backgroundOpacity > 0)
            Divider()
            Toggle("Override embedded styles", isOn: $store.settings.overrideEmbeddedStyles)
            Text("Enable for custom fonts and colors in styled ASS/SSA subtitles. This may change signs and positioning. Image-based subtitles cannot be recolored.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes apply to all windows and are saved automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(16)
        .frame(width: 340)
    }

    private func color(_ keyPath: WritableKeyPath<SubtitleSettings, SubtitleSettings.Color>) -> Binding<Color> {
        Binding {
            let value = store.settings[keyPath: keyPath]
            return Color(.sRGB, red: value.red, green: value.green, blue: value.blue)
        } set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            store.settings[keyPath: keyPath] = .init(red: rgb.redComponent, green: rgb.greenComponent,
                                                    blue: rgb.blueComponent)
        }
    }
}

/// AppKit owns menu tracking, so playback redraws cannot replace an open menu.
struct SubtitleMenuButton: NSViewRepresentable {
    let showMenu: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(showMenu: showMenu) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Subtitles")!,
                              target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.82)
        button.toolTip = "Subtitles"
        button.setAccessibilityLabel("Subtitles")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.showMenu = showMenu
    }

    final class Coordinator: NSObject {
        var showMenu: (NSView) -> Void
        init(showMenu: @escaping (NSView) -> Void) { self.showMenu = showMenu }
        @objc func open(_ sender: NSButton) { showMenu(sender) }
    }
}
