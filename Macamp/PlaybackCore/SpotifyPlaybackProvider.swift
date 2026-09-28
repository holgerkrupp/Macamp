import Foundation

@MainActor
final class SpotifyPlaybackProvider: ExternalPlaybackProviderBase, MusicDiscoveryProvider, OAuthCallbackHandling {
    struct Device: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let type: String
        let isActive: Bool
        let isRestricted: Bool
        let supportsVolume: Bool
    }

    private let transport: any ProviderHTTPTransport
    private let oauth: OAuthSession?
    private var syncTask: Task<Void, Never>?
    private(set) var devices: [Device] = []
    private(set) var isPremium = false
    private var selectedDeviceID: String?
    private let baseURL = URL(string: "https://api.spotify.com/v1")!

    var isConfigured: Bool { oauth != nil }

    init(configuration: ExternalProviderConfiguration, transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) {
        self.transport = transport
        if let clientID = configuration.spotifyClientID, let redirectURI = configuration.spotifyRedirectURI {
            oauth = OAuthSession(
                providerID: .spotify,
                configuration: OAuthPKCEConfiguration(
                    clientID: clientID,
                    authorizationEndpoint: URL(string: "https://accounts.spotify.com/authorize")!,
                    tokenEndpoint: URL(string: "https://accounts.spotify.com/api/token")!,
                    redirectURI: redirectURI,
                    scopes: [
                        "user-read-private", "user-read-email", "user-read-playback-state", "user-modify-playback-state",
                        "user-library-read", "playlist-read-private", "playlist-read-collaborative"
                    ]
                )
            )
        } else {
            oauth = nil
        }
        super.init(
            id: .spotify,
            displayName: "Spotify",
            capabilities: [.playback, .pause, .seek, .previous, .next, .shuffle, .repeat, .applicationVolume,
                            .queueReading, .catalogueSearch, .userLibrary, .playlists, .artwork, .remoteDeviceControl]
        )
        authenticationState = oauth?.isAuthorized == true ? .authorized : .notDetermined
    }

    func authorize() async throws {
        guard let oauth else { throw ProviderError(code: .providerUnavailable, message: "Spotify is not configured. Set MACAMP_SPOTIFY_CLIENT_ID and MACAMP_SPOTIFY_REDIRECT_URI.") }
        if oauth.isAuthorized {
            try await validateAccount()
            startSyncing()
            return
        }
        openAuthorizationURL(try oauth.beginAuthorization())
    }

    func handleOAuthCallback(_ url: URL) async {
        guard let oauth else { return }
        do {
            try await oauth.finishAuthorization(url)
            try await validateAccount()
            startSyncing()
        } catch let error as ProviderError {
            authenticationState = .denied
            state.lastError = error
            publish()
        } catch {
            authenticationState = .denied
            state.lastError = ProviderError(code: .authorizationDenied, message: error.localizedDescription)
            publish()
        }
    }

    func disconnect() async {
        syncTask?.cancel()
        oauth?.clear()
        devices = []
        isPremium = false
        authenticationState = .notDetermined
        state = PlaybackState(status: .stopped, providerID: id)
        queue = PlaybackQueue()
        publish()
    }

    func play() async throws {
        try await requirePremium()
        try await performNoContent(path: "/me/player/play", method: "PUT", body: nil)
        try await refreshPlayback()
    }

    func pause() async throws {
        try await performNoContent(path: "/me/player/pause", method: "PUT", body: nil)
        try await refreshPlayback()
    }

    func stop() async throws { try await pause(); state.status = .stopped; publish() }

    func play(item: PlaybackItem) async throws {
        try await requirePremium()
        guard item.providerID == id else { throw ProviderError(code: .itemUnavailable, message: "That item belongs to a different provider.") }
        let body = try JSONSerialization.data(withJSONObject: ["uris": ["spotify:track:\(item.providerItemID)"]])
        try await performNoContent(path: "/me/player/play", method: "PUT", body: body)
        queue = PlaybackQueue(items: [item], currentIndex: 0)
        try await refreshPlayback()
    }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        try await requirePremium()
        let uris = items.map { "spotify:track:\($0.providerItemID)" }
        let body = try JSONSerialization.data(withJSONObject: ["uris": uris, "offset": ["position": index]])
        try await performNoContent(path: "/me/player/play", method: "PUT", body: body)
        queue = PlaybackQueue(items: items, currentIndex: index)
        try await refreshPlayback()
    }

    func seek(to position: Duration) async throws {
        let milliseconds = max(0, Int(position.secondsValue * 1_000))
        try await performNoContent(path: "/me/player/seek", method: "PUT", query: [URLQueryItem(name: "position_ms", value: "\(milliseconds)")], body: nil)
        try await refreshPlayback()
    }

    func skipToNext() async throws { try await performNoContent(path: "/me/player/next", method: "POST", body: nil); try await refreshPlayback() }
    func skipToPrevious() async throws { try await performNoContent(path: "/me/player/previous", method: "POST", body: nil); try await refreshPlayback() }

    func setVolume(_ volume: Double) async throws {
        guard devices.first(where: { $0.isActive })?.supportsVolume == true else {
            throw ProviderError(code: .unsupported, message: "The active Spotify device does not expose volume control.")
        }
        let value = min(max(Int((volume * 100).rounded()), 0), 100)
        try await performNoContent(path: "/me/player/volume", method: "PUT", query: [URLQueryItem(name: "volume_percent", value: "\(value)")], body: nil)
        try await refreshPlayback()
    }

    func setShuffleMode(_ mode: ShuffleMode) async throws {
        try await performNoContent(path: "/me/player/shuffle", method: "PUT", query: [URLQueryItem(name: "state", value: mode == .songs ? "true" : "false")], body: nil)
        try await refreshPlayback()
    }

    func setRepeatMode(_ mode: RepeatMode) async throws {
        let value = switch mode { case .off: "off"; case .all: "context"; case .one: "track" }
        try await performNoContent(path: "/me/player/repeat", method: "PUT", query: [URLQueryItem(name: "state", value: value)], body: nil)
        try await refreshPlayback()
    }

    func search(_ term: String) async throws -> MusicSearchResults {
        let data = try await request(path: "/search", query: [
            URLQueryItem(name: "q", value: term), URLQueryItem(name: "type", value: "track,album,artist,playlist"), URLQueryItem(name: "limit", value: "20")
        ])
        return try SpotifyMapper.search(data: data)
    }

    func library() async throws -> MusicLibrarySnapshot {
        async let tracksData = request(path: "/me/tracks", query: [URLQueryItem(name: "limit", value: "50")])
        async let playlistsData = request(path: "/me/playlists", query: [URLQueryItem(name: "limit", value: "50")])
        let tracks = try await SpotifyMapper.savedTracks(data: tracksData)
        let playlists = try await SpotifyMapper.playlists(data: playlistsData)
        return MusicLibrarySnapshot(songs: tracks, playlists: playlists)
    }

    func transferPlayback(to deviceID: String, play: Bool = false) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["device_ids": [deviceID], "play": play])
        try await performNoContent(path: "/me/player", method: "PUT", body: body)
        selectedDeviceID = deviceID
        try await refreshPlayback()
    }

    func refreshDevices() async throws -> [Device] {
        let data = try await request(path: "/me/player/devices")
        let response = try JSONDecoder().decode(DeviceResponse.self, from: data)
        devices = response.devices.map { Device(id: $0.id ?? "", name: $0.name, type: $0.type, isActive: $0.isActive, isRestricted: $0.isRestricted, supportsVolume: $0.supportsVolume) }
        return devices
    }

    private func validateAccount() async throws {
        let data = try await request(path: "/me")
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        isPremium = profile.product?.lowercased() == "premium"
        authenticationState = .authorized
        state.status = .stopped
        publish()
    }

    private func requirePremium() async throws {
        if authenticationState != .authorized { try await authorize() }
        guard isPremium else { throw ProviderError(code: .subscriptionRequired, message: "Spotify playback control requires a Premium account.") }
    }

    private func startSyncing() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                try? await self?.refreshPlayback()
            }
        }
    }

    private func refreshPlayback() async throws {
        guard authenticationState == .authorized else { return }
        let (data, response) = try await requestWithResponse(path: "/me/player")
        if response.statusCode == 204 {
            state.status = .stopped
            state.currentItem = nil
            state.duration = nil
            queue = PlaybackQueue()
            publish()
            return
        }
        let playback = try JSONDecoder().decode(PlaybackResponse.self, from: data)
        let item = playback.item.map(SpotifyMapper.item)
        state.currentItem = item
        state.duration = item?.duration
        state.elapsed = .seconds(Double(playback.progressMS ?? 0) / 1_000)
        state.status = playback.isPlaying == true ? .playing : .paused
        state.volume = Double(playback.device?.volumePercent ?? Int(state.volume * 100)) / 100
        state.shuffleMode = playback.shuffleState == true ? .songs : .off
        state.repeatMode = switch playback.repeatState { case "track": .one; case "context": .all; default: .off }
        if let device = playback.device {
            devices = [Device(id: device.id ?? "", name: device.name, type: device.type, isActive: device.isActive, isRestricted: device.isRestricted, supportsVolume: device.supportsVolume)]
            selectedDeviceID = device.id
        }
        if let item { queue = PlaybackQueue(items: [item], currentIndex: 0) }
        publish()
    }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let (data, response) = try await requestWithResponse(path: path, method: method, query: query, body: body)
        guard (200..<300).contains(response.statusCode) else { throw mappedProviderError(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        return data
    }

    private func requestWithResponse(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let oauth else { throw ProviderError(code: .providerUnavailable, message: "Spotify is not configured.") }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw ProviderError(code: .invalidResponse, message: "Spotify request URL could not be created.") }
        let token = try await oauth.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setOAuthBearer(token)
        let response = try await transport.send(request)
        if response.1.statusCode == 401 {
            throw mappedProviderError(status: 401)
        }
        return response
    }

    private func performNoContent(path: String, method: String, query: [URLQueryItem] = [], body: Data?) async throws {
        _ = try await request(path: path, method: method, query: query, body: body)
    }
}

