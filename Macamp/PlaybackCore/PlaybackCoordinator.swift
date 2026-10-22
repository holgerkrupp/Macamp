import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class PlaybackCoordinator {
    private(set) var activeProviderID: PlaybackProviderID?
    private(set) var activeProviderName = "No Provider"
    private(set) var capabilities: PlaybackCapabilities = []
    private(set) var authenticationState: ProviderAuthenticationState = .unavailable
    private(set) var providerReadinessRevision = 0
    private(set) var state = PlaybackState()
    var queue: PlaybackQueue { playlistStore.queue }
    private(set) var audioEffectCapabilities: AudioEffectCapabilities = []
    private(set) var audioEffectState = AudioEffectState()
    private(set) var audioEffectUnavailableReason: String? = "Equalizer unavailable for this provider's audio source."
    private(set) var recentErrors: [String] = []

    @ObservationIgnored private var providers: [PlaybackProviderID: any PlaybackProvider] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private let sessionStore: PlaybackSessionStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored let playlistStore: UnifiedPlaylistStore
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var lastAppliedProviderID: PlaybackProviderID?
    @ObservationIgnored private var isAutoAdvancing = false
    @ObservationIgnored private let logger = Logger(subsystem: "dev.holgerkrupp.Macamp", category: "Playback")

    init(
        sessionStore: PlaybackSessionStore = PlaybackSessionStore(),
        settingsStore: SettingsStore = SettingsStore(),
        playlistStore: UnifiedPlaylistStore = UnifiedPlaylistStore()
    ) {
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.playlistStore = playlistStore
    }

    deinit {
        observationTask?.cancel()
        persistenceTask?.cancel()
    }

    func register(_ provider: any PlaybackProvider) {
        providers[provider.id] = provider
        if activeProviderID == nil { activate(provider.id) }
    }

    var registeredProviders: [(id: PlaybackProviderID, name: String, capabilities: PlaybackCapabilities, authentication: ProviderAuthenticationState)] {
        providers.values
            .filter { $0.id != .localMedia && $0.id != .preview }
            .sorted { $0.displayName < $1.displayName }
            .map { ($0.id, $0.displayName, $0.capabilities, $0.authenticationState) }
    }

    func isProviderRegistered(_ id: PlaybackProviderID) -> Bool { providers[id] != nil }

    func providerAuthenticationState(for id: PlaybackProviderID) -> ProviderAuthenticationState {
        providers[id]?.authenticationState ?? .unavailable
    }

    func availability(for item: PlaybackItem) -> PlaylistEntryAvailability {
        guard let provider = providers[item.providerID] else {
            return item.providerID == .deezer ? .unsupportedByProviderPolicy : .requiresConnectionOrDevice
        }
        if let local = provider as? LocalFilePlaybackProvider, !local.canResolve(item) { return .requiresFileAccess }
        if item.providerID == .youtube {
            guard let youtube = provider as? YouTubePlaybackProvider, youtube.isPlayerVisible else { return .requiresConnectionOrDevice }
        }
        guard provider.authenticationState == .authorized else { return .requiresConnectionOrDevice }
        if let spotify = provider as? SpotifyPlaybackProvider, !spotify.hasPlayableDevice { return .requiresConnectionOrDevice }
        if activeProviderID == item.providerID,
           state.currentItem?.providerID == item.providerID,
           state.currentItem?.providerItemID == item.providerItemID,
           state.status == .playing { return .playableNow }
        return .queued
    }

    func providerDisplayName(for id: PlaybackProviderID) -> String {
        providers[id]?.displayName ?? id.rawValue
    }

    func availabilityLabel(for item: PlaybackItem) -> String {
        switch availability(for: item) {
        case .queued: "Queued"
        case .playableNow: "Playing now"
        case .requiresConnectionOrDevice: "Requires connection/device"
        case .requiresFileAccess: "Requires file access"
        case .unsupportedByProviderPolicy: "Unsupported by provider policy"
        }
    }

    func activate(_ id: PlaybackProviderID) {
        guard let provider = providers[id] else { return }
        observationTask?.cancel()
        activeProviderID = id
        activeProviderName = provider.displayName
        capabilities = provider.capabilities
        refreshAudioEffects()
        apply(ProviderSnapshot(
            authenticationState: provider.authenticationState,
            state: provider.state,
            queue: provider.queue
        ))
        observationTask = Task { [weak self, weak provider] in
            guard let provider else { return }
            for await snapshot in provider.snapshots() {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot)
            }
        }
    }

    func restorePersistedSession() async {
        guard let session = await sessionStore.load(),
              let provider = providers[session.providerID],
              let restorable = provider as? any PlaybackSessionRestoring else { return }

        activate(session.providerID)
        do {
            try await restorable.restore(session: session)
            apply(ProviderSnapshot(
                authenticationState: restorable.authenticationState,
                state: restorable.state,
                queue: restorable.queue
            ))
            if restorable.queue.items.isEmpty {
                enqueuePersistence { await $0.clear() }
            }
        } catch is CancellationError {
        } catch {
            record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription))
        }
    }

    func authorize() async { await perform { try await $0.authorize() } }
    func handleOAuthCallback(_ url: URL) async {
        guard let provider = providers.values.first(where: { ($0 as? any OAuthCallbackHandling)?.matchesOAuthCallback(url) == true }),
              let handler = provider as? any OAuthCallbackHandling else { return }
        await handler.handleOAuthCallback(url)
        providerReadinessRevision &+= 1
        if activeProviderID == provider.id { apply(ProviderSnapshot(authenticationState: provider.authenticationState, state: provider.state, queue: provider.queue)) }
    }
    func disconnect() async {
        guard let provider = activeProvider else { return }
        await provider.disconnect()
        apply(ProviderSnapshot(authenticationState: provider.authenticationState, state: provider.state, queue: provider.queue))
    }
    func play() async {
        if queue.items.isEmpty { return await perform(required: .playback) { try await $0.play() } }
        guard let currentIndex = queue.currentIndex else { return await playQueueEntry(at: 0) }
        let item = queue.items[currentIndex]
        if activeProviderID == item.providerID,
           state.currentItem?.providerID == item.providerID,
           state.currentItem?.providerItemID == item.providerItemID,
           state.status == .paused {
            await perform(required: .playback) { try await $0.play() }
        } else {
            await playQueueEntry(at: currentIndex)
        }
    }
    func pause() async { await perform(required: .pause) { try await $0.pause() } }
    func stop() async { await perform(required: .explicitStop) { try await $0.stop() } }
    func play(item: PlaybackItem) async {
        if let index = queue.items.firstIndex(where: { $0.providerID == item.providerID && $0.providerItemID == item.providerItemID }) {
            await playQueueEntry(at: index)
        } else {
            playlistStore.append([item])
            syncPlaylistQueue()
            await playQueueEntry(at: queue.items.count - 1)
        }
    }
    func play(items: [PlaybackItem], startingAt index: Int) async {
        guard items.indices.contains(index) else { return record(ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.")) }
        playlistStore.replace(with: items)
        syncPlaylistQueue()
        await playQueueEntry(at: index)
    }

    func playQueueEntry(at index: Int) async {
        guard queue.items.indices.contains(index), playlistStore.entries.indices.contains(index) else {
            return record(ProviderError(code: .itemUnavailable, message: "That playlist position is unavailable."))
        }
        let entry = playlistStore.entries[index]
        let item = entry.playbackItem
        guard let target = providers[entry.providerID] else {
            return record(ProviderError(code: .providerUnavailable, message: "\(entry.providerID.rawValue) is not configured. This playlist item is kept in the queue."))
        }
        switch availability(for: item) {
        case .requiresFileAccess:
            return record(ProviderError(code: .itemUnavailable, message: "Macamp needs file access before it can play this item. It remains in the playlist."))
        case .unsupportedByProviderPolicy:
            return record(ProviderError(code: .policyRestriction, message: "This provider is unavailable under its supported integration policy. The item remains in the playlist."))
        case .requiresConnectionOrDevice:
            let code: ProviderError.Code = item.providerID == .youtube ? .policyRestriction : .externalDeviceRequired
            return record(ProviderError(code: code, message: "Connect this provider or open its required playback surface before playing this item. It remains in the playlist."))
        case .queued, .playableNow:
            break
        }
        let previous = activeProvider
        if let previous, previous.id != target.id, [.playing, .buffering].contains(previous.state.status) {
            do { try await previous.stop() }
            catch {
                return record(error as? ProviderError ?? ProviderError(code: .playbackFailed, message: "Could not stop the current provider before switching sources."))
            }
        }
        activate(target.id)
        do {
            if target.id == .localMedia {
                try await target.setShuffleMode(.off)
                try await target.setRepeatMode(.off)
            }
            try await target.play(item: item)
            playlistStore.select(entry.id)
            syncPlaylistQueue()
            apply(ProviderSnapshot(authenticationState: target.authenticationState, state: target.state, queue: target.queue))
        } catch {
            let providerError = error as? ProviderError ?? ProviderError(code: .playbackFailed, message: error.localizedDescription)
            if let previous, previous.id != target.id { activate(previous.id) }
            record(providerError)
        }
    }

    func appendToUnifiedPlaylist(_ items: [PlaybackItem], placement: QueueInsertionPlacement) -> Bool {
        guard items.allSatisfy({ providers[$0.providerID] != nil }) else {
            record(ProviderError(code: .providerUnavailable, message: "One or more selected music services are not configured. Nothing was added."))
            return false
        }
        switch placement {
        case .append: playlistStore.append(items)
        case .next: playlistStore.insertNext(items)
        }
        syncPlaylistQueue()
        return true
    }
    func removeQueueItems(at offsets: IndexSet) async {
        guard !offsets.isEmpty else { return }
        let removesCurrent = queue.currentIndex.map(offsets.contains) ?? false
        if removesCurrent, let activeProvider, activeProvider.state.status == .playing { try? await activeProvider.stop() }
        playlistStore.remove(at: offsets)
        syncPlaylistQueue()
    }

    /// Adds items to the active provider's queue without invoking its playback
    /// replacement API. Queue insertion is intentionally unavailable for
    /// providers that do not expose queue editing.
    func addQueueItems(_ items: [PlaybackItem], placement: QueueInsertionPlacement) async {
        guard let activeProviderID else { return record(ProviderError(code: .unknown, message: "No playback provider is active.")) }
        _ = await addQueueItems(items, placement: placement, to: activeProviderID)
    }

    /// Adds items to a specific provider queue. An inactive provider mutation
    /// is persisted without publishing its playback state over the active
    /// provider's visible state.
    @discardableResult
    func addQueueItems(
        _ items: [PlaybackItem],
        placement: QueueInsertionPlacement,
        to providerID: PlaybackProviderID
    ) async -> Bool {
        guard items.allSatisfy({ $0.providerID == providerID }) else { return false }
        return appendToUnifiedPlaylist(items, placement: placement)
    }

    func clearQueue() async {
        if let activeProvider, activeProvider.state.status == .playing { try? await activeProvider.stop() }
        playlistStore.clear()
        syncPlaylistQueue()
    }
    func seek(to position: Duration) async { await perform(required: .seek) { try await $0.seek(to: position) } }
    func next() async {
        guard !queue.items.isEmpty else { return record(ProviderError(code: .itemUnavailable, message: "The playlist is empty.")) }
        let current = queue.currentIndex ?? -1
        let candidate: Int?
        if state.shuffleMode == .songs, queue.items.count > 1 {
            candidate = queue.items.indices.filter { $0 != current }.randomElement()
        } else if current + 1 < queue.items.count { candidate = current + 1 }
        else if state.repeatMode == .all { candidate = 0 }
        else { candidate = nil }
        guard let candidate else {
            if let activeProvider { try? await activeProvider.stop() }
            return
        }
        await playQueueEntry(at: candidate)
    }
    func previous() async {
        if state.elapsed.secondsValue > 3 { await perform { try await $0.seek(to: .zero) }; return }
        guard !queue.items.isEmpty else { return record(ProviderError(code: .itemUnavailable, message: "The playlist is empty.")) }
        let current = queue.currentIndex ?? 0
        let candidate = current > 0 ? current - 1 : (state.repeatMode == .all ? queue.items.count - 1 : 0)
        await playQueueEntry(at: candidate)
    }
    func setVolume(_ volume: Double) async {
        await perform(required: .applicationVolume) { try await $0.setVolume(volume.clamped(to: 0...1)) }
    }
    func setShuffle(_ mode: ShuffleMode) async {
        state.shuffleMode = mode
        if let provider = activeProvider, provider.capabilities.contains(.shuffle) { try? await provider.setShuffleMode(.off) }
    }
    func setRepeat(_ mode: RepeatMode) async {
        state.repeatMode = mode
        if let provider = activeProvider, provider.capabilities.contains(.repeat) { try? await provider.setRepeatMode(.off) }
    }

    func setEqualizerEnabled(_ enabled: Bool) async {
        await performAudioEffect(required: .enable) { try await $0.setEnabled(enabled) }
    }

    func setEqualizerBand(index: Int, gain: Float) async {
        guard EqualizerBand.winamp10.indices.contains(index) else { return }
        await performAudioEffect(required: .equalizerBands) { try await $0.setBandGain(gain, band: EqualizerBand.winamp10[index]) }
    }

    func setPreampGain(_ gain: Float) async {
        await performAudioEffect(required: .preamp) { try await $0.setPreampGain(gain.clamped(to: -12...12)) }
    }

    func resetEqualizer() async {
        guard let effects = activeProvider as? any AudioEffectController else { return }
        do {
            guard audioEffectCapabilities.contains(.equalizerBands), audioEffectCapabilities.contains(.preamp) else {
                return record(.unsupported("equalizer for this source"))
            }
            for band in EqualizerBand.winamp10 { try await effects.setBandGain(0, band: band) }
            try await effects.setPreampGain(0)
            refreshAudioEffects()
            settingsStore.equalizerState = effects.effectState
        } catch { record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription)) }
    }

    func search(_ term: String) async throws -> MusicSearchResults {
        guard let activeProviderID else { throw ProviderError.unsupported("catalogue search") }
        return try await search(providerID: activeProviderID, term: term)
    }

    func search(providerID: PlaybackProviderID, term: String) async throws -> MusicSearchResults {
        guard let provider = providers[providerID] as? any MusicDiscoveryProvider,
              provider.capabilities.contains(.catalogueSearch) else { throw ProviderError.unsupported("catalogue search") }
        if provider.authenticationState != .authorized { try await provider.authorize() }
        return try await provider.search(term)
    }

    func loadLibrary() async throws -> MusicLibrarySnapshot {
        guard let activeProviderID else { throw ProviderError.unsupported("library browsing") }
        return try await loadLibrary(providerID: activeProviderID)
    }

    func loadLibrary(providerID: PlaybackProviderID) async throws -> MusicLibrarySnapshot {
        guard let provider = providers[providerID] as? any MusicDiscoveryProvider else { throw ProviderError.unsupported("library browsing") }
        if provider.authenticationState != .authorized { try await provider.authorize() }
        return try await provider.library()
    }

    func authorize(providerID: PlaybackProviderID) async throws {
        guard let provider = providers[providerID] else {
            throw ProviderError(code: .providerUnavailable, message: "This service is not configured for this build.")
        }
        try await provider.authorize()
        providerReadinessRevision &+= 1
    }

    func items(in collection: PlaybackCollection) async throws -> [PlaybackItem] {
        guard let provider = providers[collection.providerID] as? any MusicDiscoveryProvider else {
            throw ProviderError(code: .providerUnavailable, message: "This service is not configured. The collection remains available in search results.")
        }
        if provider.authenticationState != .authorized { try await provider.authorize() }
        return try await provider.items(in: collection)
    }

    private var activeProvider: (any PlaybackProvider)? {
        activeProviderID.flatMap { providers[$0] }
    }

    private func perform(
        required capability: PlaybackCapabilities? = nil,
        action: (any PlaybackProvider) async throws -> Void
    ) async {
        guard let provider = activeProvider else { return record(ProviderError(code: .unknown, message: "No playback provider is active.")) }
        if let capability, !capabilities.contains(capability) { return record(.unsupported("this action")) }
        do {
            try await action(provider)
            apply(ProviderSnapshot(authenticationState: provider.authenticationState, state: provider.state, queue: provider.queue))
        } catch is CancellationError { } catch {
            record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription))
        }
    }

    private func performAudioEffect(
        required capability: AudioEffectCapabilities,
        action: (any AudioEffectController) async throws -> Void
    ) async {
        guard let effects = activeProvider as? any AudioEffectController else {
            return record(ProviderError(code: .unsupported, message: audioEffectUnavailableReason ?? "Equalizer unavailable for this provider's audio source."))
        }
        guard audioEffectCapabilities.contains(capability) else {
            return record(ProviderError(code: .unsupported, message: audioEffectUnavailableReason ?? "Equalizer unavailable for this source."))
        }
        do {
            try await action(effects)
            refreshAudioEffects()
            settingsStore.equalizerState = effects.effectState
        } catch { record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription)) }
    }

    private func refreshAudioEffects() {
        guard let effects = activeProvider as? any AudioEffectController else {
            audioEffectCapabilities = []
            audioEffectState = settingsStore.equalizerState
            audioEffectUnavailableReason = unavailableReason(for: activeProvider)
            capabilities = activeProvider?.capabilities ?? []
            return
        }
        audioEffectCapabilities = effects.effectCapabilities
        audioEffectState = effects.effectState
        audioEffectUnavailableReason = effects.effectUnavailableReason
        if let provider = activeProvider { capabilities = provider.capabilities }
    }

    private func unavailableReason(for provider: (any PlaybackProvider)?) -> String {
        guard let provider else { return "Equalizer unavailable because no playback provider is active." }
        switch provider.id {
        case .appleMusic:
            return "Equalizer unavailable: Apple Music keeps protected decoded audio outside Macamp's DSP path."
        case .spotify, .tidal, .soundCloud, .youtube:
            return "Equalizer unavailable: this provider streams hosted audio outside Macamp's DSP path."
        default:
            return "Equalizer unavailable for this provider's audio source."
        }
    }

    private func apply(_ snapshot: ProviderSnapshot) {
        let previousState = state
        let previousQueue = queue
        let previousProviderID = lastAppliedProviderID
        authenticationState = snapshot.authenticationState
        state = snapshot.state
        state.shuffleMode = previousState.shuffleMode
        state.repeatMode = previousState.repeatMode
        // Local playback can switch between AVAudioEngine files and AVPlayer
        // streams without changing providers. Keep controls honest per route.
        refreshAudioEffects()
        if let currentItem = snapshot.state.currentItem {
            let selectedEntry = playlistStore.currentEntryID.flatMap { id in
                playlistStore.entries.first(where: { $0.id == id })
            }
            if selectedEntry?.providerID != currentItem.providerID || selectedEntry?.providerItemID != currentItem.providerItemID {
                let matchingEntry = playlistStore.entries.first(where: {
                    $0.providerID == currentItem.providerID && $0.providerItemID == currentItem.providerItemID
                })
                playlistStore.select(matchingEntry?.id)
            }
        }
        persistMeaningfulChanges(
            from: (providerID: previousProviderID, state: previousState, queue: previousQueue),
            to: snapshot
        )
        lastAppliedProviderID = activeProviderID
        if !isAutoAdvancing,
           previousState.status == .playing,
           snapshot.state.status == .stopped,
           previousState.currentItem?.providerID == snapshot.state.currentItem?.providerID,
           previousState.currentItem?.providerItemID == snapshot.state.currentItem?.providerItemID,
           let duration = snapshot.state.duration ?? previousState.duration,
           max(snapshot.state.elapsed.secondsValue, previousState.elapsed.secondsValue) >= duration.secondsValue - 0.5 {
            isAutoAdvancing = true
            Task { [weak self] in
                await self?.next()
                self?.isAutoAdvancing = false
            }
        }
    }

    private func syncPlaylistQueue() { _ = playlistStore.queue }

    private func persistMeaningfulChanges(
        from previous: (providerID: PlaybackProviderID?, state: PlaybackState, queue: PlaybackQueue),
        to snapshot: ProviderSnapshot
    ) {
        guard let providerID = activeProviderID,
              snapshot.state.providerID == nil || snapshot.state.providerID == providerID else { return }

        let providerChanged = previous.providerID != providerID
        if snapshot.queue.items.isEmpty {
            // A provider switch can legitimately expose an empty queue. Only
            // an explicit local queue clear invalidates the saved session.
            if providerID == .localMedia, !providerChanged, !previous.queue.items.isEmpty {
                enqueuePersistence { await $0.clear() }
            }
            return
        }

        guard providers[providerID] is any PlaybackSessionRestoring else { return }
        let queueChanged = previous.queue != snapshot.queue
        let itemChanged = previous.state.currentItem?.id != snapshot.state.currentItem?.id
        let modesChanged = previous.state.shuffleMode != snapshot.state.shuffleMode
            || previous.state.repeatMode != snapshot.state.repeatMode
        let elapsedChangedWhileStopped = snapshot.state.status != .playing
            && previous.state.elapsed != snapshot.state.elapsed
        let pausedOrStopped = previous.state.status != snapshot.state.status
            && snapshot.state.status != .playing

        guard queueChanged || itemChanged || modesChanged || elapsedChangedWhileStopped || pausedOrStopped else { return }
        enqueuePersistence {
            await $0.save(PersistedPlaybackSession(providerID: providerID, queue: snapshot.queue, state: snapshot.state))
        }
    }

    private func enqueuePersistence(_ operation: @escaping @Sendable (PlaybackSessionStore) async -> Void) {
        let previous = persistenceTask
        persistenceTask = Task { [sessionStore] in
            await previous?.value
            await operation(sessionStore)
        }
    }

    private func record(_ error: ProviderError) {
        state.lastError = error
        recentErrors.insert(error.message, at: 0)
        recentErrors = Array(recentErrors.prefix(10))
        logger.error("Playback error: \(error.message, privacy: .public)")
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
