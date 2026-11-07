import AppKit
import MediaPlayback
import SwiftUI
import Testing
@testable import CRTPlayer

@Suite(.serialized)
struct FolderPlaybackTests {
    @Test func listsPlayableFilesInFinderOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Episode 10.mkv", "Episode 2.mp4", "Episode 1.mov", "Episode 1.srt", "notes.txt",
                     ".hidden.mp4", "song.m4a"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Extras.mp4"),
                                                withIntermediateDirectories: false)

        let middle = try #require(await MediaFolder.containing(directory.appendingPathComponent("Episode 2.mp4")))
        #expect(middle.files.map(\.lastPathComponent) == ["Episode 1.mov", "Episode 2.mp4", "Episode 10.mkv", "song.m4a"])
        #expect(middle.previous?.lastPathComponent == "Episode 1.mov")
        #expect(middle.next?.lastPathComponent == "Episode 10.mkv")

        let first = try #require(await MediaFolder.containing(directory.appendingPathComponent("Episode 1.mov")))
        #expect(first.previous == nil)
        let last = try #require(await MediaFolder.containing(directory.appendingPathComponent("song.m4a")))
        #expect(last.next == nil)
    }

    @Test func fileAloneInItsFolderHasNoNeighbors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Movie.mp4", "Movie.srt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        #expect(await MediaFolder.containing(directory.appendingPathComponent("Movie.mp4")) == nil)
    }

    @Test func endOfVideoOffersNextFileAndPlaysItInTheSameWindow() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (fixture, name) in [("tracks.mp4", "Episode 1.mp4"), ("rotated.mp4", "Episode 2.mp4")] {
            let source = try #require(Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }

        let model = PlayerModel(url: directory.appendingPathComponent("Episode 1.mp4"),
                                subtitleSettings: .init(defaults: nil))
        model.isMuted = true
        let controller = PlayerWindowController.playing(model)
        let window = try #require(controller.window)
        defer { window.close(); model.invalidate() }
        let content = try #require(window.contentView.flatMap {
            $0 as? PlayerContentView ?? $0.subviews.compactMap { $0 as? PlayerContentView }.first
        })
        let controls = try #require(content.subviews.compactMap { $0 as? NSHostingView<ControlBar?> }.first)
        let upNext = try #require(content.subviews.compactMap { $0 as? NSHostingView<UpNextCard?> }.first)
        var bar: ControlBar? { controls.rootView }

        try await wait { model.isLoaded && bar?.chrome.folder != nil }
        #expect(bar?.chrome.folder?.next?.lastPathComponent == "Episode 2.mp4")
        #expect(upNext.isHidden, "Nothing is offered before the video ends")

        model.seek(to: model.duration - 0.3)
        model.play()
        try await wait { model.reachedEnd && !upNext.isHidden }
        #expect(upNext.rootView?.file.lastPathComponent == "Episode 2.mp4")
        content.layoutSubtreeIfNeeded()
        #expect(abs(upNext.frame.maxX - (content.bounds.maxX - 20)) < 1, "Up Next sits at the right edge")
        #expect(upNext.frame.minY >= controls.frame.maxY + 11, "Up Next clears the control bar")
        #expect(abs(controls.frame.minY - 20) < 1, "Up Next doesn't displace the control bar")

        upNext.rootView?.play()
        let second = try #require(bar?.model)
        #expect(second !== model)
        #expect(second.url.lastPathComponent == "Episode 2.mp4")
        #expect(second.isMuted, "Mute carries over to the next file")
        #expect(upNext.isHidden)
        try await wait { second.isLoaded && bar?.chrome.folder != nil }
        #expect(second.loadError == nil)
        #expect(bar?.chrome.folder?.previous?.lastPathComponent == "Episode 1.mp4")
        #expect(bar?.chrome.folder?.next == nil)

        controller.playPreviousInFolder(nil)
        let third = try #require(bar?.model)
        #expect(third.url.lastPathComponent == "Episode 1.mp4")
        try await wait { third.isLoaded }
        #expect(third.loadError == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting for playback state")
    }
}
