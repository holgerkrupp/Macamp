import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", search = "Search", library = "Library", albums = "Albums", artists = "Artists"
    case playlists = "Playlists", songs = "Songs", localFiles = "Local Files", queue = "Queue", skins = "Skins"
    case visualizations = "Visualizations", diagnostics = "Diagnostics"
    var id: Self { self }
    var icon: String {
        switch self {
        case .home: "house"; case .search: "magnifyingglass"; case .library: "music.note.house"
        case .albums: "square.stack"; case .artists: "person.2"; case .playlists: "music.note.list"
        case .songs: "music.note"; case .localFiles: "internaldrive"; case .queue: "list.number"; case .skins: "paintbrush"
        case .visualizations: "waveform.path.ecg"; case .diagnostics: "stethoscope"
        }
    }
}

struct ContentView: View {
    let dependencies: DependencyContainer
    @State private var selection: AppSection? = .home

    var body: some View {
        @Bindable var playback = dependencies.playback
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("Macamp")
            .safeAreaInset(edge: .bottom) { ProviderBadge(dependencies: dependencies) }
        } detail: {
            Group {
                switch selection ?? .home {
                case .home: HomeView(dependencies: dependencies)
                case .search: SearchView(dependencies: dependencies)
                case .library, .albums, .artists, .playlists, .songs: LibraryView(dependencies: dependencies, section: selection ?? .library)
                case .localFiles: LocalMediaView(dependencies: dependencies)
                case .queue: QueueView(dependencies: dependencies)
                case .skins: SkinManagerView(dependencies: dependencies)
                case .visualizations: VisualizationPickerView(dependencies: dependencies)
                case .diagnostics: DiagnosticsView(dependencies: dependencies)
                }
            }
            .safeAreaInset(edge: .bottom) { NowPlayingBar(dependencies: dependencies) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { dependencies.classicPlayer.toggle() } label: { Label("Classic Player", systemImage: "macwindow") }
                Button { dependencies.visualizations.toggle() } label: { Label("Visualization", systemImage: "waveform") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dependencies.appleMusic.restoreAuthorization()
        }
    }
}

struct ProviderBadge: View {
    let dependencies: DependencyContainer
    var body: some View {
        Menu {
            Button("Apple Music") { dependencies.selectProvider(.appleMusic) }
            Button("Local Files") { dependencies.selectProvider(.localMedia) }
            Button("Demo Library") { dependencies.selectProvider(.preview) }
        } label: {
            HStack { Image(systemName: "dot.radiowaves.left.and.right"); Text(dependencies.playback.activeProviderName); Spacer() }
                .padding(10).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).padding(.horizontal, 6)
    }
}

struct HomeView: View {
    let dependencies: DependencyContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Listen Now").font(.largeTitle.bold())
            if dependencies.playback.authenticationState != .authorized {
                AuthorizationCard(dependencies: dependencies)
            } else {
                ContentUnavailableView(
                    "Ready to play",
                    systemImage: "music.note",
                    description: Text(dependencies.playback.activeProviderID == .localMedia
                        ? "Choose Local Files to browse your imported music."
                        : "Search the Apple Music catalogue or browse your library.")
                )
            }
            Spacer()
        }.padding(28).navigationTitle("Home")
    }
}

struct AuthorizationCard: View {
    let dependencies: DependencyContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect Music Library", systemImage: "music.note.house.fill").font(.title2.bold())
            Text("Grant access to browse your personal music library, including cloud-library items MusicKit makes available. Apple Music catalogue playback still requires an eligible subscription.")
                .foregroundStyle(.secondary)
            Text("Status: \(dependencies.playback.authenticationState.rawValue)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Button("Allow Music Library Access") { Task { await dependencies.playback.authorize() } }
                .buttonStyle(.borderedProminent)
                .disabled(dependencies.playback.authenticationState == .authorizing || dependencies.playback.activeProviderID != .appleMusic)
        }.padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SearchView: View {
    let dependencies: DependencyContainer
    @State private var term = ""
    @State private var results = MusicSearchResults()
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search songs, albums, artists and playlists", text: $term).textFieldStyle(.plain)
                if isSearching { ProgressView().controlSize(.small) }
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).padding()
            if dependencies.playback.authenticationState != .authorized {
                AuthorizationCard(dependencies: dependencies).padding()
            } else if let error {
                ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if term.isEmpty {
                ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass", description: Text("Results use MusicKit’s supported catalogue API."))
            } else {
                List {
                    if !results.songs.isEmpty {
                        Section("Songs") { ForEach(results.songs) { item in TrackRow(item: item) { Task { await dependencies.playback.play(item: item) } } } }
                    }
                    CollectionSection(title: "Albums", collections: results.albums)
                    CollectionSection(title: "Artists", collections: results.artists)
                    CollectionSection(title: "Playlists", collections: results.playlists)
                }
            }
        }.navigationTitle("Search")
        .task(id: term) {
            guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = .init(); return }
            isSearching = true; error = nil
            do {
                try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation()
                results = try await dependencies.playback.search(term)
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            isSearching = false
        }
    }
}

