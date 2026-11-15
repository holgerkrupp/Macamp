import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalTrackInfoSheet: View {
    let item: PlaybackItem
    let playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(item: PlaybackItem, playback: PlaybackCoordinator) {
        self.item = item
        self.playback = playback
        _title = State(initialValue: item.title)
        _artist = State(initialValue: item.artist ?? "")
        _album = State(initialValue: item.albumTitle ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Track Info").font(.title2.bold())
            Form {
                Section("ID3 tags") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    Text("Saving asks you to select this MP3 again to grant write access. Macamp updates standard ID3v2 title, artist, and album frames while retaining other frames and audio data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Technical details") {
                    LabeledContent("File", value: item.sourceURL?.lastPathComponent ?? item.providerItemID)
                    LabeledContent("Format", value: (item.fileExtension ?? item.sourceURL?.pathExtension ?? "Unknown").uppercased())
                    if let duration = item.duration {
                        LabeledContent("Duration", value: Self.time(duration.secondsValue))
                    }
                    if let bitrate = item.bitrateKbps {
                        LabeledContent("Estimated bitrate", value: "\(bitrate) kb/s")
                    }
                    if let sampleRate = item.sampleRateHz {
                        LabeledContent("Sample rate", value: "\(sampleRate) Hz")
                    }
                    if let channels = item.channelCount {
                        LabeledContent("Channels", value: channels == 1 ? "Mono" : "\(channels) channels")
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose MP3 and Save…", action: chooseWritableMP3)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || item.fileExtension?.lowercased() != "mp3")
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
    }

    private func chooseWritableMP3() {
        guard let sourceURL = item.sourceURL ?? URL(string: item.providerItemID), sourceURL.isFileURL else {
            errorMessage = "Macamp could not find the local MP3 path."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Grant Write Access to This MP3"
        panel.message = "Select \(sourceURL.lastPathComponent) to save these tag changes."
        panel.prompt = "Grant Access"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.allowedContentTypes = [.mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        guard selectedURL.standardizedFileURL == sourceURL.standardizedFileURL else {
            errorMessage = "Choose the same file shown in Track Info."
            return
        }

        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await playback.updateLocalMP3Tags(
                    for: item,
                    authorizedURL: selectedURL,
                    title: title,
                    artist: artist,
                    album: album
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
