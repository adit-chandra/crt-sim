import CRTCore
import CRTPreferences
import SwiftUI

struct IOSCRTSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CRTSettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("CRT Effect", isOn: $store.isEnabled)
                    Picker("Preset", selection: Binding(get: { store.preset?.id ?? "custom" }, set: {
                        if let preset = CRTPreset.named($0) { store.apply(preset) }
                    })) {
                        ForEach(CRTPreset.all) { Text($0.name).tag($0.id) }
                        if store.preset == nil { Text("Custom").tag("custom") }
                    }
                }
                Group {
                    Section("Tube") {
                        slider("Curvature", \.curvature)
                        slider("Vignette", \.vignette)
                        slider("Glow", \.glow)
                    }
                    Section("Beam") {
                        slider("Scanlines", \.scanlines)
                        slider("Lines", \.lines, 120...720, step: 10)
                        slider("Persistence", \.persistence)
                    }
                    Section("Phosphors") {
                        Picker("Mask", selection: $store.settings.maskType) {
                            ForEach(CRTSettings.MaskType.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        slider("Strength", \.maskStrength)
                        slider("Size", \.maskSize, 0.5...3, step: 0.5)
                        Picker("Color", selection: $store.settings.phosphor) {
                            ForEach(CRTSettings.Phosphor.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                    }
                    Section("Signal") {
                        Picker("Input", selection: $store.settings.signal) {
                            ForEach(CRTSettings.Signal.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        slider("Convergence", \.convergence)
                        slider("Interference", \.noise)
                        slider("Brightness", \.brightness, 0.5...1.6)
                        slider("Saturation", \.saturation, 0...2)
                    }
                }
                .disabled(!store.isEnabled)
                Section { Button("Reset to Classic") { store.apply(.classic) } }
            }
            .navigationTitle("CRT Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.accentColor)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<CRTSettings, Double>,
                        _ range: ClosedRange<Double> = 0...1, step: Double = 0.01) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(store.settings[keyPath: keyPath], format: .number.precision(.fractionLength(range.upperBound > 10 ? 0 : 2)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { store.settings[keyPath: keyPath] }, set: { store.settings[keyPath: keyPath] = $0 }), in: range, step: step)
                .accessibilityLabel(title)
        }
    }
}