struct LibraryView: View {
    let dependencies: DependencyContainer
    let section: AppSection
    @State private var library = MusicLibrarySnapshot()
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if dependencies.playback.authenticationState != .authorized { AuthorizationCard(dependencies: dependencies).padding() }
            else if loading { ProgressView("Loading library…") }
            else if let error { ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else {
                List {
                    if section == .library || section == .songs { Section("Songs") { ForEach(library.songs) { item in TrackRow(item: item) { Task { await dependencies.playback.play(item: item) } } } } }
                    if section == .library || section == .albums { CollectionSection(title: "Albums", collections: library.albums) }
                    if section == .library || section == .artists { CollectionSection(title: "Artists", collections: library.artists) }
                    if section == .library || section == .playlists { CollectionSection(title: "Playlists", collections: library.playlists) }
                }
            }
        }.navigationTitle(section.rawValue)
        .task(id: dependencies.playback.activeProviderID) {
            guard dependencies.playback.authenticationState == .authorized else { loading = false; return }
            loading = true; error = nil
            do { library = try await dependencies.playback.loadLibrary() } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct CollectionSection: View {
    let title: String
    let collections: [PlaybackCollection]
    var body: some View {
        if !collections.isEmpty { Section(title) { ForEach(collections) { collection in Label { VStack(alignment: .leading) { Text(collection.title); if let subtitle = collection.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) } } } icon: { ArtworkView(reference: collection.artwork).frame(width: 38, height: 38) } } } }
    }
}

struct QueueView: View {
    let dependencies: DependencyContainer
    var body: some View {
        List(Array(dependencies.playback.queue.items.enumerated()), id: \.element.id) { index, item in
            TrackRow(item: item, isCurrent: index == dependencies.playback.queue.currentIndex) {
                Task { await dependencies.playback.play(items: dependencies.playback.queue.items, startingAt: index) }
            }
        }.overlay { if dependencies.playback.queue.items.isEmpty { ContentUnavailableView("Queue is empty", systemImage: "list.number") } }
        .navigationTitle("Queue")
    }
}

struct TrackRow: View {
    let item: PlaybackItem
    var isCurrent = false
    let play: () -> Void
    var body: some View {
        HStack {
            ArtworkView(reference: item.artwork).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading) { Text(item.title).fontWeight(isCurrent ? .semibold : .regular); Text(item.artist ?? "Unknown artist").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let duration = item.duration { Text(format(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button(action: play) { Image(systemName: "play.fill") }.buttonStyle(.plain).accessibilityLabel("Play \(item.title)")
        }.contentShape(Rectangle()).onTapGesture(count: 2, perform: play)
    }
    private func format(_ duration: Duration) -> String { let value = Int(duration.secondsValue); return String(format: "%d:%02d", value / 60, value % 60) }
}

struct ArtworkView: View {
    let reference: ArtworkReference?
    var body: some View {
        Group {
            switch reference {
            case let .remote(url): AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { fallback }
            case let .embedded(data):
                if let image = NSImage(data: data) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { fallback }
            case let .systemSymbol(name): Image(systemName: name).resizable().scaledToFit().padding(8).background(.quaternary)
            case nil: fallback
            }
        }
    }
    private var fallback: some View { Image(systemName: "music.note").resizable().scaledToFit().padding(9).foregroundStyle(.secondary).background(.quaternary) }
}
