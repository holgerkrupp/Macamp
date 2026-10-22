import Foundation
import Testing
@testable import Macamp

@Suite("Local media")
struct LocalMediaTests {
    @Test func parsesRelativeM3UEntriesAndExtendedMetadata() {
        let playlistURL = URL(fileURLWithPath: "/Music/Mixes/night.m3u")
        let playlist = M3UPlaylistParser.parse(
            """
            #EXTM3U
            #EXTINF:213,The Artist - The Track
            ../Tracks/song.mp3
            https://example.com/live.mp3
            """,
            playlistURL: playlistURL
        )

        #expect(!playlist.isHLS)
        #expect(playlist.entries.count == 2)
        #expect(playlist.entries[0].url.path == "/Music/Tracks/song.mp3")
        #expect(playlist.entries[0].artist == "The Artist")
        #expect(playlist.entries[0].title == "The Track")
        #expect(playlist.entries[0].duration == .seconds(213))
        #expect(playlist.entries[1].url.absoluteString == "https://example.com/live.mp3")
    }

    @Test func recognizesHLSWithoutTreatingSegmentsAsSongs() {
        let playlist = M3UPlaylistParser.parse(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:8
            #EXTINF:8,
            segment0001.ts
            """,
            playlistURL: URL(fileURLWithPath: "/Streams/live.m3u8")
        )

        #expect(playlist.isHLS)
        #expect(playlist.entries.isEmpty)
    }

    @Test @MainActor func localProviderAdvertisesImplementedAudioBoundaries() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let provider = LocalFilePlaybackProvider(bookmarkStore: LocalMediaBookmarkStore(defaults: defaults))
        #expect(provider.capabilities.contains(.playback))
        #expect(provider.capabilities.contains(.localMetadata))
        #expect(provider.capabilities.contains(.playlists))
        #expect(!provider.capabilities.contains(.pcmAudio))
        #expect(!provider.capabilities.contains(.nativeEqualizer))
        #expect(!provider.effectCapabilities.contains(.equalizerBands))
        #expect(provider.effectUnavailableReason?.contains("AVPlayer") == true)
        do {
            try await provider.setBandGain(6, band: EqualizerBand.winamp10[0])
            Issue.record("EQ must be unavailable until playback uses the decoded local-file engine")
        } catch let error as ProviderError {
            #expect(error.code == .unsupported)
        }
    }
}
