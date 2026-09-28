import AppKit
import Foundation
import WebKit
import SwiftUI

@MainActor
final class YouTubePlaybackProvider: ExternalPlaybackProviderBase, MusicDiscoveryProvider, OAuthCallbackHandling {
    private let transport: any ProviderHTTPTransport
    private let apiKey: String?
    private let oauth: OAuthSession?
    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3")!
    private(set) var isPlayerVisible = false
    lazy var playerController: YouTubePlayerController = YouTubePlayerController { [weak self] event in
        self?.handlePlayerEvent(event)
    }

    var isConfigured: Bool { apiKey != nil }

    init(configuration: ExternalProviderConfiguration, transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()) {
        self.transport = transport
        apiKey = configuration.youtubeAPIKey
        if let clientID = configuration.youtubeClientID, let redirectURI = configuration.youtubeRedirectURI {
            oauth = OAuthSession(
                providerID: .youtube,
                configuration: OAuthPKCEConfiguration(
                    clientID: clientID,
                    authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                    tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                    redirectURI: redirectURI,
                    scopes: ["https://www.googleapis.com/auth/youtube.readonly"]
                )
            )
        } else {
            oauth = nil
        }
        super.init(
            id: .youtube,
            displayName: "YouTube",
            capabilities: [.playback, .pause, .explicitStop, .seek, .previous, .next, .applicationVolume,
                            .queueReading, .queueEditing, .catalogueSearch, .playlists, .artwork]
        )
        authenticationState = oauth?.isAuthorized == true || apiKey != nil ? .authorized : .notDetermined
    }

    func authorize() async throws {
        guard apiKey != nil else { throw ProviderError(code: .providerUnavailable, message: "YouTube is not configured. Set MACAMP_YOUTUBE_API_KEY.") }
        if let oauth, !oauth.isAuthorized {
            openAuthorizationURL(try oauth.beginAuthorization())
        } else {
            authenticationState = .authorized
            publish()
        }
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
        playerController.stop()
        oauth?.clear()
        authenticationState = apiKey == nil ? .notDetermined : .authorized
        state = PlaybackState(status: .stopped, providerID: id); queue = PlaybackQueue(); publish()
    }

    func setPlayerSurfaceVisible(_ visible: Bool) {
        isPlayerVisible = visible
        if !visible && state.isPlaying {
            playerController.pause()
            state.status = .paused
            state.playbackRate = 0
            publish()
        }
    }

    func play() async throws {
        guard isPlayerVisible else { throw ProviderError(code: .policyRestriction, message: "YouTube playback requires the visible official player surface.") }
        playerController.play(); state.status = .playing; state.playbackRate = 1; publish()
    }

    func pause() async throws { playerController.pause(); state.status = .paused; state.playbackRate = 0; publish() }
    func stop() async throws { playerController.stop(); state.status = .stopped; state.elapsed = .zero; state.playbackRate = 0; publish() }

    func play(item: PlaybackItem) async throws {
        guard isPlayerVisible else { throw ProviderError(code: .policyRestriction, message: "YouTube playback requires the visible official player surface.") }
        guard item.providerID == id else { throw ProviderError(code: .itemUnavailable, message: "That item belongs to a different provider.") }
        playerController.load(videoID: item.providerItemID)
        playerController.play()
        state.currentItem = item; state.duration = item.duration; state.elapsed = .zero; state.status = .playing; state.playbackRate = 1
        if let index = queue.items.firstIndex(where: { $0.id == item.id }) { queue.currentIndex = index } else { queue = PlaybackQueue(items: [item], currentIndex: 0) }
        publish()
    }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else { throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.") }
        queue = PlaybackQueue(items: items, currentIndex: index)
        try await play(item: items[index])
    }

