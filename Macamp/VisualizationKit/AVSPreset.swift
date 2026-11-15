import AppKit
import Foundation
import UniformTypeIdentifiers

struct AVSSimpleEffect: Sendable {
    let flags: UInt32
    let colors: [UInt32]
}

struct AVSExpressionProgram {
    private let assignments: [(String, AVSExpression)]
    let isValid: Bool

    init(_ source: String) {
        guard source.utf8.count <= 1_024 else { assignments = []; isValid = false; return }
        var parsed: [(String, AVSExpression)] = []
        for statement in source.split(separator: ";", omittingEmptySubsequences: true) {
            let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = text.firstIndex(of: "=") else { assignments = []; isValid = false; return }
            let name = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let next = text.index(after: separator)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  next < text.endIndex, text[next] != "=", parsed.count < 16 else { assignments = []; isValid = false; return }
            var parser = AVSExpressionParser(String(text[next...]))
            guard let expression = parser.parse(), parser.isAtEnd, expression.isSupported else { assignments = []; isValid = false; return }
            parsed.append((name, expression))
        }
        assignments = parsed
        isValid = true
    }

    func run(_ variables: inout [String: Double]) -> Bool {
        for (name, expression) in assignments {
            guard let value = expression.evaluate(variables), value.isFinite, abs(value) <= 1_000_000 else { return false }
            variables[name] = value
        }
        return true
    }
}

private indirect enum AVSExpression {
    case number(Double)
    case variable(String)
    case unary(String, AVSExpression)
    case binary(String, AVSExpression, AVSExpression)
    case call(String, [AVSExpression])

    var isSupported: Bool {
        switch self {
        case .number, .variable: true
        case let .unary(_, value): value.isSupported
        case let .binary(_, left, right): left.isSupported && right.isSupported
        case let .call(name, values):
            ["sin", "cos", "tan", "abs", "sqrt", "floor", "ceil", "log", "min", "max", "above", "below", "if"].contains(name)
                && values.allSatisfy(\.isSupported)
        }
    }

    func evaluate(_ variables: [String: Double]) -> Double? {
        switch self {
        case let .number(value): return value
        case let .variable(name):
            return name == "$pi" || name == "pi" ? Double.pi : (variables[name] ?? 0)
        case let .unary(op, expression):
            guard let value = expression.evaluate(variables) else { return nil }
            switch op {
            case "-": return -value
            case "+": return value
            case "!": return value == 0 ? 1 : 0
            default: return nil
            }
        case let .binary(op, left, right):
            guard let lhs = left.evaluate(variables), let rhs = right.evaluate(variables) else { return nil }
            switch op {
            case "+": return lhs + rhs
            case "-": return lhs - rhs
            case "*": return lhs * rhs
            case "/": return rhs == 0 ? 0 : lhs / rhs
            case "%": return rhs == 0 ? 0 : lhs.truncatingRemainder(dividingBy: rhs)
            case "^": return pow(lhs, rhs)
            case ">": return lhs > rhs ? 1 : 0
            case "<": return lhs < rhs ? 1 : 0
            case ">=": return lhs >= rhs ? 1 : 0
            case "<=": return lhs <= rhs ? 1 : 0
            case "==": return lhs == rhs ? 1 : 0
            case "!=": return lhs != rhs ? 1 : 0
            case "&&": return lhs != 0 && rhs != 0 ? 1 : 0
            case "||": return lhs != 0 || rhs != 0 ? 1 : 0
            default: return nil
            }
        case let .call(name, args):
            let values = args.compactMap { $0.evaluate(variables) }
            guard values.count == args.count else { return nil }
            switch (name, values.count) {
            case ("sin", 1): return sin(values[0])
            case ("cos", 1): return cos(values[0])
            case ("tan", 1): return tan(values[0])
            case ("abs", 1): return abs(values[0])
            case ("sqrt", 1): return sqrt(max(0, values[0]))
            case ("floor", 1): return floor(values[0])
            case ("ceil", 1): return ceil(values[0])
            case ("log", 1): return log(max(Double.leastNonzeroMagnitude, values[0]))
            case ("min", 2): return min(values[0], values[1])
            case ("max", 2): return max(values[0], values[1])
            case ("above", 2): return values[0] > values[1] ? 1 : 0
            case ("below", 2): return values[0] < values[1] ? 1 : 0
            case ("if", 3): return values[0] != 0 ? values[1] : values[2]
            default: return nil
            }
        }
    }
}

