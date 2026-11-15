import Foundation
import Testing
@testable import Macamp

@Suite("MP3 tag editing")
struct ID3v2TagEditorTests {
    @Test func updatesCommonTagsAndPreservesUnknownFramesAndAudioBytes() throws {
        let original = fixture(version: 3)
        let updated = try ID3v2TagEditor.updating(original, title: "New Title", artist: "New Artist", album: "New Album")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Macamp-ID3-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        try updated.write(to: file)

        let tags = try ID3v2TagEditor.read(from: file)
        #expect(tags.title == "New Title")
        #expect(tags.artist == "New Artist")
        #expect(tags.album == "New Album")
        #expect(unknownFramePayload(in: updated, version: 3) == Data([0, 1, 2, 255]))
        #expect(audioPayload(in: updated) == audioPayload(in: original))
    }

    @Test func atomicallyUpdatesAnMP3FileAndPreservesItsPermissions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Macamp-ID3-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = fixture(version: 4)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

        try ID3v2TagEditor.updateFile(at: file, title: "Edited", artist: "Artist", album: "Record")

        #expect(try ID3v2TagEditor.read(from: file).title == "Edited")
        #expect(audioPayload(in: try Data(contentsOf: file)) == audioPayload(in: original))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    }

    @Test func refusesID3LayoutsThatCannotBeRewrittenSafely() {
        var tag = Data("ID3".utf8) + Data([4, 0, 0x80, 0, 0, 0, 0])
        #expect(throws: ID3v2TagError.self) {
            try ID3v2TagEditor.updating(tag, title: "Title", artist: "Artist", album: "Album")
        }
        tag[5] = 0
        tag[3] = 2
        #expect(throws: ID3v2TagError.self) {
            try ID3v2TagEditor.updating(tag, title: "Title", artist: "Artist", album: "Album")
        }
    }

    private func fixture(version: UInt8) -> Data {
        var frames = Data()
        frames.append(frame("TIT2", text: "Old", version: version))
        frames.append(frame("TPE1", text: "Singer", version: version))
        frames.append(frame("PRIV", payload: Data([0, 1, 2, 255]), version: version))
        var header = Data("ID3".utf8)
        header.append(contentsOf: [version, 0, 0])
        header.append(contentsOf: syncSafe(frames.count))
        let audio = Data([0xff, 0xfb, 0x90, 0x64, 0x10, 0x20, 0x30, 0x40, 0x54, 0x41, 0x47])
        return header + frames + audio
    }

    private func frame(_ id: String, text: String, version: UInt8) -> Data {
        frame(id, payload: Data([3]) + Data(text.utf8), version: version)
    }

    private func frame(_ id: String, payload: Data, version: UInt8) -> Data {
        var result = Data(id.utf8)
        if version == 3 {
            result.append(contentsOf: [UInt8((payload.count >> 24) & 0xff), UInt8((payload.count >> 16) & 0xff), UInt8((payload.count >> 8) & 0xff), UInt8(payload.count & 0xff)])
        } else {
            result.append(contentsOf: syncSafe(payload.count))
        }
        result.append(contentsOf: [0, 0])
        result.append(payload)
        return result
    }

    private func syncSafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7f), UInt8((value >> 14) & 0x7f), UInt8((value >> 7) & 0x7f), UInt8(value & 0x7f)]
    }

    private func audioPayload(in data: Data) -> Data {
        let size = data[6..<10].reduce(0) { ($0 << 7) | Int($1) }
        return Data(data.dropFirst(10 + size))
    }

    private func unknownFramePayload(in data: Data, version: UInt8) -> Data? {
        var offset = 10
        while offset + 10 <= data.count {
            let id = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = version == 3
                ? data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
                : data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 7) | Int($1) }
            if id == "PRIV" { return Data(data[(offset + 10)..<(offset + 10 + size)]) }
            offset += 10 + size
        }
        return nil
    }
}
