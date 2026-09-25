import Foundation

@MainActor
final class LocalMediaBookmarkStore {
    private let defaults: UserDefaults
    private let key = "localMediaSecurityScopedBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func add(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var bookmarks = defaults.array(forKey: key) as? [Data] ?? []
        guard !bookmarks.contains(data) else { return }
        bookmarks.append(data)
        defaults.set(bookmarks, forKey: key)
    }

    func resolveAll() -> [URL] {
        let bookmarks = defaults.array(forKey: key) as? [Data] ?? []
        var refreshed: [Data] = []
        var urls: [URL] = []
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            urls.append(url)
            if stale, let replacement = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshed.append(replacement)
            } else {
                refreshed.append(data)
            }
        }
        if refreshed != bookmarks { defaults.set(refreshed, forKey: key) }
        return urls
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
    }
}
