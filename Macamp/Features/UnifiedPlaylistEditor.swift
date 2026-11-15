import SwiftUI

struct UnifiedPlaylistEditorView: View {
    @Bindable var playback: PlaybackCoordinator
    let chooseURLs: (ClassicPlaylistImportKind) -> [URL]
    let importURLs: ([URL], MediaImportAction) -> Void
    let addFromService: () -> Void
    let exportPlaylist: ([PlaybackItem]) -> Void
    @State private var selection: Set<PlaybackItemID> = []
    @State private var jumpToFileQuery = ""
    @State private var trackInfoItem: PlaybackItem?

    var body: some View {
        let visibleItems = playback.queue.items.enumerated().filter { _, item in
            jumpToFileQuery.isEmpty || [item.title, item.artist ?? "", item.albumTitle ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(jumpToFileQuery) }
        }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to File", text: $jumpToFileQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Jump to File")
                if !jumpToFileQuery.isEmpty {
                    Button { jumpToFileQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                        .buttonStyle(.plain)
                }
                Text("\(visibleItems.count) of \(playback.queue.items.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            List(selection: $selection) {
                ForEach(visibleItems, id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Button { Task { await playback.playQueueEntry(at: index) } } label: {
                            Image(systemName: index == playback.queue.currentIndex ? "speaker.wave.2.fill" : "play.fill")
                                .frame(width: 18)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(1).fontWeight(index == playback.queue.currentIndex ? .semibold : .regular)
                            Text([item.artist, playback.providerDisplayName(for: item.providerID), playback.availabilityLabel(for: item)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let duration = item.duration { Text(Self.time(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button("Play") { Task { await playback.playQueueEntry(at: index) } }
                        if item.providerID == .localMedia, item.mediaKind == .localFile {
                            Button("Track Info…") { trackInfoItem = item }
                        }
                        Button("Remove") { Task { await playback.removeQueueItems(at: IndexSet(integer: index)) } }
                    }
                }
                .onMove { playback.moveQueueItems(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in Task { await playback.removeQueueItems(at: offsets) } }
            }
            .overlay {
                if playback.queue.items.isEmpty {
                    ContentUnavailableView("Playlist is empty", systemImage: "music.note.list", description: Text("Add local files or tracks from a connected music service."))
                }
            }

            Divider()
            HStack {
                Menu {
                    Button("Add Files…") { add(kind: .files, action: .appendToQueue) }
                    Button("Add Folder…") { add(kind: .folder, action: .appendToQueue) }
                    Button("Add Playlist…") { add(kind: .playlist, action: .appendToQueue) }
                    Button("Add from Streaming Service…", action: addFromService)
                    Divider()
                    Menu("Sort Playlist") {
                        ForEach(UnifiedPlaylistSort.allCases, id: \.self) { key in
                            Button(key.title) { playback.sortQueue(by: key) }
                        }
                    }
                    Divider()
                    Button("Export Local Playlist…") { exportPlaylist(playback.queue.items) }
                        .disabled(playback.queue.items.isEmpty)
                    Divider()
                    Button("Insert Files Next…") { add(kind: .files, action: .insertNext) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Remove Selected") { removeSelection() }
                    .disabled(selection.isEmpty)
                Button("Clear Playlist") { Task { await playback.clearQueue(); selection.removeAll() } }
                    .disabled(playback.queue.items.isEmpty)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 600, minHeight: 420)
        .sheet(item: $trackInfoItem) { item in
            LocalTrackInfoSheet(item: item, playback: playback)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Self.acceptDroppedURLs(urls, importURLs: importURLs)
        }
    }

    @discardableResult
    static func acceptDroppedURLs(
        _ urls: [URL],
        importURLs: ([URL], MediaImportAction) -> Void
    ) -> Bool {
        let accepted = ClassicPlaylistDropPayload.acceptedURLs(from: urls)
        guard !accepted.isEmpty else { return false }
        importURLs(accepted, .appendToQueue)
        return true
    }

    private func add(kind: ClassicPlaylistImportKind, action: MediaImportAction) {
        let urls = chooseURLs(kind)
        guard !urls.isEmpty else { return }
        importURLs(urls, action)
    }

    private func removeSelection() {
        let offsets = IndexSet(playback.queue.items.indices.filter { selection.contains(playback.queue.items[$0].id) })
        Task { await playback.removeQueueItems(at: offsets); selection.removeAll() }
    }

    private static func time(_ duration: Duration) -> String {
        let seconds = Int(duration.secondsValue)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
