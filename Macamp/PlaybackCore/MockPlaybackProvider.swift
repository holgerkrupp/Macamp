import Foundation

@MainActor
final class MockPlaybackProvider: MusicDiscoveryProvider, QueueEditingPlaybackProvider {
    let id: PlaybackProviderID = .preview
    let displayName = "Demo Library"
    let capabilities: PlaybackCapabilities = [
        .playback, .pause, .explicitStop, .seek, .previous, .next, .queueReading,
        .queueEditing, .shuffle, .repeat, .applicationVolume, .catalogueSearch,
        .userLibrary, .playlists, .artwork
    ]
    private(set) var authenticationState: ProviderAuthenticationState = .authorized
    private(set) var state = PlaybackState(status: .stopped, providerID: .preview)
    private(set) var queue = PlaybackQueue()

    private var continuations: [UUID: AsyncStream<ProviderSnapshot>.Continuation] = [:]
    private var ticker: Task<Void, Never>?

    private static let demoItems: [PlaybackItem] = [
        PlaybackItem(id: "preview-1", providerID: .preview, providerItemID: "1", title: "Pixel Skyline", artist: "Macamp Demo", albumTitle: "Synthetic Nights", duration: .seconds(218), artwork: .systemSymbol("waveform"), mediaKind: .song, isExplicit: false),
        PlaybackItem(id: "preview-2", providerID: .preview, providerItemID: "2", title: "Neon Buffer", artist: "Concurrency Club", albumTitle: "Main Actor", duration: .seconds(194), artwork: .systemSymbol("sparkles"), mediaKind: .song, isExplicit: false),
        PlaybackItem(id: "preview-3", providerID: .preview, providerItemID: "3", title: "Transparent Window", artist: "The Bitmaps", albumTitle: "275 × 116", duration: .seconds(242), artwork: .systemSymbol("rectangle.on.rectangle"), mediaKind: .song, isExplicit: false)
    ]

    deinit { ticker?.cancel() }

    func snapshots() -> AsyncStream<ProviderSnapshot> {
        let id = UUID()
        let pair = AsyncStream<ProviderSnapshot>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.yield(snapshot)
        return pair.stream
    }

    func authorize() async throws { authenticationState = .authorized; publish() }
    func disconnect() async { authenticationState = .notDetermined; stopTicker(); publish() }

    func play() async throws {
        if queue.items.isEmpty { queue = PlaybackQueue(items: Self.demoItems, currentIndex: 0) }
        state.currentItem = queue.currentItem
        state.duration = state.currentItem?.duration
        state.status = .playing
        state.playbackRate = 1
        startTicker()
        publish()
    }

    func pause() async throws { state.status = .paused; state.playbackRate = 0; stopTicker(); publish() }
    func stop() async throws { state.status = .stopped; state.playbackRate = 0; state.elapsed = .zero; stopTicker(); publish() }
    func play(item: PlaybackItem) async throws { try await play(items: [item], startingAt: 0) }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        queue = PlaybackQueue(items: items, currentIndex: index)
        state.currentItem = items[index]
        state.duration = items[index].duration
        state.elapsed = .zero
        try await play()
    }

    func removeQueueItems(at offsets: IndexSet) async throws {
        let removed = offsets.filter { queue.items.indices.contains($0) }
        guard !removed.isEmpty else { return }
        let current = queue.currentIndex
        queue.items = queue.items.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
        if queue.items.isEmpty {
            queue.currentIndex = nil
            state.currentItem = nil
            state.duration = nil
            state.status = .stopped
            state.playbackRate = 0
        } else if let current {
            let removedBefore = removed.filter { $0 < current }.count
            queue.currentIndex = removed.contains(current) ? min(current - removedBefore, queue.items.count - 1) : current - removedBefore
            state.currentItem = queue.currentItem
            state.duration = state.currentItem?.duration
        }
        publish()
    }

    func clearQueue() async throws {
        queue = PlaybackQueue()
        state.currentItem = nil
        state.duration = nil
        state.elapsed = .zero
        state.status = .stopped
        state.playbackRate = 0
        stopTicker()
        publish()
    }

    func seek(to position: Duration) async throws {
        state.elapsed = .seconds(max(0, min(position.secondsValue, state.duration?.secondsValue ?? position.secondsValue)))
        publish()
    }

    func skipToNext() async throws { try await skip(by: 1) }
    func skipToPrevious() async throws {
        if state.elapsed.secondsValue > 3 { state.elapsed = .zero; publish() } else { try await skip(by: -1) }
    }

    func setVolume(_ volume: Double) async throws { state.volume = min(max(volume, 0), 1); publish() }
    func setShuffleMode(_ mode: ShuffleMode) async throws { state.shuffleMode = mode; publish() }
    func setRepeatMode(_ mode: RepeatMode) async throws { state.repeatMode = mode; publish() }

    func search(_ term: String) async throws -> MusicSearchResults {
        try Task.checkCancellation()
        let matches = term.isEmpty ? Self.demoItems : Self.demoItems.filter {
            $0.title.localizedCaseInsensitiveContains(term) || ($0.artist?.localizedCaseInsensitiveContains(term) ?? false)
        }
        return MusicSearchResults(songs: matches)
    }

    func library() async throws -> MusicLibrarySnapshot { MusicLibrarySnapshot(songs: Self.demoItems) }

    private var snapshot: ProviderSnapshot { ProviderSnapshot(authenticationState: authenticationState, state: state, queue: queue) }
    private func publish() { let value = snapshot; continuations.values.forEach { $0.yield(value) } }

    private func skip(by offset: Int) async throws {
        guard !queue.items.isEmpty else { throw ProviderError(code: .itemUnavailable, message: "The queue is empty.") }
        let current = queue.currentIndex ?? 0
        let proposed = current + offset
        let index: Int
        if state.repeatMode == .all { index = (proposed + queue.items.count) % queue.items.count }
        else { index = min(max(proposed, 0), queue.items.count - 1) }
        queue.currentIndex = index
        state.currentItem = queue.items[index]
        state.duration = state.currentItem?.duration
        state.elapsed = .zero
        publish()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.state.status == .playing else { return }
                self.state.elapsed += .seconds(1)
                if let duration = self.state.duration, self.state.elapsed >= duration { try? await self.skip(by: 1) }
                self.publish()
            }
        }
    }

    private func stopTicker() { ticker?.cancel(); ticker = nil }
}
