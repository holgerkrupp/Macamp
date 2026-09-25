import Foundation

struct M3UPlaylist: Equatable, Sendable {
    var entries: [M3UPlaylistEntry]
    var isHLS: Bool
}

struct M3UPlaylistEntry: Equatable, Sendable {
    var url: URL
    var title: String?
    var artist: String?
    var duration: Duration?
}

enum M3UPlaylistParser {
    static func parse(data: Data, playlistURL: URL) throws -> M3UPlaylist {
        guard let contents = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else {
            throw ProviderError(code: .invalidResponse, message: "The playlist is not valid UTF-8 or Windows-1252 text.")
        }
        return parse(contents, playlistURL: playlistURL)
    }

    static func parse(_ contents: String, playlistURL: URL) -> M3UPlaylist {
        let lines = contents.components(separatedBy: .newlines)
        let isHLS = lines.contains { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return normalized.hasPrefix("#EXT-X-")
        }
        guard !isHLS else { return M3UPlaylist(entries: [], isHLS: true) }

        var entries: [M3UPlaylistEntry] = []
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: Duration?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                let value = String(line.dropFirst(8))
                let fields = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                if let seconds = fields.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), seconds >= 0 {
                    pendingDuration = .seconds(seconds)
                }
                if fields.count == 2 {
                    let display = fields[1].trimmingCharacters(in: .whitespaces)
                    let parts = display.components(separatedBy: " - ")
                    if parts.count > 1 {
                        pendingArtist = parts[0]
                        pendingTitle = parts.dropFirst().joined(separator: " - ")
                    } else if !display.isEmpty {
                        pendingTitle = display
                    }
                }
                continue
            }
            guard !line.hasPrefix("#"), let url = resolvedURL(line, relativeTo: playlistURL) else { continue }
            entries.append(M3UPlaylistEntry(
                url: url,
                title: pendingTitle,
                artist: pendingArtist,
                duration: pendingDuration
            ))
            pendingTitle = nil
            pendingArtist = nil
            pendingDuration = nil
        }
        return M3UPlaylist(entries: entries, isHLS: false)
    }

    private static func resolvedURL(_ value: String, relativeTo playlistURL: URL) -> URL? {
        if let absolute = URL(string: value), let scheme = absolute.scheme?.lowercased() {
            guard ["file", "http", "https"].contains(scheme) else { return nil }
            return scheme == "file" ? absolute.standardizedFileURL : absolute
        }
        let decoded = value.removingPercentEncoding ?? value
        return URL(fileURLWithPath: decoded, relativeTo: playlistURL.deletingLastPathComponent()).standardizedFileURL
    }
}
