import Foundation
import Testing
@testable import Macamp

@Suite(.serialized)
@MainActor
struct PlaybackCoreTests {
    @Test func capabilitiesAreExplicit() {
        let apple: PlaybackCapabilities = [.playback, .pause, .catalogueSearch]
        #expect(apple.contains(.playback))
        #expect(!apple.contains(.applicationVolume))
        #expect(!apple.contains(.pcmAudio))
    }

    @Test func equalizerProfileIsValidatedAndPersistedAsOneGlobalProfile() {
        let suiteName = "MacampEqualizerSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)

        var profile = AudioEffectState(isEnabled: true, preampGain: 99, bandGains: [EqualizerBand.winamp10[0]: -99])
        profile.setGain(.infinity, for: EqualizerBand.winamp10[1])
        settings.equalizerState = profile

        let restored = SettingsStore(defaults: defaults).equalizerState
        #expect(restored.isEnabled)
        #expect(restored.preampGain == 12)
        #expect(restored.bandGains.count == 10)
        #expect(restored.gain(for: EqualizerBand.winamp10[0]) == -12)
        #expect(restored.gain(for: EqualizerBand.winamp10[1]) == 0)
        #expect(restored.gain(for: EqualizerBand.winamp10[9]) == 0)
    }

    @Test func providerSwitchingAndStatePropagation() async {
        let coordinator = PlaybackCoordinator()
        let first = MockPlaybackProvider()
        let second = TestPlaybackProvider(id: "second", capabilities: [.playback])
        coordinator.register(first)
        coordinator.register(second)
        coordinator.activate(second.id)
        #expect(coordinator.activeProviderID == second.id)
        await coordinator.play()
        await Task.yield()
        #expect(coordinator.state.status == .playing)
        #expect(second.playCount == 1)
    }

    @Test func unsupportedActionNeverReachesProvider() async {
        let coordinator = PlaybackCoordinator()
        let provider = TestPlaybackProvider(id: "limited", capabilities: [.playback])
        coordinator.register(provider)
        await coordinator.setVolume(0.4)
        #expect(provider.volumeCount == 0)
        #expect(coordinator.state.lastError?.code == .unsupported)
    }

    @Test func queueAppendPreservesCurrentPlaybackWithoutReplacementPlay() async {
        let coordinator = PlaybackCoordinator()
        let provider = TestPlaybackProvider(id: .localMedia, capabilities: [.playback, .queueEditing])
        let current = PlaybackItem(id: "current", providerID: provider.id, providerItemID: "current", title: "Current", mediaKind: .localFile, isExplicit: false)
        let existing = PlaybackItem(id: "existing", providerID: provider.id, providerItemID: "existing", title: "Existing", mediaKind: .localFile, isExplicit: false)
        provider.queue = PlaybackQueue(items: [current], currentIndex: 0)
        provider.state.currentItem = current
        provider.state.elapsed = .seconds(37)
        provider.state.status = .playing
        coordinator.register(provider)
        coordinator.activate(provider.id)

        await coordinator.addQueueItems([existing], placement: .append)

        #expect(provider.replacementPlayCount == 0)
        #expect(provider.queue.items.map(\.id) == [current.id, existing.id])
        #expect(provider.queue.currentIndex == 0)
        #expect(provider.state.currentItem?.id == current.id)
        #expect(provider.state.status == .playing)
        #expect(provider.state.elapsed == .seconds(37))
    }

    @Test func emptyAppendImportDoesNotAutoplay() async {
        let coordinator = PlaybackCoordinator()
        let provider = TestPlaybackProvider(id: .localMedia, capabilities: [.playback, .queueEditing])
        coordinator.register(provider)
        let service = MediaImportService(playback: coordinator, localMedia: LocalFilePlaybackProvider())

        let result = await service.importURLs([], action: .appendToQueue)

        #expect(result.items.isEmpty)
        #expect(provider.playCount == 0)
        #expect(provider.replacementPlayCount == 0)
        #expect(provider.queue.items.isEmpty)
        #expect(provider.state.status == .stopped)
    }