private struct AVSExpressionParser {
    private enum Token { case number(Double), identifier(String), operation(String), left, right, comma }
    private let tokens: [Token]
    private var index = 0
    var isAtEnd: Bool { index == tokens.count }

    init(_ source: String) {
        tokens = Self.tokenize(source)
    }

    mutating func parse() -> AVSExpression? { expression(minimumPrecedence: 0) }

    private mutating func expression(minimumPrecedence: Int) -> AVSExpression? {
        guard var left = prefix() else { return nil }
        while index < tokens.count {
            guard case let .operation(op) = tokens[index], let precedence = Self.precedence(op), precedence >= minimumPrecedence else { break }
            index += 1
            guard let right = expression(minimumPrecedence: precedence + (op == "^" ? 0 : 1)) else { return nil }
            left = .binary(op, left, right)
        }
        return left
    }

    private mutating func prefix() -> AVSExpression? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        index += 1
        switch token {
        case let .number(value): return .number(value)
        case let .operation(op) where op == "-" || op == "+" || op == "!":
            guard let value = expression(minimumPrecedence: 7) else { return nil }
            return .unary(op, value)
        case .left:
            guard let value = expression(minimumPrecedence: 0), index < tokens.count, case .right = tokens[index] else { return nil }
            index += 1
            return value
        case let .identifier(name):
            guard index < tokens.count, case .left = tokens[index] else { return .variable(name) }
            index += 1
            var arguments: [AVSExpression] = []
            if index < tokens.count, case .right = tokens[index] {
                index += 1
                return .call(name, arguments)
            }
            while true {
                guard let argument = expression(minimumPrecedence: 0) else { return nil }
                arguments.append(argument)
                guard index < tokens.count else { return nil }
                if case .right = tokens[index] { index += 1; break }
                guard case .comma = tokens[index] else { return nil }
                index += 1
            }
            return .call(name, arguments)
        default: return nil
        }
    }

    private static func precedence(_ op: String) -> Int? {
        switch op {
        case "||": 1
        case "&&": 2
        case ">", "<", ">=", "<=", "==", "!=": 3
        case "+", "-": 4
        case "*", "/", "%": 5
        case "^": 6
        default: nil
        }
    }

    private static func tokenize(_ source: String) -> [Token] {
        let chars = Array(source.lowercased())
        var result: [Token] = []
        var i = 0
        while i < chars.count, result.count < 64 {
            let char = chars[i]
            if char.isWhitespace { i += 1; continue }
            if char.isNumber || char == "." {
                let start = i; i += 1
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                if i < chars.count && (chars[i] == "e") {
                    i += 1
                    if i < chars.count && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                    while i < chars.count && chars[i].isNumber { i += 1 }
                }
                guard let value = Double(String(chars[start..<i])) else { return [] }
                result.append(.number(value)); continue
            }
            if char.isLetter || char == "_" || char == "$" {
                let start = i; i += 1
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                result.append(.identifier(String(chars[start..<i]))); continue
            }
            if char == "(" { result.append(.left); i += 1; continue }
            if char == ")" { result.append(.right); i += 1; continue }
            if char == "," { result.append(.comma); i += 1; continue }
            let pair = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["&&", "||", ">=", "<=", "==", "!="].contains(pair) {
                result.append(.operation(pair)); i += 2; continue
            }
            if "+-*/%^<>!".contains(char) { result.append(.operation(String(char))); i += 1; continue }
            return []
        }
        return i == chars.count ? result : []
    }
}

@MainActor
final class AVSScopeEffect {
    let waveform: Bool
    let drawLines: Bool
    let colors: [UInt32]
    let pointProgram: AVSExpressionProgram
    let frameProgram: AVSExpressionProgram
    let hasBeatExpression: Bool
    let initProgram: AVSExpressionProgram
    private(set) var equationsSupported: Bool
    private var variables: [String: Double] = ["n": 256, "t": 0, "w": 640, "h": 480]
    private var initialized = false

