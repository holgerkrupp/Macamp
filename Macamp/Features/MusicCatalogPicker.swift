import AppKit
import SwiftUI

@MainActor
final class MusicCatalogPickerWindowController {
    private weak var window: NSWindow?
    private let dependencies: DependencyContainer

    init(dependencies: DependencyContainer) { self.dependencies = dependencies }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add from Streaming Service"
        window.minSize = CGSize(width: 620, height: 480)
        window.contentView = NSHostingView(rootView: MusicCatalogPickerView(dependencies: dependencies))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct MusicCatalogPickerView: View {
    let dependencies: DependencyContainer
    @State private var selectedProviderRaw = PlaybackProviderID.appleMusic.rawValue
    @State private var searchTerm = ""
    @State private var songs: [PlaybackItem] = []
    @State private var collections: [PlaybackCollection] = []
    @State private var selectedItems: Set<PlaybackItemID> = []
    @State private var isLoading = false
    @State private var message: String?

    private var providerID: PlaybackProviderID { PlaybackProviderID(rawValue: selectedProviderRaw) }
    private var descriptor: ProviderDescriptor? { dependencies.providerRegistry.descriptor(for: providerID) }
    private var providerAvailable: Bool { dependencies.playback.isProviderRegistered(providerID) }
    private var authentication: ProviderAuthenticationState {
        _ = dependencies.playback.providerReadinessRevision
        return dependencies.playback.providerAuthenticationState(for: providerID)
    }
    private var canDiscover: Bool { providerAvailable && descriptor?.availability == .available }
    private var selectedSongs: [PlaybackItem] { songs.filter { selectedItems.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Menu {
                    ForEach(serviceDescriptors) { service in
                        Button {
                            selectedProviderRaw = service.id.rawValue
                            songs = []
                            collections = []
                            selectedItems = []
                            message = nil
                        } label: {
                            Label(service.displayName, systemImage: service.iconName)
                        }
                    }
                } label: {
                    Label(descriptor?.displayName ?? "Music Service", systemImage: descriptor?.iconName ?? "music.note")
                        .frame(minWidth: 170, alignment: .leading)
                }

                TextField("Search songs, albums, or playlists", text: $searchTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                    .disabled(!canDiscover || authentication != .authorized)

                Button("Search") { Task { await search() } }
                    .disabled(!canDiscover || authentication != .authorized || searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                Button("Browse Library") { Task { await browseLibrary() } }
                    .disabled(!canDiscover || authentication != .authorized || isLoading)
            }

            VStack(alignment: .leading, spacing: 5) {
                if let descriptor {
                    Text(descriptor.accountRequirements).font(.caption).foregroundStyle(.secondary)
                    if !providerAvailable || descriptor.availability != .available {
                        Label("Unavailable: \(descriptor.notes)", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    } else if authentication != .authorized {
                        HStack {
                            Label(authenticationMessage, systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(authentication == .authorizing ? "Finish Sign In" : "Connect \(descriptor.displayName)") {
                                Task { await connect() }
                            }
                            .disabled(isLoading || authentication == .authorizing)
                        }
                    } else if providerID == .spotify, !dependencies.spotify.hasPlayableDevice {
                        Label("Tracks can be queued. Playing them requires an active Spotify Connect device and Premium playback access.", systemImage: "hifispeaker")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if providerID == .youtube {
                        Label("YouTube tracks stay queued until the official embedded player is visible. Playback will never run in the background.", systemImage: "play.rectangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            List {
                if !songs.isEmpty {
                    Section("Tracks") {
                        ForEach(songs, id: \.id) { item in
                            Toggle(isOn: selectionBinding(for: item)) {
                                HStack(spacing: 10) {
                                    ArtworkView(reference: item.artwork).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).lineLimit(1)
                                        Text([item.artist, item.albumTitle].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if let duration = item.duration { Text(Self.durationLabel(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                if !collections.isEmpty {
                    Section("Albums and Playlists") {
                        ForEach(collections) { collection in
                            HStack {
                                ArtworkView(reference: collection.artwork).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading) {
                                    Text(collection.title).lineLimit(1)
                                    Text(collection.subtitle ?? collection.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add Tracks") { Task { await addCollection(collection) } }
                                    .disabled(!providerAvailable || isLoading)
                            }
                        }
                    }
                }

                if songs.isEmpty && collections.isEmpty && !isLoading {
                    ContentUnavailableView("No results", systemImage: "music.note.list", description: Text("Search or browse a connected service to add tracks to the shared playlist."))
                }
            }
            .overlay { if isLoading { ProgressView().controlSize(.small) } }

            HStack {
                Text("Selected tracks are added after the current playlist without starting playback.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add \(selectedSongs.count) to Playlist") { addSelectedSongs() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedSongs.isEmpty || isLoading)
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 480)
    }

    private var serviceDescriptors: [ProviderDescriptor] {
        dependencies.providerRegistry.allDescriptors
            .filter { $0.id != .localMedia && $0.id != .preview }
            .sorted { $0.displayName < $1.displayName }
    }

    private var authenticationMessage: String {
        switch authentication {
        case .authorizing: "Complete sign-in in your browser, then return here."
        case .denied, .restricted: "Access was denied. You can try connecting again in Settings."
        case .unavailable: "This service is not available in the current build."
        default: "Connect this service to search its catalogue and library."
        }
    }

    private func selectionBinding(for item: PlaybackItem) -> Binding<Bool> {
        Binding(
            get: { selectedItems.contains(item.id) },
            set: { isSelected in
                if isSelected { selectedItems.insert(item.id) }
                else { selectedItems.remove(item.id) }
            }
        )
    }

    private func search() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let result = try await dependencies.playback.search(providerID: providerID, term: searchTerm)
            songs = result.songs
            collections = result.albums + result.playlists
            selectedItems = []
            if songs.isEmpty && collections.isEmpty { message = "No songs, albums, or playlists matched that search." }
        } catch { message = error.localizedDescription }
    }

    private func browseLibrary() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let library = try await dependencies.playback.loadLibrary(providerID: providerID)
            songs = library.songs
            collections = library.albums + library.playlists
            selectedItems = []
            if songs.isEmpty && collections.isEmpty { message = "This provider did not return browsable library items." }
        } catch { message = error.localizedDescription }
    }

    private func connect() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do { try await dependencies.playback.authorize(providerID: providerID) }
        catch { message = error.localizedDescription }
    }

    private func addSelectedSongs() {
        guard dependencies.playback.appendToUnifiedPlaylist(selectedSongs, placement: .append) else {
            message = dependencies.playback.state.lastError?.message ?? "The selected tracks were not added."
            return
        }
        message = "Added \(selectedSongs.count) tracks to the shared playlist. Playback was not interrupted."
        selectedItems = []
    }

    private func addCollection(_ collection: PlaybackCollection) async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let items = try await dependencies.playback.items(in: collection)
            guard !items.isEmpty else { message = "This collection has no available tracks."; return }
            guard dependencies.playback.appendToUnifiedPlaylist(items, placement: .append) else {
                message = dependencies.playback.state.lastError?.message ?? "The tracks were not added."
                return
            }
            message = "Added \(items.count) tracks from \(collection.title). Playback was not interrupted."
        } catch { message = error.localizedDescription }
    }

    private static func durationLabel(_ duration: Duration) -> String {
        let seconds = Int(duration.secondsValue)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
