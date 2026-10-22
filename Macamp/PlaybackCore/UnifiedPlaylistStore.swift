import Foundation
import Observation

enum PlaylistEntryAvailability: String, Codable, Sendable {
    case queued
    case playableNow
    case requiresConnectionOrDevice
    case requiresFileAccess
    case unsupportedByProviderPolicy
}

struct UnifiedPlaylistEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let providerID: PlaybackProviderID
    let providerItemID: String
    var title: String
    var artist: String?
    var albumTitle: String?
    var durationSeconds: Double?
    var mediaKind: MediaKind
    var isExplicit: Bool
    var sourceURL: URL?
    var attribution: String?
    var artworkURL: URL?
    var artworkSymbol: String?
    var fileExtension: String?
    var bitrateKbps: Int?
    var sampleRateHz: Int?
    var channelCount: Int?

    init(id: UUID = UUID(), item: PlaybackItem) {
        self.id = id
        providerID = item.providerID
        providerItemID = item.providerItemID
        title = item.title
        artist = item.artist
        albumTitle = item.albumTitle
        durationSeconds = item.duration?.secondsValue
        mediaKind = item.mediaKind
        isExplicit = item.isExplicit
        sourceURL = item.sourceURL ?? URL(string: item.providerItemID)
        attribution = item.attribution
        switch item.artwork {
        case let .remote(url): artworkURL = url; artworkSymbol = nil
        case let .systemSymbol(symbol): artworkURL = nil; artworkSymbol = symbol
        case .embedded, .none: artworkURL = nil; artworkSymbol = "music.note"
        }
        fileExtension = item.fileExtension
        bitrateKbps = item.bitrateKbps
        sampleRateHz = item.sampleRateHz
        channelCount = item.channelCount
    }

    var playbackItem: PlaybackItem {
        var item = PlaybackItem(
            id: PlaybackItemID(rawValue: "playlist:\(id.uuidString)"),
            providerID: providerID,
            providerItemID: providerItemID,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            duration: durationSeconds.map(Duration.seconds),
            artwork: artworkURL.map(ArtworkReference.remote) ?? .systemSymbol(artworkSymbol ?? "music.note"),
            mediaKind: mediaKind,
            isExplicit: isExplicit,
            sourceURL: sourceURL,
            attribution: attribution
        )
        item.fileExtension = fileExtension
        item.bitrateKbps = bitrateKbps
        item.sampleRateHz = sampleRateHz
        item.channelCount = channelCount
        return item
    }
}

/// The single app-owned playlist shown by native and skinned queue editors.
/// It stores provider IDs and safe display metadata, never provider SDK objects.
@MainActor
@Observable
final class UnifiedPlaylistStore {
    private(set) var entries: [UnifiedPlaylistEntry]
    private(set) var currentEntryID: UUID?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "unifiedPlaylist.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            entries = state.entries
            currentEntryID = state.currentEntryID
        } else {
            entries = []
            currentEntryID = nil
        }
        if let currentEntryID, !entries.contains(where: { $0.id == currentEntryID }) {
            self.currentEntryID = nil
        }
    }

    var queue: PlaybackQueue {
        let items = entries.map(\.playbackItem)
        let currentIndex = currentEntryID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
        return PlaybackQueue(items: items, currentIndex: currentIndex)
    }

    var currentIndex: Int? { currentEntryID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } }

    @discardableResult
    func append(_ items: [PlaybackItem]) -> [UUID] {
        let added = items.map { UnifiedPlaylistEntry(item: $0) }
        entries.append(contentsOf: added)
        persist()
        return added.map(\.id)
    }

    @discardableResult
    func insertNext(_ items: [PlaybackItem]) -> [UUID] {
        let added = items.map { UnifiedPlaylistEntry(item: $0) }
        let insertionIndex = currentIndex.map { $0 + 1 } ?? 0
        entries.insert(contentsOf: added, at: insertionIndex)
        persist()
        return added.map(\.id)
    }

    func replace(with items: [PlaybackItem], selecting index: Int? = nil) {
        entries = items.map { UnifiedPlaylistEntry(item: $0) }
        currentEntryID = index.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
        persist()
    }

    func select(_ id: UUID?) {
        let next = id.flatMap { selected in entries.contains(where: { $0.id == selected }) ? selected : nil }
        guard currentEntryID != next else { return }
        currentEntryID = next
        persist()
    }

    func remove(at offsets: IndexSet) {
        let removedCurrent = currentIndex.map(offsets.contains) ?? false
        let oldCurrent = currentIndex ?? 0
        entries = entries.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        if removedCurrent {
            let target = min(max(0, oldCurrent - offsets.filter { $0 < oldCurrent }.count), entries.count - 1)
            currentEntryID = entries.indices.contains(target) ? entries[target].id : nil
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        currentEntryID = nil
        persist()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let currentID = currentEntryID
        let moving = offsets.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        entries = entries.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), entries.count)
        entries.insert(contentsOf: moving, at: insertionIndex)
        currentEntryID = currentID
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(PersistedState(entries: entries, currentEntryID: currentEntryID)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private struct PersistedState: Codable {
        var entries: [UnifiedPlaylistEntry]
        var currentEntryID: UUID?
    }
}
