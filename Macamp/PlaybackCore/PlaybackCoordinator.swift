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
    private(set) var state = PlaybackState()
    private(set) var queue = PlaybackQueue()
    private(set) var audioEffectCapabilities: AudioEffectCapabilities = []
    private(set) var audioEffectState = AudioEffectState()
    private(set) var recentErrors: [String] = []

    @ObservationIgnored private var providers: [PlaybackProviderID: any PlaybackProvider] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "dev.holgerkrupp.Macamp", category: "Playback")

    deinit { observationTask?.cancel() }

    func register(_ provider: any PlaybackProvider) {
        providers[provider.id] = provider
        if activeProviderID == nil { activate(provider.id) }
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

    func authorize() async { await perform { try await $0.authorize() } }
    func handleOAuthCallback(_ url: URL) async {
        guard let handler = activeProvider as? any OAuthCallbackHandling else { return }
        await handler.handleOAuthCallback(url)
        if let provider = activeProvider { apply(ProviderSnapshot(authenticationState: provider.authenticationState, state: provider.state, queue: provider.queue)) }
    }
    func disconnect() async {
        guard let provider = activeProvider else { return }
        await provider.disconnect()
        apply(ProviderSnapshot(authenticationState: provider.authenticationState, state: provider.state, queue: provider.queue))
    }
    func play() async { await perform(required: .playback) { try await $0.play() } }
    func pause() async { await perform(required: .pause) { try await $0.pause() } }
    func stop() async { await perform(required: .explicitStop) { try await $0.stop() } }
    func play(item: PlaybackItem) async { await perform(required: .playback) { try await $0.play(item: item) } }
    func play(items: [PlaybackItem], startingAt index: Int) async {
        await perform(required: .playback) { try await $0.play(items: items, startingAt: index) }
    }
    func seek(to position: Duration) async { await perform(required: .seek) { try await $0.seek(to: position) } }
    func next() async { await perform(required: .next) { try await $0.skipToNext() } }
    func previous() async { await perform(required: .previous) { try await $0.skipToPrevious() } }
    func setVolume(_ volume: Double) async {
        await perform(required: .applicationVolume) { try await $0.setVolume(volume.clamped(to: 0...1)) }
    }
    func setShuffle(_ mode: ShuffleMode) async { await perform(required: .shuffle) { try await $0.setShuffleMode(mode) } }
    func setRepeat(_ mode: RepeatMode) async { await perform(required: .repeat) { try await $0.setRepeatMode(mode) } }

    func setEqualizerEnabled(_ enabled: Bool) async {
        await performAudioEffect { try await $0.setEnabled(enabled) }
    }

    func setEqualizerBand(index: Int, gain: Float) async {
        guard EqualizerBand.winamp10.indices.contains(index) else { return }
        await performAudioEffect { try await $0.setBandGain(gain, band: EqualizerBand.winamp10[index]) }
    }

    func resetEqualizer() async {
        guard let effects = activeProvider as? any AudioEffectController else { return }
        do {
            for band in EqualizerBand.winamp10 { try await effects.setBandGain(0, band: band) }
            try await effects.setPreampGain(0)
            refreshAudioEffects()
        } catch { record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription)) }
    }

    func search(_ term: String) async throws -> MusicSearchResults {
        guard let provider = activeProvider as? any MusicDiscoveryProvider else {
            throw ProviderError.unsupported("catalogue search")
        }
        guard capabilities.contains(.catalogueSearch) else { throw ProviderError.unsupported("catalogue search") }
        return try await provider.search(term)
    }

    func loadLibrary() async throws -> MusicLibrarySnapshot {
        guard let provider = activeProvider as? any MusicDiscoveryProvider else {
            throw ProviderError.unsupported("library browsing")
        }
        return try await provider.library()
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

    private func performAudioEffect(action: (any AudioEffectController) async throws -> Void) async {
        guard let effects = activeProvider as? any AudioEffectController else {
            return record(.unsupported("audio effects"))
        }
        do {
            try await action(effects)
            refreshAudioEffects()
        } catch { record(error as? ProviderError ?? ProviderError(code: .unknown, message: error.localizedDescription)) }
    }

    private func refreshAudioEffects() {
        guard let effects = activeProvider as? any AudioEffectController else {
            audioEffectCapabilities = []
            audioEffectState = AudioEffectState()
            return
        }
        audioEffectCapabilities = effects.effectCapabilities
        audioEffectState = effects.effectState
    }

    private func apply(_ snapshot: ProviderSnapshot) {
        authenticationState = snapshot.authenticationState
        state = snapshot.state
        queue = snapshot.queue
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
