import CoreGraphics
import Foundation
import ImageIO

enum ModernSkinParser {
    struct Result: Sendable {
        var descriptor: ModernSkinDescriptor
        var warnings: [String]
    }

    nonisolated static func parse(files: [String: Data]) -> Result {
        var descriptor = ModernSkinDescriptor()
        var warnings: [String] = []
        var candidates: [LayoutCandidate] = []
        var elementAliases: [String: String] = [:]
        let xmlFiles = files.filter { $0.key.pathExtension.lowercased() == "xml" }.sorted { $0.key < $1.key }
        var pendingFiles = xmlFiles.map { ($0.key, $0.value) }
        var pendingIndex = 0
        var parsedPaths = Set<String>()

        while pendingIndex < pendingFiles.count {
            let (path, data) = pendingFiles[pendingIndex]
            pendingIndex += 1
            let normalizedPath = path.lowercased()
            guard parsedPaths.insert(normalizedPath).inserted else { continue }
            guard !containsDoctype(data) else {
                warnings.append("Ignored \(path) because document type declarations are not allowed.")
                continue
            }
            do {
                let document = try parseDocument(data)
                try collectMetadata(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectBitmaps(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectBitmapFonts(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectFontAndGammaResources(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                try collectMakiBindings(document: document, xmlPath: path, files: files, descriptor: &descriptor)
                collectElementAliases(document: document, into: &elementAliases)
                candidates.append(contentsOf: try collectLayouts(document: document, xmlPath: path, files: files))

                for includePath in try includedPaths(document: document, xmlPath: path, files: files) {
                    let key = includePath.lowercased()
                    guard !parsedPaths.contains(key), !pendingFiles.contains(where: { $0.0.lowercased() == key }),
                          let includeData = files[includePath] else { continue }
                    pendingFiles.append((includePath, includeData))
                }
            } catch {
                warnings.append("Could not parse \(path): \(error.localizedDescription)")
            }
        }

        applyElementAliases(elementAliases, to: &descriptor)
        // Static rendering has always repaired omitted bitmap geometry at the
        // catalog boundary.  The live Wasabi scene must receive the same
        // repaired frames, otherwise a sysregion/background object with no
        // explicit w/h becomes a zero-sized live node.
        candidates = candidates.map { normalizeBitmapGeometry($0, descriptor: descriptor, files: files) }

        let definitions: [String: LayoutCandidate] = Dictionary(candidates.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let xuiDefinitions: [String: LayoutCandidate] = Dictionary(candidates.compactMap { candidate in
            guard let xuiTag = candidate.xuiTag else { return nil }
            return (normalizeXUITag(xuiTag), candidate)
        }, uniquingKeysWith: { first, _ in first })
        let expandedCandidates = candidates.map { expand($0, definitions: definitions, xuiDefinitions: xuiDefinitions, visited: []) }
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
            descriptor.scene = makeScene(
                candidates: candidates,
                activeCandidate: selected,
                xuiDefinitions: xuiDefinitions,
                makiBindings: &descriptor.makiBindings
            )
            descriptor.objectTree = descriptor.scene.compatibilityTree
            if selected.regionShapes.contains(where: { abs($0.sysRegion) > 2 }) {
                warnings.append("Modern region values beyond +/-2 use Macamp's additive/subtractive rectangle subset.")
            }
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
        var xuiTag: String?
        var embedXUITarget: String?
        var containerID: String?
        var containerIsDefaultVisible: Bool
        var drawerTargetX: CGFloat?
        var scripts: [ScriptReference]
        var sendParams: [SendParam]
        var hiddenIDs: Set<String>
        var hiddenObjects: [HideObject]
        var sysRegion: Int?
        var hasDeclaredWidth: Bool
        var hasDeclaredHeight: Bool
    }

    private struct GroupReference {
        var definitionID: String
        var instanceID: String
        var tag: String
        var origin: CGPoint
        var attributes: [String: String]
    }

    private struct ScriptReference {
        var path: String
        var parameter: String?
    }

    private struct SendParam {
        var group: String?
        var targetIDs: [String]
        var attributes: [String: String]
    }

    private struct HideObject {
        var group: String?
        var targetIDs: [String]
    }

    nonisolated private static func collectMetadata(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        if descriptor.name == nil { descriptor.name = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='name']") }
        if descriptor.author == nil { descriptor.author = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='author']") }
        if descriptor.screenshotPath == nil, let screenshot = try firstText(document, xpath: "//*[local-name()='skininfo']/*[local-name()='screenshot']") {
            descriptor.screenshotPath = resolve(path: screenshot, relativeTo: xmlPath, files: files) ?? screenshot
        }
    }

    nonisolated private static func includedPaths(document: XMLDocument, xmlPath: String, files: [String: Data]) throws -> [String] {
        try document.nodes(forXPath: "//*[local-name()='include']").compactMap { node in
            guard let include = node as? XMLElement,
                  let file = attribute("file", include),
                  let resolved = resolve(path: file, relativeTo: xmlPath, files: files) else { return nil }
            return resolved
        }
    }

    nonisolated private static func collectElementAliases(document: XMLDocument, into aliases: inout [String: String]) {
        guard let elements = try? document.nodes(forXPath: "//*[local-name()='elementalias']") else { return }
        for case let element as XMLElement in elements {
            guard let id = attribute("id", element)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let target = attribute("target", element)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !id.isEmpty, !target.isEmpty else { continue }
            aliases[id] = target
        }
    }

    nonisolated private static func applyElementAliases(_ aliases: [String: String], to descriptor: inout ModernSkinDescriptor) {
        for alias in aliases.keys.sorted() {
            var target = aliases[alias]
            var visited = Set<String>([alias])
            while let next = target, let replacement = aliases[next], visited.insert(next).inserted {
                target = replacement
            }
            guard let target, !visited.contains(target),
                  let bitmap = descriptor.bitmapFiles[target] else { continue }
            descriptor.bitmapFiles[alias] = bitmap
            if let sourceRect = descriptor.bitmapSourceRects[target] {
                descriptor.bitmapSourceRects[alias] = sourceRect
            }
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

    nonisolated private static func collectBitmapFonts(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        for case let element as XMLElement in try document.nodes(forXPath: "//*[local-name()='bitmapfont']") {
            guard let id = attribute("id", element)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !id.isEmpty,
                  let file = attribute("file", element)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !file.isEmpty else { continue }

            let normalizedFile = file.replacingOccurrences(of: "\\", with: "/").lowercased()
            let bitmapID = descriptor.bitmapFiles[normalizedFile] != nil ? normalizedFile : nil
            let directPath = bitmapID == nil ? resolve(path: file, relativeTo: xmlPath, files: files) : nil
            guard bitmapID != nil || directPath != nil else { continue }
            let resource = ModernBitmapFontResource(
                id: id,
                imageID: bitmapID ?? normalizedFile,
                filePath: directPath,
                charWidth: max(1, Int(number(attribute("charwidth", element)) ?? 0)),
                charHeight: max(1, Int(number(attribute("charheight", element)) ?? 0)),
                horizontalSpacing: Int(number(attribute("hspacing", element)) ?? 0),
                verticalSpacing: Int(number(attribute("vspacing", element)) ?? 0)
            )
            descriptor.bitmapFonts[id] = resource
        }
    }

    nonisolated private static func collectFontAndGammaResources(document: XMLDocument, xmlPath: String, files: [String: Data], descriptor: inout ModernSkinDescriptor) throws {
        for case let element as XMLElement in try document.nodes(forXPath: "//*[local-name()='truetypefont' or local-name()='font']") {
            guard let id = attribute("id", element)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { continue }
            let rawFile = attribute("file", element) ?? attribute("src", element)
            let filePath = rawFile.flatMap { resolve(path: $0, relativeTo: xmlPath, files: files) }
            descriptor.fonts[id] = ModernFontResource(
                id: id,
                filePath: filePath,
                faceName: attribute("face", element) ?? attribute("font", element) ?? attribute("name", element),
                pointSize: number(attribute("size", element)).map(Double.init)
            )
        }
        for case let element as XMLElement in try document.nodes(forXPath: "//*[local-name()='gammagroup' or local-name()='gammaset']") {
            guard let id = attribute("id", element)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else { continue }
            let values = (element.attributes ?? []).compactMap { attribute in
                guard let name = attribute.name?.lowercased(), name.hasPrefix("gamma"), let value = Double(attribute.stringValue ?? "") else { return nil }
                return value
            } + (try element.nodes(forXPath: ".//*[local-name()='gamma']")).compactMap { node -> Double? in
                guard let child = node as? XMLElement else { return nil }
                return Double(attribute("value", child) ?? child.stringValue ?? "")
            }
            descriptor.gammaSets[id] = ModernGammaSetResource(id: id, values: values)
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

    nonisolated private static func collectLayouts(document: XMLDocument, xmlPath: String, files: [String: Data]) throws -> [LayoutCandidate] {
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
            var scripts: [ScriptReference] = []
            var sendParams: [SendParam] = []
            var hiddenIDs: Set<String> = []
            var hiddenObjects: [HideObject] = []
            let declaredWidth = number(attribute("w", root)) ?? number(attribute("default_w", root)) ?? 0
            let declaredHeight = number(attribute("h", root)) ?? number(attribute("default_h", root)) ?? 0
            let rootSize = CGSize(width: declaredWidth, height: declaredHeight)
            let desktopAlpha = bool(attribute("desktopalpha", root))
            if let background = attribute("background", root)?.lowercased() {
                layers.append(ModernSkinLayer(imageID: background, frame: .zero, isLayoutBackground: true))
            }
            for case let element as XMLElement in try root.nodes(forXPath: ".//*") {
                guard nearestStructuralRoot(of: element) === root else { continue }
                let tag = element.name?.lowercased() ?? ""
                // Wasabi drawer definitions commonly expose their target
                // position as a zero-sized layer. Treat that geometry as a
                // generic layout hint; object IDs are not runtime semantics.
                if drawerTargetX == nil, tag == "layer",
                   attribute("image", element) == nil,
                   (number(attribute("w", element)) ?? 0) <= 0,
                   (number(attribute("h", element)) ?? 0) <= 0,
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
                        label: attribute("tooltip", element),
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
                        regionShapes.append(ModernWindowRegionShape(frame: visualFrame, additive: sysRegion > 0, sysRegion: sysRegion))
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
                        orientation: orientation,
                        sysRegion: number(attribute("sysregion", element)).map(Int.init)
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
                        orientation: orientation,
                        sysRegion: number(attribute("sysregion", element)).map(Int.init)
                    ))
                }
                if let sysRegion = number(attribute("sysregion", element)).map(Int.init), sysRegion != 0,
                   !frame.isEmpty,
                   !["layer", "animatedlayer"].contains(tag) {
                    regionShapes.append(ModernWindowRegionShape(frame: frame, additive: sysRegion > 0, sysRegion: sysRegion))
                }
                if tag == "group" || element.name?.contains(":") == true {
                    let definitionID = attribute("id", element) ?? element.name ?? ""
                    guard !definitionID.isEmpty else { continue }
                    let rawInstanceID = attribute("instanceid", element) ?? attribute("id", element) ?? definitionID
                    groups.append(GroupReference(
                        definitionID: definitionID,
                        instanceID: rawInstanceID,
                        tag: element.name ?? tag,
                        origin: origin,
                        attributes: (element.attributes ?? []).reduce(into: [String: String]()) { result, attribute in
                            if let name = attribute.name, let value = attribute.stringValue { result[name.lowercased()] = value }
                        }
                    ))
                }
                if let role = textRole(tag: tag, element: element), frame.width > 0, frame.height > 0 {
                    let color = textColor(attribute("color", element))
                    textRegions.append(ModernSkinTextRegion(
                        role: role,
                        frame: frame,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible,
                        font: attribute("font", element)?.lowercased(),
                        fontSize: number(attribute("fontsize", element)).map(Double.init) ?? min(14, max(7, Double(frame.height))),
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                        alignment: attribute("align", element)?.lowercased() ?? "left",
                        sysRegion: number(attribute("sysregion", element)).map(Int.init)
                    ))
                }
                if let role = contentRole(tag: tag, element: element), frame.width > 0, frame.height > 0 {
                    contentRegions.append(ModernSkinContentRegion(
                        role: role,
                        frame: frame,
                        elementID: attribute("id", element),
                        initiallyVisible: initiallyVisible,
                        sysRegion: number(attribute("sysregion", element)).map(Int.init)
                    ))
                }
            }
            for case let script as XMLElement in try root.nodes(forXPath: ".//*[local-name()='script']") {
                guard nearestStructuralRoot(of: script) === root,
                      let file = attribute("file", script),
                      let path = resolve(path: file, relativeTo: xmlPath, files: files),
                      path.pathExtension.lowercased() == "maki" else { continue }
                scripts.append(ScriptReference(path: path, parameter: attribute("param", script)))
            }
            for case let sendparams as XMLElement in try root.nodes(forXPath: ".//*[local-name()='sendparams']") {
                guard nearestStructuralRoot(of: sendparams) === root,
                      let target = attribute("target", sendparams) else { continue }
                let attributes = (sendparams.attributes ?? []).reduce(into: [String: String]()) { result, attribute in
                    guard let name = attribute.name else { return }
                    let key = name.lowercased()
                    guard key != "group", key != "target", let value = attribute.stringValue else { return }
                    result[key] = value
                }
                sendParams.append(SendParam(
                    group: attribute("group", sendparams),
                    targetIDs: target.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                    attributes: attributes
                ))
            }
            for case let hideobject as XMLElement in try root.nodes(forXPath: ".//*[local-name()='hideobject']") {
                guard nearestStructuralRoot(of: hideobject) === root,
                      let target = attribute("target", hideobject) else { continue }
                let targetIDs = target.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
                if let group = attribute("group", hideobject)?.lowercased(), !group.isEmpty {
                    hiddenObjects.append(HideObject(group: group, targetIDs: targetIDs))
                } else {
                    for targetID in targetIDs {
                        let components = targetID.split(separator: ".", maxSplits: 1).map(String.init)
                        if components.count == 2 {
                            hiddenObjects.append(HideObject(group: components[0], targetIDs: [components[1]]))
                        } else {
                            hiddenIDs.insert(targetID)
                        }
                    }
                }
            }
            let contentBounds = layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let width = declaredWidth > 0 ? declaredWidth : max(1, contentBounds.maxX.isFinite ? contentBounds.maxX : 275)
            let height = declaredHeight > 0 ? declaredHeight : max(1, contentBounds.maxY.isFinite ? contentBounds.maxY : 116)
            let canvasSize = CGSize(width: width, height: height)
            if let sysRegion = number(attribute("sysregion", root)).map(Int.init), sysRegion != 0 {
                regionShapes.insert(
                    ModernWindowRegionShape(
                        frame: CGRect(origin: .zero, size: canvasSize),
                        additive: sysRegion > 0,
                        sysRegion: sysRegion
                    ),
                    at: 0
                )
            }
            // Retain every layout, including an intentionally sparse shade or
            // state layout. A layout is part of the live Container graph even
            // when all of its visible pixels come from runtime/component data.
            if isLayout || !layers.isEmpty || !controls.isEmpty || !groups.isEmpty || !textRegions.isEmpty || !contentRegions.isEmpty {
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
                    xuiTag: attribute("xuitag", root),
                    embedXUITarget: attribute("embed_xui", root),
                    containerID: container.flatMap { attribute("id", $0)?.lowercased() },
                    containerIsDefaultVisible: container.flatMap { attribute("default_visible", $0) }.map { $0 != "0" } ?? false,
                    drawerTargetX: drawerTargetX,
                    scripts: scripts,
                    sendParams: sendParams,
                    hiddenIDs: hiddenIDs,
                    hiddenObjects: hiddenObjects,
                    sysRegion: number(attribute("sysregion", root)).map(Int.init),
                    hasDeclaredWidth: declaredWidth > 0,
                    hasDeclaredHeight: declaredHeight > 0
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
            tree.insert(WasabiObjectNode(id: group.instanceID, kind: .group, frame: CGRect(origin: group.origin, size: .zero), parentID: candidate.id, zIndex: index + 2))
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

    /// Builds the authoritative #35 scene from the unflattened candidate
    /// definitions. The older arrays remain as a temporary compatibility
    /// projection for the renderer migration, but they are no longer used to
    /// decide parent ownership or world geometry.
    nonisolated private static func makeScene(
        candidates: [LayoutCandidate],
        activeCandidate: LayoutCandidate,
        xuiDefinitions: [String: LayoutCandidate],
        makiBindings: inout [ModernMakiBinding]
    ) -> WasabiScene {
        var scene = WasabiScene()
        let definitions = Dictionary(candidates.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let layouts = candidates.filter(\.isLayout)
        var containers: [String: WasabiHandle] = [:]

        for layout in layouts {
            let containerID = (layout.containerID ?? "main").lowercased()
            if containers[containerID] == nil {
                let visible = layout.containerIsDefaultVisible
                containers[containerID] = scene.addNode(
                    id: containerID,
                    kind: .container,
                    localFrame: CGRect(origin: .zero, size: layout.canvasSize),
                    visible: visible,
                    attributes: ["default_visible": visible ? "1" : "0"]
                )
            }
        }

        var layoutHandles: [(candidate: LayoutCandidate, handle: WasabiHandle, container: WasabiHandle)] = []
        for layout in layouts {
            let containerID = (layout.containerID ?? "main").lowercased()
            guard let container = containers[containerID] else { continue }
            let handle = scene.addNode(
                id: layout.id,
                kind: .layout,
                localFrame: CGRect(origin: .zero, size: layout.canvasSize),
                parent: container,
                visible: layout.containerIsDefaultVisible,
                attributes: [
                    "container": containerID,
                    "sysregion": layout.sysRegion.map(String.init) ?? ""
                ]
            )
            layoutHandles.append((layout, handle, container))
            if layout.id.caseInsensitiveCompare(activeCandidate.id) == .orderedSame {
                scene.setActiveLayout(handle, for: container)
            }
        }

        for item in layoutHandles {
            addDirectChildren(
                of: item.candidate,
                parent: item.handle,
                definitions: definitions,
                xuiDefinitions: xuiDefinitions,
                scene: &scene,
                visited: [],
                scopeID: nil,
                overrides: scopedOverrides(for: item.candidate.id, definition: item.candidate, enclosing: item.candidate.sendParams, inherited: [:]),
                hiddenIDs: item.candidate.hiddenIDs,
                hiddenObjects: item.candidate.hiddenObjects,
                makiBindings: &makiBindings
            )
        }

        for container in containers.values where scene.activeLayoutByContainer[container] == nil {
            if let first = layoutHandles.first(where: { $0.container == container }) {
                scene.setActiveLayout(first.handle, for: container)
            }
        }
        return scene
    }

    nonisolated private static func addDirectChildren(
        of candidate: LayoutCandidate,
        parent: WasabiHandle,
        definitions: [String: LayoutCandidate],
        xuiDefinitions: [String: LayoutCandidate],
        scene: inout WasabiScene,
        visited: Set<String>,
        scopeID: String?,
        overrides: [String: [String: String]],
        hiddenIDs: Set<String>,
        hiddenObjects: [HideObject],
        makiBindings: inout [ModernMakiBinding]
    ) {
        let candidateKey = candidate.id.lowercased()
        guard !visited.contains(candidateKey) else { return }
        var nextVisited = visited
        nextVisited.insert(candidateKey)
        var z = 0
        let controlIDs = Set(candidate.controls.compactMap { $0.elementID?.lowercased() })

        for (index, layer) in candidate.layers.enumerated() {
            let id = layer.elementID ?? "layer-\(index)"
            // A MAKI-only button/slider may also be collected as a visual
            // layer because it carries an image. Keep one live scene node for
            // that XML object; the control node owns its input and sprite.
            if controlIDs.contains(id.lowercased()) { continue }
            let nodeOverrides = overrides[id.lowercased()] ?? [:]
            let frame = frameByApplyingOverrides(layer.frame, nodeOverrides)
            let kind: WasabiObjectKind = layer.cropToFirstFrame ? .animatedLayer : .layer
            _ = scene.addNode(
                id: id,
                kind: kind,
                localFrame: frame,
                parent: parent,
                visible: layer.initiallyVisible && !hiddenIDs.contains(id.lowercased()) && bool(nodeOverrides["visible"] ?? "1"),
                alpha: CGFloat(nodeOverrides["alpha"].flatMap(Double.init).map { $0 > 1 ? $0 / 255 : $0 } ?? layer.opacity),
                ghost: false,
                zIndex: z,
                attributes: [
                    "image": nodeOverrides["image"] ?? layer.imageID,
                    "alpha": String(layer.opacity),
                    "sysregion": layer.sysRegion.map(String.init) ?? ""
                ].merging(nodeOverrides, uniquingKeysWith: { _, new in new })
            )
            z += 1
        }

        for (index, control) in candidate.controls.enumerated() {
            let id = control.elementID ?? "control-\(index)"
            let nodeOverrides = overrides[id.lowercased()] ?? [:]
            let kind: WasabiObjectKind = control.orientation == nil ? .button : .slider
            _ = scene.addNode(
                id: id,
                kind: kind,
                localFrame: frameByApplyingOverrides(control.frame, nodeOverrides),
                parent: parent,
                visible: control.initiallyVisible && !hiddenIDs.contains(id.lowercased()) && bool(nodeOverrides["visible"] ?? "1"),
                zIndex: z,
                attributes: [
                    "action": control.action.rawValue,
                    "orientation": control.orientation.map { $0 == .vertical ? "vertical" : "horizontal" } ?? "",
                    "sysregion": control.sysRegion.map(String.init) ?? ""
                ].merging(nodeOverrides, uniquingKeysWith: { _, new in new })
            )
            z += 1
        }

        for (index, region) in candidate.textRegions.enumerated() {
            let id = region.elementID ?? "text-\(index)"
            let nodeOverrides = overrides[id.lowercased()] ?? [:]
            _ = scene.addNode(
                id: id,
                kind: .text,
                localFrame: frameByApplyingOverrides(region.frame, nodeOverrides),
                parent: parent,
                visible: region.initiallyVisible && !hiddenIDs.contains(id.lowercased()) && bool(nodeOverrides["visible"] ?? "1"),
                zIndex: z,
                attributes: [
                    "role": textRoleName(region.role),
                    "font": region.font ?? "",
                    "fontSize": String(region.fontSize),
                    "red": String(region.red),
                    "green": String(region.green),
                    "blue": String(region.blue),
                    "align": region.alignment,
                    "sysregion": region.sysRegion.map(String.init) ?? ""
                ].merging(nodeOverrides, uniquingKeysWith: { _, new in new })
            )
            z += 1
        }

        for (index, region) in candidate.contentRegions.enumerated() {
            let id = region.elementID ?? "content-\(index)"
            let nodeOverrides = overrides[id.lowercased()] ?? [:]
            _ = scene.addNode(
                id: id,
                kind: .content,
                localFrame: frameByApplyingOverrides(region.frame, nodeOverrides),
                parent: parent,
                visible: region.initiallyVisible && !hiddenIDs.contains(id.lowercased()) && bool(nodeOverrides["visible"] ?? "1"),
                zIndex: z,
                attributes: [
                    "role": contentRoleName(region.role),
                    "sysregion": region.sysRegion.map(String.init) ?? ""
                ].merging(nodeOverrides, uniquingKeysWith: { _, new in new })
            )
            z += 1
        }

        for reference in candidate.groups {
            guard let definition = resolveDefinition(reference, definitions: definitions, xuiDefinitions: xuiDefinitions) else { continue }
            let instanceID = reference.instanceID.isEmpty ? "\(definition.id)-instance-\(z)" : reference.instanceID
            let instanceOverrides = scopedOverrides(
                for: instanceID,
                definition: definition,
                enclosing: candidate.sendParams,
                inherited: overrides
            )
            let instanceHiddenIDs = hiddenIDs.union(definition.hiddenIDs)
                .union(hiddenTargets(in: hiddenObjects, group: instanceID))
            let groupFrame = CGRect(
                origin: reference.origin,
                size: CGSize(
                    width: CGFloat(Double(reference.attributes["w"] ?? "") ?? Double(definition.canvasSize.width)),
                    height: CGFloat(Double(reference.attributes["h"] ?? "") ?? Double(definition.canvasSize.height))
                )
            )
            var groupAttributes = ["definition": definition.id, "tag": reference.tag]
            if let sysRegion = reference.attributes["sysregion"] ?? definition.sysRegion.map(String.init) {
                groupAttributes["sysregion"] = sysRegion
            }
            if let embedXUITarget = definition.embedXUITarget?.trimmingCharacters(in: .whitespacesAndNewlines),
               !embedXUITarget.isEmpty {
                groupAttributes["embed_xui"] = embedXUITarget
            }
            let group = scene.addNode(
                id: instanceID,
                kind: .group,
                localFrame: groupFrame,
                parent: parent,
                visible: !hiddenIDs.contains(instanceID.lowercased()) && bool(reference.attributes["visible"] ?? "1"),
                zIndex: z,
                attributes: groupAttributes.merging(reference.attributes, uniquingKeysWith: { _, new in new })
            )
            z += 1
            addDefinitionChildren(
                definition,
                parent: group,
                definitions: definitions,
                xuiDefinitions: xuiDefinitions,
                scene: &scene,
                visited: nextVisited,
                scopeID: instanceID,
                overrides: instanceOverrides,
                hiddenIDs: instanceHiddenIDs,
                hiddenObjects: definition.hiddenObjects,
                makiBindings: &makiBindings
            )
        }
    }

    nonisolated private static func addDefinitionChildren(
        _ definition: LayoutCandidate,
        parent: WasabiHandle,
        definitions: [String: LayoutCandidate],
        xuiDefinitions: [String: LayoutCandidate],
        scene: inout WasabiScene,
        visited: Set<String>,
        scopeID: String?,
        overrides: [String: [String: String]],
        hiddenIDs: Set<String>,
        hiddenObjects: [HideObject],
        makiBindings: inout [ModernMakiBinding]
    ) {
        if let scopeID {
            for script in definition.scripts {
                let binding = ModernMakiBinding(path: script.path, groupID: scopeID, parameter: script.parameter)
                if !makiBindings.contains(binding) { makiBindings.append(binding) }
            }
        }
        if let inheritedID = definition.inheritedGroupID?.lowercased(), let inherited = definitions[inheritedID] {
            addDefinitionChildren(inherited, parent: parent, definitions: definitions, xuiDefinitions: xuiDefinitions, scene: &scene, visited: visited, scopeID: scopeID, overrides: overrides, hiddenIDs: hiddenIDs, hiddenObjects: inherited.hiddenObjects, makiBindings: &makiBindings)
        }
        addDirectChildren(of: definition, parent: parent, definitions: definitions, xuiDefinitions: xuiDefinitions, scene: &scene, visited: visited, scopeID: scopeID, overrides: overrides, hiddenIDs: hiddenIDs, hiddenObjects: hiddenObjects, makiBindings: &makiBindings)
    }

    nonisolated private static func resolveDefinition(
        _ reference: GroupReference,
        definitions: [String: LayoutCandidate],
        xuiDefinitions: [String: LayoutCandidate]
    ) -> LayoutCandidate? {
        if reference.tag.lowercased() == "group" {
            return definitions[reference.definitionID.lowercased()]
        }
        return xuiDefinitions[normalizeXUITag(reference.tag)]
            ?? definitions[reference.definitionID.lowercased()]
    }

    nonisolated private static func hiddenTargets(in values: [HideObject], group: String) -> Set<String> {
        values.filter { $0.group == nil || $0.group == group.lowercased() }
            .flatMap(\.targetIDs)
            .reduce(into: Set<String>()) { $0.insert($1.lowercased()) }
    }

    nonisolated private static func normalizeXUITag(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ":", with: "_")
    }

    nonisolated private static func scopedOverrides(
        for scopeID: String,
        definition: LayoutCandidate,
        enclosing: [SendParam],
        inherited: [String: [String: String]]
    ) -> [String: [String: String]] {
        var result = inherited
        let scopeKeys = Set([scopeID.lowercased(), definition.id.lowercased()])
        for sendParam in enclosing + definition.sendParams {
            let group = sendParam.group?.lowercased()
            guard group == nil || scopeKeys.contains(group ?? "") else { continue }
            for targetID in sendParam.targetIDs {
                result[targetID.lowercased(), default: [:]].merge(sendParam.attributes, uniquingKeysWith: { _, new in new })
            }
        }
        return result
    }

    nonisolated private static func frameByApplyingOverrides(_ frame: CGRect, _ overrides: [String: String]) -> CGRect {
        var result = frame
        if let value = Double(overrides["x"] ?? "") { result.origin.x = CGFloat(value) }
        if let value = Double(overrides["y"] ?? "") { result.origin.y = CGFloat(value) }
        if let value = Double(overrides["w"] ?? "") { result.size.width = max(0, CGFloat(value)) }
        if let value = Double(overrides["h"] ?? "") { result.size.height = max(0, CGFloat(value)) }
        return result
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

    nonisolated private static func expand(
        _ candidate: LayoutCandidate,
        definitions: [String: LayoutCandidate],
        xuiDefinitions: [String: LayoutCandidate],
        visited: Set<String>
    ) -> LayoutCandidate {
        let key = candidate.id.lowercased()
        guard !visited.contains(key) else { return candidate }
        var result = candidate
        var nextVisited = visited; nextVisited.insert(key)
        if let inheritedID = candidate.inheritedGroupID?.lowercased(),
           let inherited = definitions[inheritedID], !nextVisited.contains(inheritedID) {
            let parent = expand(inherited, definitions: definitions, xuiDefinitions: xuiDefinitions, visited: nextVisited)
            result.layers.insert(contentsOf: parent.layers, at: 0)
            result.controls.insert(contentsOf: parent.controls, at: 0)
            result.textRegions.insert(contentsOf: parent.textRegions, at: 0)
            result.contentRegions.insert(contentsOf: parent.contentRegions, at: 0)
            result.drawers.insert(contentsOf: parent.drawers, at: 0)
            result.regionShapes.insert(contentsOf: parent.regionShapes, at: 0)
            result.desktopAlpha = result.desktopAlpha || parent.desktopAlpha
            if result.sysRegion == nil { result.sysRegion = parent.sysRegion }
        }
        for reference in candidate.groups {
            let referenceID = reference.definitionID.lowercased()
            if referenceID.contains("modeequalizer") || referenceID.contains("modeconfigure") || referenceID.contains("transition") { continue }
            guard let definition = resolveDefinition(reference, definitions: definitions, xuiDefinitions: xuiDefinitions) else { continue }
            let child = expand(definition, definitions: definitions, xuiDefinitions: xuiDefinitions, visited: nextVisited)
            let origin = expandedOrigin(for: reference, child: child, canvasSize: candidate.canvasSize)
            // Infer edge-drawer semantics from the definition's requested
            // target geometry, never from a skin author's identifier. A
            // group whose target reaches the left/right canvas edge is an
            // edge drawer regardless of its name or XUI tag.
            let drawerRole = drawerRole(for: child, canvasSize: candidate.canvasSize)
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
                    orientation: control.orientation,
                    sysRegion: control.sysRegion
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

    nonisolated private static func normalizeBitmapGeometry(
        _ candidate: LayoutCandidate,
        descriptor: ModernSkinDescriptor,
        files: [String: Data]
    ) -> LayoutCandidate {
        var result = candidate
        let imageSizes = Dictionary(uniqueKeysWithValues: descriptor.bitmapFiles.compactMap { id, path in
            imagePixelSize(files[path]).map { (id, $0) }
        })
        result.layers = candidate.layers.map { layer in
            var layer = layer
            if layer.isLayoutBackground {
                layer.frame = CGRect(origin: .zero, size: candidate.canvasSize)
            } else if let size = imageSizes[layer.imageID.lowercased()] {
                if layer.frame.width <= 0 { layer.frame.size.width = descriptor.bitmapSourceRects[layer.imageID.lowercased()]?.width ?? size.width }
                if layer.frame.height <= 0 { layer.frame.size.height = descriptor.bitmapSourceRects[layer.imageID.lowercased()]?.height ?? size.height }
            }
            return layer
        }
        let layerBounds = result.layers.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if layerBounds.maxX.isFinite, layerBounds.maxY.isFinite {
            result.canvasSize = CGSize(
                width: candidate.hasDeclaredWidth ? candidate.canvasSize.width : max(candidate.canvasSize.width, layerBounds.maxX),
                height: candidate.hasDeclaredHeight ? candidate.canvasSize.height : max(candidate.canvasSize.height, layerBounds.maxY)
            )
        }
        // Region shapes are also produced for controls/text/content. Keep
        // their parsed geometry, but replace zero-sized layer contributions
        // with the repaired live bitmap frames.
        result.regionShapes.removeAll { $0.frame.isEmpty }
        result.regionShapes.append(contentsOf: result.layers.compactMap { layer in
            guard let value = layer.sysRegion, value != 0, !layer.frame.isEmpty else { return nil }
            guard !result.regionShapes.contains(where: { $0.frame == layer.frame && $0.additive == (value > 0) && $0.sysRegion == value }) else { return nil }
            return ModernWindowRegionShape(frame: layer.frame, additive: value > 0, sysRegion: value)
        })
        if let value = result.sysRegion, value != 0,
           let first = result.regionShapes.firstIndex(where: { $0.frame.origin == .zero }) {
            result.regionShapes[first].frame = CGRect(origin: .zero, size: result.canvasSize)
            result.regionShapes[first].sysRegion = value
        }
        result.controls = candidate.controls.map { control in
            var frame = control.frame
            if let imageID = control.normalSprite?.assetName,
               let size = imageSizes[imageID.lowercased()] {
                if frame.width <= 0 { frame.size.width = descriptor.bitmapSourceRects[imageID.lowercased()]?.width ?? size.width }
                if frame.height <= 0 { frame.size.height = descriptor.bitmapSourceRects[imageID.lowercased()]?.height ?? size.height }
            }
            return SkinControlDefinition(
                id: control.id,
                frame: frame,
                normalSprite: control.normalSprite,
                pressedSprite: control.pressedSprite,
                disabledSprite: control.disabledSprite,
                action: control.action,
                elementID: control.elementID,
                initiallyVisible: control.initiallyVisible,
                drawerRole: control.drawerRole,
                parameter: control.parameter,
                orientation: control.orientation,
                sysRegion: control.sysRegion
            )
        }
        return result
    }

    nonisolated private static func imagePixelSize(_ data: Data?) -> CGSize? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func expandedOrigin(
        for reference: GroupReference,
        child: LayoutCandidate,
        canvasSize: CGSize
    ) -> CGPoint {
        var origin = reference.origin
        if let targetX = child.drawerTargetX {
            origin.x = targetX
        }
        return origin
    }

    nonisolated private static func drawerRole(for child: LayoutCandidate, canvasSize: CGSize) -> ModernDrawerRole? {
        guard let targetX = child.drawerTargetX, canvasSize.width > 0, child.canvasSize.width > 0 else { return nil }
        if targetX <= 0 { return .left }
        if targetX + child.canvasSize.width >= canvasSize.width - 1 { return .right }
        return nil
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

    nonisolated private static func textRoleName(_ role: ModernSkinTextRole) -> String {
        switch role {
        case .songTitle: "songTitle"
        case .elapsedTime: "elapsedTime"
        case .remainingTime: "remainingTime"
        case .bitrate: "bitrate"
        case .frequency: "frequency"
        case .channels: "channels"
        case .fileExtension: "fileExtension"
        }
    }

    nonisolated private static func contentRoleName(_ role: ModernSkinContentRole) -> String {
        switch role {
        case .albumArt: "albumArt"
        case .visualization: "visualization"
        case .playlist: "playlist"
        }
    }

    nonisolated private static func mapAction(
        _ rawAction: String?,
        id rawID: String?,
        parameter: String?,
        label: String?,
        tag: String
    ) -> (id: SkinControlID, action: SkinAction)? {
        // Runtime behavior comes from declared action/parameter/tooltip
        // semantics. XML IDs remain diagnostic identity, not a behavior
        // switch, so a skin can freely rename its controls.
        let value = "\(rawAction ?? "") \(parameter ?? "") \(label ?? "")".lowercased()
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
        if value.contains("playlist") || value.contains("guid:pl") {
            return (.playlist, .togglePlaylist)
        }
        if value.contains("equalizer") || value.contains("eq_toggle") {
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