    func seek(to position: Duration) async throws { playerController.seek(seconds: position.secondsValue); state.elapsed = position; publish() }
    func skipToNext() async throws { guard let index = queue.currentIndex, queue.items.indices.contains(index + 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no next YouTube video.") }; try await play(items: queue.items, startingAt: index + 1) }
    func skipToPrevious() async throws { guard let index = queue.currentIndex, queue.items.indices.contains(index - 1) else { throw ProviderError(code: .itemUnavailable, message: "There is no previous YouTube video.") }; try await play(items: queue.items, startingAt: index - 1) }
    func setVolume(_ volume: Double) async throws { playerController.setVolume(percent: Int(min(max(volume, 0), 1) * 100)); state.volume = volume; publish() }
    func setShuffleMode(_ mode: ShuffleMode) async throws { throw ProviderError.unsupported("shuffle") }
    func setRepeatMode(_ mode: RepeatMode) async throws { throw ProviderError.unsupported("repeat") }

    func search(_ term: String) async throws -> MusicSearchResults {
        let data = try await request(path: "/search", query: [
            URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "q", value: term), URLQueryItem(name: "type", value: "video,playlist"), URLQueryItem(name: "maxResults", value: "25")
        ])
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let videos = response.items.compactMap { item -> PlaybackItem? in
            guard let id = item.id.videoID else { return nil }
            let artwork = URL(string: item.snippet.thumbnails.default.url).map(ArtworkReference.remote)
            return PlaybackItem(id: PlaybackItemID(rawValue: id), providerID: .youtube, providerItemID: id, title: item.snippet.title,
                                artist: item.snippet.channelTitle, albumTitle: nil, duration: nil, artwork: artwork,
                                mediaKind: .song, isExplicit: false,
                                sourceURL: URL(string: "https://www.youtube.com/watch?v=\(id)"), attribution: "YouTube")
        }
        let playlists = response.items.compactMap { item -> PlaybackCollection? in
            guard let id = item.id.playlistID else { return nil }
            return PlaybackCollection(id: id, providerID: .youtube, title: item.snippet.title, subtitle: item.snippet.channelTitle,
                                      artwork: URL(string: item.snippet.thumbnails.default.url).map(ArtworkReference.remote), kind: .playlist,
                                      sourceURL: URL(string: "https://www.youtube.com/playlist?list=\(id)"), attribution: "YouTube")
        }
        return MusicSearchResults(songs: videos, playlists: playlists)
    }

    func library() async throws -> MusicLibrarySnapshot {
        guard let oauth else { throw ProviderError.unsupported("YouTube user library without OAuth") }
        let token = try await oauth.accessToken()
        let data = try await request(path: "/playlists", query: [URLQueryItem(name: "part", value: "snippet"), URLQueryItem(name: "mine", value: "true"), URLQueryItem(name: "maxResults", value: "50")], bearer: token)
        let response = try JSONDecoder().decode(PlaylistResponse.self, from: data)
        return MusicLibrarySnapshot(playlists: response.items.map { item in
            PlaybackCollection(id: item.id, providerID: .youtube, title: item.snippet.title, subtitle: item.snippet.channelTitle,
                               artwork: URL(string: item.snippet.thumbnails.default.url).map(ArtworkReference.remote), kind: .playlist,
                               sourceURL: URL(string: "https://www.youtube.com/playlist?list=\(item.id)"), attribution: "YouTube")
        })
    }

    private func request(path: String, query: [URLQueryItem], bearer: String? = nil) async throws -> Data {
        guard let apiKey else { throw ProviderError(code: .providerUnavailable, message: "YouTube Data API is not configured.") }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw ProviderError(code: .invalidResponse, message: "YouTube request URL could not be created.") }
        var request = URLRequest(url: url)
        if let bearer { request.setOAuthBearer(bearer) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw mappedProviderError(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        return data
    }

    private func handlePlayerEvent(_ event: YouTubePlayerEvent) {
        switch event.kind {
        case .playing: state.status = .playing; state.playbackRate = 1
        case .paused: state.status = .paused; state.playbackRate = 0
        case .ended: state.status = .stopped; state.playbackRate = 0
        case .buffering: state.status = .buffering
        case .time: state.elapsed = .seconds(event.currentTime); if event.duration > 0 { state.duration = .seconds(event.duration) }
        }
        publish()
    }
}

@MainActor
final class YouTubePlayerController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private var ready = false
    private var pendingVideoID: String?
    private var pendingPlay = false
    private let onEvent: (YouTubePlayerEvent) -> Void

    init(onEvent: @escaping (YouTubePlayerEvent) -> Void) {
        self.onEvent = onEvent
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)
        super.init()
        controller.add(self, name: "macampPlayer")
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://www.youtube.com"))
    }

