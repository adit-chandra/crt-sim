import CoreVideo
import CRTCore
import Foundation
import ImageIO
import MediaPlayback
import Metal
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct PlaybackTests {
    @Test func matroskaTracksSeekAndCRT() async throws {
        let model = PlayerModel(url: fixture("tracks.mkv"), subtitleSettings: .init(defaults: nil))
        defer { model.invalidate() }
        model.isMuted = true
        try #require(model.loadError == nil, "Initialization: \(String(describing: model.loadError))")
        try await wait { model.isLoaded }
        try #require(model.loadError == nil)
        try await wait { model.subtitleTracks.count == 2 && model.videoSize == CGSize(width: 640, height: 360) }
        #expect(model.loadError == nil)
        #expect(model.videoSize == CGSize(width: 640, height: 360))
        #expect(model.subtitleTracks[0].title.contains("English"))
        #expect(model.subtitleTracks[1].title.contains("jpn"))
        #expect(model.duration > 5.9)

        model.selectSubtitle(model.subtitleTracks[0].id)
        model.seek(to: 1.5)
        let caption = try await frame(model) { pixels($0, kind: .white) > 100 }
        #expect(pixels(caption, kind: .redTop) > 10_000, "Video must remain upright and in BGRA order")

        let device = try #require(MTLCreateSystemDefaultDevice())
        let crt = try CRTRenderer(device: device)
        crt.setSource(pixelBuffer: caption)
        crt.displayAspect = 16.0 / 9
        let image = try #require(crt.renderImage(width: 640, height: 360))
        try save(image, name: "crt-subtitles.png")
        crt.isEnabled = false
        let bypass = try #require(crt.renderImage(width: 640, height: 360))
        try save(bypass, name: "plain-subtitles.png")
        #expect(image.dataProvider?.data != bypass.dataProvider?.data)

        model.selectSubtitle(nil)
        _ = try await frame(model) { pixels($0, kind: .white) == 0 && pixels($0, kind: .redTop) > 10_000 }
        try await wait { model.selectedSubtitleID == nil }
        model.selectSubtitle(model.subtitleTracks[1].id)
        _ = try await frame(model) { pixels($0, kind: .green) > 100 }
        model.seek(to: 0.5)
        _ = try await frame(model) { pixels($0, kind: .green) == 0 && pixels($0, kind: .redTop) > 10_000 }
        model.seek(to: 3.5)
        _ = try await frame(model) { pixels($0, kind: .green) > 100 }
        #expect(model.playbackError == nil)
    }

    @Test func mp4CaptionsAndTransport() async throws {
        let model = PlayerModel(url: fixture("tracks.mp4"), subtitleSettings: .init(defaults: nil))
        defer { model.invalidate() }
        model.isMuted = true
        try #require(model.loadError == nil, "Initialization: \(String(describing: model.loadError))")
        try await wait { model.isLoaded && model.subtitleTracks.count == 1 }
        model.selectSubtitle(model.subtitleTracks[0].id)
        model.seek(to: 1.5)
        _ = try await frame(model) { pixels($0, kind: .white) > 100 }
        model.play()
        try await wait { model.isPlaying && model.currentTime > 1.7 }
        model.beginScrubbing()
        model.scrub(to: 3.5)
        _ = try await frame(model) { pixels($0, kind: .white) > 100 }
        model.endScrubbing()
        try await wait { model.isPlaying && model.currentTime > 3.6 }
        model.pause()
        try await wait { !model.isPlaying }
        model.loops = true
        model.seek(to: 5.8)
        model.play()
        try await wait { model.currentTime < 1 && model.isPlaying }
        model.loops = false
        model.seek(to: 5.8)
        try await wait { !model.isPlaying && model.currentTime > 5.8 }
        model.play()
        try await wait { model.isPlaying && model.currentTime < 1 }
        #expect(model.loadError == nil)
        #expect(model.playbackError == nil)
    }

    @Test func audioOnlyEmbeddedAndExternalSubtitles() async throws {
        for name in ["audio.mka", "audio.m4a"] {
            let model = PlayerModel(url: fixture(name), subtitleSettings: .init(defaults: nil))
            defer { model.invalidate() }
            model.isMuted = true
            try #require(model.loadError == nil, "Initialization: \(String(describing: model.loadError))")
            try await wait { model.isLoaded }
            #expect(model.loadError == nil)
            if name == "audio.m4a" {
                model.addSubtitle(url: fixture("english.srt"))
            }
            try await wait { model.subtitleTracks.count == 1 }
            model.selectSubtitle(model.subtitleTracks[0].id)
            model.seek(to: 1.5)
            _ = try await frame(model) { pixels($0, kind: .white) > 100 }
            #expect(model.videoSize == nil)
            model.selectSubtitle(nil)
            _ = try await frame(model) { pixels($0, kind: .white) == 0 }
            model.addSubtitle(url: fixture("missing.srt"))
            try await wait { model.playbackError != nil }
            #expect(model.loadError == nil, "A bad subtitle should not close the media")
        }
    }

    @Test func missingMediaFailsAndCloseIsIdempotent() async throws {
        let model = PlayerModel(url: fixture("missing.mkv"), subtitleSettings: .init(defaults: nil))
        try await wait { model.loadError != nil }
        #expect(model.isLoaded)
        model.invalidate()
        model.invalidate()
        #expect(!model.isPlaying)
    }

    @Test func rotationAndIndependentWindows() async throws {
        let first = PlayerModel(url: fixture("tracks.mkv"), subtitleSettings: .init(defaults: nil))
        let second = PlayerModel(url: fixture("rotated.mp4"), subtitleSettings: .init(defaults: nil))
        defer { first.invalidate(); second.invalidate() }
        first.isMuted = true
        second.isMuted = true
        try await wait { first.isLoaded && second.isLoaded && first.subtitleTracks.count == 2 }
        try await wait { second.videoSize == CGSize(width: 360, height: 640) }
        first.selectSubtitle(nil)
        second.addSubtitle(url: fixture("english.srt"))
        try await wait { second.subtitleTracks.count == 1 && second.selectedSubtitleID != nil }
        #expect(first.selectedSubtitleID == nil)
        second.seek(to: 1.5)
        _ = try await frame(second) { pixels($0, kind: .white) > 100 }
        first.invalidate()
        second.play()
        try await wait { second.currentTime > 1.7 }
        #expect(second.loadError == nil)
    }

    @Test func matchingSidecarIsDiscovered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("sample.m4a")
        try FileManager.default.copyItem(at: fixture("audio.m4a"), to: audio)
        try FileManager.default.copyItem(at: fixture("english.srt"), to: directory.appendingPathComponent("sample.srt"))
        let model = PlayerModel(url: audio, subtitleSettings: .init(defaults: nil))
        defer { model.invalidate() }
        model.isMuted = true
        try await wait { model.subtitleTracks.count == 1 }
        #expect(model.subtitleTracks[0].title.contains("External"))
        model.selectSubtitle(model.subtitleTracks[0].id)
        model.seek(to: 1.5)
        _ = try await frame(model) { pixels($0, kind: .white) > 100 }
    }

    @Test func subtitleAppearanceUpdatesRenderedFrames() async throws {
        let settings = SubtitleSettingsStore(defaults: nil)
        let model = PlayerModel(url: fixture("tracks.mkv"), subtitleSettings: settings)
        defer { model.invalidate() }
        model.isMuted = true
        try await wait { model.isLoaded && model.subtitleTracks.count == 2 }
        model.selectSubtitle(model.subtitleTracks[0].id)
        model.seek(to: 1.5)
        let normal = try await frame(model) { pixels($0, kind: .white) > 100 }
        let normalCount = pixels(normal, kind: .white)

        settings.settings.scale = 1.8
        _ = try await frame(model) { pixels($0, kind: .white) > normalCount * 2 }
        settings.settings.color = .init(red: 0, green: 1, blue: 0)
        _ = try await frame(model) { pixels($0, kind: .green) > 100 && pixels($0, kind: .white) == 0 }

        settings.settings = SubtitleSettings()
        _ = try await frame(model) { pixels($0, kind: .white) == normalCount }
        settings.settings.bold = true
        settings.settings.italic = true
        settings.settings.font = "serif"
        _ = try await frame(model) { pixels($0, kind: .white) > 100 && pixels($0, kind: .white) != normalCount }

        // The ASS fixture is green. User colors must not replace authored styles
        // until requested, and turning the override off must restore them.
        settings.settings = SubtitleSettings()
        model.selectSubtitle(model.subtitleTracks[1].id)
        _ = try await frame(model) { pixels($0, kind: .green) > 100 }
        settings.settings.overrideEmbeddedStyles = true
        _ = try await frame(model) { pixels($0, kind: .white) > 100 && pixels($0, kind: .green) == 0 }
        settings.settings.overrideEmbeddedStyles = false
        _ = try await frame(model) { pixels($0, kind: .green) > 100 && pixels($0, kind: .white) == 0 }

        // Also update captions while the clock and video are advancing.
        model.loops = true
        model.play()
        try await wait { model.isPlaying && model.currentTime > 1.7 }
        settings.settings.overrideEmbeddedStyles = true
        settings.settings.backgroundOpacity = 0.6
        settings.settings.outlineSize = 3
        settings.settings.shadow = true
        _ = try await frame(model) { pixels($0, kind: .white) > 100 }
        model.selectSubtitle(nil)
        _ = try await frame(model) { pixels($0, kind: .white) == 0 && pixels($0, kind: .green) == 0 }
        #expect(model.isPlaying)
        #expect(model.playbackError == nil)
    }

    @Test func subtitleAppearancePersistsAndReachesAllPlayers() async throws {
        let suite = "CRTSubtitleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SubtitleSettingsStore(defaults: defaults)
        store.settings.scale = 1.5
        store.settings.bold = true
        #expect(SubtitleSettingsStore(defaults: defaults).settings == store.settings)

        let first = PlayerModel(url: fixture("tracks.mp4"), subtitleSettings: store)
        let second = PlayerModel(url: fixture("tracks.mp4"), subtitleSettings: store)
        defer { first.invalidate(); second.invalidate() }
        for model in [first, second] {
            model.isMuted = true
            try await wait { model.isLoaded && model.subtitleTracks.count == 1 }
            model.selectSubtitle(model.subtitleTracks[0].id)
            model.seek(to: 1.5)
            _ = try await frame(model) { pixels($0, kind: .white) > 100 }
        }
        store.settings.color = .init(red: 0, green: 1, blue: 0)
        for model in [first, second] {
            _ = try await frame(model) { pixels($0, kind: .green) > 100 && pixels($0, kind: .white) == 0 }
            #expect(model.playbackError == nil)
        }
        #expect(SubtitleSettingsStore(defaults: defaults).settings == store.settings)
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting for playback state")
    }

    private func frame(_ model: PlayerModel, matching condition: (CVPixelBuffer) -> Bool) async throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try await wait {
            if let buffer = model.copyNewPixelBuffer(), condition(buffer) { result = buffer }
            return result != nil || model.loadError != nil
        }
        #expect(model.loadError == nil)
        return try #require(result)
    }

    private enum PixelKind { case white, green, redTop }
    private func pixels(_ buffer: CVPixelBuffer, kind: PixelKind) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rows = kind == .redTop ? 0..<(height / 4) : (height * 2 / 3)..<height
        var count = 0
        for y in rows {
            for x in 0..<width {
                let i = y * stride + x * 4
                let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2]
                switch kind {
                case .white: if r > 150 && g > 150 && b > 150 { count += 1 }
                case .green: if g > 150 && r < 100 && b < 100 { count += 1 }
                case .redTop: if r > 150 && g < 100 && b < 100 { count += 1 }
                }
            }
        }
        return count
    }

    private func save(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CRT_TEST_ARTIFACTS"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
