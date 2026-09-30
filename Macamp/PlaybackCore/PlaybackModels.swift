import Foundation

// Playback metadata also carries the technical fields used by Winamp skin readouts.

struct PlaybackProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    static let appleMusic: Self = "apple-music"
    static let preview: Self = "preview"
    static let localMedia: Self = "local-media"
    static let spotify: Self = "spotify"
    static let tidal: Self = "tidal"
    static let soundCloud: Self = "soundcloud"
    static let youtube: Self = "youtube"
    static let deezer: Self = "deezer"
}

struct PlaybackItemID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
}

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case song, album, artist, playlist, podcastEpisode, radioStation, localFile, unknown
}

enum ArtworkReference: Hashable, Sendable {
    case remote(URL)
    case embedded(Data)
    case systemSymbol(String)
}

struct PlaybackItem: Identifiable, Hashable, Sendable {
    let id: PlaybackItemID
    let providerID: PlaybackProviderID
    let providerItemID: String
    var title: String
    var artist: String?
    var albumTitle: String?
    var duration: Duration?
    var artwork: ArtworkReference?
    var mediaKind: MediaKind
    var isExplicit: Bool
    var sourceURL: URL? = nil
    var attribution: String? = nil
    var bitrateKbps: Int? = nil
    var sampleRateHz: Int? = nil
    var channelCount: Int? = nil
    var fileExtension: String? = nil

    init(
        id: PlaybackItemID,
        providerID: PlaybackProviderID,
        providerItemID: String,
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        duration: Duration? = nil,
        artwork: ArtworkReference? = nil,
        mediaKind: MediaKind,
        isExplicit: Bool,
        sourceURL: URL?,
        attribution: String?
    ) {
        self.id = id
        self.providerID = providerID
        self.providerItemID = providerItemID
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.artwork = artwork
        self.mediaKind = mediaKind
        self.isExplicit = isExplicit
        self.sourceURL = sourceURL
        self.attribution = attribution
    }

    // Keep the common initializer free of trailing default-argument entry
    // points. This also makes the model link reliably when the app is loaded
    // as a test bundle with Swift's explicit-module build mode.
    init(
        id: PlaybackItemID,
        providerID: PlaybackProviderID,
        providerItemID: String,
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        duration: Duration? = nil,
        artwork: ArtworkReference? = nil,
        mediaKind: MediaKind,
        isExplicit: Bool
    ) {
        self.init(id: id, providerID: providerID, providerItemID: providerItemID, title: title, artist: artist, albumTitle: albumTitle, duration: duration, artwork: artwork, mediaKind: mediaKind, isExplicit: isExplicit, sourceURL: nil, attribution: nil)
    }

    init(
        id: PlaybackItemID,
        providerID: PlaybackProviderID,
        providerItemID: String,
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        duration: Duration? = nil,
        artwork: ArtworkReference? = nil,
        mediaKind: MediaKind,
        isExplicit: Bool,
        attribution: String
    ) {
        self.init(id: id, providerID: providerID, providerItemID: providerItemID, title: title, artist: artist, albumTitle: albumTitle, duration: duration, artwork: artwork, mediaKind: mediaKind, isExplicit: isExplicit, sourceURL: nil, attribution: attribution)
    }
}

struct PlaybackCollection: Identifiable, Hashable, Sendable {
    let id: String
    let providerID: PlaybackProviderID
    var title: String
    var subtitle: String?
    var artwork: ArtworkReference?
    var kind: MediaKind
    var sourceURL: URL? = nil
    var attribution: String? = nil
}

enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off, all, one
}

enum ShuffleMode: String, CaseIterable, Codable, Sendable {
    case off, songs
}

enum PlaybackStatus: String, Sendable {
    case unavailable, connecting, stopped, buffering, playing, paused, interrupted, failed
}

enum ProviderAuthenticationState: String, Sendable {
    case notDetermined, authorizing, authorized, denied, restricted, unavailable
}

struct ProviderError: Error, Equatable, Sendable, LocalizedError {
    enum Code: String, Sendable {
        case unsupported, authorizationDenied, subscriptionRequired, itemUnavailable
        case network, cancelled, invalidResponse, playbackFailed, rateLimited
        case providerUnavailable, externalDeviceRequired, policyRestriction, reauthorizationRequired, unknown
    }

    let code: Code
    let message: String

    var errorDescription: String? { message }

    static func unsupported(_ action: String) -> Self {
        Self(code: .unsupported, message: "The active provider does not support \(action).")
    }
}

struct PlaybackQueue: Equatable, Sendable {
    var items: [PlaybackItem] = []
    var currentIndex: Int?

    var currentItem: PlaybackItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }
}

struct PlaybackState: Equatable, Sendable {
    var status: PlaybackStatus = .unavailable
    var currentItem: PlaybackItem?
    var elapsed: Duration = .zero
    var duration: Duration?
    var playbackRate: Double = 0
    var volume: Double = 1
    var shuffleMode: ShuffleMode = .off
    var repeatMode: RepeatMode = .off
    var providerID: PlaybackProviderID?
    var lastError: ProviderError?

    var isPlaying: Bool { status == .playing }
}

struct ProviderSnapshot: Equatable, Sendable {
    var authenticationState: ProviderAuthenticationState
    var state: PlaybackState
    var queue: PlaybackQueue
}

extension Duration {
    nonisolated var secondsValue: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    nonisolated static func seconds(_ value: Double) -> Duration {
        .milliseconds(Int64((value * 1_000).rounded()))
    }
}
