import Foundation

nonisolated enum MakiValueType: Int32, Sendable {
    case void = 0
    case event = 1
    case integer = 2
    case float = 3
    case double = 4
    case boolean = 5
    case string = 6
    case object = 7
    case any = 8
}

nonisolated struct MakiFunction: Sendable, Equatable {
    var baseType: Int32
    var name: String
}

nonisolated struct MakiVariable: Sendable, Equatable {
    var type: Int32
    var payload: UInt64
    var isTransient: Bool
    var isStatic: Bool
    var string: String?
}

/// Runtime values that can cross the MAKI VM/Wasabi boundary.
///
/// An object is always a handle into the runtime object table.  XML IDs are
/// names used for lookup, never object identity.
nonisolated enum MakiValue: Sendable, Equatable {
    case void
    case integer(Int32)
    case number(Double)
    case string(String)
    case object(WasabiHandle)

    var integer: Int32 {
        switch self {
        case let .integer(value): value
        case let .number(value): Int32(clamping: Int(value))
        case let .string(value): Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        case let .object(handle): handle.rawValue == 0 ? 0 : 1
        case .void: 0
        }
    }

    var number: Double {
        switch self {
        case let .number(value): value
        default: Double(integer)
        }
    }

    /// String conversion is intentionally not an XML-ID conversion.  Callers
    /// that need an object's ID must resolve the handle through the registry.
    var string: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .number(value): String(value)
        case let .object(handle): String(handle.rawValue)
        case .void: ""
        }
    }

    var truthy: Bool { integer != 0 }
}

/// A semantic event delivered from the host into a MAKI object.
///
/// Keeping the receiver as a Wasabi handle is important here: an XML ID is
/// only a lookup key and can be duplicated by XUI/group instances.
nonisolated struct MakiEventArguments: Sendable, Equatable {
    let values: [MakiValue]

    init(_ values: [MakiValue] = []) {
        self.values = values
    }
}

nonisolated enum MakiRuntimeTraceKind: String, Sendable, Equatable {
    case event
    case buttonPressedChanged
    case declarativeButtonAction
}

/// Observable input/runtime activity used by hosts and deterministic tests.
/// The trace deliberately contains the original receiver handle and values;
/// converting back to an XML ID here would lose object identity.
nonisolated struct MakiRuntimeTraceEntry: Sendable, Equatable {
    let kind: MakiRuntimeTraceKind
    let receiver: WasabiHandle
    let name: String
    let arguments: [MakiValue]

    init(kind: MakiRuntimeTraceKind, receiver: WasabiHandle, name: String, arguments: [MakiValue] = []) {
        self.kind = kind
        self.receiver = receiver
        self.name = name
        self.arguments = arguments
    }
}

nonisolated enum MakiNativeMethod: String, Sendable {
    case legacy
    case findObject
    case systemGetContainer
    case containerGetLayout
    case layoutGetContainer
    case systemGetPosition
    case sliderGetPosition
    case frameGetPosition
    case timerStop
}

nonisolated struct MakiMethodSignature: Sendable, Equatable {
    let arity: Int
    let implementation: MakiNativeMethod

    init(arity: Int, implementation: MakiNativeMethod = .legacy) {
        self.arity = arity
        self.implementation = implementation
    }
}

nonisolated struct MakiClassDescriptor: Sendable, Equatable {
    let name: String
    let superclass: String?
    let methods: [String: MakiMethodSignature]
}

