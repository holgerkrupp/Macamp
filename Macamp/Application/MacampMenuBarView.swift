import AppKit
import SwiftUI

struct MacampMenuBarView: View {
    let dependencies: DependencyContainer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let playback = dependencies.playback
        if let item = playback.state.currentItem {
            Text(item.title).lineLimit(1)
            if let artist = item.artist {
                Text(artist).lineLimit(1)
            }
            Divider()
        }

        Button(playback.state.isPlaying ? "Pause" : "Play") {
            Task {
                if playback.state.isPlaying { await playback.pause() }
                else { await playback.play() }
            }
        }
        .disabled(!playback.capabilities.contains(playback.state.isPlaying ? .pause : .playback))

        Button("Previous") { Task { await playback.previous() } }
            .disabled(!playback.capabilities.contains(.previous))
        Button("Next") { Task { await playback.next() } }
            .disabled(!playback.capabilities.contains(.next))
        Button("Stop") { Task { await playback.stop() } }
            .disabled(!playback.capabilities.contains(.explicitStop))

        Divider()

        Menu("Add Music") {
            Button("Open & Play…") {
                importURLs(ApplicationMediaImportPanel.chooseFilesAndFolders(), action: .replaceAndPlay)
            }
            Button("Add Files…") {
                importURLs(ApplicationMediaImportPanel.chooseFiles(), action: .appendToQueue)
            }
            Button("Add Folder…") {
                importURLs(ApplicationMediaImportPanel.chooseFolder(), action: .appendToQueue)
            }
            Button("Add Playlist…") {
                importURLs(ApplicationMediaImportPanel.choosePlaylists(), action: .appendToQueue)
            }
            Button("Add from Streaming Service…") { dependencies.showMusicCatalogPicker() }
        }

        Divider()

        Button("Show Player") { dependencies.classicPlayer.show() }
        Button("Show Playlist") { dependencies.classicPlayer.showPlaylist() }
        Button("Show Equalizer") { dependencies.classicPlayer.showEqualizer() }
        Button("Show Visualization") {
            if let window = dependencies.visualizations.window, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            } else {
                dependencies.visualizations.toggle()
            }
        }
        Button("Show Library") { openWindow(id: "library") }
        Button("Settings…") { openSettings() }
    }

    private func importURLs(_ urls: [URL], action: MediaImportAction) {
        guard !urls.isEmpty else { return }
        Task { await dependencies.importMediaURLs(urls, action: action) }
    }
}
