import Foundation

enum MediaImportAction: Equatable, Sendable {
    case appendToQueue
    case insertNext
    case replaceAndPlay
    case addToLibrary
}

struct MediaImportResult: Sendable {
    var items: [PlaybackItem] = []
    var warnings: [String] = []
}

/// The shared entry point for files, folders, playlists, and dropped URLs.
/// Queue commands and library imports remain explicit separate operations.
@MainActor
final class MediaImportService {
    private let playback: PlaybackCoordinator
    private let localMedia: LocalFilePlaybackProvider

    init(playback: PlaybackCoordinator, localMedia: LocalFilePlaybackProvider) {
        self.playback = playback
        self.localMedia = localMedia
    }

    func importURLs(_ urls: [URL], action: MediaImportAction) async -> MediaImportResult {
        guard !urls.isEmpty else { return MediaImportResult() }

        if action == .addToLibrary {
            let items = await localMedia.importURLs(urls)
            return MediaImportResult(items: items)
        }

        let report = await localMedia.importQueueItems(from: urls)
        guard !report.items.isEmpty else {
            return MediaImportResult(warnings: report.warnings)
        }

        switch action {
        case .appendToQueue:
            guard await playback.addQueueItems(report.items, placement: .append, to: .localMedia) else {
                return MediaImportResult(items: [], warnings: report.warnings + ["Could not add the imported items to the Local Files queue."])
            }
        case .insertNext:
            guard await playback.addQueueItems(report.items, placement: .next, to: .localMedia) else {
                return MediaImportResult(items: [], warnings: report.warnings + ["Could not insert the imported items into the Local Files queue."])
            }
        case .replaceAndPlay:
            playback.activate(.localMedia)
            await playback.play(items: report.items, startingAt: 0)
        case .addToLibrary:
            break
        }
        var warnings = report.warnings
        if playback.activeProviderID != .localMedia, action != .replaceAndPlay {
            warnings.append("Added to the Local Files queue. Switch to Local Files to play it; current provider playback was left unchanged.")
        }
        return MediaImportResult(items: report.items, warnings: warnings)
    }
}
