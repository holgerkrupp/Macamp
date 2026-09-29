import AppKit
import Foundation
import Testing
@testable import Macamp

@Suite
struct SkinTests {
    @Test func uppercaseAssetsAreCaseInsensitive() async throws {
        let url = try temporarySkin(entries: [("MAIN.BMP", Data([1, 2, 3]))])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(loaded.files["main.bmp"] != nil)
        #expect(loaded.report.errors.isEmpty)
        #expect(loaded.format == .classic)
    }

    @Test func classicZipIsDetectedByContents() async throws {
        let url = try temporarySkin(entries: [("nested/MAIN.BMP", Data([1]))], extension: "zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(loaded.format == .classic)
        #expect(loaded.files["nested/main.bmp"] != nil)
    }

    @Test @MainActor func walParsesSafeLayoutAndControls() async throws {
        let xml = """
        <?xml version="1.0"?>
        <WinampAbstractionLayer version="1.0">
          <skininfo><name>Synthetic Modern</name><author>Macamp Tests</author></skininfo>
          <elements>
            <bitmap id="background" file="images/background.png" />
            <bitmap id="play.button" file="images/play.png" />
          </elements>
          <container id="main">
            <layout id="player.normal" w="320" h="140">
              <layer image="background" x="0" y="0" w="320" h="140" />
              <button id="play" action="PLAY" image="play.button" x="18" y="94" w="24" h="20" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let url = try temporarySkin(entries: [
            ("skin.xml", Data(xml.utf8)), ("images/background.png", png), ("images/play.png", png),
            ("scripts/player.maki", Data([0, 1, 2]))
        ], extension: "wal")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(loaded.format == .modern)
        #expect(loaded.modern?.name == "Synthetic Modern")
        #expect(loaded.modern?.canvasSize == CGSize(width: 320, height: 140))
        #expect(loaded.modern?.controls.contains { $0.action == .play } == true)
        #expect(loaded.files["scripts/player.maki"] == nil)
        #expect(loaded.report.warnings.contains { $0.contains("MAKI") })
        let catalog = SkinAssetCatalog(name: "Synthetic Modern", files: loaded.files, report: loaded.report, format: loaded.format, modern: loaded.modern)
        #expect(catalog.mainImage != nil)
        #expect(catalog.controls.contains { $0.action == .play })
    }

    @Test func modernZipIsDetectedByManifest() async throws {
        let xml = "<WinampAbstractionLayer><skininfo><screenshot>preview.png</screenshot></skininfo></WinampAbstractionLayer>"
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let url = try temporarySkin(entries: [("skin.xml", Data(xml.utf8)), ("preview.png", png)], extension: "zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(loaded.format == .modern)
        #expect(loaded.report.isValid)
    }

    @Test @MainActor func importedSkinsAndActiveSelectionRestoreAcrossLaunches() async throws {
        let source = try temporarySkin(entries: [("main.bmp", Data([1]))])
        let temporaryRoot = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let libraryRoot = temporaryRoot.appending(path: "Application Support Skins", directoryHint: .isDirectory)
        let defaultsName = "Macamp.SkinTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let firstLaunch = SkinLibraryStore(defaults: defaults, root: libraryRoot)
        await firstLaunch.importSkin(from: source)
        let imported = try #require(firstLaunch.skins.first)
        #expect(firstLaunch.activeSkinID == imported.id)

        let secondLaunch = SkinLibraryStore(defaults: defaults, root: libraryRoot)
        await secondLaunch.restoreLibrary()
        #expect(secondLaunch.skins.count == 1)
        #expect(secondLaunch.activeSkinID == imported.id)
        #expect(secondLaunch.activeCatalog.name == imported.name)

        secondLaunch.useFallback()
        let thirdLaunch = SkinLibraryStore(defaults: defaults, root: libraryRoot)
        await thirdLaunch.restoreLibrary()
        #expect(thirdLaunch.skins.count == 1)
        #expect(thirdLaunch.activeSkinID == nil)
    }

    @Test func makiDecoderValidatesTablesAndInstructions() throws {
        var data = Data([0x46, 0x47, 0x03, 0x04, 0x17, 0, 0, 0])
        appendLE(UInt32(0), to: &data) // classes
        appendLE(UInt32(1), to: &data) // functions
        appendLE(UInt32(0x101), to: &data)
        appendString("onScriptLoaded", to: &data)
        appendLE(UInt32(1), to: &data) // variables
        appendLE(UInt32(0x101), to: &data)
        appendLE(UInt64(0), to: &data)
        data.append(contentsOf: [1, 1])
        appendLE(UInt32(0), to: &data) // strings
        appendLE(UInt32(1), to: &data) // events
        appendLE(UInt32(0), to: &data)
        appendLE(UInt32(0), to: &data)
        appendLE(UInt32(0), to: &data)
        appendLE(UInt32(1), to: &data) // code size
        data.append(0x21)

        let program = try MakiDecoder.decode(data, path: "scripts/test.maki")

        #expect(program.version == 0x17)
        #expect(program.functions.first?.name == "onScriptLoaded")
        #expect(program.events.first?.codeOffset == 0)
    }

    @Test @MainActor func bundledHeadAMPMAKIProgramsValidateWhenFixtureIsAvailable() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = projectRoot.appending(path: "Skins/HeadAMP.wal")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let loaded = try await SkinArchiveLoader().load(url: url)
        let descriptor = try #require(loaded.modern)

        #expect(descriptor.makiBindings.count == 5)
        #expect(descriptor.drawers.first { $0.role == .left }?.expandedFrame.minX == 0)
        #expect(descriptor.drawers.first { $0.role == .left }?.collapsedOrigin.x == 207)
        #expect(descriptor.drawers.first { $0.role == .right }?.expandedFrame.minX == 488)
        #expect(descriptor.drawers.first { $0.role == .right }?.collapsedOrigin.x == 277)
        #expect(descriptor.controls.filter { $0.action == .setEqualizerBand }.count == 30)
        #expect(descriptor.controls.filter { $0.action == .setEqualizerBand && $0.orientation == .vertical }.count == 10)
        #expect(descriptor.controls.filter { $0.elementID?.localizedCaseInsensitiveContains("top") == true || $0.elementID?.localizedCaseInsensitiveContains("bottom") == true }.count >= 20)
        #expect(descriptor.controls.filter { $0.action == .setEqualizerBand }.allSatisfy { $0.parameter != nil })
        #expect(descriptor.contentRegions.contains { $0.role == .visualization && $0.frame == CGRect(x: 283, y: 63, width: 191, height: 138) })
        #expect(descriptor.contentRegions.contains { $0.elementID?.caseInsensitiveCompare("InlineAVS") == .orderedSame && $0.frame == CGRect(x: 283, y: 71, width: 191, height: 132) })
        #expect(loaded.files.keys.filter { ($0 as NSString).pathExtension.lowercased() == "maki" }.count == 4)
        #expect(!loaded.report.warnings.contains { $0.contains("Rejected scripts/") })
        let catalog = SkinAssetCatalog(name: "HeadAMP", files: loaded.files, report: loaded.report, format: loaded.format, modern: loaded.modern)
        #expect(catalog.modernOcclusionFrame == CGRect(x: 260, y: 0, width: 234, height: 394))
        let host = TestMakiHost()
        let runtime = MakiRuntime(programs: catalog.makiPrograms, bindings: catalog.makiBindings, host: host)
        runtime.start()
        #expect(!runtime.diagnostics.contains { $0.contains("Disabled") })
        #expect(runtime.dispatchClick(objectID: "eqToggle"))
        #expect(host.targets.last?.objectID == "leftdrawer")
        #expect(host.targets.last?.x == 0)
        #expect(runtime.dispatchClick(objectID: "eqToggle"))
        #expect(host.targets.last?.objectID == "leftdrawer")
        #expect(host.targets.last?.x == 207)
        #expect(runtime.dispatchClick(objectID: "plToggle"))
        #expect(host.targets.last?.objectID == "rightdrawer")
        #expect(host.targets.last?.x == 488)
        #expect(runtime.dispatchClick(objectID: "plToggle"))
        #expect(host.targets.last?.objectID == "rightdrawer")
        #expect(host.targets.last?.x == 277)
        #expect(!runtime.diagnostics.contains { $0.contains("Disabled") })
    }

    @Test func bundledCellLayoutAndMetadataWhenFixtureIsAvailable() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = projectRoot.appending(path: "Skins/CELL V3.wal")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let loaded = try await SkinArchiveLoader().load(url: url)
        let descriptor = try #require(loaded.modern)
        #expect(descriptor.canvasSize == CGSize(width: 810, height: 448))
        #expect(descriptor.layers.contains { $0.elementID?.caseInsensitiveCompare("playerbody") == .orderedSame })
        #expect(descriptor.textRegions.contains { $0.role == .bitrate })
        #expect(descriptor.textRegions.contains { $0.role == .frequency })
        #expect(!descriptor.makiBindings.isEmpty)
        #expect(descriptor.bitmapFiles["big.background"] == "gfx/big.png")
        let catalog = SkinAssetCatalog(name: "CELL", files: loaded.files, report: loaded.report, format: loaded.format, modern: descriptor)
        #expect(catalog.images["gfx/big.png"] != nil)
        #expect(catalog.images["gfx/big.png"]?.size == CGSize(width: 479, height: 451))
        #expect(catalog.mainImage?.size == CGSize(width: 810, height: 448))
        #expect(!catalog.makiPrograms.isEmpty)
        let rendered = try #require(catalog.mainImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        #expect(rendered.colorAt(x: 100, y: 100)?.alphaComponent ?? 0 > 0)
    }

    @Test func modernParserSelectsMainLayoutAndExpandsStaticSemantics() throws {
        let xml = """
        <WinampAbstractionLayer>
          <elements>
            <bitmap id="left" file="left.png" />
            <bitmap id="right" file="right.png" />
            <bitmap id="body" file="body.png" />
            <bitmap id="frames" file="frames.png" />
          </elements>
          <container id="auxiliary" default_visible="0">
            <layout id="normal" w="1200" h="900"><layer image="body" /></layout>
          </container>
          <container id="main" default_visible="1">
            <groupdef id="LeftDrawer" w="266" h="169">
              <layer id="left-bg" image="left" />
              <component param="guid:pl" x="12" y="10" w="172" h="140" />
            </groupdef>
            <groupdef id="RightDrawer" w="271" h="170"><layer id="right-bg" image="right" /></groupdef>
            <groupdef id="Player" w="348" h="394">
              <layer id="body-bg" image="body" />
              <animatedlayer id="meter" image="frames" x="80" y="60" w="190" h="130" />
              <layer id="hidden" image="body" alpha="0" />
              <vis x="77" y="63" w="191" h="138" />
              <text id="song" display="songname" x="90" y="210" w="170" h="18" color="255,255,255" />
            </groupdef>
            <layout id="normal" w="760" h="394">
              <group id="LeftDrawer" x="207" y="86" />
              <group id="RightDrawer" x="277" y="86" />
              <group id="Player" x="206" y="0" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let files: [String: Data] = [
            "skin.xml": Data(xml.utf8), "left.png": Data([1]), "right.png": Data([1]),
            "body.png": Data([1]), "frames.png": Data([1])
        ]

        let descriptor = ModernSkinParser.parse(files: files).descriptor

        #expect(descriptor.canvasSize == CGSize(width: 760, height: 394))
        #expect(descriptor.layers.first { $0.elementID == "left-bg" }?.frame.minX == 0)
        #expect(descriptor.layers.first { $0.elementID == "left-bg" }?.drawerRole == .left)
        #expect(descriptor.layers.first { $0.elementID == "right-bg" }?.frame.minX == 489)
        #expect(descriptor.layers.first { $0.elementID == "right-bg" }?.drawerRole == .right)
        #expect(descriptor.layers.first { $0.elementID == "body-bg" }?.frame.minX == 206)
        #expect(descriptor.layers.first { $0.elementID == "meter" }?.cropToFirstFrame == true)
        #expect(descriptor.layers.first { $0.elementID == "hidden" }?.initiallyVisible == false)
        #expect(descriptor.textRegions.count == 1)
        #expect(descriptor.contentRegions.count == 2)
        #expect(descriptor.contentRegions.first { $0.role == .playlist }?.drawerRole == .left)
        #expect(descriptor.drawers.first { $0.role == .left }?.collapsedOrigin.x == 207)
        #expect(descriptor.drawers.first { $0.role == .right }?.collapsedOrigin.x == 277)
    }

    @Test func modernParserMapsPlaylistAndEqualizerControls() throws {
        let xml = """
        <WinampAbstractionLayer>
          <elements><bitmap id="button" file="button.png" w="12" h="12" /></elements>
          <container id="main" default_visible="1">
            <layout id="normal" w="100" h="40">
              <button id="plToggle" image="button" x="2" y="2" />
              <button id="EqShowHide" image="button" x="18" y="2" />
              <button id="playlist-by-param" action="TOGGLE" param="guid:pl" image="button" x="34" y="2" />
              <button id="LeftDrawerClose" image="button" x="50" y="2" />
              <button id="RightDrawerOpen" image="button" x="66" y="2" />
              <button id="playerminimize" action="MINIMIZE" image="button" x="2" y="20" />
              <button id="playerclose" action="CLOSE" image="button" x="18" y="20" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """

        let descriptor = ModernSkinParser.parse(files: [
            "skin.xml": Data(xml.utf8),
            "button.png": Data([1])
        ]).descriptor

        #expect(descriptor.controls.filter { $0.action == .togglePlaylist }.count == 3)
        #expect(descriptor.controls.filter { $0.action == .toggleEqualizer }.count == 2)
        #expect(descriptor.controls.filter { $0.action == .minimize }.count == 1)
        #expect(descriptor.controls.filter { $0.action == .close }.count == 1)
        #expect(descriptor.controls.filter { $0.action == .play }.isEmpty)
    }

    @Test @MainActor func modernParserRetainsWasabiObjectsAndMakiOnlyButtons() {
        let xml = """
        <WinampAbstractionLayer>
          <container id="main" default_visible="1">
            <layout id="normal" w="120" h="60">
              <layer id="mouseTrap" image="pixel" x="0" y="0" w="120" h="60" />
              <button id="makiOnly" image="pixel" x="20" y="10" w="24" h="18" />
              <slider id="scriptSlider" thumb="pixel" x="50" y="10" w="40" h="18" orientation="horizontal" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8), "pixel.png": Data([1])]).descriptor
        #expect(descriptor.objectTree.object(id: "main")?.kind == .container)
        #expect(descriptor.objectTree.object(id: "makionly")?.kind == .button)
        #expect(descriptor.objectTree.object(id: "mousetrap")?.frame == CGRect(x: 0, y: 0, width: 120, height: 60))
        #expect(descriptor.controls.contains { $0.elementID == "makiOnly" && $0.action == .scripted })
        #expect(descriptor.controls.contains { $0.elementID == "scriptSlider" && $0.orientation == .horizontal })
    }

    @Test func wasabiSceneKeepsLocalFramesWhenAGroupMoves() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: CGRect(x: 0, y: 0, width: 240, height: 120), parent: container)
        scene.setActiveLayout(layout, for: container)
        let group = scene.addNode(id: "controls", kind: .group, localFrame: CGRect(x: 20, y: 12, width: 100, height: 60), parent: layout)
        let button = scene.addNode(id: "button", kind: .button, localFrame: CGRect(x: 8, y: 6, width: 24, height: 18), parent: group)

        let localBefore = try #require(scene.node(button)?.localFrame)
        #expect(scene.worldFrame(of: button) == CGRect(x: 28, y: 18, width: 24, height: 18))
        #expect(scene.hitTest(CGPoint(x: 30, y: 20))?.handle == button)

        scene.setLocalFrame(CGRect(x: 80, y: 30, width: 100, height: 60), for: group)
        #expect(scene.node(button)?.localFrame == localBefore)
        #expect(scene.worldFrame(of: button) == CGRect(x: 88, y: 36, width: 24, height: 18))
        #expect(scene.hitTest(CGPoint(x: 90, y: 38))?.handle == button)
        #expect(scene.hitTest(CGPoint(x: 30, y: 20)) == nil)

        scene.setVisible(false, for: group)
        #expect(scene.effectiveVisible(button) == false)
        #expect(scene.hitTest(CGPoint(x: 90, y: 38)) == nil)
    }

    @Test func modernParserRetainsMultipleLayoutsAndNestedOwnership() throws {
        let xml = """
        <WinampAbstractionLayer>
          <container id="main" default_visible="1">
            <groupdef id="buttons" w="80" h="30">
              <button id="ok" x="4" y="5" w="20" h="10" />
            </groupdef>
            <layout id="normal" w="200" h="100">
              <group id="buttons" x="30" y="20" />
            </layout>
            <layout id="shade" w="200" h="14">
              <layer id="shadeLayer" x="0" y="0" w="200" h="14" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8)]).descriptor
        #expect(descriptor.layouts.map(\.id).sorted() == ["normal", "shade"])

        let scene = descriptor.scene
        let normal = try #require(scene.firstHandle(for: "normal"))
        let group = try #require(scene.handles(for: "buttons").first { scene.node($0)?.parent == normal })
        let button = try #require(scene.handles(for: "ok").first { scene.node($0)?.parent == group })
        #expect(scene.node(button)?.localFrame == CGRect(x: 4, y: 5, width: 20, height: 10))
        #expect(scene.worldFrame(of: button) == CGRect(x: 34, y: 25, width: 20, height: 10))
        #expect(scene.firstHandle(for: "shade") != nil)
    }

    @Test @MainActor func makiRegistryReturnsLiveHandlesAndNavigatesTheScene() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: .zero, parent: container)
        let first = scene.addNode(id: "duplicate", kind: .button, localFrame: CGRect(x: 4, y: 4, width: 20, height: 16), parent: layout)
        let second = scene.addNode(id: "duplicate", kind: .button, localFrame: CGRect(x: 30, y: 4, width: 20, height: 16), parent: layout)
        scene.setActiveLayout(layout, for: container)

        let host = TestMakiHost()
        let runtime = MakiRuntime(programs: [], bindings: [], host: host, limits: .init(), skinID: "handles", persistentState: .standard, scene: scene)

        #expect(runtime.registry.handle(forXMLID: "duplicate") == first)
        #expect(runtime.registry.handle(forXMLID: "duplicate") != second)
        #expect(runtime.registry.object(first)?.className == "Button")

        let found = runtime.invoke(receiver: layout, method: "findObject", arguments: [.string("duplicate")])
        #expect(found == .object(first))
        #expect(runtime.invoke(receiver: layout, method: "findObject", arguments: [.string("missing"])) == .void)
        #expect(runtime.invoke(receiver: runtime.registry.systemHandle, method: "getContainer", arguments: [.string("main")]) == .object(container))
        #expect(runtime.invoke(receiver: container, method: "getLayout", arguments: [.string("normal")]) == .object(layout))
        #expect(runtime.invoke(receiver: layout, method: "getContainer", arguments: []) == .object(container))
    }

    @Test @MainActor func makiDispatchResolvesCollidingMethodsByReceiverClass() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: .zero)
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: .zero, parent: container)
        let slider = scene.addNode(id: "slider", kind: .slider, localFrame: CGRect(x: 0, y: 0, width: 80, height: 16), parent: layout)
        scene.setActiveLayout(layout, for: container)

        let host = TestMakiHost()
        let runtime = MakiRuntime(programs: [], bindings: [], host: host, limits: .init(), skinID: "dispatch", persistentState: .standard, scene: scene)
        _ = runtime.dispatchSliderPosition(objectID: "slider", value: 42)

        #expect(runtime.invoke(receiver: slider, method: "getPosition", arguments: []) == .number(42))
        #expect(runtime.invoke(receiver: runtime.registry.systemHandle, method: "getPosition", arguments: []) == .number(0))
        #expect(runtime.invoke(receiver: slider, method: "getPosition", arguments: [.integer(1)]) == .integer(0))
        #expect(runtime.diagnostics.contains { $0.contains("Invalid arity for Slider.getPosition") })
    }

    @Test func syntheticSceneValidationTraceDetectsHierarchyAndLayoutChanges() throws {
        let xml = """
        <WinampAbstractionLayer>
          <container id="main" default_visible="1">
            <groupdef id="controls" w="40" h="24">
              <button id="play" x="4" y="3" w="16" h="12" />
            </groupdef>
            <layout id="normal" w="120" h="48">
              <group id="controls" x="12" y="8" />
            </layout>
            <layout id="shade" w="120" h="14">
              <layer id="shade-background" x="0" y="0" w="120" h="14" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        var scene = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8)]).descriptor.scene
        let container = try #require(scene.firstHandle(for: "main"))
        let normal = try #require(scene.firstHandle(for: "normal"))
        let shade = try #require(scene.firstHandle(for: "shade"))
        let group = try #require(scene.handles(for: "controls").first { scene.node($0)?.parent == normal })
        let button = try #require(scene.firstHandle(for: "play"))

        var trace = SkinBehaviorTrace()
        trace.append(.init(phase: "normal", stateHash: scene.validationStateHash(), hitID: scene.hitTest(CGPoint(x: 18, y: 12))?.id))

        scene.setLocalFrame(CGRect(x: 70, y: 20, width: 40, height: 24), for: group)
        trace.append(.init(phase: "group-moved", stateHash: scene.validationStateHash(), hitID: scene.hitTest(CGPoint(x: 76, y: 25))?.id))

        scene.setActiveLayout(shade, for: container)
        trace.append(.init(phase: "shade-active", stateHash: scene.validationStateHash(), hitID: scene.hitTest(CGPoint(x: 2, y: 2))?.id))

        #expect(trace.events.map(\.phase) == ["normal", "group-moved", "shade-active"])
        #expect(trace.events[0].hitID == "play")
        #expect(trace.events[1].hitID == "play")
        #expect(trace.events[0].stateHash != trace.events[1].stateHash)
        #expect(trace.events[2].hitID == "shade-background")
        #expect(scene.worldFrame(of: button) == CGRect(x: 74, y: 23, width: 16, height: 12))
        #expect(scene.hitTest(CGPoint(x: 76, y: 25))?.id == "shade-background" || scene.hitTest(CGPoint(x: 76, y: 25)) == nil)
    }

    @Test @MainActor func syntheticDiagnosticFixturesProduceDifferentialPixelHashes() throws {
        let modernA = SkinDiagnosticFixtures.modernFiles(accent: .systemBlue)
        let modernB = SkinDiagnosticFixtures.modernFiles(accent: .systemOrange)
        let modernCatalogA = SkinAssetCatalog(
            name: "Synthetic Modern Diagnostic A",
            files: modernA,
            report: .init(),
            format: .modern,
            modern: ModernSkinParser.parse(files: modernA).descriptor
        )
        let modernCatalogB = SkinAssetCatalog(
            name: "Synthetic Modern Diagnostic B",
            files: modernB,
            report: .init(),
            format: .modern,
            modern: ModernSkinParser.parse(files: modernB).descriptor
        )

        let modernHashA = try #require(modernCatalogA.mainImage).validationPixelHash()
        let modernHashB = try #require(modernCatalogB.mainImage).validationPixelHash()
        #expect(modernHashA != modernHashB)

        let classicA = SkinAssetCatalog(name: "Synthetic Classic Diagnostic A", files: SkinDiagnosticFixtures.classicFiles(background: .systemBlue), report: .init(), format: .classic)
        let classicB = SkinAssetCatalog(name: "Synthetic Classic Diagnostic B", files: SkinDiagnosticFixtures.classicFiles(background: .systemOrange), report: .init(), format: .classic)
        let classicHashA = try #require(classicA.mainImage).validationPixelHash()
        let classicHashB = try #require(classicB.mainImage).validationPixelHash()
        #expect(classicHashA != classicHashB)
    }

    @Test @MainActor func classicDiagnosticAtlasKeepsCanonicalStatesVisiblyDistinct() throws {
        let files = SkinDiagnosticFixtures.classicFiles(background: .systemBlue)
        let catalog = SkinAssetCatalog(name: "Synthetic Classic Atlas", files: files, report: .init(), format: .classic)
        let image = try #require(catalog.images["cbuttons.bmp"])
        let ids: [SkinControlID] = [.previous, .play, .pause, .stop, .next, .open]
        let hashes = try ids.map { id -> UInt64 in
            let descriptor = try #require(ClassicSpriteCatalog.main[id])
            return try #require(image.validationPixelHash(sourceRect: descriptor.normal.sourceRect))
        }
        #expect(Set(hashes).count == hashes.count)
    }

    @Test func classicMainSpriteCatalogUsesCanonicalTables() throws {
        let next = try #require(ClassicSpriteCatalog.main[.next])
        #expect(next.frame == CGRect(x: 108, y: 88, width: 22, height: 18))
        #expect(next.normal.sourceRect == CGRect(x: 92, y: 0, width: 22, height: 18))

        let eject = try #require(ClassicSpriteCatalog.main[.open])
        #expect(eject.normal.sourceRect == CGRect(x: 114, y: 0, width: 22, height: 16))

        let shuffle = try #require(ClassicSpriteCatalog.main[.shuffle])
        #expect(shuffle.normal.sourceRect == CGRect(x: 28, y: 0, width: 47, height: 15))
        #expect(shuffle.activePressed?.sourceRect == CGRect(x: 28, y: 45, width: 47, height: 15))

        let equalizer = try #require(ClassicSpriteCatalog.main[.equalizer])
        #expect(equalizer.frame == CGRect(x: 219, y: 58, width: 23, height: 12))
        #expect(equalizer.normal.sourceRect == CGRect(x: 0, y: 61, width: 23, height: 12))

        let volume = try #require(ClassicSpriteCatalog.main[.volume])
        #expect(volume.normal.sourceRect == CGRect(x: 0, y: 0, width: 68, height: 420))
        #expect(volume.pressed?.sourceRect == CGRect(x: 15, y: 422, width: 14, height: 11))
        #expect(volume.active?.sourceRect == CGRect(x: 0, y: 422, width: 14, height: 11))
    }

    @Test @MainActor func classicCatalogExposesStandardWindowAssets() {
        let catalog = SkinAssetCatalog(name: "Synthetic Classic", files: [:], report: .init(), format: .classic)
        #expect(catalog.classicAssets?.equalizer == "eqmain.bmp")
        #expect(catalog.classicAssets?.playlist == "pledit.bmp")
        #expect(catalog.controls.contains { $0.id == .play && $0.normalSprite?.assetName == "cbuttons.bmp" })
    }

    @Test func duplicateCaseInsensitivePathsAreRejected() async throws {
        let url = try temporarySkin(entries: [("main.bmp", Data([1])), ("MAIN.BMP", Data([2]))])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: ProviderError.self) { try await SkinArchiveLoader().load(url: url) }
    }

    @Test func modernDoctypeIsNeverParsed() async throws {
        let xml = "<!DOCTYPE skin [<!ENTITY unsafe SYSTEM 'file:///etc/passwd'>]><WinampAbstractionLayer><skininfo><name>&unsafe;</name></skininfo></WinampAbstractionLayer>"
        let url = try temporarySkin(entries: [("skin.xml", Data(xml.utf8))], extension: "wal")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(!loaded.report.isValid)
        #expect(loaded.report.warnings.contains { $0.contains("document type") })
        #expect(loaded.modern?.name == nil)
    }

    @Test func missingMainAssetIsReported() async throws {
        let url = try temporarySkin(entries: [("text.bmp", Data([1]))])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(!loaded.report.isValid)
    }

    @Test func deflatedArchiveLoads() async throws {
        let encoded = "UEsDBBQAAAAIAC2GAl2AFwsGCwAAAOgDAAAIABwAbWFpbi5ibXBVVAkAA/VYb2r1WG9qdXgLAAEE9QEAAAQUAAAAY2AYBaNgFAx3AABQSwECHgMUAAAACAAthgJdgBcLBgsAAADoAwAACAAYAAAAAAAAAAAApIEAAAAAbWFpbi5ibXBVVAUAA/VYb2p1eAsAAQT1AQAABBQAAABQSwUGAAAAAAEAAQBOAAAATQAAAAAA"
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Deflated.wsz")
        try #require(Data(base64Encoded: encoded)).write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try await SkinArchiveLoader().load(url: url)
        #expect(loaded.files["main.bmp"]?.count == 1000)
    }

    @Test func pathTraversalIsRejected() async throws {
        let url = try temporarySkin(entries: [("../main.bmp", Data([1]))])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: ProviderError.self) { try await SkinArchiveLoader().load(url: url) }
    }

    @Test func oversizedEntryIsRejected() async throws {
        let url = try temporarySkin(entries: [("main.bmp", Data(repeating: 0, count: 32))])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var limits = SkinArchiveLoader.Limits()
        limits.maximumIndividualSize = 16
        await #expect(throws: ProviderError.self) { try await SkinArchiveLoader(limits: limits).load(url: url) }
    }

    @Test @MainActor func regionParserBuildsPolygon() {
        let data = Data("""
        ; Commented examples must not contribute coordinates.
        ; [Normal]
        ; NumPoints=3
        ; PointList=0,0 10,0 0,10
        [Normal]
        NumPoints=4,4
        PointList=0,0 275,0 275,20 0,20
        PointList=0,20 275,20 275,116 0,116
        [WindowShade]
        NumPoints=3
        PointList=0,0 10,0 0,10
        """.utf8)
        let path = RegionParser.parse(data)
        #expect(path?.bounds.width == 275)
        #expect(path?.bounds.height == 116)
    }

    @Test @MainActor func malformedRegionFallsBackSafely() {
        let data = Data("[Normal]\nNumPoints=4\nPointList=0,0 275,0 275,116".utf8)
        #expect(RegionParser.parse(data) == nil)
    }

    @Test @MainActor func classicChromaKeyDoesNotLeakIntoModernAssets() throws {
        let png = try alphaAndMagentaPNG()
        let modern = SkinAssetCatalog(name: "Modern", files: ["asset.png": png], report: .init(), format: .modern, modern: ModernSkinDescriptor())
        let classic = SkinAssetCatalog(name: "Classic", files: ["asset.png": png], report: .init(), format: .classic)
        let modernImage = try #require(modern.images["asset.png"])
        let classicImage = try #require(classic.images["asset.png"])
        let modernTIFF = try #require(modernImage.tiffRepresentation)
        let classicTIFF = try #require(classicImage.tiffRepresentation)
        let modernBitmap = try #require(NSBitmapImageRep(data: modernTIFF))
        let classicBitmap = try #require(NSBitmapImageRep(data: classicTIFF))

        #expect(try #require(modernBitmap.colorAt(x: 0, y: 0)).alphaComponent > 0.99)
        #expect(try #require(modernBitmap.colorAt(x: 0, y: 0)).redComponent > 0.9)
        #expect(try #require(modernBitmap.colorAt(x: 1, y: 0)).alphaComponent < 0.01)
        #expect((classicBitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) < 0.01)
    }

    @Test @MainActor func modernRegionPreservesRawSysregionAndComposesCutouts() throws {
        let xml = """
        <WinampAbstractionLayer>
          <container id="main" default_visible="1">
            <layout id="normal" w="100" h="100" desktopalpha="true">
              <layer id="outer" image="pixel" x="0" y="0" w="100" h="100" sysregion="1" />
              <layer id="hole" image="pixel" x="25" y="25" w="50" h="50" sysregion="-2" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8), "pixel.png": try alphaAndMagentaPNG()]).descriptor
        let region = try #require(descriptor.windowRegion)
        #expect(region.desktopAlpha)
        #expect(region.usesBitmapAlpha)
        #expect(region.shapes.map(\.additive) == [true, false])
        #expect(descriptor.layers.first { $0.elementID == "outer" }?.sysRegion == 1)
        #expect(descriptor.layers.first { $0.elementID == "hole" }?.sysRegion == -2)

        let catalog = SkinAssetCatalog(name: "Modern", files: ["skin.xml": Data(xml.utf8), "pixel.png": try alphaAndMagentaPNG()], report: .init(), format: .modern, modern: descriptor)
        #expect(catalog.regionPath == nil)
        #expect(catalog.modernWindowUsesBitmapAlpha)
        #expect(catalog.mainImage != nil)
    }

    @Test @MainActor func dockingUsesIntegerScaledThreshold() {
        let docking = WindowDockingController()
        let moving = CGRect(x: 91, y: 100, width: 50, height: 40)
        let other = CGRect(x: 150, y: 100, width: 50, height: 40)
        let result = docking.snappedOrigin(for: moving, near: [other], screen: CGRect(x: 0, y: 0, width: 500, height: 500), scale: 1)
        #expect(result.x == 100)
    }

    @Test @MainActor func rendererUsesLogicalBoundsAtEveryDisplayScale() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let defaultsName = "Macamp.RendererTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(2, forKey: SettingsStore.Keys.skinScale)
        let settings = SettingsStore(defaults: defaults)
        let skins = SkinLibraryStore(defaults: defaults, root: temporaryRoot)
        let view = SkinRendererView(
            coordinator: PlaybackCoordinator(),
            skinStore: skins,
            settings: settings,
            openMedia: {},
            playlistToggle: {},
            equalizerToggle: {},
            visualizationToggle: {}
        )

        #expect(view.bounds.size == SkinRendererView.fallbackLogicalSize)
        #expect(view.frame.size == CGSize(width: 550, height: 232))
        view.updateScale(3)
        #expect(view.bounds.size == SkinRendererView.fallbackLogicalSize)
        #expect(view.frame.size == CGSize(width: 825, height: 348))
    }

    @Test @MainActor func rendererDrivesSyntheticWALWithPlaybackAndDrawerAnimation() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let xml = """
        <?xml version="1.0"?>
        <WinampAbstractionLayer version="1.0">
          <skininfo><name>Renderer E2E</name></skininfo>
          <elements>
            <bitmap id="background" file="background.png" />
            <bitmap id="drawer" file="drawer.png" />
          </elements>
          <container id="main" default_visible="1">
            <groupdef id="LeftDrawer" w="20" h="40">
              <layer id="left-layer" image="drawer" x="0" y="0" w="20" h="40" />
            </groupdef>
            <groupdef id="RightDrawer" w="20" h="40">
              <layer id="right-layer" image="drawer" x="0" y="0" w="20" h="40" />
            </groupdef>
            <layout id="normal" w="100" h="40">
              <layer image="background" x="0" y="0" w="100" h="40" />
              <text id="songname" display="songname" x="22" y="4" w="56" h="12" />
              <group id="LeftDrawer" x="20" y="0" />
              <group id="RightDrawer" x="60" y="0" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let source = try temporarySkin(entries: [
            ("skin.xml", Data(xml.utf8)),
            ("background.png", png),
            ("drawer.png", png)
        ], extension: "wal")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let defaultsName = "Macamp.RendererE2E.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let skins = SkinLibraryStore(defaults: defaults, root: root)
        await skins.importSkin(from: source)
        #expect(skins.lastError == nil)
        #expect(skins.activeCatalog.drawers.map(\.role).contains(.left))
        #expect(skins.activeCatalog.drawers.map(\.role).contains(.right))

        let coordinator = PlaybackCoordinator()
        let provider = MockPlaybackProvider()
        coordinator.register(provider)
        var item = PlaybackItem(
            id: "renderer-e2e",
            providerID: .preview,
            providerItemID: "renderer-e2e",
            title: "Synthetic Song",
            artist: "Synthetic Artist",
            albumTitle: "Synthetic Album",
            duration: .seconds(125),
            artwork: nil,
            mediaKind: .song,
            isExplicit: false
        )
        item.bitrateKbps = 128
        item.sampleRateHz = 44_100
        item.channelCount = 2
        item.fileExtension = "mp3"
        await coordinator.play(item: item)

        let settings = SettingsStore(defaults: defaults)
        let view = SkinRendererView(
            coordinator: coordinator,
            skinStore: skins,
            settings: settings,
            openMedia: {},
            playlistToggle: {},
            equalizerToggle: {},
            visualizationToggle: {}
        )
        #expect(view.metadataStringsForTesting.first == "Synthetic Artist - Synthetic Song")
        #expect(Array(view.metadataStringsForTesting.suffix(2)) == ["128", "44.1"])
        #expect(view.drawerProgressForTesting[.left] == 1)

        view.makiTargetChanged(objectID: "LeftDrawer", x: 20, speed: 0.05)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.drawerProgressForTesting[.left] ?? 1 < 0.01)

        view.makiTargetChanged(objectID: "LeftDrawer", x: 0, speed: 0.05)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.drawerProgressForTesting[.left] ?? 0 > 0.99)

        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.size == view.bounds.size)
    }

    @Test @MainActor func logicalMouseInjectionUsesWasabiHitTestingPath() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let xml = """
        <WinampAbstractionLayer>
          <elements><bitmap id="pixel" file="pixel.png" /></elements>
          <container id="main" default_visible="1">
            <layout id="normal" w="80" h="40">
              <layer image="pixel" x="0" y="0" w="80" h="40" />
              <button id="scriptOnly" image="pixel" x="20" y="10" w="24" h="18" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let source = try temporarySkin(entries: [("skin.xml", Data(xml.utf8)), ("pixel.png", png)], extension: "wal")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let defaultsName = "Macamp.MouseInjection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let skins = SkinLibraryStore(defaults: defaults, root: root)
        await skins.importSkin(from: source)
        let view = SkinRendererView(coordinator: PlaybackCoordinator(), skinStore: skins, settings: SettingsStore(defaults: defaults), openMedia: {}, playlistToggle: {}, equalizerToggle: {}, visualizationToggle: {})
        #expect(view.injectMouseDown(at: CGPoint(x: 24, y: 16)) == "scriptonly")
        view.injectMouseUp(at: CGPoint(x: 24, y: 16))
    }

    private func temporarySkin(entries: [(String, Data)], extension fileExtension: String = "wsz") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Synthetic.\(fileExtension)")
        try makeStoredZIP(entries).write(to: url)
        return url
    }

    private func alphaAndMagentaPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 32
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSColor.clear.setFill()
        NSRect(x: 1, y: 0, width: 1, height: 1).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendLE(UInt16(bytes.count), to: &data)
        data.append(bytes)
    }

    private func makeStoredZIP(_ entries: [(String, Data)]) -> Data {
        var archive = Data()
        var central = Data()
        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            let localOffset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0)); archive.appendLE(UInt32(payload.count)); archive.appendLE(UInt32(payload.count))
            archive.appendLE(UInt16(nameData.count)); archive.appendLE(UInt16(0)); archive.append(nameData); archive.append(payload)

            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(UInt32(payload.count)); central.appendLE(UInt32(payload.count))
            central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(localOffset); central.append(nameData)
        }
        let centralOffset = UInt32(archive.count); archive.append(central)
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        return archive
    }
}

