import Combine
import Foundation
import MusicKit

// MusicKit's process-wide player is internally synchronized and exposes async transport,
// but its current SDK declaration omits Sendable. All access in Macamp remains main-actor isolated.
extension ApplicationMusicPlayer: @retroactive @unchecked Sendable { }

@MainActor
final class AppleMusicPlaybackProvider: MusicDiscoveryProvider {
    let id: PlaybackProviderID = .appleMusic
    let displayName = "Apple Music"
    let capabilities: PlaybackCapabilities = [
        .playback, .pause, .explicitStop, .seek, .previous, .next, .queueReading,
        .shuffle, .repeat, .catalogueSearch, .userLibrary, .playlists, .artwork,
        .backgroundPlayback
    ]

    private(set) var authenticationState: ProviderAuthenticationState
    private(set) var state: PlaybackState
    private(set) var queue = PlaybackQueue()

    private let player: ApplicationMusicPlayer
    private let authorizationService: AppleMusicAuthorizationService
    private let catalogService: AppleMusicCatalogService
    private let libraryService: AppleMusicLibraryService
    private var songsByID: [String: Song] = [:]
    private var continuations: [AsyncStream<ProviderSnapshot>.Continuation] = []
    private var stateObservation: AnyCancellable?
    private var elapsedTask: Task<Void, Never>?

    init(
        player: ApplicationMusicPlayer = .shared,
        authorizationService: AppleMusicAuthorizationService = .init(),
        catalogService: AppleMusicCatalogService = .init(),
        libraryService: AppleMusicLibraryService = .init()
    ) {
        self.player = player
        self.authorizationService = authorizationService
        self.catalogService = catalogService
        self.libraryService = libraryService
        authenticationState = authorizationService.currentState
        state = PlaybackState(status: authenticationState == .authorized ? .stopped : .unavailable, providerID: .appleMusic)
        stateObservation = player.state.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.synchronize() }
        }
        synchronize()
    }

    deinit { elapsedTask?.cancel() }

    func snapshots() -> AsyncStream<ProviderSnapshot> {
        let pair = AsyncStream<ProviderSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuations.append(pair.continuation)
        pair.continuation.yield(snapshot)
        return pair.stream
    }

    func authorize() async throws {
        authenticationState = .authorizing; publish()
        do { authenticationState = try await authorizationService.request(); synchronize() }
        catch { authenticationState = authorizationService.currentState; publish(); throw map(error) }
    }

    /// MusicKit consent is persisted by macOS. Refreshing it on launch (and when
    /// returning from System Settings) restores access without another prompt.
    func restoreAuthorization() {
        authenticationState = authorizationService.currentState
        synchronize()
    }

    func disconnect() async {
        // MusicKit authorization is system-managed. Disconnect clears app state but cannot revoke system consent.
        player.stop()
        songsByID.removeAll()
        queue = PlaybackQueue()
        synchronize()
    }

    func play() async throws { try requireAuthorization(); try await player.play(); synchronize() }
    func pause() async throws { player.pause(); synchronize() }
    func stop() async throws { player.stop(); synchronize() }

    func play(item: PlaybackItem) async throws { try await play(items: [item], startingAt: 0) }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        try requireAuthorization()
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        let songs = try items.map(resolve)
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: songs[index])
        queue = PlaybackQueue(items: items, currentIndex: index)
        try await player.play()
        synchronize()
    }

    func seek(to position: Duration) async throws { player.playbackTime = max(0, position.secondsValue); synchronize() }
    func skipToNext() async throws { try await player.skipToNextEntry(); synchronize() }
    func skipToPrevious() async throws { try await player.skipToPreviousEntry(); synchronize() }
    func setVolume(_ volume: Double) async throws { throw ProviderError.unsupported("application volume for Apple Music") }

    func setShuffleMode(_ mode: ShuffleMode) async throws {
        player.state.shuffleMode = mode == .songs ? .songs : .off
        synchronize()
    }

    func setRepeatMode(_ mode: RepeatMode) async throws {
        player.state.repeatMode = switch mode { case .off: .some(.none); case .all: .some(.all); case .one: .some(.one) }
        synchronize()
    }

    func search(_ term: String) async throws -> MusicSearchResults {
        try requireAuthorization()
        do {
            let (results, songs) = try await catalogService.search(term)
            songsByID.merge(songs) { _, new in new }
            return results
        } catch { throw map(error) }
    }

    func library() async throws -> MusicLibrarySnapshot {
        try requireAuthorization()
        do {
            let (library, songs) = try await libraryService.load()
            songsByID.merge(songs) { _, new in new }
            return library
        } catch { throw map(error) }
    }

    private var snapshot: ProviderSnapshot { ProviderSnapshot(authenticationState: authenticationState, state: state, queue: queue) }
    private func publish() { let value = snapshot; continuations.forEach { $0.yield(value) } }

    private func synchronize() {
        guard authenticationState == .authorized else {
            state.status = .unavailable
            state.playbackRate = 0
            manageElapsedUpdates()
            publish()
            return
        }
        state.status = MusicKitModelMapper.playbackStatus(player.state.playbackStatus)
        state.elapsed = .seconds(player.playbackTime)
        state.playbackRate = Double(player.state.playbackRate)
        state.shuffleMode = player.state.shuffleMode == .songs ? .songs : .off
        state.repeatMode = switch player.state.repeatMode { case .one: .one; case .all: .all; default: .off }

        let entries = Array(player.queue.entries)
        if !entries.isEmpty {
            let mapped = entries.map(MusicKitModelMapper.queueEntry)
            let currentID = player.queue.currentEntry?.id
            queue = PlaybackQueue(items: mapped, currentIndex: currentID.flatMap { id in entries.firstIndex { $0.id == id } })
            state.currentItem = queue.currentItem
            state.duration = state.currentItem?.duration
        } else if let currentEntry = player.queue.currentEntry {
            state.currentItem = MusicKitModelMapper.queueEntry(currentEntry)
            state.duration = state.currentItem?.duration
        }
        manageElapsedUpdates()
        publish()
    }

    private func manageElapsedUpdates() {
        if state.status == .playing, elapsedTask == nil {
            elapsedTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.player.state.playbackStatus == .playing else { break }
                    self.state.elapsed = .seconds(self.player.playbackTime)
                    self.publish()
                }
                self?.elapsedTask = nil
            }
        } else if state.status != .playing { elapsedTask?.cancel(); elapsedTask = nil }
    }

    private func resolve(_ item: PlaybackItem) throws -> Song {
        guard item.providerID == .appleMusic, let song = songsByID[item.providerItemID] else {
            throw ProviderError(code: .itemUnavailable, message: "Reload this Apple Music item before playing it.")
        }
        return song
    }

    private func requireAuthorization() throws {
        guard authenticationState == .authorized else {
            throw ProviderError(code: .authorizationDenied, message: "Authorize Apple Music before using this feature.")
        }
    }

    private func map(_ error: Error) -> ProviderError {
        if error is CancellationError { return ProviderError(code: .cancelled, message: "The request was cancelled.") }
        if let error = error as? ProviderError { return error }
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("subscription") || lower.contains("not eligible") {
            return ProviderError(code: .subscriptionRequired, message: "Apple Music could not play this content. Check your subscription and account availability.")
        }
        return ProviderError(code: .network, message: message)
    }
}
