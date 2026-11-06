import AVFoundation
import CRTCore
import Testing
@testable import CRTSimiOS

@MainActor
@Suite(.serialized)
struct IOSPlaybackTests {
    @Test func decodesSeeksAndRendersThroughSharedCRT() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("tracks.mp4"), autoplay: false)
        defer { model.pause() }
        #expect(model.error == nil)
        #expect(model.isLoaded)
        #expect(model.duration > 2)
        let first = try await frame(model)
        let renderer = try #require(model.renderer)
        renderer.setSource(pixelBuffer: first)
        // Finish the power-on transition before comparing the CRT and bypass.
        let now = CACurrentMediaTime() + 1
        renderer.isEnabled = false
        let plain = try #require(renderer.renderImage(width: 320, height: 180, time: now))
        renderer.isEnabled = true
        let crt = try #require(renderer.renderImage(width: 320, height: 180, time: now))
        #expect(plain.dataProvider?.data != crt.dataProvider?.data)
        model.seek(to: 1.5)
        _ = try await frame(model)
        #expect(abs(model.currentTime - 1.5) < 0.3)
        #expect(!model.isPlaying)
        model.togglePlayback()
        try await wait { model.isPlaying && model.currentTime > 1.7 }
        model.pause()
        #expect(!model.isPlaying)
    }

    @Test func rotatedVideoHasPortraitGeometry() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("rotated.mp4"), autoplay: false)
        let buffer = try await frame(model)
        #expect(model.error == nil)
        #expect(try #require(model.renderer).displayAspect < 1)
        // Stored landscape pixels must be rotated once when shown in the portrait tube.
        #expect(CVPixelBufferGetWidth(buffer) > CVPixelBufferGetHeight(buffer))
        #expect(try #require(model.renderer).rotation % 2 == 1)
    }

    @Test func audioSelectionAndReplacementReleaseOldPlayback() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("audio-tracks.m4a"), autoplay: false)
        #expect(model.error == nil)
        #expect(model.audioTracks.count >= 2)
        let alternate = try #require(model.audioTracks.last)
        model.selectAudio(alternate)
        #expect(model.selectedAudio == alternate)
        model.seek(to: 1)
        model.togglePlayback()
        try await wait { model.isPlaying }
        await model.open(fixture("tracks.mp4"), autoplay: false)
        #expect(!model.isPlaying)
        #expect(model.title == "tracks")
        #expect(model.currentTime < 0.3)
        _ = try await frame(model)
    }

    @Test func embeddedCaptionsCanBeSelectedAndDisabled() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("tracks.mp4"), autoplay: false)
        defer { model.pause() }
        let track = try #require(model.subtitleTracks.first)
        model.selectSubtitle(track)
        model.seek(to: 1.2)
        model.togglePlayback()
        try await wait { model.caption.contains("ENGLISH SUBTITLE") }
        model.selectSubtitle(nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.caption.isEmpty)
        #expect(model.selectedSubtitle == nil)
    }

    @Test func loopingRestartsPlayback() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("tracks.mp4"), autoplay: false)
        defer { model.pause() }
        _ = try await frame(model)
        model.loops = true
        model.seek(to: model.duration - 0.3)
        model.togglePlayback()
        try await wait { model.isPlaying && model.currentTime > 0 && model.currentTime < 1 }
    }

    @Test func failedOpenClearsTransportAndReportsError() async throws {
        let model = IOSPlayerModel()
        await model.open(fixture("tracks.mp4"), autoplay: false)
        await model.open(URL(fileURLWithPath: "/missing-crt-video.mp4"))
        #expect(!model.isLoaded)
        #expect(!model.isLoading)
        #expect(!model.isPlaying)
        #expect(model.error != nil)
        #expect(model.duration == 0)
    }

    private func fixture(_ name: String) -> URL {
        Bundle(for: BundleMarker.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
    private func frame(_ model: IOSPlayerModel) async throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try await wait { result = model.copyNewPixelBuffer(); return result != nil }
        return try #require(result)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !predicate() {
            if ContinuousClock.now > deadline { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}

private final class BundleMarker: NSObject {}
private struct TestTimeout: Error {}