/// The checked-in MAKI method surface used by the runtime.  This is kept
/// deliberately small and explicit while the rest of std.mi is migrated.
nonisolated enum MakiClassCatalog {
    private static func signatures(_ entries: [(String, MakiMethodSignature)]) -> [String: MakiMethodSignature] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.0.lowercased(), $0.1) })
    }

    private static let common = signatures([
        ("getclassname", .init(arity: 0)),
        ("getid", .init(arity: 0)),
        ("isvisible", .init(arity: 0)), ("setalpha", .init(arity: 1)), ("getalpha", .init(arity: 0)),
        ("getleft", .init(arity: 0)), ("gettop", .init(arity: 0)),
        ("getwidth", .init(arity: 0)), ("getheight", .init(arity: 0)),
        ("getparent", .init(arity: 0)), ("getparentlayout", .init(arity: 0)),
        ("getruntimeversion", .init(arity: 0)),
        ("getskinname", .init(arity: 0)),
        ("gettimeofday", .init(arity: 0)),
        ("getstatus", .init(arity: 0)),
        ("getscriptgroup", .init(arity: 0)),
        ("getobject", .init(arity: 1)),
        ("findobject", .init(arity: 1, implementation: .findObject)),
        ("getcontainer", .init(arity: 1, implementation: .systemGetContainer)),
        ("getlayout", .init(arity: 1, implementation: .containerGetLayout)),
        ("getposition", .init(arity: 0, implementation: .systemGetPosition)),
        ("stop", .init(arity: 0)),
        ("getxmlparam", .init(arity: 1)),
        ("getparam", .init(arity: 0)),
        ("gettoken", .init(arity: 1)),
        ("setxmlparam", .init(arity: 2)),
        ("gettext", .init(arity: 0)),
        ("settext", .init(arity: 1)),
        ("getplayitem", .init(arity: 0)),
        ("gettitle", .init(arity: 0)),
        ("getartist", .init(arity: 0)),
        ("getalbum", .init(arity: 0)),
        ("getlength", .init(arity: 0)),
        ("stringtointeger", .init(arity: 1)),
        ("settargetx", .init(arity: 1)),
        ("settargety", .init(arity: 1)),
        ("settargetw", .init(arity: 1)),
        ("settargetwidth", .init(arity: 1)),
        ("settargeth", .init(arity: 1)),
        ("settargetheight", .init(arity: 1)),
        ("settargetalpha", .init(arity: 1)),
        ("settargetspeed", .init(arity: 1)),
        ("gototarget", .init(arity: 0)),
        ("leftclick", .init(arity: 0)),
        ("setvolume", .init(arity: 1)),
        ("seteqband", .init(arity: 2)),
        ("geteqband", .init(arity: 1)),
        ("geteqpreamp", .init(arity: 0)),
        ("geteq", .init(arity: 0)),
        ("seteq", .init(arity: 1)),
        ("seteqpreamp", .init(arity: 1)),
        ("setposition", .init(arity: 1)),
        ("setprivateint", .init(arity: 3)),
        ("setprivatestring", .init(arity: 3)),
        ("getprivateint", .init(arity: 2)),
        ("getprivatestring", .init(arity: 2)),
        ("getconfigattribute", .init(arity: 1)),
        ("setconfigattribute", .init(arity: 3)),
        ("settimer", .init(arity: 1)),
        ("settimerinterval", .init(arity: 1)),
        ("killtimer", .init(arity: 0)),
        ("switchtolayout", .init(arity: 1)),
        ("resize", .init(arity: 4)),
        ("beforeredock", .init(arity: 0)),
        ("redock", .init(arity: 0)),
        ("snapadjust", .init(arity: 0)),
        ("messagebox", .init(arity: 4)),
        ("hide", .init(arity: 0)),
        ("show", .init(arity: 0))
    ])

    static let descriptors: [String: MakiClassDescriptor] = [
        "object": .init(name: "Object", superclass: nil, methods: common),
        "system": .init(name: "System", superclass: "Object", methods: common.merging(signatures([
            ("getcontainer", .init(arity: 1, implementation: .systemGetContainer)),
            ("getposition", .init(arity: 0, implementation: .systemGetPosition)),
            ("stop", .init(arity: 0)),
            ("newdynamiccontainer", .init(arity: 1)),
            ("newgroup", .init(arity: 1)),
            ("newgroupaslayout", .init(arity: 1))
        ]), uniquingKeysWith: { _, new in new })),
        "guiobject": .init(name: "GuiObject", superclass: "Object", methods: common.merging(signatures([
            ("findobject", .init(arity: 1, implementation: .findObject))
        ]), uniquingKeysWith: { _, new in new })),
        "container": .init(name: "Container", superclass: "GuiObject", methods: common.merging(signatures([
            ("getlayout", .init(arity: 1, implementation: .containerGetLayout)),
            ("getnumlayouts", .init(arity: 0)), ("enumlayout", .init(arity: 1)),
            ("switchtolayout", .init(arity: 1)), ("getcurlayout", .init(arity: 0)),
            ("toggle", .init(arity: 0)), ("close", .init(arity: 0)), ("isdynamic", .init(arity: 0))
        ]), uniquingKeysWith: { _, new in new })),
        "layout": .init(name: "Layout", superclass: "GuiObject", methods: common.merging(signatures([
            ("getcontainer", .init(arity: 0, implementation: .layoutGetContainer)),
            ("getscale", .init(arity: 0)), ("setscale", .init(arity: 1)),
            ("getdesktopalpha", .init(arity: 0)), ("setdesktopalpha", .init(arity: 1))
        ]), uniquingKeysWith: { _, new in new })),
        "group": .init(name: "Group", superclass: "GuiObject", methods: common.merging(signatures([
            ("getobject", .init(arity: 1)), ("getnumobjects", .init(arity: 0)),
            ("enumobject", .init(arity: 1)), ("islayout", .init(arity: 0))
        ]), uniquingKeysWith: { _, new in new })),
        "slider": .init(name: "Slider", superclass: "GuiObject", methods: common.merging(signatures([
            ("getposition", .init(arity: 0, implementation: .sliderGetPosition)),
            ("lock", .init(arity: 0)), ("unlock", .init(arity: 0))
        ]), uniquingKeysWith: { _, new in new })),
        "button": .init(name: "Button", superclass: "GuiObject", methods: common.merging(signatures([
            ("onactivate", .init(arity: 1)), ("setactivated", .init(arity: 1)),
            ("setactivatednocallback", .init(arity: 1)), ("getactivated", .init(arity: 0)),
            ("rightclick", .init(arity: 0))
        ]), uniquingKeysWith: { _, new in new })),
        "frame": .init(name: "Frame", superclass: "GuiObject", methods: signatures([
            ("getposition", .init(arity: 0, implementation: .frameGetPosition))
        ])),
        "timer": .init(name: "Timer", superclass: "Object", methods: signatures([
            ("stop", .init(arity: 0, implementation: .timerStop)), ("setdelay", .init(arity: 1)),
            ("getdelay", .init(arity: 0)), ("start", .init(arity: 0)),
            ("isrunning", .init(arity: 0)), ("getskipped", .init(arity: 0))
        ])),
        "configattribute": .init(name: "ConfigAttribute", superclass: "Object", methods: signatures([
            ("getdata", .init(arity: 0)), ("setdata", .init(arity: 1)), ("getattributename", .init(arity: 0))
        ]))
    ]

    static func resolve(className: String, method: String) -> MakiMethodSignature? {
        var current = className.lowercased()
        let normalizedMethod = method.lowercased()
        while let descriptor = descriptors[current] {
            if let signature = descriptor.methods[normalizedMethod] { return signature }
            guard let superclass = descriptor.superclass else { break }
            current = superclass.lowercased()
        }
        return nil
    }
}

