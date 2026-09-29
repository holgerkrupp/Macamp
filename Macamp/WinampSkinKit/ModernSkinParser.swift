import CoreGraphics
import Foundation

enum ModernSkinParser {
    struct Result: Sendable {
        var descriptor: ModernSkinDescriptor
        var warnings: [String]
    }

    nonisolated static func parse(files: [String: Data]) -> Result {
        var descriptor = ModernSkinDescriptor()
        var warnings: [String] = []
        var candidates: [LayoutCandidate] = []
        let xmlFiles = files.filter { $0.key.pathExtension.lowercased() == "xml" }.sorted { $0.key < $1.key }

        for (path, data) in xmlFiles {
            guard !containsDoctype(data) else {
                warnings.append("Ignored \(path) because document type declarations are not allowed.")
                continue
            }
            do {
                let document = try parseDocument(data)
                try collectMetadata(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectBitmaps(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectMakiBindings(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                candidates.append(contentsOf: try collectLayouts(document: document))
            } catch {
                warnings.append("Could not parse \(path): \(error.localizedDescription)")
            }
        }

        let definitions = Dictionary(candidates.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let expandedCandidates = candidates.map { expand($0, definitions: definitions, visited: []) }
        if let selected = expandedCandidates.max(by: { score($0) < score($1) }) {
            let clamped = CGSize(width: min(max(selected.canvasSize.width, 16), 2_048), height: min(max(selected.canvasSize.height, 16), 2_048))
            if clamped != selected.canvasSize { warnings.append("The selected Modern layout canvas was clamped to safe dimensions.") }
            descriptor.canvasSize = clamped
            descriptor.layers = selected.layers
            descriptor.controls = selected.controls
            descriptor.textRegions = selected.textRegions
            descriptor.contentRegions = deduplicatedContent(selected.contentRegions)
            descriptor.drawers = selected.drawers
            descriptor.layouts = expandedCandidates
                .filter(\.isLayout)
                .map {
                    ModernLayoutDescriptor(
                        id: $0.id,
                        frame: CGRect(origin: .zero, size: $0.canvasSize),
                        containerID: $0.containerID ?? "main",
                        initiallyVisible: $0.containerIsDefaultVisible
                    )
                }
            descriptor.objectTree = makeObjectTree(for: selected)
            if !selected.regionShapes.isEmpty || selected.desktopAlpha {
                descriptor.windowRegion = ModernWindowRegionDescriptor(
                    shapes: selected.regionShapes,
                    desktopAlpha: selected.desktopAlpha,
                    usesBitmapAlpha: selected.desktopAlpha
                )
            }
        }
        descriptor.screenshotPath = descriptor.screenshotPath.flatMap { resolve(path: $0, relativeTo: "skin.xml", files: files) }
        return Result(descriptor: descriptor, warnings: warnings)
    }

    private struct LayoutCandidate {
        var id: String
        var isLayout: Bool
        var canvasSize: CGSize
        var layers: [ModernSkinLayer]
        var controls: [SkinControlDefinition]
        var textRegions: [ModernSkinTextRegion]
        var contentRegions: [ModernSkinContentRegion]
        var groups: [GroupReference]
        var drawers: [ModernDrawerDescriptor]
        var regionShapes: [ModernWindowRegionShape]
        var desktopAlpha: Bool
        var inheritedGroupID: String?
        var containerID: String?
        var containerIsDefaultVisible: Bool
        var drawerTargetX: CGFloat?
    }

    private struct GroupReference { var id: String; var origin: CGPoint }

    nonisolated private static func collectMetadata(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        if descriptor.name == nil { descriptor.name = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='name']") }
        if descriptor.author == nil { descriptor.author = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='author']") }
        if descriptor.screenshotPath == nil, let screenshot = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='screenshot']") {
            descriptor.screenshotPath = resolve(path: screenshot, relativeTo: xmlPath, files: files) ?? screenshot
        }
    }

    nonisolated private static func collectBitmaps(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        for case let element as XMLElement in try document.nodes(forXPath: "//*[local-name()='bitmap']") {
            guard let id = attribute("id", element)?.lowercased(), let file = attribute("file", element),
                  let resolved = resolve(path: file, relativeTo: xmlPath, files: files) else { continue }
            descriptor.bitmapFiles[id] = resolved
            let stateBase = id.last?.isNumber == true ? String(id.dropLast()) : nil
            if let stateBase, descriptor.bitmapFiles[stateBase] == nil { descriptor.bitmapFiles[stateBase] = resolved }
            if let width = number(attribute("w", element)), let height = number(attribute("h", element)), width > 0, height > 0 {
                let source = CGRect(x: number(attribute("x", element)) ?? 0, y: number(attribute("y", element)) ?? 0, width: width, height: height)
                descriptor.bitmapSourceRects[id] = source
                if let stateBase, descriptor.bitmapSourceRects[stateBase] == nil { descriptor.bitmapSourceRects[stateBase] = source }
            }
        }
    }

    nonisolated private static func collectMakiBindings(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        for case let element as XMLElement in try document.nodes(forXPath: "//*[local-name()='script']") {
            guard let file = attribute("file", element),
                  let path = resolve(path: file, relativeTo: xmlPath, files: files),
                  path.pathExtension.lowercased() == "maki",
                  let root = nearestStructuralRoot(of: element),
                  let groupID = attribute("id", root) else { continue }
            let binding = ModernMakiBinding(path: path, groupID: groupID, parameter: attribute("param", element))
            if !descriptor.makiBindings.contains(binding) { descriptor.makiBindings.append(binding) }
        }
    }

    nonisolated private static func collectLayouts(document: XMLDocument) throws -> [LayoutCandidate] {
        var result: [LayoutCandidate] = []
        let xpath = "//*[local-name()='layout' or local-name()='groupdef']"
        for case let root as XMLElement in try document.nodes(forXPath: xpath) {
            let id = attribute("id", root) ?? "unnamed"
            let isLayout = root.name?.lowercased() == "layout"
            var layers: [ModernSkinLayer] = []
            var controls: [SkinControlDefinition] = []
            var textRegions: [ModernSkinTextRegion] = []
            var contentRegions: [ModernSkinContentRegion] = []
            var groups: [GroupReference] = []
            var regionShapes: [ModernWindowRegionShape] = []
            var drawerTargetX: CGFloat?
            let declaredWidth = number(attribute("w", root)) ?? number(attribute("default_w", root)) ?? 0
            let declaredHeight = number(attribute("h", root)) ?? number(attribute("default_h", root)) ?? 0
            let rootSize = CGSize(width: declaredWidth, height: declaredHeight)
            let desktopAlpha = bool(attribute("desktopalpha", root))
            if let background = attribute("background", root)?.lowercased() {
                layers.append(ModernSkinLayer(imageID: background, frame: .zero, elementID: id))
            }
            for case let element as XMLElement in try root.nodes(forXPath: ".//*") {
                guard nearestStructuralRoot(of: element) === root else { continue }
                let tag = element.name?.lowercased() ?? ""
                if let elementID = attribute("id", element)?.lowercased(),
                   elementID.contains("drawercoords"),
                   let targetX = number(attribute("x", element)) {
                    drawerTargetX = targetX
                }
                let initiallyVisible = isInitiallyVisible(element)
                let origin = absoluteOrigin(of: element, within: root)
                let frame = resolvedFrame(of: element, origin: origin, parentSize: rootSize)
                let controlTags = ["button", "togglebutton", "nstatesbutton", "slider"]
                let mapped = controlTags.contains(tag)
                    ? mapAction(
                        attribute("action", element),
                        id: attribute("id", element),
                        parameter: attribute("param", element),
                        tag: tag
                    )
                    : nil
                let imageID = (tag == "slider" ? attribute("thumb", element) : nil)
                    ?? attribute("image", element)
                    ?? attribute("background", element)
                if ["layer", "animatedlayer", "button", "togglebutton", "nstatesbutton", "slider"].contains(tag),
                   let imageID,
                   mapped == nil {
                    let sysRegion = number(attribute("sysregion", element)).map(Int.init)
                    let visualFrame = tag == "slider" ? CGRect(origin: frame.origin, size: .zero) : frame
                    layers.append(ModernSkinLayer(
                        imageID: imageID.lowercased(),
                        frame: visualFrame,
                        elementID: attribute("id", element),
                        opacity: opacity(of: element),
                        cropToFirstFrame: tag == "animatedlayer",
                        action: mapped?.action,
                        initiallyVisible: initiallyVisible,
                        sysRegion: sysRegion
                    ))
                    if let sysRegion, sysRegion != 0, !visualFrame.isEmpty {
                        regionShapes.append(ModernWindowRegionShape(frame: visualFrame, additive: sysRegion > 0))
                    }
                }
                if let mapped {
                    let sprite = imageID.map { SpriteReference(assetName: $0.lowercased(), sourceRect: .zero) }
                    let pressed = attribute("downimage", element).map { SpriteReference(assetName: $0.lowercased(), sourceRect: .zero) }
                    let orientation: SkinControlOrientation? = tag == "slider"
                        ? (attribute("orientation", element)?.lowercased() == "vertical" ? .vertical : .horizontal)
                        : nil
                    controls.append(SkinControlDefinition(
                        id: mapped.id,
                        frame: frame,
                        normalSprite: sprite,
                        pressedSprite: pressed,
                        disabledSprite: nil,
                        action: mapped.action,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible,
                        parameter: Int(attribute("param", element) ?? "") ?? equalizerBandNumber(from: attribute("id", element)),
                        orientation: orientation
                    ))
                } else if ["button", "togglebutton", "nstatesbutton", "slider"].contains(tag) {
                    // A button can be completely MAKI-owned. It still needs a
                    // hit target even when its XML has no native action.
                    let scriptedID: SkinControlID = .scripted
                    let orientation: SkinControlOrientation? = tag == "slider"
                        ? (attribute("orientation", element)?.lowercased() == "vertical" ? .vertical : .horizontal)
                        : nil
                    controls.append(SkinControlDefinition(
                        id: scriptedID,
                        frame: frame,
                        normalSprite: imageID.map { SpriteReference(assetName: $0.lowercased(), sourceRect: .zero) },
                        pressedSprite: attribute("downimage", element).map { SpriteReference(assetName: $0.lowercased(), sourceRect: .zero) },
                        disabledSprite: nil,
                        action: .scripted,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible,
                        parameter: Int(attribute("param", element) ?? "") ?? equalizerBandNumber(from: attribute("id", element)),
                        orientation: orientation
                    ))
                }
                if tag == "group", let groupID = attribute("id", element) {
                    groups.append(GroupReference(id: groupID, origin: origin))
                }
                if let role = textRole(tag: tag, element: element), frame.width > 0, frame.height > 0 {
                    let color = textColor(attribute("color", element))
                    textRegions.append(ModernSkinTextRegion(
                        role: role,
                        frame: frame,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible,
                        fontSize: number(attribute("fontsize", element)).map(Double.init) ?? min(14, max(7, Double(frame.height))),
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        alignment: attribute("align", element)?.lowercased() ?? "left"
                    ))
                }
                if let role = contentRole(tag: tag, element: element), frame.width > 0, frame.height > 0 {
                    contentRegions.append(ModernSkinContentRegion(
                        role: role,
                        frame: frame,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible
                    ))
                }
            }
            let contentBounds = layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let width = declaredWidth > 0 ? declaredWidth : max(1, contentBounds.maxX.isFinite ? contentBounds.maxX : 275)
            let height = declaredHeight > 0 ? declaredHeight : max(1, contentBounds.maxY.isFinite ? contentBounds.maxY : 116)
            if !layers.isEmpty || !controls.isEmpty || !groups.isEmpty || !textRegions.isEmpty || !contentRegions.isEmpty {
                let container = nearestAncestor(named: "container", of: root)
                result.append(LayoutCandidate(
                    id: id,
                    isLayout: isLayout,
                    canvasSize: CGSize(width: width, height: height),
                    layers: layers,
                    controls: controls,
                    textRegions: textRegions,
                    contentRegions: contentRegions,
                    groups: groups,
                    drawers: [],
                    regionShapes: regionShapes,
                    desktopAlpha: desktopAlpha,
                    inheritedGroupID: attribute("inherit_group", root),
                    containerID: container.flatMap { attribute("id", $0)?.lowercased() },
                    containerIsDefaultVisible: container.flatMap { attribute("default_visible", $0) }.map { $0 != "0" } ?? false,
                    drawerTargetX: drawerTargetX
                ))
            }
        }
        return result
    }

    nonisolated private static func makeObjectTree(for candidate: LayoutCandidate) -> WasabiObjectTree {
        var tree = WasabiObjectTree()
        let containerID = (candidate.containerID ?? "main").lowercased()
        tree.rootID = containerID
        tree.insert(WasabiObjectNode(id: containerID, kind: .container, frame: CGRect(origin: .zero, size: candidate.canvasSize), parentID: nil, initiallyVisible: candidate.containerIsDefaultVisible, zIndex: 0))
        tree.insert(WasabiObjectNode(id: candidate.id, kind: .layout, frame: CGRect(origin: .zero, size: candidate.canvasSize), parentID: containerID, zIndex: 1))
        for (index, group) in candidate.groups.enumerated() {
            tree.insert(WasabiObjectNode(id: group.id, kind: .group, frame: CGRect(origin: group.origin, size: .zero), parentID: candidate.id, zIndex: index + 2))
        }
        var z = candidate.groups.count + 2
        for (index, layer) in candidate.layers.enumerated() {
            let id = (layer.elementID?.lowercased() ?? "layer-\(index)")
            tree.insert(WasabiObjectNode(id: id, kind: .layer, frame: layer.frame, parentID: candidate.id, initiallyVisible: layer.initiallyVisible, attributes: ["alpha": String(layer.opacity)], zIndex: z)); z += 1
        }
        for (index, control) in candidate.controls.enumerated() {
            let id = (control.elementID?.lowercased() ?? "control-\(index)")
            tree.insert(WasabiObjectNode(id: id, kind: control.orientation == nil ? (control.action == .scripted ? .button : .button) : .slider, frame: control.frame, parentID: candidate.id, initiallyVisible: control.initiallyVisible, zIndex: z)); z += 1
        }
        for (index, region) in candidate.textRegions.enumerated() {
            tree.insert(WasabiObjectNode(id: (region.elementID?.lowercased() ?? "text-\(index)"), kind: .text, frame: region.frame, parentID: candidate.id, initiallyVisible: region.initiallyVisible, zIndex: z)); z += 1
        }
        for (index, region) in candidate.contentRegions.enumerated() {
            tree.insert(WasabiObjectNode(id: (region.elementID?.lowercased() ?? "content-\(index)"), kind: .content, frame: region.frame, parentID: candidate.id, initiallyVisible: region.initiallyVisible, zIndex: z)); z += 1
        }
        return tree
    }

    nonisolated private static func score(_ candidate: LayoutCandidate) -> Int {
        let id = candidate.id.lowercased()
        var value = candidate.layers.count + candidate.controls.count * 4
        if candidate.isLayout { value += 300 }
        if candidate.containerID == "main" { value += 1_000 }
        if candidate.containerIsDefaultVisible { value += 300 }
        if id.contains("player") { value += 100 }
        if id.contains("normal") || id.contains("main") { value += 80 }
        if id == "normal" || id == "main" || id.hasSuffix(".normal") { value += 500 }
        if id.contains("visual") || id.contains("vis") { value -= 80 }
        if id.contains("equalizer") || id.contains("eq") { value -= 80 }
        if id.contains("shade") || id.contains("compact") { value -= 30 }
        return value
    }

    nonisolated private static func expand(_ candidate: LayoutCandidate, definitions: [String: LayoutCandidate], visited: Set<String>) -> LayoutCandidate {
        let key = candidate.id.lowercased()
        guard !visited.contains(key) else { return candidate }
        var result = candidate
        var nextVisited = visited; nextVisited.insert(key)
        if let inheritedID = candidate.inheritedGroupID?.lowercased(),
           let inherited = definitions[inheritedID], !nextVisited.contains(inheritedID) {
            let parent = expand(inherited, definitions: definitions, visited: nextVisited)
            result.layers.insert(contentsOf: parent.layers, at: 0)
            result.controls.insert(contentsOf: parent.controls, at: 0)
            result.textRegions.insert(contentsOf: parent.textRegions, at: 0)
            result.contentRegions.insert(contentsOf: parent.contentRegions, at: 0)
            result.drawers.insert(contentsOf: parent.drawers, at: 0)
            result.regionShapes.insert(contentsOf: parent.regionShapes, at: 0)
            result.desktopAlpha = result.desktopAlpha || parent.desktopAlpha
        }
        for reference in candidate.groups {
            let referenceID = reference.id.lowercased()
            if referenceID.contains("modeequalizer") || referenceID.contains("modeconfigure") || referenceID.contains("transition") { continue }
            guard let definition = definitions[referenceID] else { continue }
            let child = expand(definition, definitions: definitions, visited: nextVisited)
            let origin = expandedOrigin(for: reference, child: child, canvasSize: candidate.canvasSize)
            let drawerRole = drawerRole(for: reference.id)
            result.layers.append(contentsOf: child.layers.map { layer in
                var translated = layer
                translated.frame.origin.x += origin.x
                translated.frame.origin.y += origin.y
                if translated.drawerRole == nil { translated.drawerRole = drawerRole }
                return translated
            })
            result.regionShapes.append(contentsOf: child.regionShapes.map { shape in
                var translated = shape
                translated.frame.origin.x += origin.x
                translated.frame.origin.y += origin.y
                if translated.drawerRole == nil { translated.drawerRole = drawerRole }
                return translated
            })
            result.controls.append(contentsOf: child.controls.map { control in
                var frame = control.frame
                frame.origin.x += origin.x
                frame.origin.y += origin.y
                return SkinControlDefinition(
                    id: control.id,
                    frame: frame,
                    normalSprite: control.normalSprite,
                    pressedSprite: control.pressedSprite,
                    disabledSprite: control.disabledSprite,
                    action: control.action,
                    elementID: control.elementID,
                    initiallyVisible: control.initiallyVisible,
                    drawerRole: control.drawerRole ?? drawerRole,
                    parameter: control.parameter,
                    orientation: control.orientation
                )
            })
            result.textRegions.append(contentsOf: child.textRegions.map { region in
                var translated = region
                translated.frame.origin.x += origin.x
                translated.frame.origin.y += origin.y
                if translated.drawerRole == nil { translated.drawerRole = drawerRole }
                return translated
            })
            result.contentRegions.append(contentsOf: child.contentRegions.map { region in
                var translated = region
                translated.frame.origin.x += origin.x
                translated.frame.origin.y += origin.y
                if translated.drawerRole == nil { translated.drawerRole = drawerRole }
                return translated
            })
            result.drawers.append(contentsOf: child.drawers.map { drawer in
                var translated = drawer
                translated.expandedFrame.origin.x += origin.x
                translated.expandedFrame.origin.y += origin.y
                translated.collapsedOrigin.x += origin.x
                translated.collapsedOrigin.y += origin.y
                return translated
            })
            if let drawerRole {
                result.drawers.removeAll { $0.role == drawerRole }
                result.drawers.append(ModernDrawerDescriptor(
                    role: drawerRole,
                    expandedFrame: CGRect(origin: origin, size: child.canvasSize),
                    collapsedOrigin: reference.origin
                ))
            }
        }
        return result
    }

    nonisolated private static func drawerRole(for id: String) -> ModernDrawerRole? {
        let value = id.lowercased()
        if value.contains("leftdrawer") { return .left }
        if value.contains("rightdrawer") { return .right }
        return nil
    }

    nonisolated private static func expandedOrigin(
        for reference: GroupReference,
        child: LayoutCandidate,
        canvasSize: CGSize
    ) -> CGPoint {
        let id = reference.id.lowercased()
        var origin = reference.origin
        // Drawer positions in many Modern skins are initialized by MAKI. The safe
        // static representation opens explicitly named edge drawers instead of
        // leaving them stacked underneath the main player body.
        if let targetX = child.drawerTargetX {
            origin.x = targetX
        } else if id.contains("leftdrawer"), canvasSize.width > child.canvasSize.width {
            origin.x = 0
        } else if id.contains("rightdrawer"), canvasSize.width > child.canvasSize.width {
            origin.x = canvasSize.width - child.canvasSize.width
        }
        return origin
    }

    nonisolated private static func resolvedFrame(
        of element: XMLElement,
        origin: CGPoint,
        parentSize: CGSize
    ) -> CGRect {
        var x = origin.x
        var y = origin.y
        var width = number(attribute("w", element)) ?? 0
        var height = number(attribute("h", element)) ?? 0
        if attribute("relatx", element) == "1", parentSize.width > 0 { x = parentSize.width + x }
        if attribute("relaty", element) == "1", parentSize.height > 0 { y = parentSize.height + y }
        if attribute("relatw", element) == "1", parentSize.width > 0 { width = parentSize.width + width }
        if attribute("relath", element) == "1", parentSize.height > 0 { height = parentSize.height + height }
        return CGRect(x: x, y: y, width: max(0, width), height: max(0, height))
    }

    nonisolated private static func isInitiallyVisible(_ element: XMLElement) -> Bool {
        if let value = number(attribute("visible", element)), value <= 0 { return false }
        if let value = number(attribute("alpha", element)), value <= 0 { return false }
        return true
    }

    nonisolated private static func bool(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    nonisolated private static func opacity(of element: XMLElement) -> Double {
        guard let value = number(attribute("alpha", element)) else { return 1 }
        return min(max(Double(value) / 255, 0), 1)
    }

    nonisolated private static func nearestStructuralRoot(of element: XMLElement) -> XMLElement? {
        var node = element.parent
        while let ancestor = node as? XMLElement {
            let tag = ancestor.name?.lowercased() ?? ""
            if tag == "layout" || tag == "groupdef" { return ancestor }
            node = ancestor.parent
        }
        return nil
    }

    nonisolated private static func nearestAncestor(named name: String, of element: XMLElement) -> XMLElement? {
        var node = element.parent
        while let ancestor = node as? XMLElement {
            if ancestor.name?.lowercased() == name { return ancestor }
            node = ancestor.parent
        }
        return nil
    }

    nonisolated private static func textRole(tag: String, element: XMLElement) -> ModernSkinTextRole? {
        guard tag == "text" || tag == "songticker" else { return nil }
        let value = "\(attribute("display", element) ?? "") \(attribute("id", element) ?? "")".lowercased()
        if tag == "songticker" || value.contains("songname") || value.contains("songtitle") || value.contains("songinfo") {
            return .songTitle
        }
        if value.contains("remaining") { return .remainingTime }
        if value.contains("elapsed") || value == "time" || value.contains(" timer") || value.hasPrefix("time ") { return .elapsedTime }
        if value.contains("bitrate") || value.contains("bit rate") { return .bitrate }
        if value.contains("frequency") || value.contains("sample") || value.contains("khz") { return .frequency }
        if value.contains("channels") || value.contains("channel") { return .channels }
        if value.contains("extension") || value.contains("fileext") || value.contains("file type") { return .fileExtension }
        return nil
    }

    nonisolated private static func textColor(_ value: String?) -> (red: Double, green: Double, blue: Double) {
        guard let value else { return (0.3, 1, 0.5) }
        let components = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 3 else { return (0.3, 1, 0.5) }
        return (
            min(max(components[0] / 255, 0), 1),
            min(max(components[1] / 255, 0), 1),
            min(max(components[2] / 255, 0), 1)
        )
    }

    nonisolated private static func contentRole(tag: String, element: XMLElement) -> ModernSkinContentRole? {
        if tag == "albumart" { return .albumArt }
        if tag == "vis" { return .visualization }
        guard tag == "component" else { return nil }
        let parameter = attribute("param", element)?.lowercased() ?? ""
        if parameter.contains("guid:avs") { return .visualization }
        if parameter == "guid:pl" || parameter.contains("playlist") { return .playlist }
        return nil
    }

    nonisolated private static func deduplicatedContent(_ regions: [ModernSkinContentRegion]) -> [ModernSkinContentRegion] {
        var result: [ModernSkinContentRegion] = []
        for region in regions {
            let duplicate = result.contains { existing in
                guard sameContentRole(existing.role, region.role) else { return false }
                if existing.elementID?.lowercased() != region.elementID?.lowercased() { return false }
                let overlap = existing.frame.intersection(region.frame)
                let smallerArea = min(existing.frame.width * existing.frame.height, region.frame.width * region.frame.height)
                return !overlap.isNull && smallerArea > 0 && overlap.width * overlap.height / smallerArea > 0.75
            }
            if !duplicate { result.append(region) }
        }
        return result
    }

    nonisolated private static func sameContentRole(_ lhs: ModernSkinContentRole, _ rhs: ModernSkinContentRole) -> Bool {
        switch (lhs, rhs) {
        case (.albumArt, .albumArt), (.visualization, .visualization), (.playlist, .playlist): true
        default: false
        }
    }

    nonisolated private static func absoluteOrigin(of element: XMLElement, within root: XMLElement) -> CGPoint {
        var point = CGPoint(x: number(attribute("x", element)) ?? 0, y: number(attribute("y", element)) ?? 0)
        var node = element.parent
        while let parent = node as? XMLElement, parent !== root {
            let tag = parent.name?.lowercased() ?? ""
            if ["group", "layout", "groupdef"].contains(tag) {
                point.x += number(attribute("x", parent)) ?? 0
                point.y += number(attribute("y", parent)) ?? 0
            }
            node = parent.parent
        }
        return point
    }

    nonisolated private static func mapAction(
        _ rawAction: String?,
        id rawID: String?,
        parameter: String?,
        tag: String
    ) -> (id: SkinControlID, action: SkinAction)? {
        let value = "\(rawAction ?? "") \(rawID ?? "") \(parameter ?? "")".lowercased()
        if value.contains("eq_band") || value.contains("eqband") {
            return (.equalizer, .setEqualizerBand)
        }
        if let rawID {
            let id = rawID.lowercased()
            if id.contains("eq"), id.contains("top") || id.contains("bottom"),
               let band = Int(id.filter(\Character.isNumber)), band > 0 {
                return (.equalizer, .setEqualizerBand)
            }
        }
        if value.contains("reseteq") || value.contains("eqreset") || value.contains("reset eq") {
            return (.equalizer, .resetEqualizer)
        }
        if value.contains("playlist") || value.contains("pltoggle") || value.contains("rightdrawer") || value.contains("guid:pl") {
            return (.playlist, .togglePlaylist)
        }
        if value.contains("equalizer") || value.contains("eqtoggle") || value.contains("eqshowhide") || value.contains("eq_toggle") || value.contains("leftdrawer") {
            return (.equalizer, .toggleEqualizer)
        }
        // System actions must win over IDs such as "playerclose" and
        // "playerminimize", which also happen to contain the word "play".
        if value.contains("minimize") || value.contains("minimise") { return (.minimize, .minimize) }
        if value.contains("close") { return (.close, .close) }
        if value.contains("previous") || value.contains("prev") || value.contains("rewind") { return (.previous, .previous) }
        if value.contains("play") { return (.play, .play) }
        if value.contains("pause") { return (.pause, .pause) }
        if value.contains("stop") { return (.stop, .stop) }
        if value.contains("next") || value.contains("forward") { return (.next, .next) }
        if value.contains("eject") || value.contains("open") { return (.open, .open) }
        if value.contains("volume") { return (.volume, .setVolume) }
        if value.contains("balance") || value.contains("pan") { return (.volume, .setBalance) }
        if value.contains("seek") || value.contains("position") { return (.seek, .seek) }
        if value.contains("shuffle") { return (.shuffle, .toggleShuffle) }
        if value.contains("repeat") { return (.repeat, .cycleRepeat) }
        if value.contains("visual") || value.contains("vis") { return (.visualization, .toggleVisualization) }
        return nil
    }

    nonisolated private static func equalizerBandNumber(from rawID: String?) -> Int? {
        guard let rawID else { return nil }
        let id = rawID.lowercased()
        guard id.contains("eq"), id.contains("top") || id.contains("bottom") else { return nil }
        let digits = id.filter(\Character.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    nonisolated private static func resolve(path rawPath: String, relativeTo xmlPath: String, files: [String: Data]) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else { return nil }
        if files[normalized] != nil { return normalized }
        let directory = xmlPath.split(separator: "/").dropLast().joined(separator: "/")
        let relative = directory.isEmpty ? normalized : "\(directory)/\(normalized)"
        if files[relative] != nil { return relative }
        let matches = files.keys.filter { $0 == normalized || $0.hasSuffix("/\(normalized)") }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated private static func firstText(_ document: XMLDocument, xpath: String) throws -> String? {
        try document.nodes(forXPath: xpath).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func attribute(_ name: String, _ element: XMLElement) -> String? {
        element.attribute(forName: name)?.stringValue
    }

    nonisolated private static func number(_ string: String?) -> CGFloat? {
        guard let string, let value = Double(string.trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGFloat(value)
    }

    nonisolated private static func containsDoctype(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(8_192), encoding: .utf8) else { return false }
        return prefix.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil
    }

    nonisolated private static func parseDocument(_ data: Data) throws -> XMLDocument {
        let options: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveAll]
        if let document = try? XMLDocument(data: data, options: options) { return document }
        guard var fragment = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ProviderError(code: .invalidResponse, message: "The XML text encoding is unsupported.")
        }
        fragment = fragment.replacingOccurrences(of: #"<\?xml[^?]*\?>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let wrapped = """
        <macamp-fragment xmlns:Wasabi="urn:macamp:wasabi" xmlns:wasabi="urn:macamp:wasabi" xmlns:ColorThemes="urn:macamp:colorthemes">
        \(fragment)
        </macamp-fragment>
        """
        return try XMLDocument(xmlString: wrapped, options: options)
    }
}

private extension String {
    nonisolated var pathExtension: String { (self as NSString).pathExtension }
}
