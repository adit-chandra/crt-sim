import AVFoundation
import Observation

/// Playback state for one video, observed by the control bar.
@Observable
final class PlayerModel {
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored private let item: AVPlayerItem
    @ObservationIgnored private let videoOutput: AVPlayerItemVideoOutput

    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    /// Display size of the picture (after rotation); nil until loaded or for audio-only files.
    private(set) var videoSize: CGSize?
    /// Quarter turns clockwise needed to show the decoded frames upright.
    private(set) var rotation = 0
    private(set) var loadError: Error?
    /// True once metadata has loaded (or failed), so the window can size itself.
    private(set) var isLoaded = false
    var loops = false

    var volume: Float {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var keyValueObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: Double?
    /// Set when playback stops at the end, so Play starts over.
    @ObservationIgnored private var reachedEnd = false

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        item = AVPlayerItem(asset: asset)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        let defaults = UserDefaults.standard
        volume = defaults.object(forKey: "volume") as? Float ?? 1
        player.volume = volume

        observePlayback()
        tasks.append(Task { [weak self] in await self?.loadMetadata(asset) })
    }

    func invalidate() {
        player.pause()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        keyValueObservations.forEach { $0.invalidate() }
        keyValueObservations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    /// The newest decoded frame, if one is due since the last call.
    func copyNewPixelBuffer() -> CVPixelBuffer? {
        let time = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: time) else { return nil }
        return videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            if reachedEnd {
                seek(to: 0)
            }
            player.play()
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        currentTime = target
        reachedEnd = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        player.pause()
    }

    /// Seeks while dragging, dropping intermediate positions if the decoder falls behind.
    func scrub(to seconds: Double) {
        currentTime = min(max(seconds, 0), duration)
        reachedEnd = false
        pendingSeek = currentTime
        chaseSeek()
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        pendingSeek = nil
        seek(to: currentTime)
        if resumeAfterScrub { player.play() }
    }

    private func chaseSeek() {
        guard !isSeeking, let target = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.chaseSeek()
            }
        }
    }

    // MARK: - Observation

    private func observePlayback() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loops {
                    self.player.seek(to: .zero)
                    self.player.play()
                } else {
                    self.reachedEnd = true
                    self.currentTime = self.duration
                }
            }
        }

        // Each change just triggers a re-read on the main actor, so no update can be lost.
        keyValueObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.syncPlayerState() }
            },
            item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.syncPlayerState() }
            },
        ]
    }

    private func syncPlayerState() {
        isPlaying = player.timeControlStatus != .paused
        if item.status == .failed, loadError == nil {
            loadError = item.error ?? CocoaError(.fileReadCorruptFile)
        }
    }

    private func loadMetadata(_ asset: AVURLAsset) async {
        defer { isLoaded = true }
        do {
            let duration = try await asset.load(.duration)
            self.duration = duration.isNumeric ? duration.seconds : 0
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let quarterTurns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
            rotation = ((quarterTurns % 4) + 4) % 4
            let size = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
            videoSize = rotation % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
        } catch {
            loadError = error
        }
    }
}
