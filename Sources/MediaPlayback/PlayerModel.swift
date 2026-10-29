import CMpv
import CoreVideo
import Foundation
import MPVBridge
import Observation

public struct SubtitleTrack: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
}

public struct AudioTrack: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
}

/// One playback clock owns demuxing, decoding, seeking, and subtitle composition.
@Observable
public final class PlayerModel {
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    public private(set) var currentTime: Double = 0
    public private(set) var videoSize: CGSize?
    public private(set) var loadError: Error?
    public private(set) var isLoaded = false
    public private(set) var subtitleTracks: [SubtitleTrack] = []
    public private(set) var selectedSubtitleID: Int64?
    public private(set) var audioTracks: [AudioTrack] = []
    public private(set) var selectedAudioID: Int64?
    public var playbackError: String?
    public var loops = false { didSet { set("loop-file", loops ? "inf" : "no") } }
    public var volume: Float {
        didSet {
            set("volume", String(volume * 100))
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    public var isMuted = false { didSet { set("mute", isMuted ? "yes" : "no") } }

    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private var renderer: OpaquePointer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var subtitleSettingsTask: Task<Void, Never>?
    @ObservationIgnored private var frame: CVPixelBuffer?
    @ObservationIgnored private var hasNewFrame = false
    @ObservationIgnored private var paused = true
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var hasVideo = false
    @ObservationIgnored private var width = 0.0
    @ObservationIgnored private var height = 0.0
    @ObservationIgnored private var rotation = 0.0

    public init(url: URL, subtitleSettings: SubtitleSettingsStore = .shared) {
        volume = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1
        do {
            guard let handle = mpv_create() else { throw PlaybackError("Could not create the media player.") }
            self.handle = handle
            for (name, value) in [
                "config": "no", "load-scripts": "no", "ytdl": "no",
                "vo": "libmpv", "hwdec": "auto", "pause": "yes",
                "keep-open": "yes", "audio-display": "no",
                "input-default-bindings": "no", "input-vo-keyboard": "no",
                "osd-level": "0", "osd-bar": "no", "sub-auto": "exact",
                "volume": String(volume * 100),
            ] {
                try check(mpv_set_option_string(handle, name, value), operation: "Configure playback")
            }
            try check(mpv_initialize(handle), operation: "Start playback")
            for (name, value) in subtitleSettings.settings.mpvOptions { set(name, value) }
            subtitleSettingsTask = Task { [weak self] in
                for await settings in Observations({ subtitleSettings.settings }) {
                    guard !Task.isCancelled else { return }
                    for (name, value) in settings.mpvOptions { self?.set(name, value) }
                }
            }
            for (name, format) in [
                ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                ("pause", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
                ("dwidth", MPV_FORMAT_DOUBLE), ("dheight", MPV_FORMAT_DOUBLE),
                ("video-out-params/rotate", MPV_FORMAT_DOUBLE),
                ("track-list", MPV_FORMAT_NODE), ("sid", MPV_FORMAT_NODE),
            ] {
                try check(mpv_observe_property(handle, 0, name, format), operation: "Observe playback")
            }
            var error: Int32 = 0
            renderer = crt_video_create(handle, &error)
            guard renderer != nil else {
                throw PlaybackError("Could not create the video renderer: \(String(cString: mpv_error_string(error)))")
            }
            // Audio-only files need a canvas for subtitles. Enable it only after
            // the render context exists; doing so at initialization races VO setup.
            set("force-window", "yes")
            command(["loadfile", url.path], request: 1)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            loadError = error
            isLoaded = true
            invalidate()
        }
    }

    isolated deinit { invalidate() }

    public func invalidate() {
        subtitleSettingsTask?.cancel()
        subtitleSettingsTask = nil
        timer?.invalidate()
        timer = nil
        if let renderer { crt_video_free(renderer) }
        renderer = nil
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
        frame = nil
        hasNewFrame = false
        isPlaying = false
    }

    public func copyNewPixelBuffer() -> CVPixelBuffer? {
        guard hasNewFrame else { return nil }
        hasNewFrame = false
        return frame
    }

    public func play() {
        if reachedEnd { seek(to: 0) }
        set("pause", "no")
    }

    public func pause() { set("pause", "yes") }
    public func togglePlayPause() { isPlaying ? pause() : play() }
    public func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = min(max(seconds, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        currentTime = target
        command(["seek", String(target), "absolute+exact"])
    }

    public func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        pause()
    }

    public func scrub(to seconds: Double) {
        // mpv coalesces pending seeks while decoding the latest requested position.
        seek(to: seconds)
    }

    public func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub { set("pause", "no") }
    }

    public func selectSubtitle(_ id: Int64?) {
        guard id == nil || subtitleTracks.contains(where: { $0.id == id }) else { return }
        set("sid", id.map(String.init) ?? "no")
    }

    public func selectAudio(_ id: Int64?) {
        guard id == nil || audioTracks.contains(where: { $0.id == id }) else { return }
        set("aid", id.map(String.init) ?? "no")
    }

    public func addSubtitle(url: URL) {
        command(["sub-add", url.path, "select"], request: 2)
    }

    private func set(_ name: String, _ value: String) {
        command(["set", name, value])
    }

    private func command(_ arguments: [String], request: UInt64 = 0) {
        guard let handle else { return }
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers = strings.map { UnsafePointer($0) } + [nil]
        let result = pointers.withUnsafeMutableBufferPointer { mpv_command_async(handle, request, $0.baseAddress) }
        if result < 0 { report(result, request: request) }
    }

    private func report(_ code: Int32, request: UInt64) {
        let message = String(cString: mpv_error_string(code))
        if request == 1 {
            loadError = PlaybackError(message)
            isLoaded = true
        } else {
            playbackError = request == 2 ? "Could not load subtitles: \(message)" : message
        }
    }

    private func update() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.pointee.data {
                    propertyChanged(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
                }
            case MPV_EVENT_FILE_LOADED:
                isLoaded = true
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        loadError = PlaybackError(String(cString: mpv_error_string(end.error)))
                        isLoaded = true
                        isPlaying = false
                    }
                }
            case MPV_EVENT_COMMAND_REPLY:
                if event.pointee.error < 0 { report(event.pointee.error, request: event.pointee.reply_userdata) }
            default: break
            }
        }
        guard let renderer, loadError == nil else { return }
        let size = videoSize ?? CGSize(width: 960, height: 540)
        var error: Int32 = 0
        if let buffer = crt_video_draw(renderer, Int32(size.width), Int32(size.height), &error) {
            frame = buffer
            hasNewFrame = true
        } else if error < 0 {
            loadError = PlaybackError("Could not render the video: \(String(cString: mpv_error_string(error)))")
            isLoaded = true
            pause()
        }
    }

    private func propertyChanged(_ property: mpv_event_property) {
        guard let data = property.data else { return }
        let name = String(cString: property.name)
        switch name {
        case "time-pos", "duration", "dwidth", "dheight", "video-out-params/rotate":
            let value = data.assumingMemoryBound(to: Double.self).pointee
            guard value.isFinite else { return }
            switch name {
            case "time-pos": if !isScrubbing { currentTime = max(value, 0) }
            case "duration": duration = max(value, 0)
            case "dwidth": width = value; updateVideoSize()
            case "dheight": height = value; updateVideoSize()
            default: rotation = value; updateVideoSize()
            }
        case "pause", "eof-reached":
            let value = data.assumingMemoryBound(to: Int32.self).pointee != 0
            if name == "pause" { paused = value } else { reachedEnd = value }
            isPlaying = !paused && !reachedEnd && loadError == nil
        case "sid":
            selectedSubtitleID = data.assumingMemoryBound(to: mpv_node.self).pointee.integer
        case "track-list":
            let tracks = data.assumingMemoryBound(to: mpv_node.self).pointee.array
            hasVideo = tracks.contains { $0.map["type"]?.string == "video" && $0.map["albumart"]?.flag != true }
            let audio = tracks.map(\.map).filter { $0["type"]?.string == "audio" }
            selectedAudioID = audio.first { $0["selected"]?.flag == true }?["id"]?.integer
            audioTracks = audio.compactMap { info in
                guard let id = info["id"]?.integer else { return nil }
                var parts = ["Track \(id)"]
                parts += [info["title"]?.string, info["lang"]?.string, info["codec"]?.string?.uppercased()]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if let channels = info["demux-channel-count"]?.integer, channels > 0 {
                    parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels")
                }
                if info["default"]?.flag == true { parts.append("Default") }
                return AudioTrack(id: id, title: parts.joined(separator: " · "))
            }
            subtitleTracks = tracks.compactMap { track in
                let info = track.map
                guard info["type"]?.string == "sub", let id = info["id"]?.integer else { return nil }
                var parts = [info["title"]?.string, info["lang"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
                if parts.isEmpty { parts = ["Track \(id)"] }
                if info["forced"]?.flag == true { parts.append("Forced") }
                if info["external"]?.flag == true { parts.append("External") }
                return SubtitleTrack(id: id, title: parts.joined(separator: " · "))
            }
            updateVideoSize()
        default: break
        }
    }

    private func updateVideoSize() {
        guard hasVideo, width > 0, height > 0 else { videoSize = nil; return }
        // Bound render allocations for unusually large sources while retaining aspect ratio.
        let scale = min(1, 8192 / max(width, height))
        let w = max(1, (width * scale).rounded()), h = max(1, (height * scale).rounded())
        // mpv rotates the pixels, but dwidth/dheight describe the unrotated frame.
        let quarterTurn = Int((rotation / 90).rounded()) % 2 != 0
        let size = quarterTurn ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        if videoSize != size { videoSize = size }
    }
}

private struct PlaybackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func check(_ result: Int32, operation: String) throws {
    if result < 0 { throw PlaybackError("\(operation): \(String(cString: mpv_error_string(result)))") }
}

private extension mpv_node {
    var string: String? { format == MPV_FORMAT_STRING ? String(cString: u.string) : nil }
    var integer: Int64? { format == MPV_FORMAT_INT64 ? u.int64 : nil }
    var flag: Bool? { format == MPV_FORMAT_FLAG ? u.flag != 0 : nil }
    var array: [mpv_node] {
        guard format == MPV_FORMAT_NODE_ARRAY, let list = u.list else { return [] }
        return Array(UnsafeBufferPointer(start: list.pointee.values, count: Int(list.pointee.num)))
    }
    var map: [String: mpv_node] {
        guard format == MPV_FORMAT_NODE_MAP, let list = u.list else { return [:] }
        return Dictionary(uniqueKeysWithValues: (0..<Int(list.pointee.num)).map {
            (String(cString: list.pointee.keys[$0]!), list.pointee.values[$0])
        })
    }
}
