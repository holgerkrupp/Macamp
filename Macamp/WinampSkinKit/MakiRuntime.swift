import CoreGraphics
import Foundation

@MainActor
final class WasabiObjectRegistry {
    struct Object: Sendable, Equatable {
        let handle: WasabiHandle
        let className: String
        let id: String?
        let sceneHandle: WasabiHandle?
        let parent: WasabiHandle?
        let container: WasabiHandle?
        let layout: WasabiHandle?
        let dynamic: Bool
    }

    private(set) var objects: [WasabiHandle: Object] = [:]
    private var handlesByID: [String: [WasabiHandle]] = [:]
    private var nextRawHandle: UInt64
    private let hasSceneObjects: Bool
    let systemHandle: WasabiHandle

    init(scene: WasabiScene = WasabiScene()) {
        hasSceneObjects = !scene.allNodes.isEmpty
        let highestSceneHandle = scene.allNodes.map(\.handle.rawValue).max() ?? 0
        nextRawHandle = max(highestSceneHandle + 1, 1)
        systemHandle = WasabiHandle(rawValue: nextRawHandle)
        nextRawHandle += 1
        objects[systemHandle] = Object(
            handle: systemHandle,
            className: "System",
            id: "system",
            sceneHandle: nil,
            parent: nil,
            container: nil,
            layout: nil,
            dynamic: true
        )
        handlesByID["system"] = [systemHandle]

        for node in scene.allNodes {
            let parent = node.parent
            let container = Self.nearestAncestor(of: node, kind: .container, in: scene)
            let layout = Self.nearestAncestor(of: node, kind: .layout, in: scene)
            let object = Object(
                handle: node.handle,
                className: Self.className(for: node.kind),
                id: node.id,
                sceneHandle: node.handle,
                parent: parent,
                container: container,
                layout: layout,
                dynamic: false
            )
            objects[node.handle] = object
            handlesByID[node.id.lowercased(), default: []].append(node.handle)
        }
    }

    func object(_ handle: WasabiHandle) -> Object? { objects[handle] }

    func require(_ handle: WasabiHandle) throws -> Object {
        guard let object = objects[handle] else {
            throw ProviderError(code: .invalidResponse, message: "Unknown Wasabi object handle \(handle.rawValue).")
        }
        return object
    }

    func handle(forXMLID id: String, within scope: WasabiHandle? = nil) -> WasabiHandle? {
        let candidates = handlesByID[id.lowercased()] ?? []
        guard let scope else { return candidates.first }
        return candidates.first { isDescendant($0, of: scope) }
    }

    func findObject(id: String, within scope: WasabiHandle? = nil) -> WasabiHandle? {
        if let handle = handle(forXMLID: id, within: scope) { return handle }
        // Legacy scripts can run before a declarative scene is available
        // (for example, a component-only WAL). Preserve real handle identity
        // through the compatibility registry without making this fallback
        // authoritative when a live scene exists.
        guard !hasSceneObjects else { return nil }
        return compatibilityHandle(for: id)
    }

    func container(for handle: WasabiHandle) -> WasabiHandle? {
        guard let object = objects[handle] else { return nil }
        return object.className.caseInsensitiveCompare("Container") == .orderedSame ? handle : object.container
    }

    func layout(for handle: WasabiHandle, id: String? = nil) -> WasabiHandle? {
        guard let object = objects[handle] else { return nil }
        if let id {
            let containerHandle = container(for: handle)
            let children = objects.values.filter { candidate in
                candidate.className.caseInsensitiveCompare("Layout") == .orderedSame &&
                candidate.id?.caseInsensitiveCompare(id) == .orderedSame &&
                (containerHandle == nil || candidate.container == containerHandle)
            }
            return children.first?.handle
        }
        return object.className.caseInsensitiveCompare("Layout") == .orderedSame ? handle : object.layout
    }

    func compatibilityContainer(for id: String) -> WasabiHandle? {
        guard !hasSceneObjects else { return nil }
        return compatibilityHandle(for: id, className: "Container")
    }

    func compatibilityLayout(for id: String) -> WasabiHandle? {
        guard !hasSceneObjects else { return nil }
        return compatibilityHandle(for: id, className: "Layout")
    }

