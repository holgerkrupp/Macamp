import Foundation

@MainActor
protocol PlaybackProvider: AnyObject {
    var id: PlaybackProviderID { get }
    var displayName: String { get }
    var capabilities: PlaybackCapabilities { get }
    var authenticationState: ProviderAuthenticationState { get }
    var state: PlaybackState { get }
    var queue: PlaybackQueue { get }

    func snapshots() -> AsyncStream<ProviderSnapshot>
    func authorize() async throws
    func disconnect() async
    func play() async throws
    func pause() async throws
    func stop() async throws
    func play(item: PlaybackItem) async throws
    func play(items: [PlaybackItem], startingAt index: Int) async throws
    func seek(to position: Duration) async throws
    func skipToNext() async throws
    func skipToPrevious() async throws
    func setVolume(_ volume: Double) async throws
    func setShuffleMode(_ mode: ShuffleMode) async throws
    func setRepeatMode(_ mode: RepeatMode) async throws
}

@MainActor
protocol MusicDiscoveryProvider: PlaybackProvider {
    func search(_ term: String) async throws -> MusicSearchResults
    func library() async throws -> MusicLibrarySnapshot
}

struct MusicSearchResults: Equatable, Sendable {
    var songs: [PlaybackItem] = []
    var albums: [PlaybackCollection] = []
    var artists: [PlaybackCollection] = []
    var playlists: [PlaybackCollection] = []
}

struct MusicLibrarySnapshot: Equatable, Sendable {
    var songs: [PlaybackItem] = []
    var albums: [PlaybackCollection] = []
    var artists: [PlaybackCollection] = []
    var playlists: [PlaybackCollection] = []
}
