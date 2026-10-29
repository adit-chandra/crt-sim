import Observation
import MediaPlayback
import SwiftUI

/// Window-chrome state shared between the window controller and SwiftUI overlays.
@Observable
final class ChromeState {
    var showsSettings = false
    var showsSubtitleSettings = false
    var isTrackingTrackMenu = false

    var keepsControlsVisible: Bool {
        showsSettings || showsSubtitleSettings || isTrackingTrackMenu
    }
    /// Transient on-screen-display text, like a TV's channel banner.
    var osdMessage: String?
}

/// QuickTime-style floating transport controls.
struct ControlBar: View {
    let model: PlayerModel
    @Bindable var chrome: ChromeState
    let store: CRTSettingsStore
    var onDrag: (CGSize?) -> Void = { _ in }
    let showSubtitleMenu: (NSView) -> Void
    let showAudioMenu: (NSView) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    BarButton(symbol: volumeSymbol, size: 13) { model.isMuted.toggle() }
                        .frame(width: 26, alignment: .leading)
                    ThinSlider(value: volume)
                        .frame(minWidth: 0, maxWidth: 72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 20) {
                    BarButton(symbol: "gobackward.10", size: 16) { model.skip(by: -10) }
                    BarButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                        model.togglePlayPause()
                    }
                    .frame(width: 34)
                    BarButton(symbol: "goforward.10", size: 16) { model.skip(by: 10) }
                }
                HStack(spacing: 4) {
                    TrackMenuButton(symbol: "waveform", title: "Audio Track", isEnabled: !model.audioTracks.isEmpty,
                                    showMenu: showAudioMenu)
                        .frame(width: 28, height: 28)
                    TrackMenuButton(symbol: "captions.bubble", title: "Subtitles", showMenu: showSubtitleMenu)
                        .frame(width: 28, height: 28)
                        .popover(isPresented: $chrome.showsSubtitleSettings, arrowEdge: .top) {
                            SubtitleSettingsView(store: .shared)
                        }
                    BarButton(symbol: "tv", size: 14, isActive: chrome.showsSettings) {
                        chrome.showsSubtitleSettings = false
                        chrome.showsSettings.toggle()
                    }
                    .help("CRT Settings")
                    .popover(isPresented: $chrome.showsSettings, arrowEdge: .top) {
                        CRTSettingsView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            PlaybackProgressView(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background { ControlBarDragSurface(onDrag: onDrag) }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .alert("Playback Error", isPresented: Binding(
            get: { model.playbackError != nil },
            set: { if !$0 { model.playbackError = nil } }
        )) {
            Button("OK") { model.playbackError = nil }
        } message: {
            Text(model.playbackError ?? "")
        }
    }

    private var volume: Binding<Double> {
        Binding {
            model.isMuted ? 0 : Double(model.volume)
        } set: { newValue in
            model.volume = Float(newValue)
            model.isMuted = newValue == 0
        }
    }

    private var volumeSymbol: String {
        let level = model.isMuted ? 0 : model.volume
        switch level {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Only the timeline observes the clock; menus and popovers keep a stable host.
private struct PlaybackProgressView: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(model.currentTime))
                .frame(minWidth: 38, alignment: .trailing)
            ThinSlider(value: progress) { editing in
                editing ? model.beginScrubbing() : model.endScrubbing()
            }
            Text("-" + formatTime(max(model.duration - model.currentTime, 0)))
                .frame(minWidth: 42, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }

    private var progress: Binding<Double> {
        Binding {
            model.duration > 0 ? model.currentTime / model.duration : 0
        } set: { fraction in
            model.scrub(to: fraction * model.duration)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

struct BarButton: View {
    let symbol: String
    var size: CGFloat = 15
    var isActive = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: size + 10, minHeight: size + 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isHovering || isActive ? 1 : 0.82))
        .onHover { isHovering = $0 }
    }
}

/// A thin capsule slider that thickens and shows a knob on hover, like QuickTime's scrubber.
struct ThinSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = min(max(value, 0), 1)
            let expanded = isHovering || isDragging
            let track: CGFloat = expanded ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                    .frame(height: track)
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: max(track, fraction * width), height: track)
                Circle().fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: fraction * width - 6)
                    .opacity(expanded ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = min(max(gesture.location.x / max(width, 1), 0), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: expanded)
        }
        .frame(height: 16)
    }
}

/// Retro on-screen display shown briefly when switching presets.
struct OSDView: View {
    let chrome: ChromeState

    var body: some View {
        Text(chrome.osdMessage?.uppercased() ?? "")
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(red: 0.45, green: 1, blue: 0.5))
            .shadow(color: Color(red: 0.2, green: 1, blue: 0.3).opacity(0.8), radius: 6)
            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            .opacity(chrome.osdMessage == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: chrome.osdMessage)
            .fixedSize()
    }
}