    func instantiate(className: String, id: String? = nil) -> WasabiHandle {
        let handle = WasabiHandle(rawValue: nextRawHandle)
        nextRawHandle += 1
        let normalizedID = id?.lowercased()
        objects[handle] = Object(
            handle: handle,
            className: className,
            id: normalizedID,
            sceneHandle: nil,
            parent: nil,
            container: nil,
            layout: nil,
            dynamic: true
        )
        if let normalizedID { handlesByID[normalizedID, default: []].append(handle) }
        return handle
    }

    /// Temporary bridge for callers that still dispatch input by XML ID.  It
    /// creates a registered runtime object, never a pseudo object value.
    func compatibilityHandle(for id: String, className: String = "GuiObject") -> WasabiHandle {
        handle(forXMLID: id) ?? instantiate(className: className, id: id)
    }

    func destroy(_ handle: WasabiHandle) {
        guard handle != systemHandle else { return }
        guard let object = objects.removeValue(forKey: handle), let id = object.id else { return }
        handlesByID[id, default: []].removeAll { $0 == handle }
        if handlesByID[id]?.isEmpty == true { handlesByID.removeValue(forKey: id) }
    }

    private func isDescendant(_ handle: WasabiHandle, of ancestor: WasabiHandle) -> Bool {
        var current = handle
        var visited: Set<WasabiHandle> = []
        while let object = objects[current], let parent = object.parent, visited.insert(parent).inserted {
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private static func className(for kind: WasabiObjectKind) -> String {
        switch kind {
        case .container: "Container"
        case .layout: "Layout"
        case .button: "Button"
        case .slider: "Slider"
        case .group: "GuiObject"
        case .layer, .animatedLayer, .text, .songTicker, .content, .unknown: "GuiObject"
        }
    }

    private static func nearestAncestor(of node: WasabiSceneNode, kind: WasabiObjectKind, in scene: WasabiScene) -> WasabiHandle? {
        var parent = node.parent
        var visited: Set<WasabiHandle> = []
        while let handle = parent, visited.insert(handle).inserted {
            guard let ancestor = scene.node(handle) else { return nil }
            if ancestor.kind == kind { return handle }
            parent = ancestor.parent
        }
        return nil
    }
}

@MainActor
protocol MakiRuntimeHost: AnyObject {
    func makiPlaybackStatus() -> Int
    func makiXMLParameter(objectID: String, name: String) -> String?
    func makiVisibilityChanged(objectID: String, isVisible: Bool)
    func makiTargetChanged(objectID: String, x: Double, speed: Double)
    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double)
    func makiLayoutSwitched(containerID: String, layoutID: String)
    func makiLayoutResized(objectID: String, frame: CGRect)
    func makiRedock(objectID: String, before: Bool)
    func makiTargetReached(objectID: String)
    func makiVolumeChanged(_ value: Double)
    func makiEQBandChanged(index: Int, value: Int)
    func makiEQBandValue(index: Int) -> Int
    func makiEQPreampValue() -> Int
    func makiEQPreampChanged(value: Int)
    func makiEQEnabled() -> Bool
    func makiEQEnabledChanged(_ enabled: Bool)
    func makiRuntimeNeedsDisplay()
    func makiPlaybackItem() -> PlaybackItem?
    func makiElapsed() -> Duration
    func makiDuration() -> Duration?
    func makiText(objectID: String) -> String?
    func makiSetText(objectID: String, text: String)
    func makiEventDispatched(receiver: WasabiHandle, name: String, arguments: MakiEventArguments)
    func makiButtonPressedChanged(receiver: WasabiHandle, isPressed: Bool)
    func makiDeclarativeButtonAction(receiver: WasabiHandle)
}

@MainActor
extension MakiRuntimeHost {
    func makiTargetReached(objectID: String) {}
    func makiEQBandValue(index: Int) -> Int { 128 }
    func makiEQPreampValue() -> Int { 128 }
    func makiEQPreampChanged(value: Int) {}
    func makiEQEnabled() -> Bool { false }
    func makiEQEnabledChanged(_ enabled: Bool) {}
    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
        if let x, y == nil, width == nil, height == nil, alpha == nil {
            makiTargetChanged(objectID: objectID, x: x, speed: speed)
        }
    }
    func makiLayoutSwitched(containerID: String, layoutID: String) {}
    func makiLayoutResized(objectID: String, frame: CGRect) {}
    func makiRedock(objectID: String, before: Bool) {}
    func makiPlaybackItem() -> PlaybackItem? { nil }
    func makiElapsed() -> Duration { .zero }
    func makiDuration() -> Duration? { nil }
    func makiText(objectID: String) -> String? { nil }
    func makiSetText(objectID: String, text: String) {}
    func makiEventDispatched(receiver: WasabiHandle, name: String, arguments: MakiEventArguments) {}
    func makiButtonPressedChanged(receiver: WasabiHandle, isPressed: Bool) {}
    func makiDeclarativeButtonAction(receiver: WasabiHandle) {}
}