    init(waveform: Bool, drawLines: Bool, colors: [UInt32], point: String, frame: String, beat: String, initialize: String) {
        self.waveform = waveform
        self.drawLines = drawLines
        self.colors = colors
        pointProgram = AVSExpressionProgram(point)
        frameProgram = AVSExpressionProgram(frame)
        hasBeatExpression = !beat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        initProgram = AVSExpressionProgram(initialize)
        equationsSupported = pointProgram.isValid && frameProgram.isValid && initProgram.isValid
    }

    func draw(_ frame: VisualizationAnalysisFrame, in bounds: CGRect) {
        let input = waveform ? frame.waveform : frame.bands
        guard input.count > 1 else { return }
        if !equationsSupported {
            drawBasicScope(input, waveform: waveform, in: bounds)
            return
        }
        if !initialized {
            initialized = initProgram.run(&variables)
            guard initialized else { equationsSupported = false; drawBasicScope(input, waveform: waveform, in: bounds); return }
        }
        guard frameProgram.run(&variables) else { equationsSupported = false; drawBasicScope(input, waveform: waveform, in: bounds); return }
        let pointCount = min(max(Int(variables["n"] ?? 256), 2), 256)
        let path = NSBezierPath(); path.lineWidth = 1.5
        let colors = colors.isEmpty ? [UInt32(0x00FFFF)] : colors
        for index in 0..<pointCount {
            let position = Double(index) / Double(pointCount - 1)
            let sampleIndex = position * Double(input.count - 1)
            let lower = Int(sampleIndex)
            let upper = min(input.count - 1, lower + 1)
            let fraction = sampleIndex - Double(lower)
            let first = input[lower].isFinite ? Double(input[lower]) : 0
            let second = input[upper].isFinite ? Double(input[upper]) : 0
            variables["i"] = position
            variables["v"] = first + (second - first) * fraction
            variables["b"] = 0
            guard pointProgram.run(&variables) else { equationsSupported = false; drawBasicScope(input, waveform: waveform, in: bounds); return }
            let x = min(max(variables["x"] ?? 0, -2), 2)
            let y = min(max(variables["y"] ?? 0, -2), 2)
            let point = CGPoint(x: bounds.midX + x * bounds.width * 0.5, y: bounds.midY - y * bounds.height * 0.5)
            if index == 0 || !drawLines { path.move(to: point) } else { path.line(to: point) }
            if !drawLines {
                avsColor(colors[index % colors.count], offset: 0).setFill()
                CGRect(x: point.x, y: point.y, width: 2, height: 2).fill()
            }
        }
        if drawLines { avsColor(colors[0], offset: 0).setStroke(); path.stroke() }
    }

    private func drawBasicScope(_ values: [Float], waveform: Bool, in bounds: CGRect) {
        let color = avsColor(colors.first ?? 0x00FFFF, offset: 0)
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.5
        for index in values.indices {
            let raw = values[index].isFinite ? values[index] : 0
            let value = waveform ? min(max(raw, -1), 1) : min(max(raw, 0), 1) * 2 - 1
            let point = CGPoint(x: bounds.minX + CGFloat(index) / CGFloat(values.count - 1) * bounds.width,
                                y: bounds.midY - CGFloat(value) * bounds.height * 0.42)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.stroke()
    }
}

enum AVSVisualEffect {
    case simple(AVSSimpleEffect)
    case scope(AVSScopeEffect)
}

@MainActor
final class AVSPreset: Identifiable {
    let id: String
    let title: String
    let effects: [AVSVisualEffect]
    let unsupportedEffectCount: Int
    var simpleEffects: [AVSSimpleEffect] { effects.compactMap { if case let .simple(effect) = $0 { effect } else { nil } } }
    var scopeEffects: [AVSScopeEffect] { effects.compactMap { if case let .scope(effect) = $0 { effect } else { nil } } }

    init(id: String, title: String, effects: [AVSVisualEffect], unsupportedEffectCount: Int) {
        self.id = id
        self.title = title
        self.effects = effects
        self.unsupportedEffectCount = unsupportedEffectCount
    }

