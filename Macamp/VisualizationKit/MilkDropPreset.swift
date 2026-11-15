import Foundation

struct MilkDropPreset: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let rendererJSON: String
}

enum MilkDropPresetError: Error, LocalizedError {
    case invalidText
    case missingPreset
    case malformedLine(String)
    case tooLarge
    case unsafeEquation

    var errorDescription: String? {
        switch self {
        case .invalidText: "The MilkDrop preset is not valid UTF-8 text."
        case .missingPreset: "The file does not contain a MilkDrop preset section."
        case let .malformedLine(line): "The MilkDrop preset contains an invalid line: \(line)"
        case .tooLarge: "The MilkDrop preset exceeds the 2 MB import limit."
        case .unsafeEquation: "The MilkDrop preset contains an equation that Macamp cannot safely run."
        }
    }
}

enum MilkDropPresetParser {
    private static let baseValueNames: [String: String] = [
        "zoom": "zoom", "rot": "rot", "cx": "cx", "cy": "cy", "dx": "dx", "dy": "dy",
        "sx": "sx", "sy": "sy", "warp": "warp", "fdecay": "decay", "fgammaadj": "gammaadj",
        "fbrighten": "brighten", "bdarken": "darken", "bsolarize": "solarize", "binvert": "invert",
        "bredblue": "red_blue", "bbrighten": "brighten", "fvideoechozoom": "echo_zoom",
        "fvideoechoalpha": "echo_alpha", "nvideoechoorientation": "echo_orient", "nwavemode": "wave_mode",
        "badditivewaves": "additivewave", "bwavedots": "wave_dots", "bwavethick": "wave_thick",
        "bmodwavealphabyvolume": "modwavealphabyvolume", "bmaximizewavecolor": "maximizewavecolor",
        "fwavealpha": "wave_alpha", "fwavescale": "wave_scale", "fwavesmoothing": "wave_smoothing",
        "fwaveparam": "wave_param", "wave_r": "wave_r", "wave_g": "wave_g", "wave_b": "wave_b",
        "wave_x": "wave_x", "wave_y": "wave_y", "btexwrap": "texwrap", "bdarkencenter": "darken_center",
        "fwarpanimspeed": "warpanimspeed", "fwarpscale": "warpscale", "fzoomexponent": "zoomexp",
        "fshader": "fshader", "ob_size": "ob_size", "ib_size": "ib_size", "nmotionvectorsx": "mv_x",
        "nmotionvectorsy": "mv_y", "mv_l": "mv_l", "frating": "fRating"
    ]

