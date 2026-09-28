import Foundation
import Auth
import EventProducer
import Player
import TidalAPI

@MainActor
final class TidalPlaybackProvider: ExternalPlaybackProviderBase, MusicDiscoveryProvider, OAuthCallbackHandling, PlayerListener {
    private let clientID: String?
    private let clientSecret: String?
    private let redirectURI: String
    private var loginInProgress = false
    private lazy var tidalPlayer: Player? = {
        Player.bootstrap(playerListener: self, credentialsProvider: TidalAuth.shared, eventSender: TidalEventSender.shared, shouldAddLogging: false)
    }()

    var isConfigured: Bool { clientID != nil && clientSecret != nil }

    init(configuration: ExternalProviderConfiguration) {
        clientID = configuration.tidalClientID
        clientSecret = configuration.tidalClientSecret
        redirectURI = "macamp://oauth/tidal"
        if let clientID = configuration.tidalClientID, let clientSecret = configuration.tidalClientSecret {
            TidalAuth.shared.config(config: AuthConfig(
                clientId: clientID,
                clientSecret: clientSecret,
                credentialsKey: "dev.holgerkrupp.Macamp.tidal",
                scopes: ["user.read", "collection.read", "playback"],
                enableLogging: false
            ))
        }
        super.init(
            id: .tidal,
            displayName: "TIDAL",
            capabilities: [.playback, .pause, .explicitStop, .seek, .previous, .next, .queueReading,
                            .queueEditing, .catalogueSearch, .userLibrary, .playlists, .artwork]
        )
        authenticationState = isConfigured && TidalAuth.shared.isUserLoggedIn ? .authorized : .notDetermined
    }

    func authorize() async throws {
        guard let clientID, clientSecret != nil else { throw ProviderError(code: .providerUnavailable, message: "TIDAL is not configured. Set MACAMP_TIDAL_CLIENT_ID and MACAMP_TIDAL_CLIENT_SECRET.") }
        _ = clientID
        guard !TidalAuth.shared.isUserLoggedIn else { authenticationState = .authorized; publish(); return }
        guard let url = TidalAuth.shared.initializeLogin(redirectUri: redirectURI, loginConfig: nil) else {
            throw ProviderError(code: .authorizationDenied, message: "TIDAL could not create an authorization URL.")
        }
        loginInProgress = true
        openAuthorizationURL(url)
    }

    func handleOAuthCallback(_ url: URL) async {
        guard loginInProgress else { return }
        do {
            try await TidalAuth.shared.finalizeLogin(loginResponseUri: url.absoluteString)
            loginInProgress = false; authenticationState = .authorized; publish()
        } catch {
            authenticationState = .denied
            state.lastError = ProviderError(code: .authorizationDenied, message: error.localizedDescription)
            publish()
        }
    }

    func disconnect() async {
        try? TidalAuth.shared.logout()
        tidalPlayer?.reset()
        authenticationState = .notDetermined
        state = PlaybackState(status: .stopped, providerID: id); queue = PlaybackQueue(); publish()
    }

    func play() async throws { try requireAuthorized(); tidalPlayer?.play(); state.status = .playing; state.playbackRate = 1; publish() }
    func pause() async throws { tidalPlayer?.pause(); state.status = .paused; state.playbackRate = 0; publish() }
    func stop() async throws { tidalPlayer?.reset(); state.status = .stopped; state.elapsed = .zero; state.playbackRate = 0; publish() }

