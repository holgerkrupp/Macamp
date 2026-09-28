import AVFoundation
import Foundation

@MainActor
final class SoundCloudPlaybackProvider: ExternalPlaybackProviderBase, MusicDiscoveryProvider, OAuthCallbackHandling {
    private let transport: any ProviderHTTPTransport
    private let oauth: OAuthSession?
    private let clientID: String?
    private let player = AVPlayer()
    private let baseURL = URL(string: "https://api.soundcloud.com")!
    private var timeObserver: Any?
    private var currentIndex: Int?

    var isConfigured: Bool { oauth != nil && clientID != nil }

    init(configuration: ExternalProviderConfiguration, transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) {
        self.transport = transport
        clientID = configuration.soundCloudClientID
        if let clientID = configuration.soundCloudClientID, let redirectURI = configuration.soundCloudRedirectURI {
            oauth = OAuthSession(
                providerID: .soundCloud,
                configuration: OAuthPKCEConfiguration(
                    clientID: clientID,
                    clientSecret: configuration.soundCloudClientSecret,
                    authorizationEndpoint: URL(string: "https://secure.soundcloud.com/authorize")!,
                    tokenEndpoint: URL(string: "https://secure.soundcloud.com/oauth/token")!,
                    redirectURI: redirectURI,
                    scopes: ["non-expiring"]
                )
            )
        } else {
            oauth = nil
        }
        super.init(
            id: .soundCloud,
            displayName: "SoundCloud",
            capabilities: [.playback, .pause, .explicitStop, .seek, .previous, .next, .applicationVolume,
                            .queueReading, .queueEditing, .catalogueSearch, .userLibrary, .playlists, .artwork]
        )
        authenticationState = oauth?.isAuthorized == true ? .authorized : .notDetermined
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard time.isNumeric else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.elapsed = .seconds(time.seconds)
                self.publish()
            }
        }
    }

    func authorize() async throws {
        guard let oauth else { throw ProviderError(code: .providerUnavailable, message: "SoundCloud is not configured. Set MACAMP_SOUNDCLOUD_CLIENT_ID and MACAMP_SOUNDCLOUD_REDIRECT_URI.") }
        if oauth.isAuthorized { authenticationState = .authorized; publish(); return }
        openAuthorizationURL(try oauth.beginAuthorization())
    }

    func handleOAuthCallback(_ url: URL) async {
        guard let oauth else { return }
        do {
            try await oauth.finishAuthorization(url)
            authenticationState = .authorized
            publish()
        } catch let error as ProviderError {
            authenticationState = .denied; state.lastError = error; publish()
        } catch {
            authenticationState = .denied; state.lastError = ProviderError(code: .authorizationDenied, message: error.localizedDescription); publish()
        }
    }

    func disconnect() async {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause(); player.replaceCurrentItem(with: nil)
        oauth?.clear(); authenticationState = .notDetermined
        state = PlaybackState(status: .stopped, providerID: id); queue = PlaybackQueue(); currentIndex = nil; publish()
    }

    func play() async throws {
        guard player.currentItem != nil else {
            guard let currentIndex, queue.items.indices.contains(currentIndex) else { throw ProviderError(code: .itemUnavailable, message: "No SoundCloud track is queued.") }
            try await play(item: queue.items[currentIndex])
            return
        }
        player.play(); state.status = .playing; state.playbackRate = 1; publish()
    }

    func pause() async throws { player.pause(); state.status = .paused; state.playbackRate = 0; publish() }
    func stop() async throws { player.pause(); await player.seek(to: .zero); state.status = .stopped; state.elapsed = .zero; state.playbackRate = 0; publish() }

    func play(item: PlaybackItem) async throws {
        guard item.providerID == id else { throw ProviderError(code: .itemUnavailable, message: "That item belongs to a different provider.") }
        let url = try await resolveStreamURL(for: item.providerItemID)
        let token = try await oauth?.accessToken()
        let assetOptions: [String: Any] = token.map { ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "OAuth \($0)"]] } ?? [:]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        player.play()
        state.currentItem = item
        state.duration = item.duration
        state.elapsed = .zero
        state.status = .playing
        state.playbackRate = 1
        if let index = queue.items.firstIndex(where: { $0.id == item.id }) { currentIndex = index } else { queue = PlaybackQueue(items: [item], currentIndex: 0); currentIndex = 0 }
        publish()
    }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        queue = PlaybackQueue(items: items, currentIndex: index); currentIndex = index
        try await play(item: items[index])
    }

    func seek(to position: Duration) async throws {
        let target = max(0, position.secondsValue)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        state.elapsed = .seconds(target); publish()
    }

    func skipToNext() async throws {
        guard let currentIndex, queue.items.indices.contains(currentIndex + 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no next SoundCloud track.") }
        try await play(items: queue.items, startingAt: currentIndex + 1)
    }

    func skipToPrevious() async throws {
        guard let currentIndex, queue.items.indices.contains(currentIndex - 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no previous SoundCloud track.") }
        try await play(items: queue.items, startingAt: currentIndex - 1)
    }

    func setVolume(_ volume: Double) async throws { player.volume = Float(min(max(volume, 0), 1)); state.volume = volume; publish() }
    func setShuffleMode(_ mode: ShuffleMode) async throws { throw ProviderError.unsupported("shuffle") }
    func setRepeatMode(_ mode: RepeatMode) async throws { throw ProviderError.unsupported("repeat") }

    func search(_ term: String) async throws -> MusicSearchResults {
        let data = try await request(path: "/tracks", query: [URLQueryItem(name: "q", value: term), URLQueryItem(name: "limit", value: "50")])
        return MusicSearchResults(songs: try JSONDecoder().decode([SoundCloudTrack].self, from: data).map(mapTrack))
    }

    func library() async throws -> MusicLibrarySnapshot {
        let meData = try await request(path: "/me")
        let me = try JSONDecoder().decode(SoundCloudUser.self, from: meData)
        async let likesData = request(path: "/users/\(me.id)/likes/tracks", query: [URLQueryItem(name: "limit", value: "50")])
        async let playlistsData = request(path: "/users/\(me.id)/playlists", query: [URLQueryItem(name: "limit", value: "50")])
        let likes = try await JSONDecoder().decode([SoundCloudLike].self, from: likesData).compactMap { $0.track }.map(mapTrack)
        let playlists = try await JSONDecoder().decode([SoundCloudPlaylist].self, from: playlistsData).map { mapPlaylist($0) }
        return MusicLibrarySnapshot(songs: likes, playlists: playlists)
    }

    private func resolveStreamURL(for trackID: String) async throws -> URL {
        var request = URLRequest(url: baseURL.appending(path: "/tracks/\(trackID)/stream"))
        request.httpMethod = "GET"
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        if let token = try? await oauth?.accessToken() { request.setOAuthHeader(token) }
        if let clientID { request.url = request.url.flatMap { addClientID($0, clientID: clientID) } }
        let (data, response) = try await transport.send(request)
        guard (200..<400).contains(response.statusCode), let url = response.url, url != request.url else {
            _ = data
            throw mappedProviderError(status: response.statusCode)
        }
        return url
    }

    private func request(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let clientID else { throw ProviderError(code: .providerUnavailable, message: "SoundCloud is not configured.") }
        var url = baseURL.appending(path: path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query + [URLQueryItem(name: "client_id", value: clientID)]
        url = components?.url ?? url
        var request = URLRequest(url: url)
        if let token = try? await oauth?.accessToken() { request.setOAuthHeader(token) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw mappedProviderError(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        return data
    }

    private func addClientID(_ url: URL, clientID: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let existingItems = components.queryItems ?? []
        components.queryItems = existingItems + [URLQueryItem(name: "client_id", value: clientID)]
        return components.url ?? url
    }

    private func mapTrack(_ track: SoundCloudTrack) -> PlaybackItem {
        PlaybackItem(id: PlaybackItemID(rawValue: "\(track.id)"), providerID: id, providerItemID: "\(track.id)", title: track.title,
                     artist: track.user?.username, albumTitle: nil,
                     duration: track.duration.map { .milliseconds($0) },
                     artwork: track.artworkURL.flatMap(URL.init(string:)).map(ArtworkReference.remote),
                     mediaKind: .song, isExplicit: false,
                     sourceURL: track.permalinkURL.flatMap(URL.init(string:)),
                     attribution: track.user.map { "© \($0.username) on SoundCloud" })
    }

    private func mapPlaylist(_ playlist: SoundCloudPlaylist) -> PlaybackCollection {
        PlaybackCollection(id: "\(playlist.id)", providerID: id, title: playlist.title, subtitle: "SoundCloud playlist",
                           artwork: playlist.artworkURL.flatMap(URL.init(string:)).map(ArtworkReference.remote), kind: .playlist,
                           sourceURL: playlist.permalinkURL.flatMap(URL.init(string:)), attribution: "SoundCloud")
    }
}

fileprivate struct SoundCloudUser: Decodable { var id: Int; var username: String }
fileprivate struct SoundCloudLike: Decodable { var track: SoundCloudTrack? }
fileprivate struct SoundCloudPlaylist: Decodable { var id: Int; var title: String; var artworkURL: String?; var permalinkURL: String?; enum CodingKeys: String, CodingKey { case id, title, artworkURL = "artwork_url", permalinkURL = "permalink_url" } }
fileprivate struct SoundCloudTrack: Decodable {
    var id: Int; var title: String; var duration: Int?; var artworkURL: String?; var permalinkURL: String?; var user: SoundCloudUser?
    enum CodingKeys: String, CodingKey { case id, title, duration, artworkURL = "artwork_url", permalinkURL = "permalink_url", user }
}
