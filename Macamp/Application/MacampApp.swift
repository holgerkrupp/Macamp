import AppKit
import SwiftUI

@main
struct MacampApp: App {
    @NSApplicationDelegateAdaptor(MacampApplicationDelegate.self) private var applicationDelegate
    @State private var dependencies: DependencyContainer
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false
    private let startup: ApplicationStartupCoordinator
    private let openRouter: ApplicationOpenRouter

    init() {
        let dependencies = DependencyContainer()
        let openRouter = ApplicationOpenRouter(dependencies: dependencies)
        let startup = ApplicationStartupCoordinator(dependencies: dependencies, openRouter: openRouter)
        _dependencies = State(initialValue: dependencies)
        self.startup = startup
        self.openRouter = openRouter
        MacampApplicationDelegate.openRouter = openRouter

        // Startup is app-scoped, so it still runs when the Library window is
        // suppressed and cannot be repeated by opening another scene.
        Task { @MainActor in await startup.start() }
    }

    var body: some Scene {
        WindowGroup("Library", id: "library") {
            ContentView(dependencies: dependencies)
                .frame(minWidth: 860, minHeight: 580)
                .onOpenURL { openRouter.handleURL($0) }
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            MacampCommands(dependencies: dependencies)
        }

        Settings {
            SettingsView(dependencies: dependencies)
                .frame(width: 620, height: 480)
        }

        MenuBarExtra("Macamp", systemImage: "music.note", isInserted: $showMenuBarExtra) {
            MacampMenuBarView(dependencies: dependencies)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private final class ApplicationStartupCoordinator {
    private let dependencies: DependencyContainer
    private let openRouter: ApplicationOpenRouter
    private var didStart = false

    init(dependencies: DependencyContainer, openRouter: ApplicationOpenRouter) {
        self.dependencies = dependencies
        self.openRouter = openRouter
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        dependencies.appleMusic.restoreAuthorization()
        await dependencies.skins.restoreLibrary()
        await dependencies.localMedia.restoreLibrary()
        dependencies.localMedia.restoreQueueAccess()
        await dependencies.playback.restorePersistedSession()
        if dependencies.settings.showPlayerOnLaunch {
            dependencies.classicPlayer.show()
        }
        openRouter.markReady()
    }
}

@MainActor
final class MacampApplicationDelegate: NSObject, NSApplicationDelegate {
    private static var pendingOpenFiles: [[String]] = []
    static var openRouter: ApplicationOpenRouter? {
        didSet {
            guard let openRouter else { return }
            let pending = pendingOpenFiles
            pendingOpenFiles.removeAll()
            pending.forEach { filenames in
                openRouter.handleFileURLs(filenames.map { URL(fileURLWithPath: $0) }, action: .replaceAndPlay)
            }
        }
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let openRouter = Self.openRouter {
            openRouter.handleFileURLs(urls, action: .replaceAndPlay)
        } else {
            Self.pendingOpenFiles.append(filenames)
        }
        application.reply(toOpenOrPrint: .success)
    }
}

struct MacampCommands: Commands {
    let dependencies: DependencyContainer
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open & Play…") {
                importURLs(ApplicationMediaImportPanel.chooseFilesAndFolders(), action: .replaceAndPlay)
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Add Files…") {
                importURLs(ApplicationMediaImportPanel.chooseFiles(), action: .appendToQueue)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Add Folder…") {
                importURLs(ApplicationMediaImportPanel.chooseFolder(), action: .appendToQueue)
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Button("Add Playlist…") {
                importURLs(ApplicationMediaImportPanel.choosePlaylists(), action: .appendToQueue)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Add from Streaming Service…") { dependencies.showMusicCatalogPicker() }

            Divider()

            Button("Show Library") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandMenu("Playback") {
            Button(dependencies.playback.state.isPlaying ? "Pause" : "Play") {
                Task {
                    if dependencies.playback.state.isPlaying { await dependencies.playback.pause() }
                    else { await dependencies.playback.play() }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!dependencies.playback.capabilities.contains(
                dependencies.playback.state.isPlaying ? .pause : .playback
            ))

            Button("Previous") { Task { await dependencies.playback.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!dependencies.playback.capabilities.contains(.previous))
            Button("Next") { Task { await dependencies.playback.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!dependencies.playback.capabilities.contains(.next))
            Button("Stop") { Task { await dependencies.playback.stop() } }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!dependencies.playback.capabilities.contains(.explicitStop))

            Divider()

            Menu("Shuffle") {
                ForEach(ShuffleMode.allCases, id: \.self) { mode in
                    Button {
                        Task { await dependencies.playback.setShuffle(mode) }
                    } label: {
                        if dependencies.playback.state.shuffleMode == mode {
                            Label(mode == .off ? "Off" : "On", systemImage: "checkmark")
                        } else {
                            Text(mode == .off ? "Off" : "On")
                        }
                    }
                    .disabled(!dependencies.playback.capabilities.contains(.shuffle))
                }
            }

            Menu("Repeat") {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Button {
                        Task { await dependencies.playback.setRepeat(mode) }
                    } label: {
                        if dependencies.playback.state.repeatMode == mode {
                            Label(repeatName(mode), systemImage: "checkmark")
                        } else {
                            Text(repeatName(mode))
                        }
                    }
                    .disabled(!dependencies.playback.capabilities.contains(.repeat))
                }
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Show Player") { dependencies.classicPlayer.show() }
                .keyboardShortcut("1", modifiers: [.command, .option])
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
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Show Library") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Show Menu Bar Item", isOn: $showMenuBarExtra)
        }

        CommandMenu("Skins") {
            Button("Use Bundled Fallback") {
                dependencies.skins.useFallback()
                dependencies.classicPlayer.applySettings()
                dependencies.classicPlayer.show()
            }
            Divider()
            if dependencies.skins.skins.isEmpty {
                Text("No Imported Skins").disabled(true)
            } else {
                ForEach(dependencies.skins.skins, id: \.id) { skin in
                    Button {
                        Task {
                            await dependencies.skins.use(skin)
                            dependencies.classicPlayer.applySettings()
                            dependencies.classicPlayer.show()
                        }
                    } label: {
                        if dependencies.skins.activeSkinID == skin.id {
                            Label(skin.name, systemImage: "checkmark")
                        } else {
                            Text(skin.name)
                        }
                    }
                    .disabled(!skin.report.isValid || dependencies.skins.activeSkinID == skin.id)
                }
            }
            Divider()
            Menu("Player Scale") {
                ForEach(1...4, id: \.self) { scale in
                    Button {
                        dependencies.settings.skinScale = scale
                        dependencies.classicPlayer.applySettings()
                    } label: {
                        if dependencies.settings.skinScale == scale {
                            Label("\(scale)×", systemImage: "checkmark")
                        } else {
                            Text("\(scale)×")
                        }
                    }
                }
            }
        }
    }

    private func importURLs(_ urls: [URL], action: MediaImportAction) {
        guard !urls.isEmpty else { return }
        Task { await dependencies.importMediaURLs(urls, action: action) }
    }

    private func repeatName(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}
