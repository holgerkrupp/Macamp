import CoreGraphics
import Foundation
import ImageIO
import AppKit

struct WinampCursorFrame {
    let image: CGImage
    let hotSpot: CGPoint
    let duration: Duration
}

struct WinampCursor {
    let frames: [WinampCursorFrame]
    let sequence: [Int]
}

enum WinampCursorResource {
    case staticCursor(WinampCursorFrame)
    case animated(WinampCursor)
}

@MainActor
final class WinampCursorController {
    private var task: Task<Void, Never>?

    func apply(_ resource: WinampCursorResource) {
        stop()
        switch resource {
        case .staticCursor(let frame):
            NSCursor(image: NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height)), hotSpot: frame.hotSpot).set()
        case .animated(let cursor):
            task = Task { @MainActor [weak self] in
                guard !cursor.sequence.isEmpty else { return }
                var index = 0
                while !Task.isCancelled {
                    let frame = cursor.frames[cursor.sequence[index % cursor.sequence.count]]
                    NSCursor(image: NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height)), hotSpot: frame.hotSpot).set()
                    try? await Task.sleep(for: frame.duration)
                    index += 1
                }
                self?.task = nil
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        NSCursor.arrow.set()
    }
}

enum ANICursorError: Error, Equatable {
    case malformed(String)
    case unsupported(String)
    case limitExceeded(String)
}

enum ANICursorDecoder {
    struct Limits: Equatable {
        var maximumFrames = 64
        var maximumDimension = 256
        var maximumChunkBytes = 4 * 1024 * 1024
        var maximumTotalBytes = 16 * 1024 * 1024
    }

    private struct Chunk {
        let id: String
        let payload: ArraySlice<UInt8>
    }

    static func decodeFrame(_ data: Data, duration: Duration = .zero, limits: Limits = .init()) throws -> WinampCursorFrame {
        guard data.count <= limits.maximumTotalBytes else { throw ANICursorError.limitExceeded("Cursor resource is too large.") }
        let decoded = try decodeIcon(data, limits: limits)
        return WinampCursorFrame(image: decoded.image, hotSpot: decoded.hotSpot, duration: duration)
    }

    static func decode(_ data: Data, limits: Limits = .init()) throws -> WinampCursor {
        guard data.count <= limits.maximumTotalBytes else { throw ANICursorError.limitExceeded("ANI resource is too large.") }
        let bytes = Array(data)
        guard bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "ACON" else {
            throw ANICursorError.malformed("ANI must be a RIFF ACON resource.")
        }
        var headerFrameCount: Int?
        var defaultRate: UInt32 = 6
        var rates: [UInt32] = []
        var sequence: [Int] = []
        var iconData: [Data] = []
        for chunk in try chunks(in: bytes, start: 12, end: bytes.count, limits: limits) {
            switch chunk.id {
            case "anih":
                guard chunk.payload.count >= 32 else { throw ANICursorError.malformed("ANI header is truncated.") }
                headerFrameCount = Int(readU32(chunk.payload, offset: 4))
                defaultRate = max(1, readU32(chunk.payload, offset: 28))
            case "rate":
                rates = stride(from: 0, to: chunk.payload.count - 3, by: 4).map { readU32(chunk.payload, offset: $0) }
            case "seq ":
                sequence = stride(from: 0, to: chunk.payload.count - 3, by: 4).map { Int(readU32(chunk.payload, offset: $0)) }
            case "icon":
                iconData.append(Data(chunk.payload))
            case "LIST":
                guard chunk.payload.count >= 4,
                      String(bytes: chunk.payload.prefix(4), encoding: .ascii) == "fram" else { continue }
                let nested = try chunks(in: Array(chunk.payload.dropFirst(4)), start: 0, end: chunk.payload.count - 4, limits: limits)
                iconData.append(contentsOf: nested.filter { $0.id == "icon" }.map { Data($0.payload) })
            default:
                continue
            }
        }
        guard !iconData.isEmpty else { throw ANICursorError.malformed("ANI contains no icon frames.") }
        let expected = headerFrameCount ?? iconData.count
        guard expected > 0, expected <= limits.maximumFrames, iconData.count >= expected else {
            throw ANICursorError.limitExceeded("ANI frame count is outside the supported bounds.")
        }
        let selected = Array(iconData.prefix(expected))
        let frames = try selected.enumerated().map { index, raw in
            let decoded = try decodeIcon(raw, limits: limits)
            let rate = rates.indices.contains(index) ? max(1, rates[index]) : defaultRate
            let milliseconds = max(1, Int((Double(rate) * 1000 / 60).rounded()))
            return WinampCursorFrame(image: decoded.image, hotSpot: decoded.hotSpot, duration: .milliseconds(milliseconds))
        }
        let resolvedSequence = sequence.isEmpty ? Array(frames.indices) : sequence
        guard resolvedSequence.allSatisfy({ frames.indices.contains($0) }) else {
            throw ANICursorError.malformed("ANI sequence references a missing frame.")
        }
        return WinampCursor(frames: frames, sequence: resolvedSequence)
    }

