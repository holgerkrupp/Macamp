import Foundation

nonisolated struct PersistedQueueItem: Codable, Equatable, Sendable {
    let id: PlaybackItemID
    let providerItemID: String
    let title: String
    let artist: String?
    let albumTitle: String?
    let durationSeconds: Double?
    let mediaKind: MediaKind
    let sourceURL: URL?

    init(item: PlaybackItem) {
        id = item.id
        providerItemID = item.providerItemID
        title = item.title
        artist = item.artist
        albumTitle = item.albumTitle
        durationSeconds = item.duration?.secondsValue
        mediaKind = item.mediaKind
        sourceURL = item.sourceURL ?? URL(string: item.providerItemID)
    }
}

nonisolated struct PersistedPlaybackSession: Codable, Equatable, Sendable {
    let providerID: PlaybackProviderID
    let items: [PersistedQueueItem]
    let currentIndex: Int?
    let elapsedSeconds: Double?
    let shuffleMode: ShuffleMode
    let repeatMode: RepeatMode

    init(
        providerID: PlaybackProviderID,
        items: [PersistedQueueItem],
        currentIndex: Int?,
        elapsedSeconds: Double?,
        shuffleMode: ShuffleMode,
        repeatMode: RepeatMode
    ) {
        self.providerID = providerID
        self.items = items
        self.currentIndex = currentIndex
        self.elapsedSeconds = elapsedSeconds
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
    }

    init(providerID: PlaybackProviderID, queue: PlaybackQueue, state: PlaybackState) {
        self.init(
            providerID: providerID,
            items: queue.items.map(PersistedQueueItem.init),
            currentIndex: queue.currentIndex,
            elapsedSeconds: state.elapsed.secondsValue,
            shuffleMode: state.shuffleMode,
            repeatMode: state.repeatMode
        )
    }
}

/// Persists the last local playback session outside UserDefaults. File access
/// and JSON work happen on the actor's executor so launch does not block the
/// main actor while a large queue is decoded.
actor PlaybackSessionStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("dev.holgerkrupp.Macamp", isDirectory: true)
                .appendingPathComponent("playback-session.json")
        }
    }

    func save(_ session: PersistedPlaybackSession) {
        do {
            let data = try JSONEncoder().encode(session)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Playback persistence is best effort and must never interrupt audio.
        }
    }

    func load() -> PersistedPlaybackSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedPlaybackSession.self, from: data)
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
    }
}
