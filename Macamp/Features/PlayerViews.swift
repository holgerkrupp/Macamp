import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingBar: View {
    let dependencies: DependencyContainer

    var body: some View {
        let playback = dependencies.playback
        HStack(spacing: 14) {
            ArtworkView(reference: playback.state.currentItem?.artwork).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.state.currentItem?.title ?? "Nothing Playing").lineLimit(1)
                Text(playback.state.currentItem?.artist ?? playback.activeProviderName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 165, alignment: .leading)
            Button { Task { await playback.previous() } } label: { Image(systemName: "backward.fill") }.disabled(!playback.capabilities.contains(.previous))
            Button { Task { playback.state.isPlaying ? await playback.pause() : await playback.play() } } label: { Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                .disabled(!playback.capabilities.contains(playback.state.isPlaying ? .pause : .playback))
            Button { Task { await playback.next() } } label: { Image(systemName: "forward.fill") }.disabled(!playback.capabilities.contains(.next))
            if playback.capabilities.contains(.seek), let duration = playback.state.duration {
                Slider(value: Binding(get: { playback.state.elapsed.secondsValue }, set: { value in Task { await playback.seek(to: .seconds(value)) } }), in: 0...max(1, duration.secondsValue))
                Text(time(playback.state.elapsed)).font(.caption.monospacedDigit()).frame(width: 42)
            } else { Spacer() }
            if playback.capabilities.contains(.applicationVolume) {
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { playback.state.volume }, set: { value in Task { await playback.setVolume(value) } }), in: 0...1).frame(width: 90)
            }
            Menu { ForEach(RepeatMode.allCases, id: \.self) { mode in Button(mode.rawValue.capitalized) { Task { await playback.setRepeat(mode) } } } } label: { Image(systemName: playback.state.repeatMode == .one ? "repeat.1" : "repeat") }
                .disabled(!playback.capabilities.contains(.repeat))
        }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThickMaterial)
    }

    private func time(_ duration: Duration) -> String { let value = Int(duration.secondsValue); return String(format: "%d:%02d", value / 60, value % 60) }
}

struct LocalMediaView: View {
    let dependencies: DependencyContainer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Files").font(.largeTitle.bold())
                    Text("Play MP3 files and M3U/M3U8 playlists. Folder access is remembered securely.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if dependencies.localMedia.isImporting { ProgressView().controlSize(.small) }
                Button("Add Files or Playlist…") { importFiles() }
                Button("Add Folder…") { importFolder() }.buttonStyle(.borderedProminent)
            }.padding(24)

