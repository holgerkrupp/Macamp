import Foundation
import MusicKit

enum MusicKitModelMapper {
    static func item(_ song: Song) -> PlaybackItem {
        let rawID = song.id.rawValue
        return PlaybackItem(
            id: PlaybackItemID(rawValue: "apple-music:song:\(rawID)"),
            providerID: .appleMusic,
            providerItemID: rawID,
            title: song.title,
            artist: song.artistName,
            albumTitle: song.albumTitle,
            duration: song.duration.map(Duration.seconds),
            artwork: artwork(song.artwork),
            mediaKind: .song,
            isExplicit: song.contentRating == .explicit
        )
    }

    static func album(_ album: Album) -> PlaybackCollection {
        PlaybackCollection(id: album.id.rawValue, providerID: .appleMusic, title: album.title, subtitle: album.artistName, artwork: artwork(album.artwork), kind: .album)
    }

    static func artist(_ artist: Artist) -> PlaybackCollection {
        PlaybackCollection(id: artist.id.rawValue, providerID: .appleMusic, title: artist.name, artwork: artwork(artist.artwork), kind: .artist)
    }

    static func playlist(_ playlist: Playlist) -> PlaybackCollection {
        PlaybackCollection(id: playlist.id.rawValue, providerID: .appleMusic, title: playlist.name, subtitle: playlist.curatorName, artwork: artwork(playlist.artwork), kind: .playlist)
    }

    static func queueEntry(_ entry: MusicPlayer.Queue.Entry) -> PlaybackItem {
        if case let .song(song)? = entry.item { return item(song) }
        return PlaybackItem(
            id: PlaybackItemID(rawValue: "apple-music:queue:\(entry.id)"), providerID: .appleMusic,
            providerItemID: entry.id, title: entry.title, artist: entry.subtitle, artwork: artwork(entry.artwork),
            mediaKind: .unknown, isExplicit: false
        )
    }

    static func artwork(_ artwork: Artwork?) -> ArtworkReference? {
        artwork?.url(width: 600, height: 600).map(ArtworkReference.remote)
    }

    static func authorization(_ status: MusicAuthorization.Status) -> ProviderAuthenticationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .unavailable
        }
    }

    static func playbackStatus(_ status: MusicPlayer.PlaybackStatus) -> PlaybackStatus {
        switch status {
        case .stopped: .stopped
        case .playing: .playing
        case .paused: .paused
        case .interrupted: .interrupted
        case .seekingForward, .seekingBackward: .buffering
        @unknown default: .unavailable
        }
    }
}
