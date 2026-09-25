import MusicKit

struct AppleMusicCatalogService: Sendable {
    func search(_ term: String, limit: Int = 25) async throws -> (MusicSearchResults, [String: Song]) {
        try Task.checkCancellation()
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
        request.limit = limit
        let response = try await request.response()
        try Task.checkCancellation()
        let songs = Array(response.songs)
        return (
            MusicSearchResults(
                songs: songs.map(MusicKitModelMapper.item),
                albums: response.albums.map(MusicKitModelMapper.album),
                artists: response.artists.map(MusicKitModelMapper.artist),
                playlists: response.playlists.map(MusicKitModelMapper.playlist)
            ),
            Dictionary(uniqueKeysWithValues: songs.map { ($0.id.rawValue, $0) })
        )
    }
}
