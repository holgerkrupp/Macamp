import Foundation

struct MP3TextTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
}

enum ID3v2TagError: Error, LocalizedError {
    case unsupportedFile
    case unsupportedTag(String)
    case malformedTag
    case oversizedTag
    case frameTooLarge
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a regular MP3 file to edit tags."
        case let .unsupportedTag(reason): "This MP3 tag layout cannot be edited safely: \(reason)"
        case .malformedTag: "The MP3 contains an invalid ID3v2 tag."
        case .oversizedTag: "The ID3v2 tag is too large to edit safely."
        case .frameTooLarge: "The updated text is too large for an ID3v2 frame."
        case let .writeFailed(reason): "Could not replace the MP3 file: \(reason)"
        }
    }
}

/// Edits only the standard ID3v2 title, artist, and album frames. Other frames,
/// ID3v1 data, and the audio payload are copied byte-for-byte to an atomic replacement.
enum ID3v2TagEditor {
    private struct Frame {
        var id: String
        var flags: (UInt8, UInt8)
        var payload: Data
        var raw: Data
    }

    private struct ParsedTag {
        var majorVersion: UInt8
        var revision: UInt8
        var frames: [Frame]
        var byteCount: UInt64
    }

    private static let maxTagSize = 16 * 1_024 * 1_024
    private static let textFrameIDs = ["TIT2", "TPE1", "TALB"]

    static func read(from url: URL) throws -> MP3TextTags {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        file.seek(toFileOffset: 0)
        guard let tag = try readTag(from: file, fileSize: size) else { return MP3TextTags() }
        return MP3TextTags(
            title: text(in: tag.frames, id: "TIT2"),
            artist: text(in: tag.frames, id: "TPE1"),
            album: text(in: tag.frames, id: "TALB")
        )
    }