            if dependencies.localMedia.libraryItems.isEmpty {
                ContentUnavailableView(
                    "No local music",
                    systemImage: "internaldrive",
                    description: Text("Choose MP3 files, a playlist, or a folder containing your music.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("\(dependencies.localMedia.libraryItems.count) Tracks") {
                        ForEach(dependencies.localMedia.libraryItems) { item in
                            TrackRow(
                                item: item,
                                isCurrent: dependencies.playback.state.currentItem?.id == item.id
                            ) {
                                let items = dependencies.localMedia.libraryItems
                                guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                                dependencies.selectProvider(.localMedia)
                                Task { await dependencies.playback.play(items: items, startingAt: index) }
                            }
                        }
                    }
                    if !dependencies.localMedia.importWarnings.isEmpty {
                        Section("Import Warnings") {
                            ForEach(dependencies.localMedia.importWarnings, id: \.self) {
                                Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Local Files")
        .task { await dependencies.localMedia.restoreLibrary() }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await dependencies.importLocalMedia(urls) }
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItem {
                Button("Forget Local Library", role: .destructive) {
                    Task { await dependencies.localMedia.clearLibrary() }
                }
                .disabled(dependencies.localMedia.libraryItems.isEmpty)
            }
        }
    }

    private func importFiles() {
        let urls = LocalMediaImportPanel.chooseFilesAndPlaylists()
        guard !urls.isEmpty else { return }
        Task { await dependencies.importLocalMedia(urls) }
    }

    private func importFolder() {
        let urls = LocalMediaImportPanel.chooseFolder()
        guard !urls.isEmpty else { return }
        Task { await dependencies.importLocalMedia(urls) }
    }
}

@MainActor
enum LocalMediaImportPanel {
    static func chooseFilesAndPlaylists() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose MP3 Files or Playlists"
        panel.allowedContentTypes = ["mp3", "m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Choose a Music Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}

struct SkinManagerView: View {
    let dependencies: DependencyContainer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) { Text("Winamp Skins").font(.title.bold()); Text("Safe .wsz, .wal, and content-detected .zip imports with sandboxed MAKI compatibility.").foregroundStyle(.secondary) }
                Spacer()
                Button("Import Skin…", action: importSkin).buttonStyle(.borderedProminent)
            }
            HStack(alignment: .top, spacing: 20) {
                SkinPreview(catalog: dependencies.skins.activeCatalog).frame(width: 550, height: 232)
                Form {
                    LabeledContent("Active", value: dependencies.skins.activeCatalog.name)
                    LabeledContent("Format", value: dependencies.skins.activeCatalog.format.displayName)
                    Picker("Scale", selection: Binding(get: { dependencies.settings.skinScale }, set: { dependencies.settings.skinScale = $0; dependencies.classicPlayer.applySettings() })) { ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) } }
                    Toggle("Window shadow", isOn: Binding(get: { dependencies.settings.playerShadow }, set: { dependencies.settings.playerShadow = $0; dependencies.classicPlayer.applySettings() }))
                    Toggle("Click through transparent pixels", isOn: Binding(get: { dependencies.settings.clickThroughTransparentPixels }, set: { dependencies.settings.clickThroughTransparentPixels = $0 }))
                    Button("Use bundled fallback") { dependencies.skins.useFallback(); dependencies.classicPlayer.applySettings(); dependencies.classicPlayer.show() }
                    Button("Show Classic Player") { dependencies.classicPlayer.toggle() }
                }.formStyle(.grouped)
            }
            if let error = dependencies.skins.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            List {
                ForEach(Array(dependencies.skins.skins), id: \.id) { skin in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(skin.name)
                            Text(skin.format.displayName).font(.caption).foregroundStyle(.secondary)
                            SkinValidationLabel(report: skin.report)
                        }
                        Spacer()
                        Button(dependencies.skins.activeSkinID == skin.id ? "Active" : "Use") {
                            Task {
                                await dependencies.skins.use(skin)
                                dependencies.classicPlayer.applySettings()
                                dependencies.classicPlayer.show()
                            }
                        }
                        .disabled(dependencies.skins.activeSkinID == skin.id || !skin.report.isValid)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([skin.originalArchive]) }
                        Button(role: .destructive) {
                            let wasActive = dependencies.skins.activeSkinID == skin.id
                            dependencies.skins.delete(skin)
                            if wasActive { dependencies.classicPlayer.applySettings(); dependencies.classicPlayer.show() }
                        } label: { Image(systemName: "trash") }
                    }
                }
            }.frame(minHeight: 120)
        }.padding(24).navigationTitle("Skins")
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { ["wsz", "wal", "zip"].contains($0.pathExtension.lowercased()) }
            for url in supported { Task { await dependencies.skins.importSkin(from: url); dependencies.classicPlayer.applySettings(); dependencies.classicPlayer.show() } }
            return !supported.isEmpty
        }
    }

    private func importSkin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["wsz", "wal", "zip"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await dependencies.skins.importSkin(from: url); dependencies.classicPlayer.applySettings(); dependencies.classicPlayer.show() }
    }
}

