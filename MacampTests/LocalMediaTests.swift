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

    @Test func importsDirectAndPlaylistRadioStreamsWithoutLocalAssetOrBookmarkProbes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampRadioImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = root.appendingPathComponent("stations.m3u")
        try "#EXTM3U\n#EXTINF:-1,Local Jazz - Live\nhttps://radio.example/live.mp3\n".write(to: playlist, atomically: true, encoding: .utf8)
        let direct = URL(string: "https://news.example/stream")!

        let report = await LocalMediaImporter.importURLs([direct, playlist])

        #expect(report.items.count == 2)
        #expect(report.items[0].mediaKind == .radioStation)
        #expect(report.items[0].title == "news.example")
        #expect(report.items[0].sourceURL == direct)
        #expect(report.items[0].duration == nil)
        #expect(report.items[1].mediaKind == .radioStation)
        #expect(report.items[1].title == "Live")
        #expect(report.items[1].artist == "Local Jazz")
        #expect(report.items[1].sourceURL?.absoluteString == "https://radio.example/live.mp3")
        #expect(report.warnings.isEmpty)
    }

    @Test func importerAdvertisesCommonAVFoundationAudioFormatsAndReportsDecodeErrors() async throws {
        #expect(LocalMediaImporter.mediaExtensions == ["mp3", "aac", "m4a", "alac", "flac", "wav", "aif", "aiff"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampUnsupportedAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corruptFLAC = root.appendingPathComponent("broken.flac")
        try Data("not a flac stream".utf8).write(to: corruptFLAC)

        let report = await LocalMediaImporter.importURLs([corruptFLAC])

        #expect(report.items.isEmpty)
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].contains("could not be decoded by macOS"))
    }

    @Test func parsesPLSAndXSPFInSourceOrderWithRelativeReferences() throws {
        let directory = URL(fileURLWithPath: "/Music/Playlists", isDirectory: true)
        let plsURL = directory.appendingPathComponent("mix.pls")
        let pls = try PlaylistFileParser.parse(data: Data("[playlist]\nFile2=second.wav\nTitle2=Second\nLength2=20\nFile1=first.wav\nTitle1=First\nNumberOfEntries=2\n".utf8), playlistURL: plsURL)
        #expect(pls.map(\.title) == ["First", "Second"])
        #expect(pls.map(\.url.lastPathComponent) == ["first.wav", "second.wav"])
        #expect(pls[1].duration == .seconds(20))

        let xspfURL = directory.appendingPathComponent("mix.xspf")
        let xspf = #"<?xml version="1.0"?><playlist version="1" xmlns="http://xspf.org/ns/0/"><trackList><track><location>first.wav</location><title>First</title><creator>Artist</creator></track><track><location>https://example.com/second.mp3</location><title>Second</title><duration>12500</duration></track></trackList></playlist>"#
        let tracks = try PlaylistFileParser.parse(data: Data(xspf.utf8), playlistURL: xspfURL)
        #expect(tracks.map(\.title) == ["First", "Second"])
        #expect(tracks[0].artist == "Artist")
        #expect(tracks[0].url.path == "/Music/Playlists/first.wav")
        #expect(tracks[1].duration == .seconds(12.5))
    }

    @Test func parsesCueTrackOffsetsForSingleAndMultipleAudioFiles() throws {
        let directory = URL(fileURLWithPath: "/Music/Albums", isDirectory: true)
        let cueURL = directory.appendingPathComponent("album.cue")
        let cue = """
        PERFORMER "Album Artist"
        FILE "disc one.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Opening Track"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second Track"
            PERFORMER "Guest Artist"
            INDEX 01 03:15:00
        FILE "disc two.wav" WAVE
          TRACK 03 AUDIO
            TITLE "Final Track"
            INDEX 01 00:00:00
        """
        let tracks = try PlaylistFileParser.parse(data: Data(cue.utf8), playlistURL: cueURL)
        #expect(tracks.map(\.title) == ["Opening Track", "Second Track", "Final Track"])
        #expect(tracks.map(\.artist) == ["Album Artist", "Guest Artist", "Album Artist"])
        #expect(tracks.map(\.url.lastPathComponent) == ["disc one.wav", "disc one.wav", "disc two.wav"])
        #expect(tracks[0].sourceStartSeconds == 0)
        #expect(tracks[0].sourceEndSeconds == 195)
        #expect(tracks[1].sourceStartSeconds == 195)
        #expect(tracks[1].sourceEndSeconds == nil)
        #expect(tracks[0].occurrenceID != tracks[1].occurrenceID)
    }

    @Test func importsCueTracksAsIndependentSeekableAudioSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampCueImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSilentWaveFixture(to: root.appendingPathComponent("disc.wav"), duration: 8)
        let cueURL = root.appendingPathComponent("disc.cue")
        try """
        FILE "disc.wav" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:03:00
        """.write(to: cueURL, atomically: true, encoding: .utf8)

        let report = await LocalMediaImporter.importURLs([cueURL])

        #expect(report.items.map(\.title) == ["First", "Second"])
        #expect(report.items[0].duration == .seconds(3))
        #expect(report.items[1].duration == .seconds(5))
        #expect(report.items[0].id != report.items[1].id)
        #expect(report.items[1].sourceStartSeconds == 3)
    }

    @Test func m3uExportPreservesLocalOccurrencesAndReportsHostedEntries() {
        let local = PlaybackItem(id: "local", providerID: .localMedia, providerItemID: "file:///Music/track.wav", title: "Track", mediaKind: .localFile, isExplicit: false)
        let hosted = PlaybackItem(id: "hosted", providerID: .spotify, providerItemID: "service-track", title: "Hosted", mediaKind: .song, isExplicit: false)
        let export = M3UPlaylistExporter.export([local, local, hosted])
        #expect(export.contents == "#EXTM3U\n/Music/track.wav\n/Music/track.wav\n")
        #expect(export.skippedHostedItems == 1)
    }

    @Test func importerPreservesRepeatedPlaylistOccurrences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampRepeatedPlaylist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let track = root.appendingPathComponent("track.wav")
        try writeSilentWaveFixture(to: track)
        let playlist = root.appendingPathComponent("repeat.m3u")
        try "#EXTM3U\ntrack.wav\ntrack.wav\n".write(to: playlist, atomically: true, encoding: .utf8)

        let report = await LocalMediaImporter.importURLs([playlist])

        #expect(report.items.count == 2)
        #expect(report.items[0].providerItemID == report.items[1].providerItemID)
        #expect(report.items[0].id == report.items[1].id)
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
