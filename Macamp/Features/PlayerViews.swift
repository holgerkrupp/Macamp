import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingBar: View {
    let dependencies: DependencyContainer
    @State private var showingJumpToTime = false
    @State private var jumpToTimeText = ""

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
                Button {
                    jumpToTimeText = time(playback.state.elapsed)
                    showingJumpToTime = true
                } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Jump to Time")
                .popover(isPresented: $showingJumpToTime) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Jump to Time").font(.headline)
                        TextField("m:ss", text: $jumpToTimeText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { jumpToTime() }
                        Button("Go") { jumpToTime() }
                            .disabled(Self.seconds(from: jumpToTimeText).map { $0 > duration.secondsValue } ?? true)
                    }
                    .padding(14)
                    .frame(width: 220)
                }
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

    private func jumpToTime() {
        guard let seconds = Self.seconds(from: jumpToTimeText),
              let duration = dependencies.playback.state.duration,
              seconds <= duration.secondsValue else { return }
        Task { await dependencies.playback.seek(to: .seconds(seconds)) }
        showingJumpToTime = false
    }

    private static func seconds(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        if parts.count == 1 { return Double(parts[0]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let numbers = parts.map(String.init).compactMap(Double.init)
        guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}

struct LocalMediaView: View {
    let dependencies: DependencyContainer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Files").font(.largeTitle.bold())
                    Text("Play local audio and MP4, MOV, or M4V video files. Folder access is remembered securely.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if dependencies.localMedia.isImporting { ProgressView().controlSize(.small) }
                Button("Add Files or Playlist…") { importFiles() }
                Button("Add Folder…") { importFolder() }.buttonStyle(.borderedProminent)
            }.padding(24)

            if dependencies.localMedia.libraryItems.isEmpty {
                ContentUnavailableView(
                    "No local media",
                    systemImage: "internaldrive",
                    description: Text("Choose audio, video, a playlist, or a folder containing your media.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("\(dependencies.localMedia.libraryItems.count) Items") {
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
        panel.title = "Choose Audio, Video, or Playlists"
        panel.allowedContentTypes = LocalMediaImporter.importFileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
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
    var catalog: SkinAssetCatalog {
        didSet {
            guard oldValue !== catalog else {
                needsDisplay = true
                return
            }
            resourceRegistry = catalog.format == .modern ? WasabiResourceRegistry(catalog: catalog) : nil
            cachedModernPreview = nil
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    private var resourceRegistry: WasabiResourceRegistry?
    private var cachedModernPreview: NSImage?

    init(catalog: SkinAssetCatalog) {
        self.catalog = catalog
        super.init(frame: .zero)
        resourceRegistry = catalog.format == .modern ? WasabiResourceRegistry(catalog: catalog) : nil
        wantsLayer = true
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let previewImage: NSImage?
        if catalog.format == .modern, let resourceRegistry {
            if cachedModernPreview == nil {
                let snapshot = WasabiScenePainter.previewSnapshot(for: catalog)
                cachedModernPreview = WasabiScenePainter.renderBitmapScene(
                    snapshot.scene,
                    resources: resourceRegistry,
                    size: catalog.canvasSize,
                    clipPath: catalog.regionPath,
                    activeObjectIDs: snapshot.activeObjectIDs
                ) ?? catalog.mainImage
            }
            previewImage = cachedModernPreview
        } else {
            previewImage = catalog.mainImage
        }
        guard let image = previewImage, image.size.width > 0, image.size.height > 0 else { return }
        let size = image.size
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        guard scale > 0 else { return }
        let destination = CGRect(
            x: bounds.midX - size.width * scale / 2,
            y: bounds.midY - size.height * scale / 2,
            width: size.width * scale,
            height: size.height * scale
        )
        NSGraphicsContext.saveGraphicsState()
        if catalog.format != .modern, let regionPath = catalog.regionPath {
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
            Label("Visualizations react to decoded local audio. Apple Music and other hosted sources do not expose audio for visualization. Right-click an inline skin visualization to switch between spectrum and waveform.", systemImage: "info.circle")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                ForEach(BuiltInVisualization.allCases) { mode in
                    Button { dependencies.visualizations.select(mode); if dependencies.visualizations.window?.isVisible != true { dependencies.visualizations.toggle() } } label: {
                        VStack(spacing: 12) { Image(systemName: icon(mode)).font(.system(size: 34)).foregroundStyle(.green); Text(mode.title).fontWeight(.semibold); Text(mode == (BuiltInVisualization(rawValue: dependencies.settings.selectedVisualization) ?? .spectrum) ? "Selected" : "Built-in").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 110).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
            GroupBox("MilkDrop presets") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Import .milk…") { dependencies.visualizations.importMilkDropPresets() }
                        Picker("Preset", selection: Binding(
                            get: { min(dependencies.settings.selectedMilkDropPreset, max(0, dependencies.visualizations.milkDropPresetTitles.count - 1)) },
                            set: { dependencies.visualizations.selectMilkDropPreset(at: $0) }
                        )) {
                            ForEach(Array(dependencies.visualizations.milkDropPresetTitles.enumerated()), id: \.offset) { index, title in
                                Text(title).tag(index)
                            }
                        }
                        .frame(maxWidth: 280)
                        Button("Previous") { dependencies.visualizations.previousMilkDropPreset() }
                        Button("Next") { dependencies.visualizations.nextMilkDropPreset() }
                    }
                    if !dependencies.visualizations.milkDropImportWarnings.isEmpty {
                        ForEach(dependencies.visualizations.milkDropImportWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack { Picker("Frame-rate limit", selection: Binding(get: { dependencies.settings.visualizationFrameRate }, set: { dependencies.settings.visualizationFrameRate = $0; dependencies.visualizations.applySettings() })) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.frame(width: 180); Slider(value: Binding(get: { dependencies.settings.visualizationIntensity }, set: { dependencies.settings.visualizationIntensity = $0; dependencies.visualizations.applySettings() }), in: 0...1); Text("Intensity") }
            Spacer()
        }.padding(24).navigationTitle("Visualizations")
    }
    private func icon(_ mode: BuiltInVisualization) -> String { switch mode { case .spectrum, .classicPeakHold: "chart.bar.fill"; case .oscilloscope: "waveform.path"; case .mirroredSpectrum: "arrow.up.and.down"; case .radialSpectrum: "circle.hexagongrid.fill"; case .starfield, .milkDrop: "sparkles"; case .artworkAmbience: "photo.artframe"; case .retroPattern: "aqi.medium" } }
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
            Section("Analysis") {
                LabeledContent("Source", value: dependencies.playback.capabilities.contains(.pcmAudio) ? "Decoded local PCM (post-EQ)" : "Unavailable for this source")
                LabeledContent("Target frame rate", value: "\(dependencies.settings.visualizationFrameRate) fps")
            }
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
            Form { Picker("Mode", selection: Binding(get: { BuiltInVisualization(rawValue: dependencies.settings.selectedVisualization) ?? .spectrum }, set: { dependencies.visualizations.select($0) })) { ForEach(BuiltInVisualization.allCases) { Text($0.title).tag($0) } }; Text("Visualizations are available for decoded local audio.") }.padding().tabItem { Label("Visualization", systemImage: "waveform") }
            Form {
                if let reason = dependencies.playback.audioEffectUnavailableReason,
                   !dependencies.playback.audioEffectCapabilities.contains(.pitch) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Enable pitch, tempo and reverb", isOn: Binding(
                    get: { dependencies.playback.audioEffectState.advancedEffectsEnabled },
                    set: { enabled in Task { await dependencies.playback.setAdvancedEffectsEnabled(enabled) } }
                ))
                .disabled(!dependencies.playback.audioEffectCapabilities.contains(.pitch))
                effectSlider(
                    "Pitch", value: dependencies.playback.audioEffectState.pitchSemitones,
                    range: -12...12, suffix: " st", capability: .pitch,
                    update: dependencies.playback.setPitchSemitones
                )
                effectSlider(
                    "Tempo", value: dependencies.playback.audioEffectState.tempoRate,
                    range: 0.5...2, suffix: "×", capability: .tempo,
                    update: dependencies.playback.setTempoRate
                )
                effectSlider(
                    "Reverb", value: dependencies.playback.audioEffectState.reverbMix,
                    range: 0...100, suffix: "%", capability: .reverb,
                    update: dependencies.playback.setReverbMix
                )
                effectSlider(
                    "Crossfade", value: dependencies.playback.audioEffectState.crossfadeDuration,
                    range: 0...12, suffix: " s", capability: .crossfade,
                    update: dependencies.playback.setCrossfadeDuration
                )
                Text("Effects apply to decoded local audio. Disable pitch, tempo and reverb to bypass those units; set crossfade to 0 s to turn it off. Video, radio and hosted audio keep their own playback route.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Label("Audio Effects", systemImage: "slider.horizontal.3") }
        }.padding()
    }

    private func effectSlider(
        _ title: String,
        value: Float,
        range: ClosedRange<Double>,
        suffix: String,
        capability: AudioEffectCapabilities,
        update: @escaping (Float) async -> Void
    ) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value) },
                set: { newValue in Task { await update(Float(newValue)) } }
            ), in: range)
            Text(String(format: "%.2f%@", value, suffix))
                .monospacedDigit().frame(width: 58, alignment: .trailing)
        }
        .disabled(!dependencies.playback.audioEffectCapabilities.contains(capability))
    }
}