private struct Profile: Decodable { var product: String? }
private struct DeviceResponse: Decodable { var devices: [SpotifyDevice] }
private struct SpotifyDevice: Decodable { var id: String?; var name: String; var type: String; var isActive: Bool; var isRestricted: Bool; var supportsVolume: Bool }
private struct PlaybackResponse: Decodable {
    var device: SpotifyPlaybackDevice?
    var repeatState: String?
    var shuffleState: Bool?
    var progressMS: Int?
    var isPlaying: Bool?
    var item: SpotifyTrack?
    enum CodingKeys: String, CodingKey { case device, repeatState = "repeat_state", shuffleState = "shuffle_state", progressMS = "progress_ms", isPlaying = "is_playing", item }
}
private struct SpotifyPlaybackDevice: Decodable {
    var id: String?
    var name: String
    var type: String
    var isActive: Bool
    var isRestricted: Bool
    var supportsVolume: Bool
    var volumePercent: Int?
    enum CodingKeys: String, CodingKey { case id, name, type, isActive = "is_active", isRestricted = "is_restricted", supportsVolume = "supports_volume", volumePercent = "volume_percent" }
}

fileprivate enum SpotifyMapper {
    static func item(_ track: SpotifyTrack) -> PlaybackItem {
        PlaybackItem(id: PlaybackItemID(rawValue: track.id), providerID: .spotify, providerItemID: track.id, title: track.name,
                     artist: track.artists.first?.name, albumTitle: track.album?.name,
                     duration: track.durationMS.map { .milliseconds($0) },
                     artwork: track.album?.images.first.flatMap { URL(string: $0.url) }.map(ArtworkReference.remote),
                     mediaKind: .song, isExplicit: track.explicit)
    }

    static func search(data: Data) throws -> MusicSearchResults {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return MusicSearchResults(
            songs: response.tracks?.items.map(item) ?? [],
            albums: response.albums?.items.map { PlaybackCollection(id: $0.id, providerID: .spotify, title: $0.name, subtitle: $0.artists.first?.name, artwork: $0.images.first.flatMap { URL(string: $0.url) }.map(ArtworkReference.remote), kind: .album) } ?? [],
            artists: response.artists?.items.map { PlaybackCollection(id: $0.id, providerID: .spotify, title: $0.name, artwork: $0.images.first.flatMap { URL(string: $0.url) }.map(ArtworkReference.remote), kind: .artist) } ?? [],
            playlists: response.playlists?.items.map { PlaybackCollection(id: $0.id, providerID: .spotify, title: $0.name, subtitle: $0.owner?.displayName, artwork: $0.images.first.flatMap { URL(string: $0.url) }.map(ArtworkReference.remote), kind: .playlist) } ?? []
        )
    }

    static func savedTracks(data: Data) throws -> [PlaybackItem] { try JSONDecoder().decode(SavedTrackResponse.self, from: data).items.map { item($0.track) } }
    static func playlists(data: Data) throws -> [PlaybackCollection] { try JSONDecoder().decode(PlaylistResponse.self, from: data).items.map { PlaybackCollection(id: $0.id, providerID: .spotify, title: $0.name, subtitle: $0.owner?.displayName, artwork: $0.images.first.flatMap { URL(string: $0.url) }.map(ArtworkReference.remote), kind: .playlist) } }
}