    private static let initPattern = try! NSRegularExpression(pattern: #"^per_frame_init_(\d+)$"#)
    private static let framePattern = try! NSRegularExpression(pattern: #"^per_frame_(\d+)$"#)
    private static let pixelPattern = try! NSRegularExpression(pattern: #"^per_pixel_(\d+)$"#)
    private static let waveFramePattern = try! NSRegularExpression(pattern: #"^wave_(\d+)_per_frame_(\d+)$"#)
    private static let wavePointPattern = try! NSRegularExpression(pattern: #"^wave_(\d+)_per_point_(\d+)$"#)
    private static let forbiddenTokens = ["window", "document", "globalthis", "fetch", "eval", "function", "constructor", "prototype", "webkit"]

    static func parse(data: Data, fileName: String) throws -> MilkDropPreset {
        guard data.count <= 2 * 1_024 * 1_024 else { throw MilkDropPresetError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw MilkDropPresetError.invalidText }
        return try parse(text: text, fileName: fileName)
    }

    static func parse(text: String, fileName: String) throws -> MilkDropPreset {
        guard text.utf8.count <= 2 * 1_024 * 1_024 else { throw MilkDropPresetError.tooLarge }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= 50_000 else { throw MilkDropPresetError.tooLarge }

        var inPreset = false
        var foundPreset = false
        var baseValues: [String: Double] = [:]
        var initEquations: [(Int, String)] = []
        var frameEquations: [(Int, String)] = []
        var pixelEquations: [(Int, String)] = []
        var waveFrameEquations: [Int: [(Int, String)]] = [:]
        var wavePointEquations: [Int: [(Int, String)]] = [:]

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                inPreset = line.lowercased().hasPrefix("[preset")
                foundPreset = foundPreset || inPreset
                continue
            }
            guard inPreset else { continue }
            guard let separator = line.firstIndex(of: "=") else { throw MilkDropPresetError.malformedLine(line) }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let keyRange = NSRange(key.startIndex..., in: key)

            if let match = initPattern.firstMatch(in: key, range: keyRange), let number = int(match, 1, in: key) {
                try appendEquation(value, number, to: &initEquations)
            } else if let match = framePattern.firstMatch(in: key, range: keyRange), let number = int(match, 1, in: key) {
                try appendEquation(value, number, to: &frameEquations)
            } else if let match = pixelPattern.firstMatch(in: key, range: keyRange), let number = int(match, 1, in: key) {
                try appendEquation(value, number, to: &pixelEquations)
            } else if let match = waveFramePattern.firstMatch(in: key, range: keyRange),
                      let wave = int(match, 1, in: key), let number = int(match, 2, in: key) {
                try appendEquation(value, number, to: &waveFrameEquations[wave, default: []])
            } else if let match = wavePointPattern.firstMatch(in: key, range: keyRange),
                      let wave = int(match, 1, in: key), let number = int(match, 2, in: key) {
                try appendEquation(value, number, to: &wavePointEquations[wave, default: []])
            } else if let rendererKey = baseValueNames[key], let number = Double(value), number.isFinite {
                baseValues[rendererKey] = number
            }
        }
        guard foundPreset else { throw MilkDropPresetError.missingPreset }
        guard !baseValues.isEmpty || !initEquations.isEmpty || !frameEquations.isEmpty || !pixelEquations.isEmpty else {
            throw MilkDropPresetError.missingPreset
        }

        let waveIndices = Set(waveFrameEquations.keys).union(wavePointEquations.keys).filter { (0..<4).contains($0) }.sorted()
        let waves: [[String: Any]] = (0..<4).map { index in
            let frame = (waveFrameEquations[index] ?? []).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
            let point = (wavePointEquations[index] ?? []).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
            let enabled = waveIndices.contains(index) ? 1.0 : 0.0
            return [
                "baseVals": ["enabled": enabled, "samples": 512.0, "a": 0.8, "r": 1.0, "g": 1.0, "b": 1.0, "x": 0.5, "y": 0.5],
                "init_eqs_str": "", "frame_eqs_str": frame, "point_eqs_str": point
            ]
        }
        let disabledShapes = (0..<4).map { _ in ["baseVals": ["enabled": 0.0], "init_eqs_str": "", "frame_eqs_str": ""] }
        let rendererObject: [String: Any] = [
            "baseVals": baseValues,
            "init_eqs_str": sorted(initEquations),
            "frame_eqs_str": sorted(frameEquations),
            "pixel_eqs_str": sorted(pixelEquations),
            "warp": "", "comp": "", "waves": waves, "shapes": disabledShapes
        ]
        let json = try JSONSerialization.data(withJSONObject: rendererObject, options: [.sortedKeys])
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return MilkDropPreset(id: UUID().uuidString, title: name.isEmpty ? "MilkDrop Preset" : name, rendererJSON: String(decoding: json, as: UTF8.self))
    }

    private static func appendEquation(_ value: String, _ index: Int, to values: inout [(Int, String)]) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ +-*/%.,;()=<>!&|^?:\t")
        guard index > 0, index <= 512, values.count < 512, !value.isEmpty, value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy(allowed.contains),
              !forbiddenTokens.contains(where: { token in
                  value.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: token) + #"\b"#, options: .regularExpression) != nil
              }) else { throw MilkDropPresetError.unsafeEquation }
        values.append((index, value))
    }

    private static func int(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> Int? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }

    private static func sorted(_ pairs: [(Int, String)]) -> String {
        pairs.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }
}

@MainActor
final class MilkDropPresetStore {
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macamp/MilkDropPresets", isDirectory: true)
        self.directory = base
    }

    func importFiles(_ urls: [URL]) -> (presets: [MilkDropPreset], warnings: [String]) {
        var imported: [MilkDropPreset] = []
        var warnings: [String] = []
        var importedBytes = 0
        guard urls.count <= 100 else {
            return ([], ["Choose up to 100 MilkDrop presets at a time."])
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return ([], ["Could not create the MilkDrop preset folder: \(error.localizedDescription)"]) }

        for url in urls {
            guard url.pathExtension.lowercased() == "milk" else {
                warnings.append("Skipped unsupported MilkDrop file: \(url.lastPathComponent)")
                continue
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 2 * 1_024 * 1_024,
                      importedBytes + size <= 20 * 1_024 * 1_024 else {
                    throw MilkDropPresetError.tooLarge
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let preset = try MilkDropPresetParser.parse(data: data, fileName: url.lastPathComponent)
                let safeName = preset.title
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                let baseName = safeName.isEmpty ? "MilkDrop Preset" : safeName
                var destination = directory.appendingPathComponent(baseName).appendingPathExtension("milk")
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = directory.appendingPathComponent("\(baseName) (\(suffix))").appendingPathExtension("milk")
                    suffix += 1
                }
                try data.write(to: destination, options: .atomic)
                importedBytes += data.count
                imported.append(preset)
            } catch {
                warnings.append("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (imported, warnings)
    }

    func allPresets() -> (presets: [MilkDropPreset], warnings: [String]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }
        var presets: [MilkDropPreset] = []
        var warnings: [String] = []
        for url in urls where url.pathExtension.lowercased() == "milk" {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 2 * 1_024 * 1_024 else { throw MilkDropPresetError.tooLarge }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                var preset = try MilkDropPresetParser.parse(data: data, fileName: url.lastPathComponent)
                preset = MilkDropPreset(id: url.deletingPathExtension().lastPathComponent, title: preset.title, rendererJSON: preset.rendererJSON)
                presets.append(preset)
            } catch {
                warnings.append("Skipped invalid preset \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (presets.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, warnings)
    }
}
