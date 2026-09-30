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
private final class TestPlaybackProvider: PlaybackSessionRestoring {
    let id: PlaybackProviderID
    let displayName = "Test"
    let capabilities: PlaybackCapabilities
    var authenticationState: ProviderAuthenticationState = .authorized
    var state: PlaybackState
    var queue = PlaybackQueue()
    var playCount = 0
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
    func play(items: [PlaybackItem], startingAt index: Int) async throws { try await play() }
    func seek(to position: Duration) async throws { }
    func skipToNext() async throws { }
    func skipToPrevious() async throws { }
    func setVolume(_ volume: Double) async throws { volumeCount += 1 }
    func setShuffleMode(_ mode: ShuffleMode) async throws { }
    func setRepeatMode(_ mode: RepeatMode) async throws { }

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