    func draw(_ frame: VisualizationAnalysisFrame, in bounds: CGRect) {
        guard !effects.isEmpty else {
            drawFallback(frame, in: bounds)
            return
        }
        for visualEffect in effects {
            if case let .scope(effect) = visualEffect {
                effect.draw(frame, in: bounds)
                continue
            }
            guard case let .simple(effect) = visualEffect else { continue }
            let colorValues = effect.colors.isEmpty ? [UInt32(0x00FF80)] : effect.colors
            let sourceIsWaveform = effect.flags & 0b10 != 0
            let drawLines = effect.flags & 0b1 != 0
            let isDots = effect.flags & 0b1000000 != 0
            let position = (effect.flags >> 4) & 0b11
            let centerY: CGFloat = position == 0 ? bounds.minY + bounds.height * 0.22
                : position == 1 ? bounds.maxY - bounds.height * 0.22 : bounds.midY
            let values = sourceIsWaveform ? frame.waveform : frame.bands
            guard values.count > 1 else { continue }
            let scale = sourceIsWaveform ? bounds.height * 0.4 : bounds.height * 0.68
            let step = bounds.width / CGFloat(values.count)
            let path = NSBezierPath(); path.lineWidth = 1.5
            if sourceIsWaveform { path.move(to: CGPoint(x: bounds.minX, y: centerY)) }
            for index in values.indices {
                let x = bounds.minX + CGFloat(index) * step
                let value = CGFloat(values[index].isFinite ? min(max(values[index], sourceIsWaveform ? -1 : 0), 1) : 0)
                let y = sourceIsWaveform ? centerY - value * scale : centerY - value * scale
                let color = avsColor(colorValues[index % colorValues.count], offset: 0)
                if sourceIsWaveform || drawLines {
                    if sourceIsWaveform { path.line(to: CGPoint(x: bounds.minX + CGFloat(index) / CGFloat(values.count - 1) * bounds.width, y: y)) }
                    else {
                        color.setStroke()
                        let line = NSBezierPath(); line.lineWidth = 1
                        line.move(to: CGPoint(x: x, y: centerY)); line.line(to: CGPoint(x: x, y: y)); line.stroke()
                    }
                } else if isDots {
                    color.setFill()
                    CGRect(x: x, y: y, width: max(1.5, step * 0.55), height: 2).fill()
                } else {
                    color.setFill()
                    CGRect(x: x, y: y, width: max(1, step - 1), height: max(1, centerY - y)).fill()
                }
            }
            if sourceIsWaveform { avsColor(colorValues[0], offset: 0).setStroke(); path.stroke() }
        }
    }

    private func drawFallback(_ frame: VisualizationAnalysisFrame, in bounds: CGRect) {
        let bands = frame.bands
        guard !bands.isEmpty else { return }
        let width = bounds.width / CGFloat(bands.count)
        NSColor.systemGreen.setFill()
        for (index, value) in bands.enumerated() {
            let height = bounds.height * 0.75 * CGFloat(value.isFinite ? min(max(value, 0), 1) : 0)
            CGRect(x: bounds.minX + CGFloat(index) * width, y: bounds.maxY - height, width: max(1, width - 1), height: height).fill()
        }
    }
}

private func avsColor(_ value: UInt32, offset: CGFloat) -> NSColor {
    let red = CGFloat((value >> 16) & 0xff) / 255
    let green = CGFloat((value >> 8) & 0xff) / 255
    let blue = CGFloat(value & 0xff) / 255
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).blended(withFraction: offset, of: .systemCyan) ?? .white
}

enum AVSPresetError: Error, LocalizedError {
    case invalid
    case tooLarge
    case unsupported

    var errorDescription: String? {
        switch self {
        case .invalid: "The AVS preset is malformed."
        case .tooLarge: "The AVS preset exceeds the 5 MB import limit."
        case .unsupported: "The file is not a supported legacy AVS preset."
        }
    }
}

@MainActor
enum AVSPresetParser {
    private static let maxEffects = 512
    private static let maxScopes = 8

    static func parse(_ data: Data, fileName: String) throws -> AVSPreset {
        guard data.count <= 5 * 1_024 * 1_024 else { throw AVSPresetError.tooLarge }
        let magic = Array("Nullsoft AVS Preset 0.".utf8)
        let bytes = [UInt8](data)
        guard bytes.count > magic.count + 2, bytes.starts(with: magic),
              (bytes[magic.count] == 49 || bytes[magic.count] == 50),
              bytes[magic.count + 1] == 0x1a else { throw AVSPresetError.unsupported }
        let payload = Data(bytes.dropFirst(magic.count + 2))
        guard payload.count >= 1 else { throw AVSPresetError.invalid }
        var effects: [AVSVisualEffect] = []
        var unsupported = 0
        var count = 0
        var scopeCount = 0
        try parseEffects(payload, start: 1, end: payload.count, depth: 0, effects: &effects, scopeCount: &scopeCount, unsupported: &unsupported, count: &count)
        let title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return AVSPreset(id: UUID().uuidString, title: title.isEmpty ? "AVS Preset" : title,
                         effects: effects, unsupportedEffectCount: unsupported)
    }

