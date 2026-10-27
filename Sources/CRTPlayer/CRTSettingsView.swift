import CRTCore
import SwiftUI

/// Popover with presets and every CRT parameter.
struct CRTSettingsView: View {
    @Bindable var store: CRTSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(isOn: $store.isEnabled) {
                    Text("CRT Effect").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Picker("Preset", selection: presetID) {
                    ForEach(CRTPreset.all) { Text($0.name).tag($0.id) }
                    if store.preset == nil {
                        Divider()
                        Text("Custom").tag("custom")
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Glass Pane", isOn: $store.glassPane)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .help("Show the picture as light on a pane of glass, so the desktop shows through dark areas")

            VStack(alignment: .leading, spacing: 14) {
                section("Tube") {
                    slider("Curvature", \.curvature)
                    slider("Vignette", \.vignette)
                    slider("Glow", \.glow)
                }
                section("Beam") {
                    slider("Scanlines", \.scanlines)
                    slider("Lines", \.lines, 120...720, step: 10) { "\(Int($0))" }
                    slider("Persistence", \.persistence)
                }
                section("Phosphors") {
                    row("Mask") {
                        Picker("Mask", selection: $store.settings.maskType) {
                            ForEach(CRTSettings.MaskType.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    slider("Strength", \.maskStrength)
                    slider("Size", \.maskSize, 0.5...3, step: 0.5) { String(format: "%.1f", $0) }
                    row("Color") {
                        Picker("Color", selection: $store.settings.phosphor) {
                            ForEach(CRTSettings.Phosphor.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                section("Signal") {
                    row("Input") {
                        Picker("Input", selection: $store.settings.signal) {
                            ForEach(CRTSettings.Signal.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    slider("Convergence", \.convergence)
                    slider("Interference", \.noise)
                    slider("Brightness", \.brightness, 0.5...1.6)
                    slider("Saturation", \.saturation, 0...2)
                }
            }
            .disabled(!store.isEnabled)
            .opacity(store.isEnabled ? 1 : 0.45)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var presetID: Binding<String> {
        Binding {
            store.preset?.id ?? "custom"
        } set: { id in
            if let preset = CRTPreset.named(id) { store.apply(preset) }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 82, alignment: .leading)
            content()
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<CRTSettings, Double>,
        _ range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    ) -> some View {
        let value = Binding {
            store.settings[keyPath: keyPath]
        } set: { newValue in
            store.settings[keyPath: keyPath] = step.map { (newValue / $0).rounded() * $0 } ?? newValue
        }
        return row(title) {
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
