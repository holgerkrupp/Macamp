import AVFoundation
import Foundation

struct LocalMediaImportReport: Sendable {
    var items: [PlaybackItem]
    var locations: [PlaybackItemID: URL]
    var warnings: [String]
}

enum LocalMediaImporter {
    static let mediaExtensions: Set<String> = ["mp3"]
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    static func importURLs(_ urls: [URL]) async -> LocalMediaImportReport {
        var candidates: [M3UPlaylistEntry] = []
        var warnings: [String] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let scanned = scanDirectory(url)
                for playlistURL in scanned.playlists {
                    appendPlaylist(playlistURL, candidates: &candidates, warnings: &warnings)
                }
                candidates.append(contentsOf: scanned.media.map { M3UPlaylistEntry(url: $0) })
            } else if playlistExtensions.contains(url.pathExtension.lowercased()) {
                appendPlaylist(url, candidates: &candidates, warnings: &warnings)
            } else if isSupportedMediaURL(url) {
                candidates.append(M3UPlaylistEntry(url: url))
            } else {
                warnings.append("Skipped unsupported file: \(url.lastPathComponent)")
            }
        }

        var seen: Set<URL> = []
        var items: [PlaybackItem] = []
        var locations: [PlaybackItemID: URL] = [:]
        for candidate in candidates where seen.insert(candidate.url).inserted {
            do {
                let item = try await makeItem(candidate)
                items.append(item)
                locations[item.id] = candidate.url
            } catch {
                warnings.append("Could not read \(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return LocalMediaImportReport(items: items, locations: locations, warnings: warnings)
    }

    private static func appendPlaylist(
        _ playlistURL: URL,
        candidates: inout [M3UPlaylistEntry],
        warnings: inout [String]
    ) {
        do {
            let playlist = try M3UPlaylistParser.parse(data: Data(contentsOf: playlistURL), playlistURL: playlistURL)
            if playlist.isHLS {
                candidates.append(M3UPlaylistEntry(url: playlistURL, title: playlistURL.deletingPathExtension().lastPathComponent))
            } else {
                let supported = playlist.entries.filter { isSupportedMediaURL($0.url) }
                candidates.append(contentsOf: supported)
                let skipped = playlist.entries.count - supported.count
                if skipped > 0 { warnings.append("Skipped \(skipped) unsupported entries in \(playlistURL.lastPathComponent).") }
            }
        } catch {
            warnings.append("Could not read \(playlistURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func scanDirectory(_ directory: URL) -> (media: [URL], playlists: [URL]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], []) }
        var media: [URL] = []
        var playlists: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if mediaExtensions.contains(ext) { media.append(url) }
            else if playlistExtensions.contains(ext) { playlists.append(url) }
        }
        return (media.sorted { $0.path < $1.path }, playlists.sorted { $0.path < $1.path })
    }

    private static func isSupportedMediaURL(_ url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) { return true }
        return url.isFileURL && mediaExtensions.contains(url.pathExtension.lowercased())
    }

    private static func makeItem(_ entry: M3UPlaylistEntry) async throws -> PlaybackItem {
        let asset = AVURLAsset(url: entry.url)
        let durationTime = try? await asset.load(.duration)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let metadataTitle = await stringValue(for: .commonKeyTitle, in: metadata)
        let metadataArtist = await stringValue(for: .commonKeyArtist, in: metadata)
        let album = await stringValue(for: .commonKeyAlbumName, in: metadata)
        let artworkData = await dataValue(for: .commonKeyArtwork, in: metadata)
        let duration: Duration? = entry.duration ?? durationTime.flatMap { time in
            let seconds = time.seconds
            return seconds.isFinite && seconds >= 0 ? .seconds(seconds) : nil
        }
        let rawID = entry.url.absoluteString
        let itemID = PlaybackItemID(rawValue: "local:\(rawID)")
        return PlaybackItem(
            id: itemID,
            providerID: .localMedia,
            providerItemID: rawID,
            title: entry.title ?? metadataTitle ?? entry.url.deletingPathExtension().lastPathComponent,
            artist: entry.artist ?? metadataArtist,
            albumTitle: album,
            duration: duration,
            artwork: artworkData.map(ArtworkReference.embedded) ?? .systemSymbol("music.note"),
            mediaKind: entry.url.pathExtension.lowercased() == "m3u8" ? .radioStation : .localFile,
            isExplicit: false
        )
    }

    private static func stringValue(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func dataValue(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else { return nil }
        return try? await item.load(.dataValue)
    }
}