@MainActor
final class MakiRuntime {
    struct Limits {
        var maximumInstructionsPerEvent = 25_000
        var maximumStackDepth = 1_024
        var maximumCallDepth = 128
        var maximumNestedEvents = 32
    }

    private typealias Value = MakiValue

    private struct StackValue {
        var value: Value
        var variableIndex: Int?
    }

    private final class Instance {
        let program: MakiProgram
        let groupID: String
        var variables: [Value]
        var disabledReason: String?

        init(program: MakiProgram, groupID: String, registry: WasabiObjectRegistry) {
            self.program = program
            self.groupID = groupID.lowercased()
            variables = program.variables.enumerated().map { index, variable in
                if index == 0 { return .object(registry.systemHandle) }
                // Compiled MAKI uses private type IDs above the public value
                // range for object declarations. Their initial value is
                // populated by getObject/findObject during script startup;
                // never turn an uninitialized object into a string.
                if variable.type >= 0x100 {
                    if let id = variable.string, !id.isEmpty {
                        return .object(registry.compatibilityHandle(for: id))
                    }
                    return .void
                }
                switch MakiValueType(rawValue: variable.type) {
                case .object, .any:
                    if let id = variable.string, !id.isEmpty {
                        return .object(registry.compatibilityHandle(for: id))
                    }
                    return .void
                case .string:
                    return .string(variable.string ?? "")
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
    let registry: WasabiObjectRegistry
    private var instances: [Instance] = []
    private var xmlParameters: [String: [String: String]] = [:]
    private var targetX: [String: Double] = [:]
    private var targetSpeed: [String: Double] = [:]
    private var visibleObjects: [String: Bool] = [:]
    private var scriptedTexts: [String: String] = [:]
    private var targetStates: [String: [String: Double]] = [:]
    private var privateState: [String: Value] = [:]
    private var configAttributes: [String: Value] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var playItemHandle: WasabiHandle?
    private let persistentState: UserDefaults
    private let skinID: String
    private var nestedEventDepth = 0
    private var pressedButton: WasabiHandle?
    private(set) var pressedButtons: Set<WasabiHandle> = []
    private(set) var diagnostics: [String] = []
    private(set) var trace: [MakiRuntimeTraceEntry] = []

    init(programs: [MakiProgram], bindings: [ModernMakiBinding], host: any MakiRuntimeHost, limits: Limits, skinID: String, persistentState: UserDefaults, scene: WasabiScene = WasabiScene()) {
        self.host = host
        self.limits = limits
        self.skinID = skinID
        self.persistentState = persistentState
        registry = WasabiObjectRegistry(scene: scene)
        let programByPath = Dictionary(programs.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        instances = bindings.compactMap { binding in
            guard let program = programByPath[binding.path.lowercased()] else { return nil }
            return Instance(program: program, groupID: binding.groupID, registry: registry)
        }
    }

    convenience init(programs: [MakiProgram], bindings: [ModernMakiBinding], host: any MakiRuntimeHost) {
        self.init(programs: programs, bindings: bindings, host: host, limits: .init(), skinID: "default", persistentState: .standard)
    }

    func start() {
        dispatch(event: "onScriptLoaded", receiver: registry.systemHandle)
    }

    deinit { timers.values.forEach { $0.cancel() } }

    @discardableResult
    func dispatchMouseDown(objectID: String, x: Int = 0, y: Int = 0) -> Bool {
        let receiver = registry.compatibilityHandle(for: objectID)
        return dispatchMouseDown(receiver: receiver, x: x, y: y)
    }

    @discardableResult
    func dispatchMouseDown(receiver: WasabiHandle, x: Int, y: Int) -> Bool {
        if let pressedButton { setButtonPressed(pressedButton, isPressed: false) }
        pressedButton = nil

        if isButton(receiver) {
            pressedButton = receiver
            setButtonPressed(receiver, isPressed: true)
        }
        return dispatch(event: "onLeftButtonDown", receiver: receiver, arguments: [
            .integer(Int32(clamping: x)), .integer(Int32(clamping: y))
        ])
    }

    @discardableResult
    func dispatchMouseUp(objectID: String, x: Int = 0, y: Int = 0) -> Bool {
        let receiver = registry.compatibilityHandle(for: objectID)
        return dispatchMouseUp(receiver: receiver, x: x, y: y)
    }

    @discardableResult
    func dispatchMouseUp(receiver: WasabiHandle, x: Int, y: Int) -> Bool {
        // Winamp keeps the pressed Button as the mouse-capture receiver. The
        // release coordinates are still those of the pointer at mouse-up.
        let eventReceiver = pressedButton ?? receiver
        var handled = dispatch(event: "onLeftButtonUp", receiver: eventReceiver, arguments: [
            .integer(Int32(clamping: x)), .integer(Int32(clamping: y))
        ])

        if let button = pressedButton {
            setButtonPressed(button, isPressed: false)
            if button == receiver {
                emitTrace(.init(kind: .declarativeButtonAction, receiver: button, name: "declarativeAction"))
                host?.makiDeclarativeButtonAction(receiver: button)
                handled = dispatch(event: "onLeftClick", receiver: button) || handled
            }
        }
        pressedButton = nil
        return handled
    }

    @discardableResult
    func dispatchMouseEnter(objectID: String) -> Bool {
        dispatch(event: "onEnterArea", objectID: objectID.lowercased())
    }

    @discardableResult
    func dispatchMouseLeave(objectID: String) -> Bool {
        dispatch(event: "onLeaveArea", objectID: objectID.lowercased())
    }

    @discardableResult
    func dispatchSliderPosition(objectID: String, value: Int, final: Bool = false, posted: Bool = false) -> Bool {
        let receiver = registry.compatibilityHandle(for: objectID)
        return dispatchSliderPosition(receiver: receiver, value: value, final: final, posted: posted)
    }

    @discardableResult
    func dispatchSliderPosition(receiver: WasabiHandle, value: Int, final: Bool = false, posted: Bool = false) -> Bool {
        let event = final ? "onSetFinalPosition" : posted ? "onPostedPosition" : "onSetPosition"
        let key = stateKey(for: receiver)
        targetStates[key, default: [:]]["position"] = Double(value)
        return dispatch(event: event, receiver: receiver, arguments: [.integer(Int32(clamping: value))])
    }

    /// Dispatch a typed event from a host integration. This is also the
    /// escape hatch for events that are not yet represented by convenience
    /// input methods above.
    @discardableResult
    func dispatchEvent(_ name: String, receiver: WasabiHandle, arguments: [MakiValue] = []) -> Bool {
        dispatch(event: name, receiver: receiver, arguments: arguments)
    }

    func isPressed(_ receiver: WasabiHandle) -> Bool { pressedButtons.contains(receiver) }

    func clearTrace() { trace.removeAll(keepingCapacity: true) }

    func scheduleTimer(objectID: String, interval: Duration, event: String = "onTimer") {
        let key = objectID.lowercased()
        timers[key]?.cancel()
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.dispatch(event: event, objectID: key)
        }
    }

    func cancelTimer(objectID: String) { timers.removeValue(forKey: objectID.lowercased())?.cancel() }

    func diagnosticsReport() -> String {
        diagnostics.isEmpty ? "No unsupported MAKI operations encountered." : diagnostics.joined(separator: "\n")
    }

    var registeredEventNames: [String] {
        Array(Set(instances.flatMap { instance in
            instance.program.events.compactMap { event in
                instance.program.functions.indices.contains(event.functionIndex) ? instance.program.functions[event.functionIndex].name : nil
            }
        })).sorted()
    }

    var targetAnimationObjectIDs: [String] { targetStates.keys.sorted() }

    func recordExternalDiagnostic(_ message: String) { record(message) }

    private func persistentKey(_ key: String) -> String { "Macamp.MAKI.\(skinID).\(key)" }

    private func readPersisted(_ key: String) -> Value? {
        guard let value = persistentState.object(forKey: persistentKey(key)) else { return nil }
        if let value = value as? Int { return .integer(Int32(clamping: value)) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? String { return .string(value) }
        return nil
    }

    private func persist(_ value: Value, for key: String) {
        switch value {
        case let .integer(value): persistentState.set(Int(value), forKey: persistentKey(key))
        case let .number(value): persistentState.set(value, forKey: persistentKey(key))
        case let .string(value): persistentState.set(value, forKey: persistentKey(key))
        case let .object(handle): persistentState.set(Int64(handle.rawValue), forKey: persistentKey(key))
        case .void: persistentState.removeObject(forKey: persistentKey(key))
        }
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
        let receiver = registry.compatibilityHandle(for: objectID)
        return dispatch(event: eventName, receiver: receiver)
    }

    @discardableResult
    private func dispatch(event eventName: String, receiver: WasabiHandle, arguments: [Value] = []) -> Bool {
        guard nestedEventDepth < limits.maximumNestedEvents else {
            record("Stopped nested MAKI event dispatch at the safety limit.")
            return false
        }
        emitTrace(.init(kind: .event, receiver: receiver, name: eventName, arguments: arguments))
        host?.makiEventDispatched(receiver: receiver, name: eventName, arguments: .init(arguments))
        nestedEventDepth += 1
        defer { nestedEventDepth -= 1 }
        var handled = false
        for instance in instances where instance.disabledReason == nil {
            for event in instance.program.events {
                guard instance.program.functions[event.functionIndex].name.caseInsensitiveCompare(eventName) == .orderedSame,
                      instance.variables[event.variableIndex] == .object(receiver) else { continue }
                do {
                    try execute(instance, at: event.codeOffset, arguments: arguments)
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

    private func isButton(_ receiver: WasabiHandle) -> Bool {
        registry.object(receiver)?.className.caseInsensitiveCompare("Button") == .orderedSame
    }

    private func setButtonPressed(_ receiver: WasabiHandle, isPressed: Bool) {
        if isPressed {
            pressedButtons.insert(receiver)
        } else {
            pressedButtons.remove(receiver)
        }
        emitTrace(.init(
            kind: .buttonPressedChanged,
            receiver: receiver,
            name: "pressed",
            arguments: [.integer(isPressed ? 1 : 0)]
        ))
        host?.makiButtonPressedChanged(receiver: receiver, isPressed: isPressed)
    }

    private func stateKey(for receiver: WasabiHandle) -> String {
        registry.object(receiver)?.id?.lowercased() ?? "handle:\(receiver.rawValue)"
    }

    private func emitTrace(_ entry: MakiRuntimeTraceEntry) {
        trace.append(entry)
        if trace.count > 512 { trace.removeFirst(trace.count - 512) }
    }

    private func execute(_ instance: Instance, at entryPoint: Int, arguments: [Value] = []) throws {
        var pc = entryPoint
        // MAKI's event arguments are pushed in reverse order so the first
        // source-level parameter is at the top of the VM stack.
        var stack: [StackValue] = arguments.reversed().map { StackValue(value: $0, variableIndex: nil) }
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
                    else { argumentCount = checkedArity(of: instance.program.functions[functionIndex].name) }
                } else { argumentCount = checkedArity(of: instance.program.functions[functionIndex].name) }
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
        let normalizedName = rawName.lowercased()
        // These are legacy global helpers emitted by older standard-frame
        // scripts. They do not have a Wasabi object receiver even though the
        // VM call form still supplies one stack slot.
        if normalizedName == "getparam" || normalizedName == "gettoken" {
            return .string(arguments.first?.string ?? "")
        }
        guard case let .object(receiver) = object else {
            record("MAKI call (\(rawName)) received a non-object receiver: \(object)")
            return .integer(0)
        }
        return invoke(method: rawName, receiver: receiver, arguments: arguments, instance: instance)
    }

    @discardableResult
    func invoke(receiver: WasabiHandle, method: String, arguments: [MakiValue]) -> MakiValue {
        invoke(method: method, receiver: receiver, arguments: arguments, instance: nil)
    }

    private func invoke(method rawName: String, receiver: WasabiHandle, arguments: [Value], instance: Instance?) -> Value {
        guard let object = registry.object(receiver) else {
            record("MAKI call \(rawName) received an unknown Wasabi handle \(receiver.rawValue).")
            return .integer(0)
        }
        guard let signature = MakiClassCatalog.resolve(className: object.className, method: rawName) else {
            record("Unsupported \(object.className).\(rawName).")
            return .integer(0)
        }
        guard arguments.count == signature.arity else {
            record("Invalid arity for \(object.className).\(rawName): expected \(signature.arity), received \(arguments.count).")
            return .integer(0)
        }

        let name = rawName.lowercased()
        let objectID = object.id?.lowercased() ?? "handle:\(receiver.rawValue)"
        switch signature.implementation {
        case .findObject:
            guard let id = arguments.first?.string, let handle = registry.findObject(id: id, within: receiver) else { return .void }
            return .object(handle)
        case .systemGetContainer:
            guard let id = arguments.first?.string else { return .void }
            if let handle = registry.findObject(id: id) {
                if let container = registry.container(for: handle) { return .object(container) }
                if registry.object(handle)?.className.caseInsensitiveCompare("Container") == .orderedSame { return .object(handle) }
            }
            return registry.compatibilityContainer(for: id).map(MakiValue.object) ?? .void
        case .containerGetLayout:
            guard let id = arguments.first?.string else { return .void }
            if let handle = registry.layout(for: receiver, id: id) { return .object(handle) }
            return registry.compatibilityLayout(for: id).map(MakiValue.object) ?? .void
        case .layoutGetContainer:
            return registry.container(for: receiver).map(MakiValue.object) ?? .void
        case .systemGetPosition:
            return .number(host?.makiElapsed().secondsValue ?? 0)
        case .sliderGetPosition:
            return .number(targetStates[objectID]?["position"] ?? 0)
        case .frameGetPosition:
            return .number(targetStates[objectID]?["position"] ?? 0)
        case .timerStop:
            cancelTimer(objectID: objectID)
            return .void
        case .legacy:
            break
        }

        let instance = instance
        switch name {
        case "getruntimeversion": return .number(5.666)
        case "getskinname": return .string("Macamp Modern")
        case "gettimeofday", "getstatus": return .integer(Int32(host?.makiPlaybackStatus() ?? 0))
        case "getscriptgroup":
            let handle = registry.handle(forXMLID: instance?.groupID ?? "") ?? registry.compatibilityHandle(for: instance?.groupID ?? "")
            return .object(handle)
        case "getobject":
            guard let id = arguments.first?.string, !id.isEmpty else { return .void }
            return .object(registry.compatibilityHandle(for: id))
        case "hide":
            visibleObjects[objectID] = false; host?.makiVisibilityChanged(objectID: objectID, isVisible: false); return .void
        case "show":
            visibleObjects[objectID] = true; host?.makiVisibilityChanged(objectID: objectID, isVisible: true); return .void
        case "getxmlparam":
            let key = arguments.first?.string.lowercased() ?? ""
            return .string(xmlParameters[objectID]?[key] ?? host?.makiXMLParameter(objectID: objectID, name: key) ?? "")
        case "getparam", "gettoken":
            return .string(arguments.first?.string ?? "")
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
        case "getplayitem":
            if playItemHandle == nil { playItemHandle = registry.instantiate(className: "PlayItem", id: "playitem") }
            return playItemHandle.map(MakiValue.object) ?? .void
        case "gettitle": return .string(host?.makiPlaybackItem()?.title ?? "")
        case "getartist": return .string(host?.makiPlaybackItem()?.artist ?? "")
        case "getalbum": return .string(host?.makiPlaybackItem()?.albumTitle ?? "")
        case "getlength": return .number(host?.makiDuration()?.secondsValue ?? 0)
        case "getposition": return .number(host?.makiElapsed().secondsValue ?? 0)
        case "stringtointeger": return .integer(arguments.first?.integer ?? 0)
        case "settargetx":
            targetX[objectID] = arguments.first?.number ?? 0
            targetStates[objectID, default: [:]]["x"] = arguments.first?.number ?? 0
            return .void
        case "settargety": targetStates[objectID, default: [:]]["y"] = arguments.first?.number ?? 0; return .void
        case "settargetw", "settargetwidth": targetStates[objectID, default: [:]]["w"] = arguments.first?.number ?? 0; return .void
        case "settargeth", "settargetheight": targetStates[objectID, default: [:]]["h"] = arguments.first?.number ?? 0; return .void
        case "settargetalpha": targetStates[objectID, default: [:]]["alpha"] = arguments.first?.number ?? 1; return .void
        case "settargetspeed": targetSpeed[objectID] = max(0.01, arguments.first?.number ?? 0.25); return .void
        case "gototarget":
            let state = targetStates[objectID] ?? [:]
            if state.isEmpty {
                host?.makiTargetChanged(objectID: objectID, x: targetX[objectID] ?? 0, speed: targetSpeed[objectID] ?? 0.25)
            } else {
                host?.makiTargetGeometryChanged(objectID: objectID, x: targetX[objectID], y: state["y"], width: state["w"], height: state["h"], alpha: state["alpha"], speed: targetSpeed[objectID] ?? 0.25)
            }
            return .void
        case "leftclick": _ = dispatch(event: "onLeftClick", receiver: receiver); return .void
        case "setvolume": host?.makiVolumeChanged((arguments.first?.number ?? 0) / 255); return .void
        case "seteqband":
            if arguments.count >= 2 { host?.makiEQBandChanged(index: Int(arguments[0].integer), value: Int(arguments[1].integer)) }
            return .void
        case "geteqband": return .integer(Int32(host?.makiEQBandValue(index: Int(arguments.first?.integer ?? 0)) ?? 128))
        case "geteqpreamp": return .integer(Int32(host?.makiEQPreampValue() ?? 128))
        case "geteq": return .integer(host?.makiEQEnabled() == true ? 1 : 0)
        case "seteq": host?.makiEQEnabledChanged((arguments.first?.integer ?? 0) != 0); return .void
        case "seteqpreamp": host?.makiEQPreampChanged(value: Int(arguments.first?.integer ?? 128)); return .void
        case "setposition":
            if let value = arguments.first?.number { targetStates[objectID, default: [:]]["position"] = value; host?.makiRuntimeNeedsDisplay() }
            return .void
        case "setprivateint", "setprivatestring":
            guard !arguments.isEmpty else { return .void }
            let key = arguments.dropLast().map(\.string).joined(separator: ".")
            let value = arguments.last ?? .void
            privateState[key] = value; persist(value, for: key); return .void
        case "getprivateint", "getprivatestring":
            let key = arguments.dropLast().map(\.string).joined(separator: ".")
            return privateState[key] ?? readPersisted(key) ?? arguments.last ?? .void
        case "getconfigattribute":
            let key = arguments.first?.string ?? ""
            return configAttributes[key] ?? readPersisted("config.\(key)") ?? .void
        case "setconfigattribute":
            guard arguments.count >= 2 else { return .void }
            let key = arguments[0].string; let value = arguments[1]
            configAttributes[key] = value; persist(value, for: "config.\(key)"); return .void
        case "settimer", "settimerinterval":
            let interval = max(0.001, arguments.first?.number ?? 0.25)
            scheduleTimer(objectID: objectID, interval: .milliseconds(Int64(interval * 1_000))); return .void
        case "killtimer": cancelTimer(objectID: objectID); return .void
        case "switchtolayout": host?.makiLayoutSwitched(containerID: objectID, layoutID: arguments.first?.string ?? "normal"); return .void
        case "resize":
            if arguments.count >= 4 { host?.makiLayoutResized(objectID: objectID, frame: CGRect(x: CGFloat(arguments[0].number), y: CGFloat(arguments[1].number), width: CGFloat(arguments[2].number), height: CGFloat(arguments[3].number))) }
            return .void
        case "beforeredock": host?.makiRedock(objectID: objectID, before: true); return .void
        case "redock": host?.makiRedock(objectID: objectID, before: false); return .void
        case "snapadjust": host?.makiRuntimeNeedsDisplay(); return .void
        case "messagebox": record("MAKI messageBox is unsupported but was safely ignored."); return .void
        default:
            if !name.hasPrefix("on") { record("Unsupported MAKI host call: \(rawName)") }
            return .integer(0)
        }
    }

    private func valuesEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case let (.string(left), .string(right)):
            left.caseInsensitiveCompare(right) == .orderedSame
        case let (.object(left), .object(right)):
            left == right
        case (.void, .void): true
        case (.string, _), (_, .string), (.object, _), (_, .object), (.void, _), (_, .void): false
        default: lhs.number == rhs.number
        }
    }

    private func checkedArity(of method: String) -> Int {
        MakiClassCatalog.resolve(className: "Object", method: method)?.arity ?? 0
    }

    private func record(_ message: String) {
        guard !diagnostics.contains(message), diagnostics.count < 100 else { return }
        diagnostics.append(message)
    }

    private func runtimeError(_ detail: String) -> ProviderError {
        ProviderError(code: .invalidResponse, message: "MAKI runtime error: \(detail).")
    }
}
