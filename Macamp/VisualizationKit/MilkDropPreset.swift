import Foundation
import ImageIO

struct MilkDropPreset: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let rendererJSON: String
    let unsupportedFeatures: [String]
    let textureNames: [String]
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
    private static let shapeInitPattern = try! NSRegularExpression(pattern: #"^shape_(\d+)_init_(\d+)$"#)
    private static let shapeFramePattern = try! NSRegularExpression(pattern: #"^shape_(\d+)_per_frame_(\d+)$"#)
    private static let shapeValuePattern = try! NSRegularExpression(pattern: #"^shape_(\d+)_(enabled|sides|additive|textured|thick|num_inst|tex_zoom|tex_ang|x|y|rad|ang|r|g|b|a|r2|g2|b2|a2|border_r|border_g|border_b|border_a)$"#)
    private static let shapeValueNames: [String: String] = [
        "enabled": "enabled", "sides": "sides", "additive": "additive", "textured": "textured",
        "thick": "thickoutline", "num_inst": "num_inst", "tex_zoom": "tex_zoom", "tex_ang": "tex_ang",
        "x": "x", "y": "y", "rad": "rad", "ang": "ang", "r": "r", "g": "g", "b": "b", "a": "a",
        "r2": "r2", "g2": "g2", "b2": "b2", "a2": "a2", "border_r": "border_r",
        "border_g": "border_g", "border_b": "border_b", "border_a": "border_a"
    ]
    private static let shaderPattern = try! NSRegularExpression(pattern: #"^(warp|comp)_(\d+)$"#)
    private static let forbiddenTokens = ["window", "document", "globalthis", "fetch", "eval", "function", "constructor", "prototype", "webkit"]
    private static let hlslTypes: [(String, String)] = [("float2", "vec2"), ("float3", "vec3"), ("float4", "vec4"), ("half2", "vec2"), ("half3", "vec3"), ("half4", "vec4")]

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
        var shapeValues: [Int: [String: Double]] = [:]
        var shapeInitEquations: [Int: [(Int, String)]] = [:]
        var shapeFrameEquations: [Int: [(Int, String)]] = [:]
        var warpShaderChunks: [(Int, String)] = []
        var compShaderChunks: [(Int, String)] = []

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

            if let match = shaderPattern.firstMatch(in: key, range: keyRange),
               let index = int(match, 2, in: key), (1...512).contains(index) {
                var chunk = String(value)
                if chunk.first == "`" { chunk.removeFirst() }
                if capture(match, 1, in: key) == "warp" { warpShaderChunks.append((index, chunk)) }
                else { compShaderChunks.append((index, chunk)) }
                continue
            }

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
            } else if let match = shapeInitPattern.firstMatch(in: key, range: keyRange),
                      let shape = int(match, 1, in: key), let number = int(match, 2, in: key), (0..<4).contains(shape) {
                try appendEquation(value, number, to: &shapeInitEquations[shape, default: []])
            } else if let match = shapeFramePattern.firstMatch(in: key, range: keyRange),
                      let shape = int(match, 1, in: key), let number = int(match, 2, in: key), (0..<4).contains(shape) {
                try appendEquation(value, number, to: &shapeFrameEquations[shape, default: []])
            } else if let match = shapeValuePattern.firstMatch(in: key, range: keyRange),
                      let shape = int(match, 1, in: key), let valueName = capture(match, 2, in: key),
                      (0..<4).contains(shape), let rendererKey = shapeValueNames[valueName],
                      let number = Double(value), number.isFinite {
                shapeValues[shape, default: [:]][rendererKey] = number
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
        let shapes: [[String: Any]] = (0..<4).map { index in
            [
                "baseVals": shapeValues[index] ?? ["enabled": 0.0],
                "init_eqs_str": sorted(shapeInitEquations[index] ?? []),
                "frame_eqs_str": sorted(shapeFrameEquations[index] ?? [])
            ]
        }
        var unsupportedFeatures: [String] = []
        var textureNames: [String] = []
        let warp = translateShader(warpShaderChunks, stage: "warp", textureNames: &textureNames, warnings: &unsupportedFeatures)
        let comp = translateShader(compShaderChunks, stage: "composite", textureNames: &textureNames, warnings: &unsupportedFeatures)
        let rendererObject: [String: Any] = [
            "baseVals": baseValues,
            "init_eqs_str": sorted(initEquations),
            "frame_eqs_str": sorted(frameEquations),
            "pixel_eqs_str": sorted(pixelEquations),
            "warp": warp ?? "", "comp": comp ?? "", "waves": waves, "shapes": shapes
        ]
        let json = try JSONSerialization.data(withJSONObject: rendererObject, options: [.sortedKeys])
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return MilkDropPreset(
            id: UUID().uuidString,
            title: name.isEmpty ? "MilkDrop Preset" : name,
            rendererJSON: String(decoding: json, as: UTF8.self),
            unsupportedFeatures: unsupportedFeatures,
            textureNames: Array(Set(textureNames)).sorted()
        )
    }

    private static func translateShader(_ chunks: [(Int, String)], stage: String, textureNames: inout [String], warnings: inout [String]) -> String? {
        guard !chunks.isEmpty else { return "" }
        let source = chunks.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
        let hasUnsupportedControlFlow = source.range(of: #"\b(for|while|do|discard|include|define)\b"#, options: .regularExpression) != nil
        guard source.utf8.count <= 32_768, !hasUnsupportedControlFlow else {
            warnings.append("The custom \(stage) shader uses code outside Macamp's supported shader subset; that shader stage was skipped.")
            return nil
        }
        let lowered = source.lowercased()
        guard lowered.contains("shader_body"), lowered.contains("{") && lowered.contains("}") else {
            warnings.append("The custom \(stage) shader is malformed or unsupported; that shader stage was skipped.")
            return nil
        }

        let samplerRegex = try! NSRegularExpression(pattern: #"\bsampler\s+(sampler_[A-Za-z0-9_]+)\s*;"#)
        let nsSource = source as NSString
        var samplers: [String] = []
        for match in samplerRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
            let name = nsSource.substring(with: match.range(at: 1))
            samplers.append(name)
        }
        let builtInTextures: Set<String> = ["sampler_main", "sampler_fw_main", "sampler_fc_main", "sampler_pw_main", "sampler_pc_main", "sampler_blur1", "sampler_blur2", "sampler_blur3", "sampler_noise_lq", "sampler_noise_lq_lite", "sampler_noise_mq", "sampler_noise_hq", "sampler_pw_noise_lq", "sampler_noisevol_lq", "sampler_noisevol_hq"]
        textureNames.append(contentsOf: samplers.filter { !builtInTextures.contains($0) }.map { String($0.dropFirst("sampler_".count)).lowercased() })

        var translated = replace(source, pattern: #"\bsampler\s+(sampler_[A-Za-z0-9_]+)\s*;"#, with: "uniform sampler2D $1;")
        for (from, to) in hlslTypes {
            translated = replace(translated, pattern: #"\b"# + from + #"\b"#, with: to)
        }
        translated = replace(translated, pattern: #"\btex2D\b"#, with: "texture", options: [.caseInsensitive])
        translated = replace(translated, pattern: #"\blerp\b"#, with: "mix", options: [.caseInsensitive])
        let helpers = """
        float saturate(float x) { return clamp(x, 0.0, 1.0); }
        vec2 saturate(vec2 x) { return clamp(x, vec2(0.0), vec2(1.0)); }
        vec3 saturate(vec3 x) { return clamp(x, vec3(0.0), vec3(1.0)); }
        vec4 saturate(vec4 x) { return clamp(x, vec4(0.0), vec4(1.0)); }
        float lum(vec3 x) { return dot(x, vec3(0.32, 0.49, 0.29)); }
        vec3 GetBlur1(vec2 p) { return texture(sampler_blur1, p).xyz * scale1 + bias1; }
        vec3 GetBlur2(vec2 p) { return texture(sampler_blur2, p).xyz * scale2 + bias2; }
        vec3 GetBlur3(vec2 p) { return texture(sampler_blur3, p).xyz * scale3 + bias3; }
        vec3 GetPixel(vec2 p) { return texture(sampler_main, p).xyz; }
        """
        guard let body = translated.range(of: "shader_body") else { return nil }
        translated.insert(contentsOf: helpers, at: body.lowerBound)
        return translated
    }

    private static func replace(_ source: String, pattern: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return source }
        return regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: replacement)
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

    private static func capture(_ match: NSTextCheckingResult, _ group: Int, in text: String) -> String? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func sorted(_ pairs: [(Int, String)]) -> String {
        pairs.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }
}

@MainActor
final class MilkDropPresetStore {
    private let directory: URL
    private var textureDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("MilkDropTextures", isDirectory: true) }
    private static let textureExtensions: Set<String> = ["png", "jpg", "jpeg"]

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

    func importTextures(_ urls: [URL]) -> (names: Set<String>, warnings: [String]) {
        guard urls.count <= 100 else { return ([], ["Choose up to 100 MilkDrop textures at a time."]) }
        do { try FileManager.default.createDirectory(at: textureDirectory, withIntermediateDirectories: true) }
        catch { return ([], ["Could not create the MilkDrop texture folder: \(error.localizedDescription)"]) }

        var imported: Set<String> = []
        var warnings: [String] = []
        var totalBytes = 0
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let ext = url.pathExtension.lowercased()
                guard Self.textureExtensions.contains(ext) else { throw MilkDropTextureError.unsupportedFormat }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count > 0, data.count <= 10 * 1_024 * 1_024,
                      totalBytes + data.count <= 50 * 1_024 * 1_024,
                      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 4_096, height <= 4_096,
                      CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
                    throw MilkDropTextureError.invalidImage
                }
                var name = url.deletingPathExtension().lastPathComponent.lowercased()
                if name.hasPrefix("sampler_") { name.removeFirst("sampler_".count) }
                name = String(name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                guard !name.isEmpty else { throw MilkDropTextureError.invalidName }
                let target = textureDirectory.appendingPathComponent(name).appendingPathExtension(ext)
                for existingExt in Self.textureExtensions where existingExt != ext {
                    try? FileManager.default.removeItem(at: textureDirectory.appendingPathComponent(name).appendingPathExtension(existingExt))
                }
                try data.write(to: target, options: .atomic)
                totalBytes += data.count
                imported.insert(name)
            } catch {
                warnings.append("Could not import texture \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (imported, warnings)
    }

    func texturePayload(for names: [String]) -> String {
        var payload: [String: [String: Any]] = [:]
        for name in Set(names.map { $0.lowercased() }) {
            guard let file = Self.textureExtensions.compactMap({ ext -> URL? in
                let url = textureDirectory.appendingPathComponent(name).appendingPathExtension(ext)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }).first,
            let data = try? Data(contentsOf: file) else { continue }
            let mime = file.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            payload[name] = ["data": "data:\(mime);base64,\(data.base64EncodedString())", "width": 1, "height": 1]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func availableTextureNames() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: textureDirectory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { Self.textureExtensions.contains($0.pathExtension.lowercased()) }.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
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
                preset = MilkDropPreset(
                    id: url.deletingPathExtension().lastPathComponent,
                    title: preset.title,
                    rendererJSON: preset.rendererJSON,
                    unsupportedFeatures: preset.unsupportedFeatures,
                    textureNames: preset.textureNames
                )
                presets.append(preset)
                warnings.append(contentsOf: preset.unsupportedFeatures.map { "\(preset.title): \($0)" })
                let missingTextures = Set(preset.textureNames).subtracting(availableTextureNames()).sorted()
                warnings.append(contentsOf: missingTextures.map { "\(preset.title): texture '\($0)' is missing; Butterchurn will use its fallback image." })
            } catch {
                warnings.append("Skipped invalid preset \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (presets.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, warnings)
    }
}

private enum MilkDropTextureError: LocalizedError {
    case unsupportedFormat
    case invalidImage
    case invalidName

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Choose a PNG or JPEG texture."
        case .invalidImage: "The texture is invalid, too large, or has unsupported dimensions."
        case .invalidName: "The texture filename must contain letters, numbers, or underscores."
        }
    }
}