private struct SkinBehaviorEvent: Equatable {
    let phase: String
    let stateHash: UInt64
    let hitID: String?
}

private struct SkinBehaviorTrace {
    private(set) var events: [SkinBehaviorEvent] = []

    mutating func append(_ event: SkinBehaviorEvent) {
        events.append(event)
    }
}

private struct SkinValidationHasher {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        value ^= 0xff
        value &*= 1_099_511_628_211
    }

    mutating func append(_ number: Double) {
        append(String(format: "%.4f", number))
    }

    mutating func append(_ number: CGFloat) {
        append(Double(number))
    }

    var result: UInt64 { value }
}

private extension WasabiScene {
    func validationStateHash() -> UInt64 {
        var hasher = SkinValidationHasher()
        for node in nodes.values.sorted(by: { $0.handle.rawValue < $1.handle.rawValue }) {
            hasher.append(String(node.handle.rawValue))
            hasher.append(node.id)
            hasher.append(node.kind.rawValue)
            hasher.append(node.localFrame.minX)
            hasher.append(node.localFrame.minY)
            hasher.append(node.localFrame.width)
            hasher.append(node.localFrame.height)
            hasher.append(node.parent.map { String($0.rawValue) } ?? "root")
            hasher.append(node.visible ? "visible" : "hidden")
            hasher.append(node.alpha)
            hasher.append(node.ghost ? "ghost" : "live")
            hasher.append(String(node.zIndex))
            for child in node.children { hasher.append(String(child.rawValue)) }
        }
        for (container, layout) in activeLayoutByContainer.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            hasher.append("active")
            hasher.append(String(container.rawValue))
            hasher.append(String(layout.rawValue))
        }
        return hasher.result
    }
}

