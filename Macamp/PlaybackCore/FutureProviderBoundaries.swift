import Foundation

enum ExternalPlaybackIntegrationKind: String, Codable, Sendable {
    case remoteDeviceControl
    case officialEmbeddedPlayer
    case nativeDecodedAudio
}

struct FutureProviderDescriptor: Identifiable, Sendable {
    var id: PlaybackProviderID
    var displayName: String
    var permittedIntegrationKinds: Set<ExternalPlaybackIntegrationKind>
    var notes: String

    static let spotify = Self(
        id: "spotify", displayName: "Spotify",
        permittedIntegrationKinds: [.remoteDeviceControl, .officialEmbeddedPlayer],
        notes: "Requires OAuth and official Spotify APIs/SDKs. No native audio decoding is assumed."
    )
    static let youtube = Self(
        id: "youtube", displayName: "YouTube",
        permittedIntegrationKinds: [.officialEmbeddedPlayer],
        notes: "Metadata and playback remain separate; playback requires an official embedded player where permitted."
    )
}
