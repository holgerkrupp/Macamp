import Foundation
import Observation

struct LocalTrackBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var fileName: String
    var positionSeconds: Double
    var securityScopedBookmark: Data

    var displayTitle: String {
        let seconds = Int(positionSeconds)
        return "\(title) — \(String(format: "%d:%02d", seconds / 60, seconds % 60))"
    }
}

enum LocalTrackBookmarkError: Error, LocalizedError {
    case invalidPosition
    case missingFile
    case unreadableBookmark

    var errorDescription: String? {
        switch self {
        case .invalidPosition: "Choose a valid local playback position to bookmark."
        case .missingFile: "This bookmark's audio file is no longer available."
        case .unreadableBookmark: "Macamp could not restore access to this bookmark's file."
        }
    }
}

@MainActor
@Observable
final class LocalTrackBookmarkStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var bookmarks: [LocalTrackBookmark]

    init(defaults: UserDefaults = .standard, key: String = "localTrackBookmarks.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([LocalTrackBookmark].self, from: data) {
            bookmarks = stored
        } else {
            bookmarks = []
        }
    }

    @discardableResult
    func add(fileURL: URL, title: String, positionSeconds: Double) throws -> LocalTrackBookmark {
        guard fileURL.isFileURL, positionSeconds.isFinite, positionSeconds >= 0 else {
            throw LocalTrackBookmarkError.invalidPosition
        }
        let bookmarkData = try fileURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmark = LocalTrackBookmark(
            id: UUID(),
            title: title.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : title,
            fileName: fileURL.lastPathComponent,
            positionSeconds: positionSeconds,
            securityScopedBookmark: bookmarkData
        )
        bookmarks.insert(bookmark, at: 0)
        if bookmarks.count > 100 { bookmarks.removeLast(bookmarks.count - 100) }
        persist()
        return bookmark
    }

    func resolve(_ bookmark: LocalTrackBookmark) throws -> URL {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark.securityScopedBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { throw LocalTrackBookmarkError.unreadableBookmark }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalTrackBookmarkError.missingFile }
        if stale,
           let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
           let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index].securityScopedBookmark = refreshed
            persist()
        }
        return url
    }

    func isAvailable(_ bookmark: LocalTrackBookmark) -> Bool {
        (try? resolve(bookmark)) != nil
    }

    func remove(_ bookmark: LocalTrackBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: key)
    }
}
