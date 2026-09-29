import Foundation

@MainActor
protocol MakiRuntimeHost: AnyObject {
    func makiPlaybackStatus() -> Int
    func makiXMLParameter(objectID: String, name: String) -> String?
    func makiVisibilityChanged(objectID: String, isVisible: Bool)
    func makiTargetChanged(objectID: String, x: Double, speed: Double)
    func makiTargetReached(objectID: String)
    func makiVolumeChanged(_ value: Double)
    func makiEQBandChanged(index: Int, value: Int)
    func makiRuntimeNeedsDisplay()
    func makiPlaybackItem() -> PlaybackItem?
    func makiElapsed() -> Duration
    func makiDuration() -> Duration?
    func makiText(objectID: String) -> String?
    func makiSetText(objectID: String, text: String)
}

@MainActor
extension MakiRuntimeHost {
    func makiTargetReached(objectID: String) {}
    func makiPlaybackItem() -> PlaybackItem? { nil }
    func makiElapsed() -> Duration { .zero }
    func makiDuration() -> Duration? { nil }
    func makiText(objectID: String) -> String? { nil }
    func makiSetText(objectID: String, text: String) {}
}

@MainActor
final class MakiRuntime {
    struct Limits {
        var maximumInstructionsPerEvent = 25_000
        var maximumStackDepth = 1_024
        var maximumCallDepth = 128
        var maximumNestedEvents = 32
    }

    private enum Value: Equatable {
        case void
        case integer(Int32)
        case number(Double)
        case string(String)
        case object(String)

        var integer: Int32 {
            switch self {
            case let .integer(value): value
            case let .number(value): Int32(clamping: Int(value))
            case let .string(value): Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            case let .object(value): value.isEmpty ? 0 : 1
            case .void: 0
            }
        }

        var number: Double {
            switch self {
            case let .number(value): value
            default: Double(integer)
            }
        }

        var string: String {
            switch self {
            case let .string(value), let .object(value): value
            case let .integer(value): String(value)
            case let .number(value): String(value)
            case .void: ""
            }
        }

        var truthy: Bool { integer != 0 }
    }

    private struct StackValue {
        var value: Value
        var variableIndex: Int?
    }

    private final class Instance {
        let program: MakiProgram
        let groupID: String
        var variables: [Value]
        var disabledReason: String?

        init(program: MakiProgram, groupID: String) {
            self.program = program
            self.groupID = groupID.lowercased()
            variables = program.variables.enumerated().map { index, variable in
                if index == 0 || variable.isStatic && variable.type >= 0x100 { return .object("system") }
                if let string = variable.string { return .string(string) }
                switch MakiValueType(rawValue: variable.type) {
                case .float, .double:
                    return .number(Double(Float(bitPattern: UInt32(truncatingIfNeeded: variable.payload))))
                case .integer, .boolean, .event:
                    return .integer(Int32(bitPattern: UInt32(truncatingIfNeeded: variable.payload)))
                default:
                    return .void
                }
            }
        }
    }

    private weak var host: (any MakiRuntimeHost)?
    private let limits: Limits
    private var instances: [Instance] = []
    private var xmlParameters: [String: [String: String]] = [:]
    private var targetX: [String: Double] = [:]
    private var targetSpeed: [String: Double] = [:]
    private var visibleObjects: [String: Bool] = [:]
    private var scriptedTexts: [String: String] = [:]
    private var nestedEventDepth = 0
    private(set) var diagnostics: [String] = []