    private static func parseEffects(_ data: Data, start: Int, end: Int, depth: Int,
                                     effects: inout [AVSVisualEffect],
                                     scopeCount: inout Int,
                                     unsupported: inout Int, count: inout Int) throws {
        guard depth <= 8, start >= 0, end <= data.count, start <= end else { throw AVSPresetError.invalid }
        var offset = start
        while offset < end {
            guard end - offset >= 8, count < maxEffects,
                  let rawID = readInt32(data, at: offset) else {
                throw AVSPresetError.invalid
            }
            offset += 4
            if rawID >= 0x4000 {
                guard end - offset >= 32 else { throw AVSPresetError.invalid }
                offset += 32
            }
            guard let rawLength = readUInt32(data, at: offset) else { throw AVSPresetError.invalid }
            offset += 4
            guard rawLength <= UInt32(end - offset) else { throw AVSPresetError.invalid }
            let effectEnd = offset + Int(rawLength)
            count += 1
            if rawID == 0 {
                if let effect = parseSimple(data, start: offset, end: effectEnd) { effects.append(.simple(effect)) }
                else { unsupported += 1 }
            } else if rawID == 36 {
                if let effect = parseScope(data, start: offset, end: effectEnd) {
                    if scopeCount < maxScopes {
                        effects.append(.scope(effect))
                        scopeCount += 1
                        if !effect.equationsSupported || effect.hasBeatExpression { unsupported += 1 }
                    } else { unsupported += 1 }
                } else { unsupported += 1 }
            } else if rawID == -2 {
                try parseNestedList(data, start: offset, end: effectEnd, depth: depth + 1,
                                    effects: &effects, scopeCount: &scopeCount, unsupported: &unsupported, count: &count)
            } else {
                unsupported += 1
            }
            offset = effectEnd
        }
    }

    private static func parseNestedList(_ data: Data, start: Int, end: Int, depth: Int,
                                        effects: inout [AVSVisualEffect],
                                        scopeCount: inout Int,
                                        unsupported: inout Int, count: inout Int) throws {
        guard start < end, let first = data.byte(at: start) else { throw AVSPresetError.invalid }
        if first & 0b10 != 0 { return }
        var offset = start + 1
        if first & 0x80 != 0 {
            guard start + 5 <= end, let extraLength = data.byte(at: start + 4) else { throw AVSPresetError.invalid }
            let headerEnd = start + max(5, Int(extraLength) + 5)
            guard headerEnd <= end else { throw AVSPresetError.invalid }
            offset = headerEnd
        }
        try parseEffects(data, start: offset, end: end, depth: depth, effects: &effects, scopeCount: &scopeCount, unsupported: &unsupported, count: &count)
    }

    private static func parseSimple(_ data: Data, start: Int, end: Int) -> AVSSimpleEffect? {
        guard end - start >= 8, let flags = readUInt32(data, at: start), let colorCount = readUInt32(data, at: start + 4), colorCount <= 16,
              end - start >= 8 + Int(colorCount) * 4 else { return nil }
        var colors: [UInt32] = []
        for index in 0..<Int(colorCount) {
            guard let color = readUInt32(data, at: start + 8 + index * 4) else { return nil }
            colors.append(color)
        }
        return AVSSimpleEffect(flags: flags, colors: colors)
    }