    func load(videoID: String) { pendingVideoID = videoID; evaluate("loadVideoById('\(Self.escape(videoID))')") }
    func play() {
        guard ready else { pendingPlay = true; return }
        evaluate("playVideo()")
    }
    func pause() { evaluate("pauseVideo()") }
    func stop() { evaluate("stopVideo()") }
    func seek(seconds: Double) { evaluate("seekTo(\(max(0, seconds)))") }
    func setVolume(percent: Int) { evaluate("setVolume(\(min(max(percent, 0), 100)))") }
    func setVisible(_ value: Bool) { webView.isHidden = !value }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dictionary = message.body as? [String: Any], let kindValue = dictionary["kind"] as? String else { return }
        let kind: YouTubePlayerEvent.Kind = switch kindValue { case "playing": .playing; case "paused": .paused; case "ended": .ended; case "buffering": .buffering; default: .time }
        onEvent(YouTubePlayerEvent(kind: kind, currentTime: dictionary["currentTime"] as? Double ?? 0, duration: dictionary["duration"] as? Double ?? 0))
        if kind == .time, !ready {
            ready = true
            if let pendingVideoID { load(videoID: pendingVideoID) }
            if pendingPlay { pendingPlay = false; evaluate("playVideo()") }
        }
    }

    private func evaluate(_ script: String) { guard ready else { return }; webView.evaluateJavaScript("window.macampPlayer && window.macampPlayer.\(script)") }

    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }

    private static let html = """
    <!doctype html><html><body style="margin:0;background:#000;overflow:hidden"><div id="player" style="width:640px;height:360px"></div>
    <script src="https://www.youtube.com/iframe_api"></script><script>
    var player; window.macampPlayer={loadVideoById:function(id){if(player)player.loadVideoById(id)},playVideo:function(){if(player)player.playVideo()},pauseVideo:function(){if(player)player.pauseVideo()},stopVideo:function(){if(player)player.stopVideo()},seekTo:function(v){if(player)player.seekTo(v,true)},setVolume:function(v){if(player)player.setVolume(v)}};
    function send(kind){if(window.webkit&&window.webkit.messageHandlers.macampPlayer){window.webkit.messageHandlers.macampPlayer.postMessage({kind:kind,currentTime:player?player.getCurrentTime():0,duration:player?player.getDuration():0})}}
    function onYouTubeIframeAPIReady(){player=new YT.Player('player',{width:'640',height:'360',videoId:'',playerVars:{playsinline:1},events:{onReady:function(){send('time')},onStateChange:function(e){send(e.data==1?'playing':e.data==2?'paused':e.data==0?'ended':e.data==3?'buffering':'time')}}});setInterval(function(){if(player)send('time')},500)}
    </script></body></html>
    """
}

struct YouTubePlayerEvent: Sendable {
    enum Kind: Sendable { case playing, paused, ended, buffering, time }
    var kind: Kind
    var currentTime: Double
    var duration: Double
}

struct YouTubePlayerSurface: NSViewRepresentable {
    let provider: YouTubePlaybackProvider
    func makeCoordinator() -> Coordinator { Coordinator(provider: provider) }
    func makeNSView(context: Context) -> WKWebView { provider.setPlayerSurfaceVisible(true); return provider.playerController.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { provider.setPlayerSurfaceVisible(true); provider.playerController.setVisible(true) }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) { coordinator.provider.setPlayerSurfaceVisible(false) }

    @MainActor final class Coordinator {
        let provider: YouTubePlaybackProvider
        init(provider: YouTubePlaybackProvider) { self.provider = provider }
    }
}

private struct SearchResponse: Decodable { var items: [SearchItem] }
private struct SearchItem: Decodable { var id: SearchID; var snippet: SearchSnippet }
private struct SearchID: Decodable { var videoID: String?; var playlistID: String?; enum CodingKeys: String, CodingKey { case videoID = "videoId", playlistID = "playlistId" } }
private struct SearchSnippet: Decodable { var title: String; var channelTitle: String; var thumbnails: Thumbnails }
private struct PlaylistResponse: Decodable { var items: [PlaylistItem] }
private struct PlaylistItem: Decodable { var id: String; var snippet: SearchSnippet }
private struct Thumbnails: Decodable { var `default`: Thumbnail }
private struct Thumbnail: Decodable { var url: String }