private struct SearchResponse: Decodable { var tracks: Page<SpotifyTrack>?; var albums: Page<SpotifyAlbum>?; var artists: Page<SpotifyArtist>?; var playlists: Page<SpotifyPlaylist>? }
private struct Page<T: Decodable>: Decodable { var items: [T] }
private struct SavedTrackResponse: Decodable { var items: [SavedTrack] }
private struct SavedTrack: Decodable { var track: SpotifyTrack }
private struct PlaylistResponse: Decodable { var items: [SpotifyPlaylist] }
private struct SpotifyTrack: Decodable { var id: String; var name: String; var explicit: Bool; var durationMS: Int?; var artists: [SpotifyArtist]; var album: SpotifyAlbum?; enum CodingKeys: String, CodingKey { case id, name, explicit, durationMS = "duration_ms", artists, album } }
private struct SpotifyAlbum: Decodable { var id: String; var name: String; var artists: [SpotifyArtist]; var images: [SpotifyImage] }
private struct SpotifyArtist: Decodable { var id: String; var name: String; var images: [SpotifyImage] = [] }
private struct SpotifyPlaylist: Decodable { var id: String; var name: String; var owner: SpotifyOwner?; var images: [SpotifyImage] }
private struct SpotifyOwner: Decodable { var displayName: String?; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
private struct SpotifyImage: Decodable { var url: String }