    private static func chunks(in bytes: [UInt8], start: Int, end: Int, limits: Limits) throws -> [Chunk] {
        var cursor = start
        var result: [Chunk] = []
        while cursor < end {
            guard cursor + 8 <= end,
                  let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) else {
                throw ANICursorError.malformed("ANI chunk header is truncated.")
            }
            let size = Int(readU32(bytes[cursor...], offset: 4))
            guard size <= limits.maximumChunkBytes, size >= 0, cursor + 8 + size <= end else {
                throw ANICursorError.limitExceeded("ANI chunk is outside the supported bounds.")
            }
            result.append(Chunk(id: id, payload: bytes[(cursor + 8)..<(cursor + 8 + size)]))
            cursor += 8 + size + (size & 1)
        }
        guard cursor == end || cursor == end + 1 else { throw ANICursorError.malformed("ANI chunks do not align.") }
        return result
    }

    private static func decodeIcon(_ data: Data, limits: Limits) throws -> (image: CGImage, hotSpot: CGPoint) {
        let bytes = Array(data)
        var imageData = data
        var hotSpot = CGPoint.zero
        if bytes.count >= 22, bytes[0] == 0, bytes[1] == 0, bytes[2] == 2, bytes[3] == 0 {
            let imageSize = Int(readU32(bytes[14...], offset: 0))
            let imageOffset = Int(readU32(bytes[18...], offset: 0))
            guard imageOffset >= 0, imageSize > 0, imageOffset + imageSize <= bytes.count else {
                throw ANICursorError.malformed("CUR image payload is truncated.")
            }
            hotSpot = CGPoint(x: CGFloat(readU16(bytes[10...], offset: 0)), y: CGFloat(readU16(bytes[12...], offset: 0)))
            imageData = Data(bytes[imageOffset..<(imageOffset + imageSize)])
        }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= limits.maximumDimension, image.height <= limits.maximumDimension else {
            throw ANICursorError.unsupported("Cursor frame is not a supported image.")
        }
        return (image, hotSpot)
    }

    private static func readU16<S: Collection>(_ bytes: S, offset: Int) -> UInt16 where S.Element == UInt8 {
        let values = Array(bytes.dropFirst(offset).prefix(2))
        return values.count == 2 ? UInt16(values[0]) | UInt16(values[1]) << 8 : 0
    }

    private static func readU32<S: Collection>(_ bytes: S, offset: Int) -> UInt32 where S.Element == UInt8 {
        let values = Array(bytes.dropFirst(offset).prefix(4))
        guard values.count == 4 else { return 0 }
        return UInt32(values[0]) | UInt32(values[1]) << 8 | UInt32(values[2]) << 16 | UInt32(values[3]) << 24
    }
}

struct WinampEQPreset: Equatable {
    var name: String
    var bands: [UInt8]
    var preamp: UInt8