    private static func parseScope(_ data: Data, start: Int, end: Int) -> AVSScopeEffect? {
        guard start < end else { return nil }
        let point: String
        let frame: String
        let beat: String
        let initialize: String
        var offset: Int
        if data.byte(at: start) == 1 {
            offset = start + 1
            var strings: [String] = []
            for _ in 0..<4 {
                guard offset < end, let terminator = (offset..<end).first(where: { data[$0] == 0 }), terminator - offset <= 1_024,
                      let value = String(bytes: data[offset..<terminator], encoding: .utf8) else { return nil }
                strings.append(value)
                offset = terminator + 1
            }
            (point, frame, beat, initialize) = (strings[0], strings[1], strings[2], strings[3])
        } else {
            guard end - start >= 1_040 else { return nil }
            let scripts = (0..<4).map { index -> String in
                let range = (start + index * 256)..<(start + (index + 1) * 256)
                let chunk = data[range]
                let text = chunk.prefix { $0 != 0 }
                return String(bytes: text, encoding: .utf8) ?? "\u{0}"
            }
            (point, frame, beat, initialize) = (scripts[0], scripts[1], scripts[2], scripts[3])
            offset = start + 1_024
        }
        guard let source = readUInt32(data, at: offset), let colorCount = readUInt32(data, at: offset + 4), colorCount <= 16 else { return nil }
        offset += 8
        guard offset + Int(colorCount) * 4 + 4 <= end else { return nil }
        var colors: [UInt32] = []
        for _ in 0..<Int(colorCount) {
            guard let color = readUInt32(data, at: offset) else { return nil }
            colors.append(color); offset += 4
        }
        guard let drawMode = readUInt32(data, at: offset) else { return nil }
        return AVSScopeEffect(waveform: source & 0b100 != 0, drawLines: drawMode > 0, colors: colors,
                              point: point, frame: frame, beat: beat, initialize: initialize)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func readInt32(_ data: Data, at offset: Int) -> Int32? {
        readUInt32(data, at: offset).map { Int32(bitPattern: $0) }
    }
}

private extension Data {
    func byte(at index: Int) -> UInt8? { indices.contains(index) ? self[index] : nil }
}

@MainActor
final class AVSPresetStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macamp/AVSPresets", isDirectory: true)
    }

    func allPresets() -> (presets: [AVSPreset], warnings: [String]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var presets: [AVSPreset] = []
        var warnings: [String] = []
        for url in urls where url.pathExtension.lowercased() == "avs" {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 5 * 1_024 * 1_024 else { throw AVSPresetError.tooLarge }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                var preset = try AVSPresetParser.parse(data, fileName: url.lastPathComponent)
                preset = AVSPreset(id: url.lastPathComponent, title: preset.title, effects: preset.effects,
                                   unsupportedEffectCount: preset.unsupportedEffectCount)
                presets.append(preset)
                if preset.unsupportedEffectCount > 0 {
                    warnings.append("\(preset.title): skipped \(preset.unsupportedEffectCount) unsupported effect(s).")
                }
                if preset.simpleEffects.isEmpty && preset.scopeEffects.isEmpty {
                    warnings.append("\(preset.title): no supported AVS effects; showing the built-in spectrum fallback.")
                }
            } catch { warnings.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (presets.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, warnings)
    }

    func importPresets(from urls: [URL]) -> (count: Int, warnings: [String]) {
        guard urls.count <= 100 else { return (0, ["Choose up to 100 AVS presets or folders at a time."]) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return (0, ["Could not create the AVS preset folder: \(error.localizedDescription)"]) }
        var warnings: [String] = []
        var importedCount = 0
        var bytesCopied = 0
        var files: [URL] = []
        var scopedURLs: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                while let item = enumerator.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "avs" { files.append(item) }
                    if files.count > 100 { break }
                }
            } else if url.pathExtension.lowercased() == "avs" {
                files.append(url)
            }
        }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard files.count <= 100 else { return (0, ["The selected folders contain more than 100 AVS presets."]) }
        for file in files {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 5 * 1_024 * 1_024, bytesCopied + size <= 50 * 1_024 * 1_024 else { throw AVSPresetError.tooLarge }
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                _ = try AVSPresetParser.parse(data, fileName: file.lastPathComponent)
                let base = file.deletingPathExtension().lastPathComponent
                    .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-") }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let safeBase = base.isEmpty ? "AVS Preset" : base
                var target = directory.appendingPathComponent(safeBase).appendingPathExtension("avs")
                var suffix = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = directory.appendingPathComponent("\(safeBase) (\(suffix))").appendingPathExtension("avs")
                    suffix += 1
                }
                try data.write(to: target, options: .atomic)
                bytesCopied += data.count
                importedCount += 1
            } catch { warnings.append("Could not import \(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return (importedCount, warnings)
    }
}