    static func updateFile(at url: URL, title: String, artist: String, album: String) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "mp3",
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = attributes[.size] as? NSNumber else {
            throw ID3v2TagError.unsupportedFile
        }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let originalTag = try readTag(from: input, fileSize: fileSize.uint64Value)
        let audioOffset = originalTag?.byteCount ?? 0
        input.seek(toFileOffset: 0)
        let oldTagData: Data?
        if let originalTag {
            oldTagData = try input.read(upToCount: Int(originalTag.byteCount))
            guard oldTagData?.count == Int(originalTag.byteCount) else { throw ID3v2TagError.malformedTag }
        } else {
            oldTagData = nil
        }
        let replacementTag = try updatedTag(oldTagData, title: title, artist: artist, album: album)

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do { try FileManager.default.copyItem(at: url, to: temporaryURL) }
        catch {
            throw ID3v2TagError.writeFailed("Could not create a temporary file next to the MP3.")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            if let permissions = attributes[.posixPermissions] as? NSNumber,
               (permissions.intValue & 0o200) == 0 {
                try FileManager.default.setAttributes([.posixPermissions: permissions.intValue | 0o200], ofItemAtPath: temporaryURL.path)
            }
            let output = try FileHandle(forUpdating: temporaryURL)
            defer { try? output.close() }
            try output.truncate(atOffset: 0)
            try output.write(contentsOf: replacementTag)
            input.seek(toFileOffset: audioOffset)
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            let outputSize = UInt64(replacementTag.count) + fileSize.uint64Value - audioOffset
            try output.truncate(atOffset: outputSize)
            try output.synchronize()
            try output.close()

            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            throw ID3v2TagError.writeFailed(error.localizedDescription)
        }
    }

    /// In-memory form used by tests and import diagnostics.
    static func updating(_ fileData: Data, title: String, artist: String, album: String) throws -> Data {
        let tag = try parseTagData(fileData)
        let offset = Int(tag?.byteCount ?? 0)
        let oldTag = tag.map { _ in Data(fileData.prefix(offset)) }
        let newTag = try updatedTag(oldTag, title: title, artist: artist, album: album)
        return newTag + fileData.dropFirst(offset)
    }

    private static func readTag(from file: FileHandle, fileSize: UInt64) throws -> ParsedTag? {
        file.seek(toFileOffset: 0)
        guard let header = try file.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8) else { return nil }
        let version = header[3]
        let flags = header[5]
        guard version == 3 || version == 4 else {
            throw ID3v2TagError.unsupportedTag("only ID3v2.3 and ID3v2.4 are supported")
        }
        guard flags & 0x80 == 0 else { throw ID3v2TagError.unsupportedTag("tag-level unsynchronization is enabled") }
        guard flags & 0x40 == 0 else { throw ID3v2TagError.unsupportedTag("the tag has an extended header") }
        guard version != 4 || flags & 0x10 == 0 else { throw ID3v2TagError.unsupportedTag("the tag has a footer") }
        let size = try decodeTagSize(header[6..<10])
        guard size <= maxTagSize else { throw ID3v2TagError.oversizedTag }
        guard fileSize >= UInt64(10 + size) else { throw ID3v2TagError.malformedTag }
        guard let bytes = try file.read(upToCount: size), bytes.count == size else { throw ID3v2TagError.malformedTag }
        return try parseTagData(header + bytes)
    }

    private static func parseTagData(_ rawTag: Data) throws -> ParsedTag? {
        guard rawTag.count >= 10, rawTag.prefix(3) == Data("ID3".utf8) else { return nil }
        let version = rawTag[3]
        let revision = rawTag[4]
        let flags = rawTag[5]
        guard version == 3 || version == 4 else {
            throw ID3v2TagError.unsupportedTag("only ID3v2.3 and ID3v2.4 are supported")
        }
        guard flags & 0x80 == 0 else { throw ID3v2TagError.unsupportedTag("tag-level unsynchronization is enabled") }
        guard flags & 0x40 == 0 else { throw ID3v2TagError.unsupportedTag("the tag has an extended header") }
        guard version != 4 || flags & 0x10 == 0 else { throw ID3v2TagError.unsupportedTag("the tag has a footer") }
        let size = try decodeTagSize(rawTag[6..<10])
        guard size <= maxTagSize, rawTag.count >= 10 + size else { throw ID3v2TagError.malformedTag }
        let tagBytes = Data(rawTag.prefix(10 + size))
        let frames = try parseFrames(tagBytes, version: version)
        return ParsedTag(majorVersion: version, revision: revision, frames: frames, byteCount: UInt64(10 + size))
    }

    private static func updatedTag(_ oldTag: Data?, title: String, artist: String, album: String) throws -> Data {
        let parsed = try oldTag.flatMap(parseTagData)
        let version = parsed?.majorVersion ?? 4
        var frames = parsed?.frames ?? []
        for (id, value) in zip(textFrameIDs, [title, artist, album]) {
            guard value.utf8.count <= 1_000_000 else { throw ID3v2TagError.frameTooLarge }
            let matching = frames.indices.filter { frames[$0].id == id }
            if let first = matching.first {
                let old = frames[first]
                let formatFlags = version == 3 ? old.flags.1 & 0xe0 : old.flags.1 & 0x4f
                guard formatFlags == 0 else { throw ID3v2TagError.unsupportedTag("the \(id) frame is compressed, encrypted, grouped, or unsynchronized") }
                frames[first] = makeFrame(id: id, text: value, version: version)
                for duplicate in matching.dropFirst().reversed() { frames.remove(at: duplicate) }
            } else {
                frames.append(makeFrame(id: id, text: value, version: version))
            }
        }
        let body = frames.reduce(into: Data()) { $0.append($1.raw) }
        guard body.count <= maxTagSize else { throw ID3v2TagError.oversizedTag }
        var header = Data("ID3".utf8)
        header.append(version)
        header.append(parsed?.revision ?? 0)
        header.append(0)
        header.append(contentsOf: encodeSyncSafe(body.count))
        return header + body
    }

    private static func parseFrames(_ tag: Data, version: UInt8) throws -> [Frame] {
        var frames: [Frame] = []
        var offset = 10
        while offset < tag.count {
            guard offset + 10 <= tag.count else {
                if tag[offset...].allSatisfy({ $0 == 0 }) { break }
                throw ID3v2TagError.malformedTag
            }
            let frameHeader = Data(tag[offset..<(offset + 10)])
            if frameHeader.prefix(4).allSatisfy({ $0 == 0 }) { break }
            guard let id = String(data: frameHeader.prefix(4), encoding: .ascii),
                  id.utf8.count == 4,
                  id.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
                throw ID3v2TagError.malformedTag
            }
            let size = version == 3
                ? decodeBigEndianSize(frameHeader[4..<8])
                : try decodeTagSize(frameHeader[4..<8])
            guard offset + 10 + size <= tag.count else { throw ID3v2TagError.malformedTag }
            let payload = Data(tag[(offset + 10)..<(offset + 10 + size)])
            let raw = Data(tag[offset..<(offset + 10 + size)])
            frames.append(Frame(id: id, flags: (frameHeader[8], frameHeader[9]), payload: payload, raw: raw))
            offset += 10 + size
        }
        return frames
    }

    private static func makeFrame(id: String, text: String, version: UInt8) -> Frame {
        var payload = Data([3])
        payload.append(contentsOf: text.utf8)
        var raw = Data(id.utf8)
        raw.append(contentsOf: version == 3 ? encodeBigEndian(payload.count) : encodeSyncSafe(payload.count))
        raw.append(contentsOf: [0, 0])
        raw.append(payload)
        return Frame(id: id, flags: (0, 0), payload: payload, raw: raw)
    }

    private static func text(in frames: [Frame], id: String) -> String? {
        guard let payload = frames.first(where: { $0.id == id })?.payload, payload.count > 1 else { return nil }
        let encoding = payload[payload.startIndex]
        let bytes = payload.dropFirst()
        let value: String?
        switch encoding {
        case 0: value = String(bytes: bytes, encoding: .isoLatin1)
        case 1: value = String(data: Data(bytes), encoding: .utf16)
        case 2: value = String(data: Data(bytes), encoding: .utf16BigEndian)
        case 3: value = String(data: Data(bytes), encoding: .utf8)
        default: value = nil
        }
        return value?.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n "))
    }

    private static func decodeTagSize(_ bytes: Data.SubSequence) throws -> Int {
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 128 }) else { throw ID3v2TagError.malformedTag }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    private static func decodeBigEndianSize(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func encodeSyncSafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7f), UInt8((value >> 14) & 0x7f), UInt8((value >> 7) & 0x7f), UInt8(value & 0x7f)]
    }

    private static func encodeBigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}
