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
        #expect(descriptor.controls.filter { $0.action == .setEqualizerBand }.count == 10)
        #expect(descriptor.controls.filter { $0.action == .setEqualizerBand }.allSatisfy { $0.orientation == .vertical })
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
        let data = Data("0,0 275,0 275,116 0,116".utf8)
        let path = RegionParser.parse(data)
        #expect(path?.bounds.width == 275)
        #expect(path?.bounds.height == 116)
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

    private func temporarySkin(entries: [(String, Data)], extension fileExtension: String = "wsz") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Synthetic.\(fileExtension)")
        try makeStoredZIP(entries).write(to: url)
        return url
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
