import AppKit
import Foundation
import Testing
@testable import Macamp

@Suite
struct ModernActionMappingTests {
    @Test func parserMapsPlaylistImportAndOpenActionsSemantically() {
        let xml = """
        <WinampAbstractionLayer>
          <container id="main" default_visible="1">
            <layout id="normal" w="120" h="40">
              <button id="add-files" action="PE_Add" tooltip="Add files to playlist" x="0" y="0" w="10" h="10" />
              <button id="add-folder" action="EJECT_DIR" tooltip="Open Folder..." x="12" y="0" w="10" h="10" />
              <button id="add-playlist" action="PE_AddPlaylist" tooltip="Add Playlist..." x="24" y="0" w="10" h="10" />
              <button id="add-service" action="PE_AddService" tooltip="Add from Streaming Service..." x="30" y="0" w="10" h="10" />
              <button id="eject" action="EJECT" tooltip="Open file" x="36" y="0" w="10" h="10" />
              <button id="playlist-toggle" action="TOGGLE" param="guid:pl" tooltip="Playlist" x="48" y="0" w="10" h="10" />
              <button id="ambiguous-playlist" tooltip="Playlist" x="60" y="0" w="10" h="10" />
            </layout>
          </container>
        </WinampAbstractionLayer>
        """

        let descriptor = ModernSkinParser.parse(files: ["skin.xml": Data(xml.utf8)]).descriptor
        let actionByID = Dictionary(uniqueKeysWithValues: descriptor.controls.compactMap { control in
            control.elementID.map { ($0, control.action) }
        })

        #expect(actionByID["add-files"] == .addFiles)
        #expect(actionByID["add-folder"] == .addFolder)
        #expect(actionByID["add-playlist"] == .addPlaylist)
        #expect(actionByID["add-service"] == .addFromService)
        #expect(actionByID["eject"] == .open)
        #expect(actionByID["playlist-toggle"] == .togglePlaylist)
        #expect(actionByID["ambiguous-playlist"] == .scripted)
    }

    @Test @MainActor func handledMAKIInputSequenceSuppressesNativeClickFallback() throws {
        var scene = WasabiScene()
        let container = scene.addNode(id: "main", kind: .container, localFrame: CGRect(x: 0, y: 0, width: 40, height: 20))
        let layout = scene.addNode(id: "normal", kind: .layout, localFrame: .zero, parent: container)
        let button = scene.addNode(id: "script-owned", kind: .button, localFrame: CGRect(x: 0, y: 0, width: 20, height: 20), parent: layout)
        scene.setActiveLayout(layout, for: container)

        let program = MakiProgram(
            path: "scripts/script-owned.maki",
            version: 0x17,
            classGUIDs: [],
            functions: [MakiFunction(baseType: 0, name: "onLeftButtonDown")],
            variables: [
                MakiVariable(type: 0x101, payload: 0, isTransient: false, isStatic: true, string: nil),
                MakiVariable(type: 0x101, payload: 0, isTransient: false, isStatic: false, string: "script-owned")
            ],
            events: [MakiEvent(variableIndex: 1, functionIndex: 0, codeOffset: 0)],
            code: Data([0x02, 0x02, 0x28])
        )
        let runtime = MakiRuntime(
            programs: [program],
            bindings: [ModernMakiBinding(path: program.path, groupID: "main", parameter: nil)],
            host: ModernActionTestHost(),
            limits: .init(),
            skinID: "script-owned-action",
            persistentState: .standard,
            scene: scene
        )

        #expect(runtime.dispatchMouseDown(receiver: button, x: 4, y: 5))
        // The script owns the pointer sequence even though it has no click
        // handler. This result gates the renderer's native action fallback.
        #expect(runtime.dispatchMouseUp(receiver: button, x: 4, y: 5))
        #expect(runtime.diagnostics.isEmpty)
    }
}

@MainActor
private final class ModernActionTestHost: MakiRuntimeHost {
    func makiPlaybackStatus() -> Int { 0 }
    func makiXMLParameter(objectID: String, name: String) -> String? { nil }
    func makiVisibilityChanged(objectID: String, isVisible: Bool) {}
    func makiTargetChanged(objectID: String, x: Double, speed: Double) {}
    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {}
    func makiTargetGeometryChanged(receiver: WasabiHandle, objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {}
    func makiLayoutSwitched(containerID: String, layoutID: String) {}
    func makiLayoutResized(objectID: String, frame: CGRect) {}
    func makiRedock(objectID: String, before: Bool) {}
    func makiTargetReached(objectID: String) {}
    func makiTargetReached(receiver: WasabiHandle, objectID: String) {}
    func makiVolumeChanged(_ value: Double) {}
    func makiEQBandChanged(index: Int, value: Int) {}
    func makiEQBandValue(index: Int) -> Int { 128 }
    func makiEQPreampValue() -> Int { 128 }
    func makiEQPreampChanged(value: Int) {}
    func makiEQEnabled() -> Bool { false }
    func makiEQEnabledChanged(_ enabled: Bool) {}
    func makiRuntimeNeedsDisplay() {}
    func makiPlaybackItem() -> PlaybackItem? { nil }
    func makiElapsed() -> Duration { .zero }
    func makiDuration() -> Duration? { nil }
    func makiText(objectID: String) -> String? { nil }
    func makiSetText(objectID: String, text: String) {}
    func makiEventDispatched(receiver: WasabiHandle, name: String, arguments: MakiEventArguments) {}
    func makiButtonPressedChanged(receiver: WasabiHandle, isPressed: Bool) {}
    func makiDeclarativeButtonAction(receiver: WasabiHandle) {}
}
