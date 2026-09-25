import MusicKit

struct AppleMusicLibraryService: Sendable {
    func load(limit: Int = 100) async throws -> (MusicLibrarySnapshot, [String: Song]) {
        var songRequest = MusicLibraryRequest<Song>(); songRequest.limit = limit
        var albumRequest = MusicLibraryRequest<Album>(); albumRequest.limit = limit
        var artistRequest = MusicLibraryRequest<Artist>(); artistRequest.limit = limit
        var playlistRequest = MusicLibraryRequest<Playlist>(); playlistRequest.limit = limit

        let songResponse = try await songRequest.response()
        try Task.checkCancellation()
        let albumResponse = try await albumRequest.response()
        let artistResponse = try await artistRequest.response()
        let playlistResponse = try await playlistRequest.response()
        let songs = Array(songResponse.items)
        return (
            MusicLibrarySnapshot(
                songs: songs.map(MusicKitModelMapper.item),
                albums: albumResponse.items.map(MusicKitModelMapper.album),
                artists: artistResponse.items.map(MusicKitModelMapper.artist),
                playlists: playlistResponse.items.map(MusicKitModelMapper.playlist)
            ),
            Dictionary(uniqueKeysWithValues: songs.map { ($0.id.rawValue, $0) })
        )
    }
}