private struct SkinValidationLabel: View {
    let report: SkinValidationReport
    var body: some View {
        Text(report.isValid ? "Valid with \(report.warnings.count) warnings" : report.errors.joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(report.isValid ? Color.secondary : Color.red)
    }
}

struct SkinPreview: NSViewRepresentable {
    let catalog: SkinAssetCatalog
    func makeNSView(context: Context) -> SkinPreviewSurface { SkinPreviewSurface(catalog: catalog) }
    func updateNSView(_ view: SkinPreviewSurface, context: Context) { view.catalog = catalog; view.needsDisplay = true }
}

@MainActor
final class SkinPreviewSurface: NSView {
    var catalog: SkinAssetCatalog { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(catalog: SkinAssetCatalog) {
        self.catalog = catalog
        super.init(frame: .zero)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = catalog.mainImage, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        guard scale > 0 else { return }
        let destination = CGRect(
            x: bounds.midX - image.size.width * scale / 2,
            y: bounds.midY - image.size.height * scale / 2,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        NSGraphicsContext.saveGraphicsState()
        if let regionPath = catalog.regionPath {
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: destination.minX, ty: destination.minY)
            if let transformed = regionPath.cgPath.copy(using: &transform) {
                NSBezierPath(cgPath: transformed).addClip()
            }
        }
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct VisualizationPickerView: View {
    let dependencies: DependencyContainer
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Visualizations").font(.largeTitle.bold())
            Label("Providers without decoded PCM access use deterministic simulated data. Apple Music audio is never captured.", systemImage: "info.circle.fill").foregroundStyle(.orange)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                ForEach(BuiltInVisualization.allCases) { mode in
                    Button { dependencies.visualizations.select(mode); if dependencies.visualizations.window?.isVisible != true { dependencies.visualizations.toggle() } } label: {
                        VStack(spacing: 12) { Image(systemName: icon(mode)).font(.system(size: 34)).foregroundStyle(.green); Text(mode.title).fontWeight(.semibold); Text(mode == (BuiltInVisualization(rawValue: dependencies.settings.selectedVisualization) ?? .spectrum) ? "Selected" : "Built-in").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 110).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
            HStack { Picker("Frame-rate limit", selection: Binding(get: { dependencies.settings.visualizationFrameRate }, set: { dependencies.settings.visualizationFrameRate = $0; dependencies.visualizations.applySettings() })) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.frame(width: 180); Slider(value: Binding(get: { dependencies.settings.visualizationIntensity }, set: { dependencies.settings.visualizationIntensity = $0; dependencies.visualizations.applySettings() }), in: 0...1); Text("Intensity") }
            Spacer()
        }.padding(24).navigationTitle("Visualizations")
    }
    private func icon(_ mode: BuiltInVisualization) -> String { switch mode { case .spectrum, .classicPeakHold: "chart.bar.fill"; case .oscilloscope: "waveform.path"; case .mirroredSpectrum: "arrow.up.and.down"; case .radialSpectrum: "circle.hexagongrid.fill"; case .starfield: "sparkles"; case .artworkAmbience: "photo.artframe"; case .retroPattern: "aqi.medium" } }
}

struct DiagnosticsView: View {
    let dependencies: DependencyContainer
    var body: some View {
        List {
            Section("Playback") {
                LabeledContent("Provider", value: dependencies.playback.activeProviderName)
                LabeledContent("Authorization", value: dependencies.playback.authenticationState.rawValue)
                LabeledContent("Status", value: dependencies.playback.state.status.rawValue)
                LabeledContent("Queue size", value: "\(dependencies.playback.queue.items.count)")
                LabeledContent("Capabilities", value: dependencies.playback.capabilities.labels.joined(separator: ", "))
            }
            Section("Skin") { LabeledContent("Active", value: dependencies.skins.activeCatalog.name); LabeledContent("Warnings", value: "\(dependencies.skins.activeCatalog.report.warnings.count)") }
            Section("Analysis") { LabeledContent("Source", value: "Simulated (no PCM)"); LabeledContent("Target frame rate", value: "\(dependencies.settings.visualizationFrameRate) fps"); LabeledContent("Dropped frames", value: "0") }
            Section("Recent non-sensitive errors") { if dependencies.playback.recentErrors.isEmpty { Text("None").foregroundStyle(.secondary) } else { ForEach(dependencies.playback.recentErrors, id: \.self, content: Text.init) } }
        }.navigationTitle("Diagnostics")
    }
}

struct SettingsView: View {
    let dependencies: DependencyContainer
    var body: some View {
        TabView {
            Form { Toggle("Show classic player on launch", isOn: Binding(get: { dependencies.settings.showPlayerOnLaunch }, set: { dependencies.settings.showPlayerOnLaunch = $0 })); Toggle("Keep classic player above other windows", isOn: Binding(get: { dependencies.settings.playerFloating }, set: { dependencies.settings.playerFloating = $0; dependencies.classicPlayer.applySettings() })); Text("Launch at login and menu-bar-only mode are not enabled in this milestone.").font(.caption).foregroundStyle(.secondary) }.padding().tabItem { Label("General", systemImage: "gear") }
            Form { Picker("Active provider", selection: Binding(get: { dependencies.playback.activeProviderID ?? .appleMusic }, set: { dependencies.selectProvider($0) })) { ForEach(dependencies.providerRegistry.availableDescriptors) { descriptor in Text(descriptor.displayName).tag(descriptor.id) } }; LabeledContent("Active status", value: dependencies.playback.authenticationState.rawValue); Text("Provider capabilities and account limitations are shown by Music Services. Unavailable services remain out of the connection menu until their official integration is configured.").font(.caption).foregroundStyle(.secondary) }.padding().tabItem { Label("Providers", systemImage: "dot.radiowaves.left.and.right") }
            Form { Picker("Integer scale", selection: Binding(get: { dependencies.settings.skinScale }, set: { dependencies.settings.skinScale = $0; dependencies.classicPlayer.applySettings() })) { ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) } }; Toggle("Transparent-pixel click-through", isOn: Binding(get: { dependencies.settings.clickThroughTransparentPixels }, set: { dependencies.settings.clickThroughTransparentPixels = $0 })); Toggle("Shadow", isOn: Binding(get: { dependencies.settings.playerShadow }, set: { dependencies.settings.playerShadow = $0; dependencies.classicPlayer.applySettings() })) }.padding().tabItem { Label("Skin", systemImage: "paintbrush") }
            Form { Picker("Mode", selection: Binding(get: { BuiltInVisualization(rawValue: dependencies.settings.selectedVisualization) ?? .spectrum }, set: { dependencies.visualizations.select($0) })) { ForEach(BuiltInVisualization.allCases) { Text($0.title).tag($0) } }; Text("Playback providers currently use simulated visualization data.").foregroundStyle(.orange) }.padding().tabItem { Label("Visualization", systemImage: "waveform") }
        }.padding()
    }
}
