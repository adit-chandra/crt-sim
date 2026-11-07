import Foundation

/// A file's place among the playable files in its folder, in Finder's name order.
nonisolated struct MediaFolder {
    let files: [URL]
    let index: Int

    var previous: URL? { index > 0 ? files[index - 1] : nil }
    var next: URL? { index + 1 < files.count ? files[index + 1] : nil }

    /// Lists the folder holding `file`; nil when it can't be read or has nothing
    /// else to play. Runs off the main actor because network volumes can be slow.
    @concurrent static func containing(_ file: URL) async -> MediaFolder? {
        let name = file.lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles)
        else { return nil }
        let files = entries
            .filter {
                $0.lastPathComponent == name || MediaFileTypes.isMedia($0)
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard files.count > 1, let index = files.firstIndex(where: { $0.lastPathComponent == name }) else { return nil }
        return MediaFolder(files: files, index: index)
    }
}
