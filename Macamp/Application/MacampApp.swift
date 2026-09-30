import SwiftUI

@main
struct MacampApp: App {
    @State private var dependencies = DependencyContainer()

    var body: some Scene {
        WindowGroup("Macamp") {
            ContentView(dependencies: dependencies)
                .frame(minWidth: 860, minHeight: 580)
                .onOpenURL { url in
                    Task { await dependencies.playback.handleOAuthCallback(url) }
                }
                .task {
                    dependencies.appleMusic.restoreAuthorization()
                    await dependencies.skins.restoreLibrary()
                    await dependencies.localMedia.restoreLibrary()
                    await dependencies.playback.restorePersistedSession()
                    if dependencies.settings.showPlayerOnLaunch, dependencies.classicPlayer.window?.isVisible != true {
                        dependencies.classicPlayer.toggle()
                    }
                }
        }
        .commands {
            MacampCommands(dependencies: dependencies)
        }

        Settings {
            SettingsView(dependencies: dependencies)
                .frame(width: 620, height: 480)
        }
    }
}

struct MacampCommands: Commands {
    let dependencies: DependencyContainer

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Open Local Media…") {
                let urls = LocalMediaImportPanel.chooseFilesAndPlaylists()
                guard !urls.isEmpty else { return }
                Task { await dependencies.importLocalMedia(urls, playImmediately: true) }
            }.keyboardShortcut("o", modifiers: [.command])
            Divider()
            Button("Play/Pause") { Task { dependencies.playback.state.isPlaying ? await dependencies.playback.pause() : await dependencies.playback.play() } }
                .keyboardShortcut(.space, modifiers: [])
            Button("Previous") { Task { await dependencies.playback.previous() } }.keyboardShortcut(.leftArrow, modifiers: [.command])
            Button("Next") { Task { await dependencies.playback.next() } }.keyboardShortcut(.rightArrow, modifiers: [.command])
            Button("Stop") { Task { await dependencies.playback.stop() } }.keyboardShortcut(".", modifiers: [.command])
        }
        CommandMenu("Classic") {
            Button("Show Classic Player") { dependencies.classicPlayer.toggle() }.keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Show Visualization") { dependencies.visualizations.toggle() }.keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }
}