    init(name: String, bands: [UInt8], preamp: UInt8) throws {
        guard bands.count == 10, bands.allSatisfy({ $0 <= 64 }), preamp <= 64 else { throw WinampEQFError.invalidPreset }
        self.name = name
        self.bands = bands
        self.preamp = preamp
    }
}

enum WinampEQPresetFileKind: String, Equatable {
    case eqf
    case q1

    init?(fileName: String) {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "eqf": self = .eqf
        case "q1": self = .q1
        default: return nil
        }
    }
}

struct WinampEQPresetFile: Equatable {
    var presets: [WinampEQPreset]
    /// The binary payload is shared by .EQF and Winamp.q1. Keep the external
    /// file kind and the format description alongside the decoded records so a
    /// Q1 preset library can be imported and exported without losing its
    /// interchange metadata.
    var kind: WinampEQPresetFileKind
    var type: String

    init(
        presets: [WinampEQPreset],
        kind: WinampEQPresetFileKind = .eqf,
        type: String = "Winamp EQ library file v1.1"
    ) {
        self.presets = presets
        self.kind = kind
        self.type = type
    }
}

enum WinampEQFError: Error, Equatable {
    case invalidSignature
    case truncated
    case invalidPreset
    case limitExceeded
}

enum WinampEQF {
    static let fileType = "Winamp EQ library file v1.1"
    static let signature = Array(fileType.utf8)
    private static let prefix = signature + [26, 45, 45, 45]
    private static let recordSize = 257 + 11

    static func decode(_ data: Data, maximumPresets: Int = 512, fileName: String? = nil) throws -> WinampEQPresetFile {
        let bytes = Array(data)
        guard bytes.starts(with: prefix) else { throw WinampEQFError.invalidSignature }
        let body = Array(bytes.dropFirst(prefix.count))
        guard !body.isEmpty, body.count % recordSize == 0 else { throw WinampEQFError.truncated }
        let count = body.count / recordSize
        guard count <= maximumPresets else { throw WinampEQFError.limitExceeded }
        var presets: [WinampEQPreset] = []
        for index in 0..<count {
            let start = index * recordSize
            let nameBytes = body[start..<(start + 257)]
            let terminator = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
            let name = String(decoding: nameBytes[..<terminator], as: UTF8.self)
            let values = body[(start + 257)..<(start + recordSize)].map { byte -> UInt8 in UInt8(64 - min(64, Int(byte))) }
            guard values.count == 11 else { throw WinampEQFError.truncated }
            presets.append(try WinampEQPreset(name: name, bands: Array(values.prefix(10)), preamp: values[10]))
        }
        return WinampEQPresetFile(
            presets: presets,
            kind: fileName.flatMap(WinampEQPresetFileKind.init(fileName:)) ?? .eqf,
            type: fileType
        )
    }

    static func encode(_ file: WinampEQPresetFile) throws -> Data {
        guard !file.presets.isEmpty, file.presets.count <= 512 else { throw WinampEQFError.limitExceeded }
        guard file.type == fileType else { throw WinampEQFError.invalidSignature }
        var data = Data(prefix)
        for preset in file.presets {
            guard preset.bands.count == 10, preset.bands.allSatisfy({ $0 <= 64 }), preset.preamp <= 64 else { throw WinampEQFError.invalidPreset }
            let name = Array(preset.name.utf8)
            // Winamp stores a 256-byte name followed by a NUL inside a fixed
            // 257-byte field. Do not emit a field without its terminator.
            guard name.count <= 256 else { throw WinampEQFError.invalidPreset }
            data.append(contentsOf: name)
            data.append(0)
            data.append(contentsOf: repeatElement(UInt8(0), count: 256 - name.count))
            data.append(contentsOf: preset.bands.map { 64 - $0 })
            data.append(64 - preset.preamp)
        }
        return data
    }

    static func gainDB(fromWinamp value: UInt8) -> Float {
        12 - (Float(min(value, 63)) / 63) * 24
    }
}