    init(programs: [MakiProgram], bindings: [ModernMakiBinding], host: any MakiRuntimeHost, limits: Limits = .init()) {
        self.host = host
        self.limits = limits
        let programByPath = Dictionary(programs.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        instances = bindings.compactMap { binding in
            guard let program = programByPath[binding.path.lowercased()] else { return nil }
            return Instance(program: program, groupID: binding.groupID)
        }
    }

    func start() {
        dispatch(event: "onScriptLoaded", objectID: "system")
    }

    @discardableResult
    func dispatchClick(objectID: String) -> Bool {
        dispatch(event: "onLeftClick", objectID: objectID.lowercased())
    }

    func dispatchSystemEvent(_ name: String) {
        dispatch(event: name, objectID: "system")
    }

    func isVisible(objectID: String) -> Bool? { visibleObjects[objectID.lowercased()] }

    func xmlParameter(objectID: String, name: String) -> String? {
        xmlParameters[objectID.lowercased()]?[name.lowercased()]
    }

    func text(objectID: String) -> String? { scriptedTexts[objectID.lowercased()] }

    func targetReached(objectID: String) {
        _ = dispatch(event: "onTargetReached", objectID: objectID.lowercased())
    }

    @discardableResult
    private func dispatch(event eventName: String, objectID: String) -> Bool {
        guard nestedEventDepth < limits.maximumNestedEvents else {
            record("Stopped nested MAKI event dispatch at the safety limit.")
            return false
        }
        nestedEventDepth += 1
        defer { nestedEventDepth -= 1 }
        var handled = false
        for instance in instances where instance.disabledReason == nil {
            for event in instance.program.events {
                guard instance.program.functions[event.functionIndex].name.caseInsensitiveCompare(eventName) == .orderedSame,
                      instance.variables[event.variableIndex] == .object(objectID) else { continue }
                do {
                    try execute(instance, at: event.codeOffset)
                    handled = true
                }
                catch {
                    let reason = "Disabled \(instance.program.path): \(error.localizedDescription)"
                    instance.disabledReason = reason
                    record(reason)
                }
            }
        }
        return handled
    }

    private func execute(_ instance: Instance, at entryPoint: Int) throws {
        var pc = entryPoint
        var stack: [StackValue] = []
        var callStack: [Int] = []
        var instructions = 0
        var complete = false

        func pop() throws -> StackValue {
            guard let value = stack.popLast() else { throw runtimeError("stack underflow") }
            return value
        }
        func push(_ value: StackValue) throws {
            guard stack.count < limits.maximumStackDepth else { throw runtimeError("stack limit exceeded") }
            stack.append(value)
        }
        func operand() throws -> Int32 {
            guard pc + 4 <= instance.program.code.count else { throw runtimeError("truncated instruction") }
            let data = instance.program.code
            let value = UInt32(data[pc]) | UInt32(data[pc + 1]) << 8 | UInt32(data[pc + 2]) << 16 | UInt32(data[pc + 3]) << 24
            pc += 4
            return Int32(bitPattern: value)
        }

        while pc < instance.program.code.count, !complete {
            instructions += 1
            guard instructions <= limits.maximumInstructionsPerEvent else { throw runtimeError("instruction budget exceeded") }
            let opcode = instance.program.code[pc]
            pc += 1
            switch opcode {
            case 0x00: break
            case 0x01:
                let index = Int(try operand())
                guard instance.variables.indices.contains(index) else { throw runtimeError("invalid variable") }
                try push(StackValue(value: instance.variables[index], variableIndex: index))
            case 0x02:
                _ = try pop()
            case 0x03:
                let index = Int(try operand())
                guard instance.variables.indices.contains(index) else { throw runtimeError("invalid variable") }
                instance.variables[index] = try pop().value
            case 0x08...0x0d:
                let rhs = try pop().value
                let lhs = try pop().value
                let equal = valuesEqual(lhs, rhs)
                let result: Bool = switch opcode {
                case 0x08: equal
                case 0x09: !equal
                case 0x0a: lhs.number > rhs.number
                case 0x0b: lhs.number >= rhs.number
                case 0x0c: lhs.number < rhs.number
                default: lhs.number <= rhs.number
                }
                try push(StackValue(value: .integer(result ? 1 : 0), variableIndex: nil))
            case 0x10, 0x11:
                let shift = Int(try operand())
                let condition = try pop().value.truthy
                if opcode == 0x10 ? !condition : condition { pc += shift }
            case 0x12:
                pc += Int(try operand())
            case 0x18, 0x70:
                let functionIndex = Int(try operand())
                guard instance.program.functions.indices.contains(functionIndex) else { throw runtimeError("invalid function") }
                var argumentCount: Int
                if opcode == 0x70 {
                    guard pc < instance.program.code.count else { throw runtimeError("truncated call") }
                    argumentCount = Int(instance.program.code[pc]); pc += 1
                } else if pc + 4 <= instance.program.code.count {
                    let marker = UInt32(instance.program.code[pc]) | UInt32(instance.program.code[pc + 1]) << 8 | UInt32(instance.program.code[pc + 2]) << 16 | UInt32(instance.program.code[pc + 3]) << 24
                    if marker & 0xffff_0000 == 0xffff_0000 { argumentCount = Int(marker & 0xffff); pc += 4 }
                    else { argumentCount = arity(of: instance.program.functions[functionIndex].name) }
                } else { argumentCount = arity(of: instance.program.functions[functionIndex].name) }
                var arguments: [Value] = []
                for _ in 0..<argumentCount { arguments.append(try pop().value) }
                let object = try pop().value
                let result = call(instance.program.functions[functionIndex].name, object: object, arguments: arguments, instance: instance)
                try push(StackValue(value: result, variableIndex: nil))
            case 0x19:
                let shift = Int(try operand())
                guard callStack.count < limits.maximumCallDepth else { throw runtimeError("call depth exceeded") }
                callStack.append(pc); pc += shift
            case 0x20, 0x21:
                if let returnAddress = callStack.popLast() { pc = returnAddress } else { return }
            case 0x28:
                complete = true
            case 0x30:
                let rhs = try pop().value
                let lhs = try pop()
                guard let index = lhs.variableIndex, instance.variables.indices.contains(index) else { throw runtimeError("assignment target is not a variable") }
                instance.variables[index] = rhs
                try push(StackValue(value: rhs, variableIndex: index))
            case 0x38...0x3b:
                let value = try pop()
                let delta = opcode == 0x38 || opcode == 0x3a ? 1.0 : -1.0
                let updated: Value = .number(value.value.number + delta)
                if let index = value.variableIndex { instance.variables[index] = updated }
                try push(StackValue(value: opcode == 0x38 || opcode == 0x39 ? updated : value.value, variableIndex: value.variableIndex))
            case 0x40...0x44, 0x48, 0x49, 0x4d, 0x50, 0x51, 0x58, 0x59:
                let rhs = try pop().value
                let lhs = try pop().value
                let result: Value = switch opcode {
                case 0x40:
                    if case .string = lhs { .string(lhs.string + rhs.string) } else { .number(lhs.number + rhs.number) }
                case 0x41: .number(lhs.number - rhs.number)
                case 0x42: .number(lhs.number * rhs.number)
                case 0x43: .number(rhs.number == 0 ? 0 : lhs.number / rhs.number)
                case 0x44: .integer(rhs.integer == 0 ? 0 : lhs.integer % rhs.integer)
                case 0x48: .integer(lhs.integer & rhs.integer)
                case 0x49: .integer(lhs.integer | rhs.integer)
                case 0x4d: .integer(lhs.integer ^ rhs.integer)
                case 0x50: .integer(lhs.truthy && rhs.truthy ? 1 : 0)
                case 0x51: .integer(lhs.truthy || rhs.truthy ? 1 : 0)
                case 0x58: .integer(lhs.integer << rhs.integer)
                default: .integer(lhs.integer >> rhs.integer)
                }
                try push(StackValue(value: result, variableIndex: nil))
            case 0x4a, 0x4b, 0x4c:
                let value = try pop().value
                let result: Value = switch opcode {
                case 0x4a: .integer(value.truthy ? 0 : 1)
                case 0x4b: .integer(~value.integer)
                default: .number(-value.number)
                }
                try push(StackValue(value: result, variableIndex: nil))
            case 0x61:
                try push(try pop())
            case 0x60, 0x68, 0x69:
                throw runtimeError(String(format: "opcode 0x%02X requires an unsupported dynamic Wasabi object", opcode))
            default:
                throw runtimeError(String(format: "unsupported opcode 0x%02X", opcode))
            }
            guard pc >= 0, pc <= instance.program.code.count else { throw runtimeError("branch escaped code block") }
        }
    }

    private func call(_ rawName: String, object: Value, arguments: [Value], instance: Instance) -> Value {
        let name = rawName.lowercased()
        let objectID = object.string.lowercased()
        switch name {
        case "getruntimeversion": return .number(5.666)
        case "getskinname": return .string("Macamp Modern")
        case "gettimeofday", "getstatus": return .integer(Int32(host?.makiPlaybackStatus() ?? 0))
        case "getscriptgroup": return .object(instance.groupID)
        case "findobject", "getobject": return .object(arguments.first?.string.lowercased() ?? "")
        case "getcontainer": return .object("container:\(arguments.first?.string.lowercased() ?? "")")
        case "getlayout": return .object("layout:\(arguments.first?.string.lowercased() ?? "")")
        case "hide":
            visibleObjects[objectID] = false; host?.makiVisibilityChanged(objectID: objectID, isVisible: false); return .void
        case "show":
            visibleObjects[objectID] = true; host?.makiVisibilityChanged(objectID: objectID, isVisible: true); return .void
        case "getxmlparam":
            let key = arguments.first?.string.lowercased() ?? ""
            return .string(xmlParameters[objectID]?[key] ?? host?.makiXMLParameter(objectID: objectID, name: key) ?? "")
        case "setxmlparam":
            guard arguments.count >= 2 else { return .void }
            xmlParameters[objectID, default: [:]][arguments[0].string.lowercased()] = arguments[1].string
            host?.makiRuntimeNeedsDisplay(); return .void
        case "gettext":
            return .string(scriptedTexts[objectID] ?? host?.makiText(objectID: objectID) ?? "")
        case "settext":
            let value = arguments.first?.string ?? ""
            scriptedTexts[objectID] = value
            host?.makiSetText(objectID: objectID, text: value)
            return .void
        case "getplayitem": return .object("playitem")
        case "gettitle": return .string(host?.makiPlaybackItem()?.title ?? "")
        case "getartist": return .string(host?.makiPlaybackItem()?.artist ?? "")
        case "getalbum": return .string(host?.makiPlaybackItem()?.albumTitle ?? "")
        case "getlength": return .number(host?.makiDuration()?.secondsValue ?? 0)
        case "getposition": return .number(host?.makiElapsed().secondsValue ?? 0)
        case "stringtointeger": return .integer(arguments.first?.integer ?? 0)
        case "settargetx": targetX[objectID] = arguments.first?.number ?? 0; return .void
        case "settargetspeed": targetSpeed[objectID] = max(0.01, arguments.first?.number ?? 0.25); return .void
        case "gototarget":
            host?.makiTargetChanged(objectID: objectID, x: targetX[objectID] ?? 0, speed: targetSpeed[objectID] ?? 0.25)
            return .void
        case "leftclick": _ = dispatch(event: "onLeftClick", objectID: objectID); return .void
        case "setvolume": host?.makiVolumeChanged((arguments.first?.number ?? 0) / 255); return .void
        case "seteqband":
            if arguments.count >= 2 { host?.makiEQBandChanged(index: Int(arguments[0].integer), value: Int(arguments[1].integer)) }
            return .void
        case "setposition", "setprivateint", "messagebox": return .void
        case "getprivateint": return .integer(arguments.last?.integer ?? 0)
        default:
            if !name.hasPrefix("on") { record("Unsupported MAKI host call: \(rawName)") }
            return .integer(0)
        }
    }

    private func arity(of rawName: String) -> Int {
        switch rawName.lowercased() {
        case "getprivateint", "setxmlparam", "seteqband": 2
        case "setprivateint": 3
        case "messagebox": 4
        case "findobject", "getobject", "getcontainer", "getlayout", "getxmlparam", "gettext", "stringtointeger",
             "settargetx", "settargetspeed", "setvolume", "setposition", "settext": 1
        default: 0
        }
    }

    private func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case let (.string(left), .string(right)), let (.object(left), .object(right)):
            left.caseInsensitiveCompare(right) == .orderedSame
        case (.void, .void): true
        case (.string, _), (_, .string), (.object, _), (_, .object), (.void, _), (_, .void): false
        default: lhs.number == rhs.number
        }
    }

    private func record(_ message: String) {
        guard !diagnostics.contains(message), diagnostics.count < 100 else { return }
        diagnostics.append(message)
    }

    private func runtimeError(_ detail: String) -> ProviderError {
        ProviderError(code: .invalidResponse, message: "MAKI runtime error: \(detail).")
    }
}
