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
}

@MainActor
private final class TestPlaybackProvider: PlaybackProvider {
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
    private var snapshot: ProviderSnapshot { .init(authenticationState: authenticationState, state: state, queue: queue) }
    private func publish() { continuation?.yield(snapshot) }
}
