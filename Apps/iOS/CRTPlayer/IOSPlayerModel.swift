import AVFoundation
import CRTCore
import Metal
import Observation
import QuartzCore
import UIKit

/// Keeps Files-provider access alive until the player has released its asset.
private final class ScopedMediaURL {
    let url: URL
    private let accessed: Bool
    init(_ url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

/// Audio-session configuration may block; serialize it away from the UI executor.
private actor PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .moviePlayback {
            try session.setCategory(.playback, mode: .moviePlayback)
        }
        try session.setActive(true)
    }
}

@MainActor
@Observable
final class IOSPlayerModel: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let player = AVPlayer()
    let renderer: CRTRenderer?
    private(set) var title = "CRT Sim"
    private(set) var isLoading = false
    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    private(set) var caption = ""
    private(set) var audioTracks: [AVMediaSelectionOption] = []
    private(set) var subtitleTracks: [AVMediaSelectionOption] = []
    private(set) var selectedAudio: AVMediaSelectionOption?
    private(set) var selectedSubtitle: AVMediaSelectionOption?
    var error: String?
    var loops = false
    var isMuted = false { didSet { player.isMuted = isMuted } }

    @ObservationIgnored private var mediaURL: ScopedMediaURL?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var legibleOutput: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var subtitleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var resumeAfterScrubbing = false
    @ObservationIgnored private var isScrubbing = false

    override init() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw PlayerError("Metal is unavailable on this device.")
            }
            renderer = try CRTRenderer(device: device)
        } catch {
            renderer = nil
            self.error = "Could not start the CRT renderer: \(error.localizedDescription)"
        }
        super.init()
        renderer?.willDraw = { [weak self] renderer in
            if let frame = self?.copyNewPixelBuffer() { renderer.setSource(pixelBuffer: frame) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLoaded, !self.isScrubbing else { return }
                let seconds = self.player.currentTime().seconds
                self.currentTime = seconds.isFinite ? seconds : 0
            }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus != .paused
                UIApplication.shared.isIdleTimerDisabled = self.isPlaying
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if type == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor [weak self] in self?.pause() }
            }
        }
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func open(_ url: URL, autoplay: Bool = true) async {
        guard renderer != nil else {
            error = "Metal rendering is unavailable on this device."
            return
        }
        let request = UUID()
        generation = request
        resetItem()
        isLoading = true
        error = nil
        defer { if generation == request { isLoading = false } }
        let scopedURL = ScopedMediaURL(url)
        do {
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else {
                throw PlayerError("This file cannot be played on iOS. Try an MP4 or MOV with H.264 or HEVC video.")
            }
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            var aspect = 16.0 / 9.0
            var rotation = 0
            if let track = videoTracks.first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                rotation = (Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded()) % 4 + 4) % 4
                let displayed = size.applying(transform)
                if abs(displayed.height) > 0 { aspect = abs(displayed.width / displayed.height) }
            }
            let audio = try await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
            try Task.checkCancellation()
            guard generation == request else { return }
            try await PlaybackAudioSession.shared.activate()
            try Task.checkCancellation()
            guard generation == request else { return }
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)
            let legible = AVPlayerItemLegibleOutput()
            legible.setDelegate(self, queue: .main)
            legible.suppressesPlayerRendering = true
            item.add(legible)
            mediaURL = scopedURL
            videoOutput = output
            legibleOutput = legible
            audioGroup = audio
            subtitleGroup = subtitles
            audioTracks = audio?.options ?? []
            subtitleTracks = subtitles?.options ?? []
            self.duration = duration.seconds.isFinite ? duration.seconds : 0
            title = url.deletingPathExtension().lastPathComponent
            renderer?.displayAspect = aspect
            // Video output supplies stored pixels; the shader applies the display rotation.
            renderer?.rotation = rotation
            if videoTracks.isEmpty { renderer?.setBlankSource() }
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player.currentItem === item else { return }
                    if item.status == .readyToPlay, let group = self.audioGroup {
                        self.selectedAudio = item.currentMediaSelection.selectedMediaOption(in: group)
                    }
                    if item.status == .failed {
                        self.error = item.error?.localizedDescription ?? "This file could not be decoded. Try another video."
                        self.pause()
                        self.isLoaded = false
                    }
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == request else { return }
                    if self.loops { self.seek(to: 0); self.player.play() }
                    else { self.pause(); self.currentTime = self.duration }
                }
            }
            player.replaceCurrentItem(with: item)
            selectedAudio = audio.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
            selectSubtitle(nil)
            isLoaded = true
            renderer?.play(.powerOn)
            if autoplay { player.play() }
        } catch is CancellationError {
            // A new document or disappearing view superseded this load.
        } catch {
            guard generation == request else { return }
            self.error = error.localizedDescription
        }
    }

    func copyNewPixelBuffer() -> CVPixelBuffer? {
        guard let videoOutput else { return nil }
        let time = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: time) else { return nil }
        return videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    func pause() { player.pause(); isPlaying = false; UIApplication.shared.isIdleTimerDisabled = false }
    func togglePlayback() {
        guard isLoaded else { return }
        if isPlaying { pause() }
        else {
            if duration > 0, currentTime >= duration - 0.1 { seek(to: 0) }
            player.play()
        }
    }
    func seek(to time: Double) {
        guard time.isFinite, isLoaded else { return }
        currentTime = min(max(time, 0), duration)
        caption = ""
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func beginScrubbing() { resumeAfterScrubbing = isPlaying; isScrubbing = true; pause() }
    func endScrubbing() { isScrubbing = false; if resumeAfterScrubbing { player.play() } }
    func selectAudio(_ option: AVMediaSelectionOption) {
        guard let audioGroup, audioTracks.contains(option) else { return }
        player.currentItem?.select(option, in: audioGroup)
        selectedAudio = option
    }
    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        guard let subtitleGroup else { return }
        player.currentItem?.select(option, in: subtitleGroup)
        selectedSubtitle = option
        caption = ""
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                  didOutputAttributedStrings strings: [NSAttributedString],
                                  nativeSampleBuffers: [Any], forItemTime time: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n")
        Task { @MainActor [weak self] in
            guard let self, self.legibleOutput === output, self.selectedSubtitle != nil else { return }
            self.caption = text
        }
    }

    private func resetItem() {
        pause()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        legibleOutput = nil
        mediaURL = nil
        audioGroup = nil
        subtitleGroup = nil
        audioTracks = []; subtitleTracks = []
        selectedAudio = nil; selectedSubtitle = nil
        caption = ""; currentTime = 0; duration = 0
        isScrubbing = false; resumeAfterScrubbing = false
        isLoaded = false
        renderer?.clearSource()
    }
}

private struct PlayerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