@MainActor
private extension NSImage {
    func validationPixelHash(sourceRect: CGRect? = nil) -> UInt64? {
        let image: NSImage
        if let sourceRect {
            guard !sourceRect.isEmpty else { return nil }
            image = NSImage(size: sourceRect.size, flipped: true) { destination in
                let flippedSource = CGRect(
                    x: sourceRect.minX,
                    y: self.size.height - sourceRect.maxY,
                    width: sourceRect.width,
                    height: sourceRect.height
                )
                self.draw(in: destination, from: flippedSource, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
                return true
            }
        } else {
            image = self
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let bytes = bitmap.bitmapData else { return nil }
        let data = Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        var hasher = SkinValidationHasher()
        hasher.append("(bitmap.pixelsWide)x(bitmap.pixelsHigh):(bitmap.bitsPerPixel):(bitmap.bytesPerRow)")
        for byte in data { hasher.append(String(byte)) }
        return hasher.result
    }
}

@MainActor
private enum SkinDiagnosticFixtures {
    static func modernFiles(accent: NSColor) -> [String: Data] {
        let xml = """
        <WinampAbstractionLayer>
          <elements>
            <bitmap id="background" file="background.png" />
            <bitmap id="marker" file="marker.png" />
          </elements>
          <container id="main" default_visible="1">
            <layout id="normal" w="64" h="32">
              <layer id="background-layer" image="background" x="0" y="0" w="64" h="32" />
              <button id="diagnostic-marker" image="marker" x="24" y="12" w="16" h="8" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        return [
            "skin.xml": Data(xml.utf8),
            "background.png": diagnosticPNG(size: CGSize(width: 64, height: 32), background: NSColor(calibratedWhite: 0.08, alpha: 1), fills: [
                (CGRect(x: 0, y: 0, width: 64, height: 4), NSColor(calibratedWhite: 0.18, alpha: 1))
            ]),
            "marker.png": diagnosticPNG(size: CGSize(width: 16, height: 8), background: accent, fills: [])
        ]
    }

    static func classicFiles(background: NSColor) -> [String: Data] {
        var buttonFills: [(CGRect, NSColor)] = []
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.95, green: 0.15, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.2, alpha: 1),
            NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.95, alpha: 1)
        ]
        let buttonRects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 23, height: 18),
            CGRect(x: 23, y: 0, width: 23, height: 18),
            CGRect(x: 46, y: 0, width: 23, height: 18),
            CGRect(x: 69, y: 0, width: 23, height: 18),
            CGRect(x: 92, y: 0, width: 22, height: 18),
            CGRect(x: 114, y: 0, width: 22, height: 16)
        ]
        for (index, rect) in buttonRects.enumerated() {
            buttonFills.append((rect, colors[index]))
            buttonFills.append((rect.offsetBy(dx: 0, dy: index == 5 ? 16 : 18), colors[index].withAlphaComponent(0.5)))
        }

        return [
            "main.bmp": diagnosticPNG(size: CGSize(width: 275, height: 116), background: background, fills: [
                (CGRect(x: 0, y: 0, width: 275, height: 14), NSColor(calibratedWhite: 0.18, alpha: 1)),
                (CGRect(x: 0, y: 108, width: 275, height: 8), NSColor(calibratedWhite: 0.04, alpha: 1))
            ]),
            "cbuttons.bmp": diagnosticPNG(size: CGSize(width: 136, height: 36), background: .black, fills: buttonFills),
            "shufrep.bmp": diagnosticPNG(size: CGSize(width: 75, height: 85), background: .black, fills: [
                (CGRect(x: 0, y: 0, width: 28, height: 15), colors[0]),
                (CGRect(x: 28, y: 0, width: 47, height: 15), colors[1]),
                (CGRect(x: 0, y: 15, width: 28, height: 15), colors[2]),
                (CGRect(x: 28, y: 15, width: 47, height: 15), colors[3]),
                (CGRect(x: 0, y: 30, width: 28, height: 15), colors[4]),
                (CGRect(x: 28, y: 30, width: 47, height: 15), colors[5]),
                (CGRect(x: 0, y: 45, width: 28, height: 15), colors[0].withAlphaComponent(0.5)),
                (CGRect(x: 28, y: 45, width: 47, height: 15), colors[1].withAlphaComponent(0.5)),
                (CGRect(x: 0, y: 61, width: 23, height: 12), colors[2].withAlphaComponent(0.5)),
                (CGRect(x: 23, y: 61, width: 23, height: 12), colors[3].withAlphaComponent(0.5)),
                (CGRect(x: 46, y: 61, width: 23, height: 12), colors[4].withAlphaComponent(0.5)),
                (CGRect(x: 69, y: 61, width: 6, height: 12), colors[5].withAlphaComponent(0.5)),
                (CGRect(x: 0, y: 73, width: 23, height: 12), colors[0].withAlphaComponent(0.25)),
                (CGRect(x: 23, y: 73, width: 23, height: 12), colors[1].withAlphaComponent(0.25)),
                (CGRect(x: 46, y: 73, width: 23, height: 12), colors[2].withAlphaComponent(0.25))
            ]),
            "posbar.bmp": diagnosticPNG(size: CGSize(width: 307, height: 10), background: NSColor(calibratedWhite: 0.3, alpha: 1), fills: []),
            "volume.bmp": diagnosticPNG(size: CGSize(width: 68, height: 433), background: NSColor(calibratedWhite: 0.25, alpha: 1), fills: [])
        ]
    }

    private static func diagnosticPNG(size: CGSize, background: NSColor, fills: [(CGRect, NSColor)]) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (rect, color) in fills {
            color.setFill()
            rect.fill()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor
private final class TestMakiHost: MakiRuntimeHost {
    var targets: [(objectID: String, x: Double, speed: Double)] = []
    func makiPlaybackStatus() -> Int { 0 }
    func makiXMLParameter(objectID: String, name: String) -> String? {
        guard name == "x" else { return nil }
        return switch objectID {
        case "leftdrawer": "207"
        case "leftdrawercoords": "0"
        case "rightdrawer": "277"
        case "rightdrawercoords": "488"
        default: "0"
        }
    }
    func makiVisibilityChanged(objectID: String, isVisible: Bool) { }
    func makiTargetChanged(objectID: String, x: Double, speed: Double) { targets.append((objectID, x, speed)) }
    func makiVolumeChanged(_ value: Double) { }
    func makiEQBandChanged(index: Int, value: Int) { }
    func makiRuntimeNeedsDisplay() { }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)) }
    mutating func appendLE(_ value: UInt32) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff)) }
}
