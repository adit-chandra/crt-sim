import AVFoundation
import CRTPreferences
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var model = IOSPlayerModel()
    @State private var store = CRTSettingsStore.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showControls = true
    @State private var interaction = 0
    @State private var isScrubbing = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer = model.renderer {
                CRTVideoView(renderer: renderer, store: store, isActive: scenePhase == .active)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { revealControls() }
            }
            if !model.caption.isEmpty {
                VStack {
                    Spacer()
                    Text(model.caption)
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 24)
                        .padding(.bottom, showControls ? 160 : 24)
                }
                .allowsHitTesting(false)
            }
            if !model.isLoaded && !model.isLoading {
                ContentUnavailableView {
                    Label("Your own late-night television", systemImage: "tv")
                } description: {
                    Text("Open a video and give it the warmth of a picture tube.")
                } actions: {
                    Button("Open Video", systemImage: "folder") { showImporter = true }
                        .buttonStyle(.glassProminent)
                    Button("Try Test Pattern", action: openDemo)
                        .buttonStyle(.glass)
                }
                .padding()
                .background(.black.opacity(0.7))
            }
            if model.isLoading {
                ProgressView("Opening video…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            if model.isLoaded {
                VStack {
                    HStack {
                        Text(model.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button("Open Video", systemImage: "folder") { showImporter = true }
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 20)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer(minLength: 0)
                    controls
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                // Retain the menu anchor while fading the controls.
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(showControls ? .visible : .hidden)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .video, .audio]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showSettings) { IOSCRTSettingsView(store: store) }
        .alert("Unable to Play", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onOpenURL { open($0) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.pause() }
        }
        .onChange(of: store.announcement) { _, _ in model.renderer?.play(.channelChange) }
        .onChange(of: model.isPlaying) { _, playing in if playing { revealControls() } else { showControls = true } }
        .task(id: interaction) {
            guard model.isPlaying, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying, !isScrubbing, !showSettings, !showImporter else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showControls = false }
        }
        .onChange(of: showSettings) { _, _ in revealControls() }
        .onChange(of: showImporter) { _, _ in revealControls() }
        .onDisappear { loadTask?.cancel(); model.pause() }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--demo") { openDemo() }
        }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(timestamp(model.currentTime))
                    .accessibilityIdentifier("playbackTime")
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                       in: 0...max(model.duration, 0.01)) { editing in
                    isScrubbing = editing
                    if editing { model.beginScrubbing() } else { model.endScrubbing() }
                    revealControls()
                }
                .accessibilityLabel("Playback position")
                .disabled(model.duration <= 0)
                Text(timestamp(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                control("CRT Settings", icon: "tv") { showSettings = true }
                Menu {
                    Toggle("Loop", isOn: $model.loops)
                    Toggle("Mute", isOn: $model.isMuted)
                    if !model.audioTracks.isEmpty {
                        Section("Audio") {
                            ForEach(model.audioTracks, id: \.self) { option in
                                Button { model.selectAudio(option) } label: {
                                    if model.selectedAudio == option { Label(option.displayName, systemImage: "checkmark") }
                                    else { Text(option.displayName) }
                                }
                            }
                        }
                    }
                    if !model.subtitleTracks.isEmpty {
                        Section("Subtitles") {
                            Button { model.selectSubtitle(nil) } label: {
                                if model.selectedSubtitle == nil { Label("Off", systemImage: "checkmark") }
                                else { Text("Off") }
                            }
                            ForEach(model.subtitleTracks, id: \.self) { option in
                                Button { model.selectSubtitle(option) } label: {
                                    if model.selectedSubtitle == option { Label(option.displayName, systemImage: "checkmark") }
                                    else { Text(option.displayName) }
                                }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Playback Options")
                Spacer(minLength: 0)
                control("Back 10 seconds", icon: "gobackward.10") { model.seek(to: model.currentTime - 10) }
                control(model.isPlaying ? "Pause" : "Play", icon: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlayback() }
                    .font(.title2)
                control("Forward 10 seconds", icon: "goforward.10") { model.seek(to: model.currentTime + 10) }
                Spacer(minLength: 0)
                control(store.isEnabled ? "Disable CRT" : "Enable CRT", icon: store.isEnabled ? "power.circle.fill" : "power.circle") { store.isEnabled.toggle() }
            }
            .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    }

    private func control(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { action(); revealControls() } label: { Image(systemName: icon).frame(width: 44, height: 44) }
            .accessibilityLabel(title)
    }
    private func revealControls() { showControls = true; interaction += 1 }
    private func open(_ url: URL) {
        loadTask?.cancel()
        revealControls()
        loadTask = Task {
            await model.open(url, autoplay: !ProcessInfo.processInfo.arguments.contains("--paused"))
            if scenePhase != .active { model.pause() }
        }
    }
    private func openDemo() {
        guard let url = Bundle.main.url(forResource: "Demo", withExtension: "mp4") else {
            model.error = "The test pattern is missing from this app bundle."
            return
        }
        open(url)
    }
    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}