    @Test func appendImportTargetsLocalQueueWhileExternalPlaybackRemainsActive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampQueueImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("queued.mp3")
        try Data([0x49, 0x44, 0x33]).write(to: mediaURL)

        let current = PlaybackItem(id: "stream-current", providerID: .spotify, providerItemID: "stream-current", title: "Streaming", mediaKind: .song, isExplicit: false)
        let external = TestPlaybackProvider(id: .spotify, capabilities: [.playback, .queueEditing])
        external.queue = PlaybackQueue(items: [current], currentIndex: 0)
        external.state.currentItem = current
        external.state.status = .playing
        external.state.elapsed = .seconds(24)
        let storeURL = root.appendingPathComponent("session.json")
        let defaultsName = "MacampQueueImport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let local = LocalFilePlaybackProvider(
            bookmarkStore: LocalMediaBookmarkStore(defaults: defaults),
            sessionStore: PlaybackSessionStore(fileURL: storeURL)
        )
        let coordinator = PlaybackCoordinator(sessionStore: PlaybackSessionStore(fileURL: storeURL))
        coordinator.register(external)
        coordinator.register(local)
        let service = MediaImportService(playback: coordinator, localMedia: local)

        let result = await service.importURLs([mediaURL], action: .appendToQueue)

        #expect(result.items.count == 1)
        #expect(result.warnings.contains { $0.contains("Switch to Local Files") })
        #expect(coordinator.activeProviderID == .spotify)
        #expect(external.queue.items.map(\.id) == [current.id])
        #expect(external.state.currentItem?.id == current.id)
        #expect(external.state.status == .playing)
        #expect(external.state.elapsed == .seconds(24))
        #expect(coordinator.state.currentItem?.id == current.id)
        #expect(local.queue.items.map(\.id) == result.items.map(\.id))
    }

    @Test func providerSnapshotRefreshesRouteDependentEffectCapabilities() async {
        let coordinator = PlaybackCoordinator()
        let provider = LocalFilePlaybackProvider()
        coordinator.register(provider)
        #expect(!coordinator.capabilities.contains(.nativeEqualizer))
        #expect(!coordinator.capabilities.contains(.pcmAudio))
        #expect(coordinator.audioEffectUnavailableReason != nil)
        coordinator.activate(provider.id)
        #expect(!coordinator.capabilities.contains(.nativeEqualizer))
    }

    @Test func mockQueueMapsCurrentItem() async {
        let provider = MockPlaybackProvider()
        try? await provider.play()
        #expect(provider.queue.items.count == 3)
        #expect(provider.queue.currentItem == provider.state.currentItem)
        try? await provider.skipToNext()
        #expect(provider.queue.currentIndex == 1)
    }

    @Test func persistedPlaybackSessionRoundTripsAndClears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacampPlaybackSessionTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(fileURL: root)
        let item = PlaybackItem(
            id: "local:/Music/one.mp3", providerID: .localMedia,
            providerItemID: "file:///Music/one.mp3", title: "One",
            artist: "Artist", duration: .seconds(120), mediaKind: .localFile,
            isExplicit: false
        )
        let session = PersistedPlaybackSession(
            providerID: .localMedia,
            items: [PersistedQueueItem(item: item)],
            currentIndex: 0,
            elapsedSeconds: 24.5,
            shuffleMode: .songs,
            repeatMode: .all
        )

        await store.save(session)
        #expect(await store.load() == session)
        await store.clear()
        #expect(await store.load() == nil)
    }

    @Test func persistedSessionRestoresQueueWithoutStartingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacampPlaybackSessionTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = TestPlaybackProvider(id: "restorable", capabilities: [.playback])
        let store = PlaybackSessionStore(fileURL: root)
        let coordinator = PlaybackCoordinator(sessionStore: store)
        coordinator.register(provider)

        let first = PlaybackItem(id: "first", providerID: provider.id, providerItemID: "1", title: "First", mediaKind: .song, isExplicit: false)
        let second = PlaybackItem(id: "second", providerID: provider.id, providerItemID: "2", title: "Second", mediaKind: .song, isExplicit: false)
        let session = PersistedPlaybackSession(
            providerID: provider.id,
            items: [PersistedQueueItem(item: first), PersistedQueueItem(item: second)],
            currentIndex: 1,
            elapsedSeconds: 8,
            shuffleMode: .off,
            repeatMode: .off
        )
        await store.save(session)

        await coordinator.restorePersistedSession()

        #expect(coordinator.queue.items.map(\.title) == ["First", "Second"])
        #expect(coordinator.queue.currentIndex == 1)
        #expect(coordinator.state.status == .paused)
        #expect(provider.playCount == 0)
    }

    @Test func queueEditingProviderMutatesQueueWithoutChangingPlaybackContract() async throws {
        let provider = MockPlaybackProvider()
        try await provider.play()
        try await provider.removeQueueItems(at: IndexSet(integer: 0))
        #expect(provider.queue.items.map(\.title) == ["Neon Buffer", "Transparent Window"])
        #expect(provider.queue.currentIndex == 0)
        try await provider.clearQueue()
        #expect(provider.queue.items.isEmpty)
        #expect(provider.state.status == .stopped)
    }

    @Test func providerRegistrySeparatesAvailableAndUnavailableDescriptors() {
        let registry = ProviderRegistry()
        registry.register(TestPlaybackProvider(id: .appleMusic, capabilities: [.catalogueSearch]), descriptor: .appleMusic)
        registry.register(TestPlaybackProvider(id: .localMedia, capabilities: [.playback]), descriptor: .localMedia)
        registry.register(MockPlaybackProvider(), descriptor: .preview)
        registry.registerUnavailable(.spotify)
        registry.registerUnavailable(.deezer)

        #expect(registry.availableDescriptors.map(\.id) == [.appleMusic, .localMedia, .preview])
        #expect(registry.allDescriptors.count == 5)
        #expect(registry.descriptor(for: .spotify)?.availability == .requiresConfiguration)
        #expect(registry.descriptor(for: .deezer)?.notes.contains("no scraping") == true)
    }

    @Test func pkceAuthorizationURLContainsChallengeAndState() throws {
        let client = OAuthPKCEClient(configuration: OAuthPKCEConfiguration(
            clientID: "client", authorizationEndpoint: try #require(URL(string: "https://example.com/authorize")),
            tokenEndpoint: try #require(URL(string: "https://example.com/token")), redirectURI: try #require(URL(string: "macamp://oauth")), scopes: ["library.read"]
        ))
        let verifier = String(repeating: "a", count: 64)
        let url = try #require(client.authorizationURL(state: "state-123", verifier: verifier))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
        #expect(query.contains("state=state-123"))
        #expect(query.contains("code_challenge_method=S256"))
        #expect(query.contains("code_challenge="))
    }

    @Test func externalProvidersKeepHostedAudioBoundaries() {
        let configuration = ExternalProviderConfiguration(
            spotifyClientID: nil, spotifyRedirectURI: nil,
            tidalClientID: nil, tidalClientSecret: nil,
            soundCloudClientID: nil, soundCloudClientSecret: nil, soundCloudRedirectURI: nil,
            youtubeAPIKey: nil, youtubeClientID: nil, youtubeRedirectURI: nil
        )
        let providers: [any PlaybackProvider] = [
            SpotifyPlaybackProvider(configuration: configuration),
            TidalPlaybackProvider(configuration: configuration),
            SoundCloudPlaybackProvider(configuration: configuration),
            YouTubePlaybackProvider(configuration: configuration)
        ]

        #expect(providers.map(\.id) == [.spotify, .tidal, .soundCloud, .youtube])
        for provider in providers {
            #expect(provider.capabilities.contains(.catalogueSearch))
            #expect(!provider.capabilities.contains(.pcmAudio))
            #expect(!provider.capabilities.contains(.frequencySpectrum))
            #expect(!provider.capabilities.contains(.waveform))
            #expect(!provider.capabilities.contains(.nativeEqualizer))
        }
    }

    @Test func youtubeRequiresVisibleOfficialPlayerSurface() async {
        let configuration = ExternalProviderConfiguration(
            spotifyClientID: nil, spotifyRedirectURI: nil,
            tidalClientID: nil, tidalClientSecret: nil,
            soundCloudClientID: nil, soundCloudClientSecret: nil, soundCloudRedirectURI: nil,
            youtubeAPIKey: nil, youtubeClientID: nil, youtubeRedirectURI: nil
        )
        let provider = YouTubePlaybackProvider(configuration: configuration)
        do {
            try await provider.play()
            Issue.record("YouTube playback should require a visible player surface")
        } catch let error as ProviderError {
            #expect(error.code == .policyRestriction)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@MainActor
private final class TestPlaybackProvider: PlaybackSessionRestoring, QueueEditingPlaybackProvider {
    let id: PlaybackProviderID
    let displayName = "Test"
    let capabilities: PlaybackCapabilities
    var authenticationState: ProviderAuthenticationState = .authorized
    var state: PlaybackState
    var queue = PlaybackQueue()
    var playCount = 0
    var replacementPlayCount = 0
    var volumeCount = 0
    private var continuation: AsyncStream<ProviderSnapshot>.Continuation?

    init(id: PlaybackProviderID, capabilities: PlaybackCapabilities) {
        self.id = id; self.capabilities = capabilities
        state = PlaybackState(status: .stopped, providerID: id)
    }

    func snapshots() -> AsyncStream<ProviderSnapshot> {
        let pair = AsyncStream<ProviderSnapshot>.makeStream(); continuation = pair.continuation; pair.continuation.yield(snapshot); return pair.stream
    }
    func authorize() async throws { }
    func disconnect() async { }
    func play() async throws { playCount += 1; state.status = .playing; publish() }
    func pause() async throws { state.status = .paused; publish() }
    func stop() async throws { state.status = .stopped; publish() }
    func play(item: PlaybackItem) async throws { try await play() }
    func play(items: [PlaybackItem], startingAt index: Int) async throws { replacementPlayCount += 1; try await play() }
    func seek(to position: Duration) async throws { }
    func skipToNext() async throws { }
    func skipToPrevious() async throws { }
    func setVolume(_ volume: Double) async throws { volumeCount += 1 }
    func setShuffleMode(_ mode: ShuffleMode) async throws { }
    func setRepeatMode(_ mode: RepeatMode) async throws { }
    func removeQueueItems(at offsets: IndexSet) async throws {
        queue.items = queue.items.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
    }
    func clearQueue() async throws { queue = PlaybackQueue() }
    func addQueueItems(_ items: [PlaybackItem], placement: QueueInsertionPlacement) async throws {
        guard !items.isEmpty else { return }
        let index = switch placement {
        case .append: queue.items.endIndex
        case .next: queue.currentIndex.map { $0 + 1 } ?? 0
        }
        queue.items.insert(contentsOf: items, at: index)
        if let current = queue.currentIndex, index <= current { queue.currentIndex = current + items.count }
    }

    func restore(session: PersistedPlaybackSession) async throws {
        guard session.providerID == id else {
            throw ProviderError(code: .providerUnavailable, message: "Wrong provider")
        }
        let items = session.items.map { item in
            PlaybackItem(
                id: item.id, providerID: id, providerItemID: item.providerItemID,
                title: item.title, artist: item.artist, albumTitle: item.albumTitle,
                duration: item.durationSeconds.map(Duration.seconds), mediaKind: item.mediaKind,
                isExplicit: false, sourceURL: item.sourceURL, attribution: nil
            )
        }
        queue = PlaybackQueue(items: items, currentIndex: session.currentIndex)
        state.currentItem = queue.currentItem
        state.duration = queue.currentItem?.duration
        state.elapsed = .seconds(session.elapsedSeconds ?? 0)
        state.shuffleMode = session.shuffleMode
        state.repeatMode = session.repeatMode
        state.status = queue.currentItem == nil ? .stopped : .paused
        state.playbackRate = 0
        publish()
    }
    private var snapshot: ProviderSnapshot { .init(authenticationState: authenticationState, state: state, queue: queue) }
    private func publish() { continuation?.yield(snapshot) }
}