nonisolated struct MakiEvent: Sendable, Equatable {
    var variableIndex: Int
    var functionIndex: Int
    var codeOffset: Int
}

nonisolated struct MakiProgram: Sendable, Equatable {
    var path: String
    var version: UInt8
    var classGUIDs: [Data]
    var functions: [MakiFunction]
    var variables: [MakiVariable]
    var events: [MakiEvent]
    var code: Data
}

nonisolated enum MakiDecoder {
    nonisolated struct Limits: Sendable {
        var maximumFileSize = 1_048_576
        var maximumClassCount = 512
        var maximumFunctionCount = 4_096
        var maximumVariableCount = 16_384
        var maximumStringCount = 8_192
        var maximumEventCount = 8_192
        var maximumCodeSize = 524_288
        var maximumStringLength = 65_535
    }

    nonisolated static func decode(_ data: Data, path: String = "script.maki", limits: Limits = .init()) throws -> MakiProgram {
        guard data.count <= limits.maximumFileSize else { throw error("MAKI file exceeds the size limit.") }
        var cursor = Cursor(data)
        let header = try cursor.bytes(count: 8)
        guard header.count == 8,
              header[0] == 0x46, header[1] == 0x47, header[2] == 0x03, header[3] == 0x04 else {
            throw error("Invalid MAKI header.")
        }
        let version = header[4]
        guard (0x15...0x17).contains(version), header[5...7].allSatisfy({ $0 == 0 }) else {
            throw error(version > 0x17 ? "MAKI bytecode version is newer than this runtime." : "Unsupported legacy MAKI bytecode version.")
        }

        let classCount = try cursor.count(maximum: limits.maximumClassCount, label: "class")
        var classGUIDs: [Data] = []
        classGUIDs.reserveCapacity(classCount)
        for _ in 0..<classCount { classGUIDs.append(try cursor.bytes(count: 16)) }

        let functionCount = try cursor.count(maximum: limits.maximumFunctionCount, label: "function")
        var functions: [MakiFunction] = []
        functions.reserveCapacity(functionCount)
        for _ in 0..<functionCount {
            let type = try cursor.i32()
            let name = try cursor.utf8(maximum: limits.maximumStringLength)
            guard !name.isEmpty else { throw error("MAKI contains an empty function name.") }
            functions.append(MakiFunction(baseType: type, name: name))
        }

        let variableCount = try cursor.count(maximum: limits.maximumVariableCount, label: "variable")
        var variables: [MakiVariable] = []
        variables.reserveCapacity(variableCount)
        for _ in 0..<variableCount {
            let type = try cursor.i32()
            let payload = try cursor.u64()
            let transientFlag = try cursor.u8()
            let staticFlag = version >= 0x17 ? try cursor.u8() : 0
            variables.append(MakiVariable(type: type, payload: payload, isTransient: transientFlag == 0, isStatic: staticFlag != 0, string: nil))
        }

        let stringCount = try cursor.count(maximum: limits.maximumStringCount, label: "string")
        for _ in 0..<stringCount {
            let variableIndex = Int(try cursor.i32())
            guard variables.indices.contains(variableIndex) else { throw error("MAKI string refers to an invalid variable.") }
            variables[variableIndex].string = try cursor.utf8(maximum: limits.maximumStringLength)
        }

        let eventCount = try cursor.count(maximum: limits.maximumEventCount, label: "event")
        var events: [MakiEvent] = []
        events.reserveCapacity(eventCount)
        for _ in 0..<eventCount {
            let variableIndex = Int(try cursor.i32())
            let functionIndex = Int(try cursor.i32())
            let codeOffset = Int(try cursor.i32())
            guard variables.indices.contains(variableIndex), functions.indices.contains(functionIndex), codeOffset >= 0 else {
                throw error("MAKI event table contains an invalid reference.")
            }
            events.append(MakiEvent(variableIndex: variableIndex, functionIndex: functionIndex, codeOffset: codeOffset))
        }

        let codeSize = try cursor.count(maximum: limits.maximumCodeSize, label: "code byte")
        let code = try cursor.bytes(count: codeSize)
        guard events.allSatisfy({ $0.codeOffset < code.count }) else { throw error("MAKI event points outside its code block.") }
        try validate(code: code, functions: functions, variables: variables)
        return MakiProgram(path: path.lowercased(), version: version, classGUIDs: classGUIDs, functions: functions, variables: variables, events: events, code: code)
    }

    nonisolated private static func validate(code: Data, functions: [MakiFunction], variables: [MakiVariable]) throws {
        var pc = 0
        var instructionCount = 0
        while pc < code.count {
            instructionCount += 1
            guard instructionCount <= 100_000 else { throw error("MAKI instruction limit exceeded.") }
            let opcode = code[pc]
            pc += 1
            switch opcode {
            case 0x01, 0x03:
                let index = Int(try readI32(code, at: pc)); pc += 4
                guard variables.indices.contains(index) else { throw error("MAKI instruction refers to an invalid variable.") }
            case 0x18:
                let index = Int(try readI32(code, at: pc)); pc += 4
                guard functions.indices.contains(index) else { throw error("MAKI instruction refers to an invalid function.") }
                if pc + 4 <= code.count, (try readU32(code, at: pc) & 0xffff_0000) == 0xffff_0000 { pc += 4 }
            case 0x70:
                let index = Int(try readI32(code, at: pc)); pc += 4
                guard functions.indices.contains(index), pc < code.count else { throw error("MAKI call instruction is truncated.") }
                pc += 1
            case 0x10, 0x11, 0x12, 0x19:
                let displacement = Int(try readI32(code, at: pc)); pc += 4
                let target = pc + displacement
                guard target >= 0, target <= code.count else { throw error("MAKI branch target is outside the code block.") }
            case 0x60, 0x68:
                _ = try readI32(code, at: pc); pc += 4
            case 0x00, 0x02, 0x08...0x0d, 0x20, 0x21, 0x28, 0x30,
                 0x38...0x3b, 0x40...0x44, 0x48...0x4d, 0x50, 0x51,
                 0x58, 0x59, 0x61, 0x69:
                break
            default:
                throw error(String(format: "Unsupported MAKI opcode 0x%02X.", opcode))
            }
        }
    }

    nonisolated private static func readU32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw error("MAKI instruction is truncated.") }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    nonisolated private static func readI32(_ data: Data, at offset: Int) throws -> Int32 {
        Int32(bitPattern: try readU32(data, at: offset))
    }

    nonisolated private static func error(_ message: String) -> ProviderError {
        ProviderError(code: .invalidResponse, message: message)
    }

    private nonisolated struct Cursor {
        var data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }

        mutating func u8() throws -> UInt8 {
            guard offset < data.count else { throw MakiDecoder.error("MAKI file is truncated.") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func u32() throws -> UInt32 {
            let value = try MakiDecoder.readU32(data, at: offset)
            offset += 4
            return value
        }

        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

        mutating func u64() throws -> UInt64 {
            let low = UInt64(try u32())
            let high = UInt64(try u32())
            return low | high << 32
        }

        mutating func bytes(count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw MakiDecoder.error("MAKI file is truncated.") }
            defer { offset += count }
            return Data(data[offset..<(offset + count)])
        }

        mutating func utf8(maximum: Int) throws -> String {
            let lengthLow = Int(try u8())
            let lengthHigh = Int(try u8())
            let length = lengthLow | lengthHigh << 8
            guard length <= maximum else { throw MakiDecoder.error("MAKI string exceeds the size limit.") }
            let encoded = try bytes(count: length)
            guard let string = String(data: encoded, encoding: .utf8) else { throw MakiDecoder.error("MAKI string is not valid UTF-8.") }
            return string
        }

        mutating func count(maximum: Int, label: String) throws -> Int {
            let raw = try i32()
            guard raw >= 0, Int(raw) <= maximum else { throw MakiDecoder.error("MAKI \(label) count exceeds the limit.") }
            return Int(raw)
        }
    }
}
