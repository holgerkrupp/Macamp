import Foundation
import Testing
@testable import Macamp

@Suite
@MainActor
struct AudioCDTests {
    @Test func readsMountedAudioTracksAndSkipsMixedModeDataTracks() throws {
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("MacampAudioCD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        for number in [1, 3] {
            try Data("test".utf8).write(to: volume.appendingPathComponent("\(number) Audio Track.aiff"))
        }
        let toc: [String: Any] = [
            "Sessions": [[
                "Session Number": 1,
                "Leadout Block": 750,
                "Track Array": [
                    ["Point": 1, "Start Block": 150, "Data": false],
                    ["Point": 2, "Start Block": 300, "Data": true],
                    ["Point": 3, "Start Block": 450, "Data": false]
                ]
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: toc, format: .xml, options: 0)
        try data.write(to: volume.appendingPathComponent(".TOC.plist"))

        let tracks = try AudioCDManager.readTracks(from: volume)

        #expect(tracks.map(\.number) == [1, 3])
        #expect(tracks[0].id != tracks[1].id)
        #expect(tracks.map(\.duration) == [4, 4])
        #expect(tracks.map { $0.url.lastPathComponent } == ["1 Audio Track.aiff", "3 Audio Track.aiff"])
    }

    @Test func unreadableAndDataOnlyDiscsHaveClearErrors() throws {
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("MacampAudioCD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: volume) }

        #expect(throws: AudioCDError.self) { try AudioCDManager.readTracks(from: volume) }

        let toc: [String: Any] = [
            "Sessions": [[
                "Session Number": 1,
                "Leadout Block": 150,
                "Track Array": [["Point": 1, "Start Block": 0, "Data": true]]
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: toc, format: .xml, options: 0)
        try data.write(to: volume.appendingPathComponent(".TOC.plist"))
        #expect(throws: AudioCDError.self) { try AudioCDManager.readTracks(from: volume) }
    }
}