    func play(item: PlaybackItem) async throws {
        try requireAuthorized()
        guard item.providerID == id else { throw ProviderError(code: .itemUnavailable, message: "That item belongs to a different provider.") }
        guard let player = tidalPlayer else { throw ProviderError(code: .providerUnavailable, message: "The official TIDAL Player could not be initialized.") }
        player.load(MediaProduct(productType: .TRACK, productId: item.providerItemID))
        player.play()
        state.currentItem = item; state.duration = item.duration; state.elapsed = .zero; state.status = .playing; state.playbackRate = 1
        if let index = queue.items.firstIndex(where: { $0.id == item.id }) { queue.currentIndex = index } else { queue = PlaybackQueue(items: [item], currentIndex: 0) }
        publish()
    }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        queue = PlaybackQueue(items: items, currentIndex: index); try await play(item: items[index])
    }

    func seek(to position: Duration) async throws { tidalPlayer?.seek(position.secondsValue); state.elapsed = position; publish() }
    func skipToNext() async throws { guard let index = queue.currentIndex, queue.items.indices.contains(index + 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no next TIDAL track.") }; try await play(items: queue.items, startingAt: index + 1) }
    func skipToPrevious() async throws { guard let index = queue.currentIndex, queue.items.indices.contains(index - 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no previous TIDAL track.") }; try await play(items: queue.items, startingAt: index - 1) }
    func setVolume(_ volume: Double) async throws { throw ProviderError.unsupported("application volume") }
    func setShuffleMode(_ mode: ShuffleMode) async throws { throw ProviderError.unsupported("shuffle") }
    func setRepeatMode(_ mode: RepeatMode) async throws { throw ProviderError.unsupported("repeat") }

    func search(_ term: String) async throws -> MusicSearchResults {
        try requireAuthorized()
        let search = try await SearchResultsAPITidal.searchResultsGet(filterQuery: term, countryCode: "US", include: ["tracks"])
        let items = (search.included ?? []).compactMap { included -> PlaybackItem? in
            guard case let .tracksResourceObject(track) = included, let attributes = track.attributes else { return nil }
            return PlaybackItem(id: PlaybackItemID(rawValue: track.id), providerID: .tidal, providerItemID: track.id, title: attributes.title,
                                artist: nil, albumTitle: nil, duration: TidalPlaybackProvider.duration(attributes.duration),
                                artwork: nil, mediaKind: .song, isExplicit: attributes.explicit)
        }
        return MusicSearchResults(songs: items)
    }

    func library() async throws -> MusicLibrarySnapshot {
        try requireAuthorized()
        let credentials = try await TidalAuth.shared.getCredentials(apiErrorSubStatus: nil)
        guard let userID = credentials.userId else {
            throw ProviderError(code: .reauthorizationRequired, message: "TIDAL did not return a user account for this authorization.")
        }
        let response = try await PlaylistsAPITidal.playlistsGet(countryCode: "US", include: ["items"], filterOwnersId: [userID])
        let playlists = response.data.map { playlist in
            PlaybackCollection(id: playlist.id, providerID: id, title: playlist.attributes?.name ?? "TIDAL playlist",
                               subtitle: "TIDAL playlist", artwork: nil, kind: .playlist, attribution: "TIDAL")
        }
        let songs = (response.included ?? []).compactMap { included -> PlaybackItem? in
            guard case let .tracksResourceObject(track) = included else { return nil }
            return mapTrack(track)
        }
        return MusicLibrarySnapshot(songs: songs, playlists: playlists)
    }

    func stateChanged(to playerState: State) {
        switch playerState {
        case .PLAYING: state.status = .playing; state.playbackRate = 1
        case .STALLED: state.status = .buffering
        case .NOT_PLAYING: state.status = .paused; state.playbackRate = 0
        case .IDLE: state.status = .stopped; state.playbackRate = 0
        }
        if let player = tidalPlayer { state.elapsed = .seconds(player.getAssetPosition() ?? state.elapsed.secondsValue) }
        publish()
    }

    func ended(_ mediaProduct: MediaProduct) { state.status = .stopped; state.playbackRate = 0; publish() }
    func mediaTransitioned(to mediaProduct: MediaProduct, with playbackContext: PlaybackContext) { publish() }
    func streamingPrivilegesLost(to device: String?) { state.lastError = ProviderError(code: .externalDeviceRequired, message: "TIDAL playback privileges were lost on this device."); publish() }
    func failed(with error: PlayerError) { state.status = .failed; state.lastError = ProviderError(code: .playbackFailed, message: "TIDAL playback failed."); publish() }
    func mediaServicesWereReset() { state.status = .stopped; publish() }
    func playbackQualityChanged(to playbackContext: PlaybackContext) { }

    private func requireAuthorized() throws {
        guard TidalAuth.shared.isUserLoggedIn else { throw ProviderError(code: .reauthorizationRequired, message: "Authorize TIDAL before using playback.") }
    }

    private static func duration(_ value: String) -> Duration? {
        let pattern = #"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func number(_ index: Int) -> Double { guard let range = Range(match.range(at: index), in: value) else { return 0 }; return Double(value[range]) ?? 0 }
        return .seconds(number(1) * 3_600 + number(2) * 60 + number(3))
    }

    private func mapTrack(_ track: TracksResourceObject) -> PlaybackItem? {
        guard let attributes = track.attributes else { return nil }
        return PlaybackItem(id: PlaybackItemID(rawValue: track.id), providerID: id, providerItemID: track.id,
                            title: attributes.title, artist: nil, albumTitle: nil,
                            duration: Self.duration(attributes.duration), artwork: nil,
                            mediaKind: .song, isExplicit: attributes.explicit, attribution: "TIDAL")
    }
}
