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

    @Test func modernBitmapFontDeclarationsReachTheScenePainter() throws {
        let xml = """
        <WinampAbstractionLayer>
          <elements>
            <bitmap id="display.sheet" file="display.png" />
            <bitmapfont id="TickerFont" file="display.sheet" charwidth="4" charheight="5" hspacing="1" vspacing="2" />
          </elements>
          <container id="main">
            <layout id="normal" w="80" h="20">
              <songticker id="title" font="TickerFont" x="2" y="2" w="24" h="7" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8), "display.png": Data([1])]).descriptor
        let font = try #require(descriptor.bitmapFonts["tickerfont"])
        #expect(font.imageID == "display.sheet")
        #expect(font.filePath == nil)
        #expect(font.charWidth == 4)
        #expect(font.charHeight == 5)
        #expect(font.horizontalSpacing == 1)
        #expect(font.verticalSpacing == 2)

        let ticker = try #require(descriptor.scene.firstHandle(for: "title"))
        #expect(descriptor.scene.node(ticker)?.attributes["font"] == "tickerfont")

        let placements = ModernBitmapFontPainter.placements(
            for: "A7",
            in: CGRect(x: 2, y: 2, width: 24, height: 7),
            resource: font,
            imageSize: CGSize(width: 124, height: 15),
            alignment: .left
        )
        #expect(placements.map(\.sourceRect) == [
            CGRect(x: 0, y: 0, width: 4, height: 5),
            CGRect(x: 28, y: 5, width: 4, height: 5)
        ])
        #expect(placements.map(\.destinationRect) == [
            CGRect(x: 2, y: 3, width: 4, height: 5),
            CGRect(x: 7, y: 3, width: 4, height: 5)
        ])
    }

    @Test func modernFontAndGammaDeclarationsAreRetainedAsResources() throws {
        let xml = """
        <WinampAbstractionLayer>
          <truetypefont id="Body" file="fonts/body.ttf" face="Body Sans" size="11" />
          <gammaset id="Night" gamma0="0.8" gamma1="1.1"><gamma value="0.9" /></gammaset>
          <container id="main"><layout id="normal" w="32" h="16" /></container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: [
            "skin.xml": Data(xml.utf8), "fonts/body.ttf": Data([1])
        ]).descriptor
        #expect(descriptor.fonts["body"] == ModernFontResource(id: "body", filePath: "fonts/body.ttf", faceName: "Body Sans", pointSize: 11))
        #expect(descriptor.gammaSets["night"]?.values == [0.8, 1.1, 0.9])
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
        #expect(descriptor.layers.first { $0.elementID?.caseInsensitiveCompare("BGLayer") == .orderedSame }?.frame.width ?? 0 > 0)
        #expect(descriptor.scene.firstHandle(for: "bglayer").flatMap { descriptor.scene.worldFrame(of: $0) }?.width ?? 0 > 0)
        #expect(catalog.regionPath != nil)
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
              <layer x="0" />
              <component param="guid:pl" x="12" y="10" w="172" h="140" />
            </groupdef>
            <groupdef id="RightDrawer" w="271" h="170"><layer id="right-bg" image="right" /><layer x="489" /></groupdef>
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
              <button id="plToggle" tooltip="Open playlist" image="button" x="2" y="2" />
              <button id="EqShowHide" tooltip="Open graphic equalizer controls" image="button" x="18" y="2" />
              <button id="playlist-by-param" action="TOGGLE" param="guid:pl" image="button" x="34" y="2" />
              <button id="LeftDrawerClose" tooltip="Close graphic equalizer controls" image="button" x="50" y="2" />
              <button id="RightDrawerOpen" tooltip="Close playlist" image="button" x="66" y="2" />
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

    @Test @MainActor func xuiGroupDefinitionsCreateIndependentSceneInstancesAndScopedOverrides() throws {
        let xml = """
        <WinampAbstractionLayer xmlns:My="urn:macamp:test">
          <elements><bitmap id="pixel" file="pixel.png" /></elements>
          <container id="main" default_visible="1">
            <groupdef id="tab.button" xuitag="My:TabButton" w="40" h="20">
              <button id="click" image="pixel" x="0" y="0" w="20" h="10" />
              <script file="scripts/tab.maki" />
            </groupdef>
            <layout id="normal" w="120" h="40">
              <My:TabButton id="first" x="10" y="5" />
              <My:TabButton id="second" x="70" y="5" />
              <sendparams group="first" target="click" x="4" w="24" />
              <hideobject target="second.click" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let descriptor = ModernSkinParser.parse(files: [
            "skin.xml": Data(xml.utf8), "pixel.png": Data([1]), "scripts/tab.maki": Data([0x46, 0x47])
        ]).descriptor
        let scene = descriptor.scene
        let groups = scene.handles(for: "first") + scene.handles(for: "second")
        #expect(groups.count == 2)
        #expect(scene.handles(for: "click").count == 2)
        let firstClick = try #require(scene.handles(for: "click").first)
        let secondClick = try #require(scene.handles(for: "click").last)
        #expect(scene.worldFrame(of: firstClick) == CGRect(x: 14, y: 5, width: 24, height: 10))
        #expect(scene.worldFrame(of: secondClick) == CGRect(x: 70, y: 5, width: 20, height: 10))
        #expect(scene.effectiveVisible(firstClick))
        #expect(!scene.effectiveVisible(secondClick))
        let scriptOwners = Set(descriptor.makiBindings.filter { $0.path == "scripts/tab.maki" }.map(\.groupID))
        #expect(scriptOwners.isSuperset(of: ["first", "second"]))
    }

    @Test func includedXMLExpandsXUIInstancesAndElementAliases() throws {
        let xml = """
        <WinampAbstractionLayer xmlns:My="urn:macamp:test">
          <elements>
            <bitmap id="actual" file="pixel.png" x="1" y="2" w="3" h="4" />
          </elements>
          <include file="widgets.inc" />
          <elementalias id="first.alias" target="second.alias" />
          <elementalias id="second.alias" target="actual" />
          <container id="main" default_visible="1">
            <layout id="normal" w="120" h="40">
              <My:Embedded id="one" x="10" y="5" />
              <My:Embedded id="two" x="70" y="5" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        let included = """
        <groupdef id="embedded.widget" xuitag="My:Embedded" embed_xui="inner" w="30" h="12">
          <button id="inner" image="first.alias" x="0" y="0" w="20" h="10" />
          <script file="scripts/embedded.maki" />
        </groupdef>
        """
        let descriptor = ModernSkinParser.parse(files: [
            "skin.xml": Data(xml.utf8),
            "widgets.inc": Data(included.utf8),
            "pixel.png": Data([1]),
            "scripts/embedded.maki": Data([0x46, 0x47])
        ]).descriptor

        #expect(descriptor.bitmapFiles["first.alias"] == "pixel.png")
        #expect(descriptor.bitmapFiles["second.alias"] == "pixel.png")
        #expect(descriptor.bitmapSourceRects["first.alias"] == CGRect(x: 1, y: 2, width: 3, height: 4))

        let one = try #require(descriptor.scene.firstHandle(for: "one"))
        let two = try #require(descriptor.scene.firstHandle(for: "two"))
        #expect(descriptor.scene.node(one)?.attributes["embed_xui"] == "inner")
        #expect(descriptor.scene.node(two)?.attributes["embed_xui"] == "inner")
        #expect(descriptor.scene.handles(for: "inner").count == 2)
        #expect(descriptor.scene.worldFrame(of: try #require(descriptor.scene.handles(for: "inner").first)) == CGRect(x: 10, y: 5, width: 20, height: 10))
        #expect(descriptor.scene.worldFrame(of: try #require(descriptor.scene.handles(for: "inner").last)) == CGRect(x: 70, y: 5, width: 20, height: 10))

        let owners = Set(descriptor.makiBindings.filter { $0.path == "scripts/embedded.maki" }.map(\.groupID))
        #expect(owners.isSuperset(of: ["one", "two"]))
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

    @Test func animatedLayerSelectsDeterministicSpriteSheetFrames() throws {
        var scene = WasabiScene()
        let animation = scene.addNode(
            id: "meter",
            kind: .animatedLayer,
            localFrame: CGRect(x: 12, y: 8, width: 8, height: 4),
            attributes: ["image": "meter", "frameindex": "1"]
        )

        let rendered = try #require(WasabiScenePainter.renderNodes(in: scene).first)
        let second = try #require(WasabiAnimatedLayer.selection(
            for: rendered,
            imageSize: CGSize(width: 8, height: 8)
        ))
        #expect(second.index == 1)
        #expect(second.count == 2)
        #expect(second.sourceRect == CGRect(x: 0, y: 4, width: 8, height: 4))

        scene.setAnimatedLayerFrame(0, for: animation)
        let firstRendered = try #require(WasabiScenePainter.renderNodes(in: scene).first)
        let first = try #require(WasabiAnimatedLayer.selection(
            for: firstRendered,
            imageSize: CGSize(width: 8, height: 8)
        ))
        #expect(scene.animatedLayerFrame(for: animation) == 0)
        #expect(first.sourceRect == CGRect(x: 0, y: 0, width: 8, height: 4))
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
        let missing = runtime.invoke(receiver: layout, method: "findObject", arguments: [.string("missing")])
        #expect(missing == MakiValue.void)
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

    @Test @MainActor func makiStandardObjectsSupportTimerAndConfigAttributeState() async throws {
        let host = TestMakiHost()
        let runtime = MakiRuntime(programs: [], bindings: [], host: host, limits: .init(), skinID: "standard-objects", persistentState: .standard)
        let timer = runtime.registry.instantiate(className: "Timer", id: "pulse")
        #expect(runtime.invoke(receiver: timer, method: "getClassName", arguments: []) == .string("Timer"))
        #expect(runtime.invoke(receiver: timer, method: "getId", arguments: []) == .string("pulse"))
        _ = runtime.invoke(receiver: timer, method: "setDelay", arguments: [.integer(5)])
        #expect(runtime.invoke(receiver: timer, method: "getDelay", arguments: []) == .integer(5))
        _ = runtime.invoke(receiver: timer, method: "start", arguments: [])
        #expect(runtime.invoke(receiver: timer, method: "isRunning", arguments: []) == .integer(1))
        _ = runtime.invoke(receiver: timer, method: "stop", arguments: [])
        #expect(runtime.invoke(receiver: timer, method: "isRunning", arguments: []) == .integer(0))

        let attribute = runtime.registry.instantiate(className: "ConfigAttribute", id: "volume")
        _ = runtime.invoke(receiver: attribute, method: "setData", arguments: [.string("128")])
        #expect(runtime.invoke(receiver: attribute, method: "getData", arguments: []) == .string("128"))
        try await Task.sleep(for: .milliseconds(1))

        let timerGUID = Data([0x5d, 0x0c, 0x5b, 0xb6, 0x7d, 0xe1, 0x4b, 0x1f, 0xa7, 0x0f, 0x8d, 0x16, 0x59, 0x94, 0x19, 0x41])
        let program = MakiProgram(
            path: "dynamic-timer.maki", version: 0x17, classGUIDs: [timerGUID],
            functions: [MakiFunction(baseType: 0, name: "onScriptLoaded")],
            variables: [
                MakiVariable(type: 0, payload: 0, isTransient: false, isStatic: true, string: nil),
                MakiVariable(type: 0x101, payload: 0, isTransient: false, isStatic: false, string: nil)
            ],
            events: [MakiEvent(variableIndex: 0, functionIndex: 0, codeOffset: 0)],
            code: Data([0x60, 0, 0, 0, 0, 0x03, 1, 0, 0, 0, 0x28])
        )
        let dynamicRuntime = MakiRuntime(
            programs: [program], bindings: [ModernMakiBinding(path: program.path, groupID: "main", parameter: nil)],
            host: host, limits: .init(), skinID: "dynamic-timer", persistentState: .standard
        )
        let objectCount = dynamicRuntime.registry.objects.count
        dynamicRuntime.start()
        #expect(dynamicRuntime.registry.objects.count == objectCount + 1)
        #expect(dynamicRuntime.registry.objects.values.contains { $0.className == "Timer" })
    }

    @Test @MainActor func makiInputLifecyclePreservesArgumentsAndButtonOrdering() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: .zero, parent: container)
        let button = scene.addNode(id: "play", kind: .button, localFrame: CGRect(x: 10, y: 10, width: 40, height: 20), parent: layout)
        scene.addNode(id: "stop", kind: .button, localFrame: CGRect(x: 70, y: 10, width: 40, height: 20), parent: layout)
        scene.setActiveLayout(layout, for: container)

        let program = MakiProgram(
            path: "scripts/input.maki",
            version: 0x17,
            classGUIDs: [],
            functions: [MakiFunction(baseType: 0, name: "onLeftButtonDown")],
            variables: [
                MakiVariable(type: 0x101, payload: 0, isTransient: false, isStatic: true, string: nil),
                MakiVariable(type: 0x101, payload: 0, isTransient: false, isStatic: false, string: "play")
            ],
            events: [MakiEvent(variableIndex: 1, functionIndex: 0, codeOffset: 0)],
            // Pop both event parameters. Without event argument propagation
            // this handler would underflow and disable the script.
            code: Data([0x02, 0x02, 0x28])
        )
        let host = TestMakiHost()
        let runtime = MakiRuntime(
            programs: [program],
            bindings: [ModernMakiBinding(path: program.path, groupID: "main", parameter: nil)],
            host: host,
            limits: .init(),
            skinID: "input-lifecycle",
            persistentState: .standard,
            scene: scene
        )

        _ = runtime.dispatchMouseDown(objectID: "play", x: 24, y: 16)
        #expect(runtime.isPressed(button))
        #expect(host.actions.isEmpty)
        #expect(runtime.trace.map(\.kind) == [.buttonPressedChanged, .event])
        #expect(runtime.trace[1].receiver == button)
        #expect(runtime.trace[1].name == "onLeftButtonDown")
        #expect(runtime.trace[1].arguments == [.integer(24), .integer(16)])
        #expect(runtime.diagnostics.isEmpty)

        _ = runtime.dispatchMouseUp(objectID: "play", x: 25, y: 17)
        #expect(!runtime.isPressed(button))
        #expect(host.actions == [button])
        #expect(runtime.trace.map(\.name) == ["pressed", "onLeftButtonDown", "onLeftButtonUp", "pressed", "declarativeAction", "onLeftClick"])
        #expect(runtime.trace[2].receiver == button)
        #expect(runtime.trace[2].arguments == [.integer(25), .integer(17)])
        #expect(runtime.trace[5].receiver == button)
        #expect(runtime.trace[5].arguments.isEmpty)

        runtime.clearTrace()
        host.actions.removeAll()
        _ = runtime.dispatchMouseDown(objectID: "play", x: 24, y: 16)
        _ = runtime.dispatchMouseUp(objectID: "stop", x: 75, y: 16)
        #expect(host.actions.isEmpty)
        #expect(runtime.trace.map(\.name) == ["pressed", "onLeftButtonDown", "onLeftButtonUp", "pressed"])
        #expect(runtime.trace[2].receiver == button)
        #expect(runtime.trace[3].receiver == button)
    }

    @Test @MainActor func makiAreaAndSliderEventsUseCanonicalNamesAndValues() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: .zero)
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: .zero, parent: container)
        let button = scene.addNode(id: "button", kind: .button, localFrame: CGRect(x: 0, y: 0, width: 20, height: 20), parent: layout)
        let slider = scene.addNode(id: "slider", kind: .slider, localFrame: CGRect(x: 0, y: 30, width: 80, height: 16), parent: layout)
        scene.setActiveLayout(layout, for: container)

        let host = TestMakiHost()
        let runtime = MakiRuntime(
            programs: [],
            bindings: [],
            host: host,
            limits: .init(),
            skinID: "area-slider",
            persistentState: .standard,
            scene: scene
        )
        _ = runtime.dispatchMouseEnter(objectID: "button")
        _ = runtime.dispatchMouseLeave(objectID: "button")
        _ = runtime.dispatchSliderPosition(receiver: slider, value: 42)
        _ = runtime.dispatchSliderPosition(receiver: slider, value: 43, posted: true)
        _ = runtime.dispatchSliderPosition(receiver: slider, value: 44, final: true)

        #expect(runtime.trace.map { $0.name } == ["onEnterArea", "onLeaveArea", "onSetPosition", "onPostedPosition", "onSetFinalPosition"])
        #expect(runtime.trace.map { $0.receiver } == [button, button, slider, slider, slider])
        let expectedSliderArguments: [[MakiValue]] = [[.integer(42)], [.integer(43)], [.integer(44)]]
        #expect(runtime.trace.dropFirst(2).map { $0.arguments } == expectedSliderArguments)
        #expect(host.eventNames == ["onEnterArea", "onLeaveArea", "onSetPosition", "onPostedPosition", "onSetFinalPosition"])
        #expect(host.eventReceivers == [button, button, slider, slider, slider])
        #expect(host.eventArguments.dropFirst(2) == [[.integer(42)], [.integer(43)], [.integer(44)]])
    }

    @Test func syntheticSceneValidationTraceDetectsHierarchyAndLayoutChanges() throws {
        let xml = """
        <WinampAbstractionLayer>
          <elements><bitmap id="pixel" file="pixel.png" /></elements>
          <container id="main" default_visible="1">
            <groupdef id="controls" w="40" h="24">
              <button id="play" x="4" y="3" w="16" h="12" />
            </groupdef>
            <layout id="normal" w="120" h="48">
              <group id="controls" x="12" y="8" />
            </layout>
            <layout id="shade" w="120" h="14">
              <layer id="shade-background" image="pixel" x="0" y="0" w="120" h="14" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """
        var scene = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8), "pixel.png": Data([1])]).descriptor.scene
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

    @Test @MainActor func classicPlaylistUsesLogicalTiledWindowGeometry() {
        #expect(ClassicPlaylistSurface.defaultSize == CGSize(width: 275, height: 232))
        #expect(ClassicPlaylistSurface.defaultSize.width >= 275)
        #expect(ClassicPlaylistSurface.defaultSize.height >= 116)
    }

    @Test func classicMainSliderPlacementsCropCanonicalTrackFrames() throws {
        let seekStart = try #require(ClassicSpriteCatalog.seekPlacement(progress: 0, pressed: false))
        let seekEnd = try #require(ClassicSpriteCatalog.seekPlacement(progress: 1, pressed: true))
        #expect(seekStart.track.sourceRect == CGRect(x: 0, y: 0, width: 248, height: 10))
        #expect(seekStart.thumbFrame == CGRect(x: 16, y: 72, width: 29, height: 10))
        #expect(seekEnd.thumb.sourceRect == CGRect(x: 278, y: 0, width: 29, height: 10))
        #expect(seekEnd.thumbFrame == CGRect(x: 235, y: 72, width: 29, height: 10))

        let volumeStart = try #require(ClassicSpriteCatalog.volumePlacement(value: 0, pressed: false))
        let volumeMid = try #require(ClassicSpriteCatalog.volumePlacement(value: 0.5, pressed: false))
        let volumeEnd = try #require(ClassicSpriteCatalog.volumePlacement(value: 1, pressed: true))
        #expect(volumeStart.track.sourceRect == CGRect(x: 0, y: 0, width: 68, height: 10))
        #expect(volumeMid.track.sourceRect == CGRect(x: 0, y: 195, width: 68, height: 10))
        #expect(volumeEnd.track.sourceRect == CGRect(x: 0, y: 405, width: 68, height: 10))
        #expect(volumeStart.thumbFrame == CGRect(x: 107, y: 57, width: 14, height: 11))
        #expect(volumeEnd.thumb.sourceRect == CGRect(x: 15, y: 422, width: 14, height: 11))
        #expect(volumeEnd.thumbFrame == CGRect(x: 161, y: 57, width: 14, height: 11))

        let catalog = SkinAssetCatalog(name: "Synthetic Classic Slider Atlas", files: SkinDiagnosticFixtures.classicFiles(background: .systemBlue), report: .init(), format: .classic)
        let volumeImage = try #require(catalog.images[ClassicSpriteSheet.volume.rawValue])
        let trackHashes = try [volumeStart, volumeMid, volumeEnd].map { placement in
            try #require(volumeImage.validationPixelHash(sourceRect: placement.track.sourceRect))
        }
        #expect(Set(trackHashes).count == 3)
    }

    @Test @MainActor func classicCatalogExposesStandardWindowAssets() {
        let catalog = SkinAssetCatalog(name: "Synthetic Classic", files: [:], report: .init(), format: .classic)
        #expect(catalog.classicAssets?.equalizer == "eqmain.bmp")
        #expect(catalog.classicAssets?.playlist == "pledit.bmp")
        #expect(catalog.controls.contains { $0.id == .play && $0.normalSprite?.assetName == "cbuttons.bmp" })
    }

    @Test @MainActor func classicPlaylistPaletteReadsPleDITColors() {
        let files = ["pledit.txt": Data("Normal=#FF0000\nCurrent=0,255,0\nNormalBG=1, 2, 3\nSelectedBG=#000080\n".utf8)]
        let catalog = SkinAssetCatalog(name: "Synthetic Playlist Palette", files: files, report: .init(), format: .classic)
        #expect(catalog.classicPlaylistPalette == ClassicPlaylistPalette(
            normalText: ClassicRGBColor(red: 255, green: 0, blue: 0),
            currentText: ClassicRGBColor(red: 0, green: 255, blue: 0),
            normalBackground: ClassicRGBColor(red: 1, green: 2, blue: 3),
            selectedBackground: ClassicRGBColor(red: 0, green: 0, blue: 128)
        ))
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
        [Equalizer]
        NumPoints=4
        PointList=0,0 275,0 275,116 0,116
        [EqualizerWS]
        NumPoints=4
        PointList=0,0 275,0 275,14 0,14
        """.utf8)
        let path = RegionParser.parse(data)
        #expect(path?.bounds.width == 275)
        #expect(path?.bounds.height == 116)
        #expect(RegionParser.parse(data, section: "Equalizer")?.bounds.height == 116)
        #expect(RegionParser.parse(data, section: "EqualizerWS")?.bounds.height == 14)
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
        #expect(catalog.regionPath != nil)
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

    @Test @MainActor func winampWindowGeometryScalesLogicalFramesAtBoundary() {
        let logical = CGRect(x: 40, y: 25, width: 275, height: 116)
        let screen = WinampSkinWindowGeometry.screenFrame(for: logical, scale: 2)

        #expect(screen == CGRect(x: 80, y: 50, width: 550, height: 232))
        #expect(WinampSkinWindowGeometry.logicalFrame(for: screen, scale: 2) == logical)
        #expect(WinampSkinWindowGeometry.screenSize(for: CGSize(width: 100, height: 14), scale: 3) == CGSize(width: 300, height: 42))
    }

    @Test @MainActor func classicPlaylistResizeSnapsAtLogicalWindowBoundary() {
        let host = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 275, height: 232), scale: 2, allowsResize: true)
        host.resizeGrid = CGSize(width: 25, height: 29)
        host.minimumLogicalSize = CGSize(width: 275, height: 116)
        let snapped = host.windowWillResize(host.window, toFrameSize: CGSize(width: 641, height: 527))
        #expect(snapped == CGSize(width: 600, height: 522))
    }

    @Test @MainActor func detachedSkinWindowsMoveIndependently() throws {
        let main = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 275, height: 116), scale: 1)
        let playlist = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 275, height: 232), scale: 2)
        main.setLogicalFrame(CGRect(x: 100, y: 80, width: 275, height: 116))
        playlist.setLogicalFrame(CGRect(x: 400, y: 80, width: 275, height: 232))

        let group = WinampSkinWindowGroup()
        group.add(main)
        group.add(playlist)

        group.move(main, toLogicalOrigin: CGPoint(x: 125, y: 65))
        #expect(main.logicalFrame.origin == CGPoint(x: 125, y: 65))
        #expect(playlist.logicalFrame.origin == CGPoint(x: 400, y: 80))

        playlist.setLogicalFrame(CGRect(x: 430, y: 75, width: 275, height: 232))
        playlist.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: playlist.window))
        #expect(playlist.logicalFrame.origin == CGPoint(x: 430, y: 75))
        #expect(main.logicalFrame.origin == CGPoint(x: 125, y: 65))
        #expect(group.hosts.count == 2)
    }

    @Test @MainActor func dockedSkinWindowsMoveAsAConnectedCluster() {
        let main = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 275, height: 116), scale: 1)
        let playlist = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 275, height: 232), scale: 1)
        main.setLogicalFrame(CGRect(x: 100, y: 80, width: 275, height: 116))
        playlist.setLogicalFrame(CGRect(x: 375, y: 80, width: 275, height: 232))

        let graph = WinampSkinWindowGroup()
        graph.add(main)
        graph.add(playlist)
        graph.dock(main, to: playlist)
        graph.move(main, toLogicalOrigin: CGPoint(x: 125, y: 65))

        #expect(main.logicalFrame.origin == CGPoint(x: 125, y: 65))
        #expect(playlist.logicalFrame.origin == CGPoint(x: 400, y: 65))

        graph.undock(playlist)
        graph.move(main, toLogicalOrigin: CGPoint(x: 140, y: 65))
        #expect(playlist.logicalFrame.origin == CGPoint(x: 400, y: 65))
    }

    @Test @MainActor func skinWindowHostSnapsToVisibleScreenEdgesInDisplayCoordinates() {
        let host = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 100, height: 40), scale: 2)
        host.screenSnapDistance = 8
        host.snapsToVisibleScreenEdges = true
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.window.setFrame(CGRect(x: visible.minX + 10, y: visible.minY + 10, width: 200, height: 80), display: false)
        host.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: host.window))
        #expect(host.window.frame.minX == visible.minX)
        #expect(host.window.frame.minY == visible.minY)
    }

    @Test func winampANIAndEQFResourcesRoundTripWithBounds() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

        func chunk(_ id: String, _ payload: Data) -> Data {
            var result = Data(id.utf8)
            result.appendLE(UInt32(payload.count))
            result.append(payload)
            if payload.count % 2 == 1 { result.append(0) }
            return result
        }

        var header = Data(repeating: 0, count: 4)
        header.appendLE(UInt32(2))
        header.appendLE(UInt32(2))
        header.append(Data(repeating: 0, count: 16))
        header.appendLE(UInt32(6))
        var rates = Data(); rates.appendLE(UInt32(6)); rates.appendLE(UInt32(12))
        var sequence = Data(); sequence.appendLE(UInt32(0)); sequence.appendLE(UInt32(1))
        var frames = Data("fram".utf8)
        frames.append(chunk("icon", png)); frames.append(chunk("icon", png))
        var body = Data("ACON".utf8)
        body.append(chunk("anih", header)); body.append(chunk("rate", rates)); body.append(chunk("seq ", sequence)); body.append(chunk("LIST", frames))
        var ani = Data("RIFF".utf8); ani.appendLE(UInt32(body.count)); ani.append(body)

        let cursor = try ANICursorDecoder.decode(ani)
        #expect(cursor.frames.count == 2)
        #expect(cursor.sequence == [0, 1])
        #expect(cursor.frames[0].duration == .milliseconds(100))
        #expect(cursor.frames[1].duration == .milliseconds(200))

        var cur = Data([0, 0, 2, 0, 1, 0, 1, 1, 0, 0])
        cur.appendLE(UInt16(3)); cur.appendLE(UInt16(4)); cur.appendLE(UInt32(png.count)); cur.appendLE(UInt32(22)); cur.append(png)
        let curFrame = try ANICursorDecoder.decodeFrame(cur)
        #expect(curFrame.hotSpot == CGPoint(x: 3, y: 4))
        #expect(curFrame.image.width == 1 && curFrame.image.height == 1)

        let first = try WinampEQPreset(name: "Flat", bands: Array(0..<10), preamp: 31)
        let second = try WinampEQPreset(name: "Bright", bands: Array(repeating: 64, count: 10), preamp: 0)
        let encoded = try WinampEQF.encode(WinampEQPresetFile(presets: [first, second]))
        let decoded = try WinampEQF.decode(encoded)
        #expect(decoded.presets == [first, second])
        #expect(WinampEQF.gainDB(fromWinamp: 0) == 12)
        #expect(WinampEQF.gainDB(fromWinamp: 63) == -12)
        #expect(throws: WinampEQFError.self) { try WinampEQF.decode(Data("invalid".utf8)) }

        let q1 = try WinampEQF.decode(encoded, fileName: "Winamp.q1")
        #expect(q1.kind == .q1)
        #expect(q1.type == WinampEQF.fileType)
        #expect(q1.presets == [first, second])
        #expect(try WinampEQF.encode(q1) == encoded)
        #expect(WinampEQPresetFileKind(fileName: "presets/WINAMP.Q1") == .q1)

        let maximumName = String(repeating: "x", count: 256)
        let maximumNamePreset = try WinampEQPreset(name: maximumName, bands: Array(repeating: 32, count: 10), preamp: 32)
        let maximumNameData = try WinampEQF.encode(WinampEQPresetFile(presets: [maximumNamePreset], kind: .q1))
        #expect(maximumNameData.count == 31 + 257 + 11)
        #expect(try WinampEQF.decode(maximumNameData, fileName: "Winamp.q1").presets.first?.name == maximumName)

        let oversizedName = try WinampEQPreset(name: String(repeating: "x", count: 257), bands: Array(repeating: 32, count: 10), preamp: 32)
        #expect(throws: WinampEQFError.self) {
            try WinampEQF.encode(WinampEQPresetFile(presets: [oversizedName]))
        }
    }

    @Test func declaredCursorResourcesResolveThroughCatalog() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let xml = "<skin><cursor id=\"pointer\" file=\"cursors/hand.cur\"/></skin>"
        let catalog = WinampCursorCatalog(files: [
            "skin.xml": Data(xml.utf8),
            "cursors/hand.cur": png
        ])
        #expect(catalog.declarations["pointer"]?.resourcePath == "cursors/hand.cur")
        #expect(throws: ANICursorError.self) { try catalog.resource(named: "missing") }
    }

    @Test @MainActor func settingsPersistLogicalPlayerFrame() throws {
        let suiteName = "Macamp.WindowHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let frame = CGRect(x: 48, y: 32, width: 275, height: 116)

        settings.savePlayerLogicalFrame(frame)

        #expect(settings.restoredPlayerLogicalFrame() == frame)
    }

    @Test @MainActor func settingsPersistAuxiliaryLogicalFrames() {
        let name = "Macamp.AuxiliaryFrame.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let frame = CGRect(x: 12, y: 34, width: 275, height: 232)
        settings.saveAuxiliaryLogicalFrame(frame, key: SettingsStore.Keys.playlistLogicalFrame)
        #expect(settings.restoredAuxiliaryLogicalFrame(key: SettingsStore.Keys.playlistLogicalFrame) == frame)
    }

    @Test @MainActor func winampWindowHostTransitionsRegionActivityAndShadeState() {
        let host = WinampSkinWindowHost(
            normalLogicalSize: CGSize(width: 100, height: 50),
            shadeLogicalSize: CGSize(width: 100, height: 14),
            scale: 2
        )
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        host.setContentView(content)

        let region = NSBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        host.regionPath = region
        host.clickThroughTransparentPixels = true
        host.clickThroughTest = { $0.x < 25 }

        #expect(content.layer?.mask != nil)
        #expect(host.acceptsInput(atLogicalPoint: CGPoint(x: 20, y: 20)))
        #expect(!host.acceptsInput(atLogicalPoint: CGPoint(x: 30, y: 20)))
        #expect(!host.acceptsInput(atLogicalPoint: CGPoint(x: 80, y: 20)))

        var activities: [WinampSkinWindowActivityState] = []
        var shadeStates: [Bool] = []
        host.onActivityStateChange = { activities.append($0) }
        host.onShadeStateChange = { shadeStates.append($0) }
        host.setSkinActive(true)
        host.setShaded(true)

        #expect(host.activityState == .active)
        #expect(host.isShaded)
        #expect(host.currentLogicalSize == CGSize(width: 100, height: 14))
        #expect(host.window.contentView?.bounds.size == CGSize(width: 200, height: 28))
        #expect(activities == [.active])
        #expect(shadeStates == [true])

        host.setShaded(false)
        host.setSkinActive(false)
        #expect(!host.isShaded)
        #expect(host.activityState == .inactive)
        #expect(shadeStates == [true, false])
        #expect(activities == [.active, .inactive])
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
            <layout id="shade" w="60" h="20">
              <layer id="shade-layer" image="background" x="0" y="0" w="60" h="20" />
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
        let group = try #require(view.liveSceneForTesting.firstHandle(for: "LeftDrawer"))
        let child = try #require(view.liveSceneForTesting.firstHandle(for: "left-layer"))
        let originalChild = try #require(view.liveSceneForTesting.worldFrame(of: child))
        #expect(originalChild.minX == 20)

        view.makiTargetChanged(objectID: "LeftDrawer", x: 50, speed: 0.05)
        try await Task.sleep(for: .milliseconds(100))
        let movedScene = view.liveSceneForTesting
        #expect(movedScene.node(group)?.localFrame.minX == 50)
        #expect(movedScene.node(child)?.localFrame.minX == 0)
        #expect(movedScene.worldFrame(of: child)?.minX == 50)
        #expect(movedScene.hitTest(CGPoint(x: 55, y: 10))?.handle == child)

        view.makiLayoutSwitched(containerID: "main", layoutID: "shade")
        let shade = view.liveSceneForTesting
        let container = try #require(shade.firstHandle(for: "main"))
        let shadeLayout = try #require(shade.layoutHandle(id: "shade", in: container))
        #expect(shade.activeLayout(for: container) == shadeLayout)
        #expect(shade.hitTest(CGPoint(x: 10, y: 10))?.handle == shade.firstHandle(for: "shade-layer"))
        #expect(shade.hitTest(CGPoint(x: 70, y: 10)) == nil)

        let host = WinampSkinWindowHost(normalLogicalSize: CGSize(width: 100, height: 40), scale: 1)
        view.windowHost = host
        view.updateScale(2)
        #expect(host.scale == 2)
        view.makiLayoutResized(objectID: "shade", frame: CGRect(x: 0, y: 0, width: 80, height: 30))
        #expect(host.currentLogicalSize == CGSize(width: 80, height: 30))
        view.makiRedock(objectID: "main", before: true)
        #expect(host.dockingState == .preparingToRedock)
        view.makiRedock(objectID: "main", before: false)
        #expect(host.dockingState == .docked)

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
        let volumeFills: [(CGRect, NSColor)] = (0..<ClassicSpriteCatalog.volumeTrackFrameCount).map { index in
            let progress = CGFloat(index) / CGFloat(ClassicSpriteCatalog.volumeTrackFrameCount - 1)
            return (
                CGRect(x: 0, y: CGFloat(index) * ClassicSpriteCatalog.volumeTrackStride, width: 68, height: ClassicSpriteCatalog.volumeTrackHeight),
                NSColor(calibratedRed: progress, green: 1 - progress, blue: 0.35 + progress * 0.5, alpha: 1)
            )
        } + [
            (CGRect(x: 15, y: 422, width: 14, height: 11), NSColor.white),
            (CGRect(x: 0, y: 422, width: 14, height: 11), NSColor.black)
        ]

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
            "volume.bmp": diagnosticPNG(size: CGSize(width: 68, height: 433), background: NSColor(calibratedWhite: 0.25, alpha: 1), fills: volumeFills)
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
    var eventNames: [String] = []
    var eventReceivers: [WasabiHandle] = []
    var eventArguments: [[MakiValue]] = []
    var actions: [WasabiHandle] = []
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
    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
        if let x { targets.append((objectID, x, speed)) }
    }
    func makiVolumeChanged(_ value: Double) { }
    func makiEQBandChanged(index: Int, value: Int) { }
    func makiRuntimeNeedsDisplay() { }
    func makiEventDispatched(receiver: WasabiHandle, name: String, arguments: MakiEventArguments) {
        eventNames.append(name)
        eventReceivers.append(receiver)
        eventArguments.append(arguments.values)
    }
    func makiButtonPressedChanged(receiver: WasabiHandle, isPressed: Bool) { }
    func makiDeclarativeButtonAction(receiver: WasabiHandle) { actions.append(receiver) }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)) }
    mutating func appendLE(_ value: UInt32) { append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff)) }
}
