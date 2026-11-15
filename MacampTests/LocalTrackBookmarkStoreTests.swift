import Foundation
import Testing
@testable import Macamp

@Suite(.serialized)
@MainActor
struct LocalTrackBookmarkStoreTests {
    @Test func bookmarksRestoreFileAccessAndPlaybackPosition() throws {
        let suite = "MacampLocalTrackBookmarks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bookmarked.mp3")
        try Data([0xff, 0xfb, 0x90, 0x64]).write(to: file)

        let store = LocalTrackBookmarkStore(defaults: defaults)
        let saved = try store.add(fileURL: file, title: "Saved Track", positionSeconds: 83.5)
        let restoredStore = LocalTrackBookmarkStore(defaults: defaults)
        let restored = try #require(restoredStore.bookmarks.first)
        let url = try restoredStore.resolve(restored)

        #expect(restored.id == saved.id)
        #expect(restored.displayTitle == "Saved Track — 1:23")
        #expect(restored.positionSeconds == 83.5)
        #expect(url.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func missingBookmarkFileReturnsAnActionableError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("missing.mp3")
        try Data([0xff, 0xfb]).write(to: file)
        let store = LocalTrackBookmarkStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let bookmark = try store.add(fileURL: file, title: "Missing", positionSeconds: 2)
        try FileManager.default.removeItem(at: file)

        #expect(throws: LocalTrackBookmarkError.self) { try store.resolve(bookmark) }
    }
}
