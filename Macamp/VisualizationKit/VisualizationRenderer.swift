import AppKit
import Observation
import UniformTypeIdentifiers

enum BuiltInVisualization: String, CaseIterable, Identifiable, Sendable {
    case spectrum, oscilloscope, mirroredSpectrum, radialSpectrum, starfield, classicPeakHold, artworkAmbience, retroPattern, goom, avs, milkDrop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spectrum: "Spectrum Bars"
        case .oscilloscope: "Oscilloscope"
        case .mirroredSpectrum: "Mirrored Spectrum"
        case .radialSpectrum: "Radial Spectrum"
        case .starfield: "Starfield Tunnel"
        case .classicPeakHold: "Classic Peak Hold"
        case .artworkAmbience: "Album-art Ambience"
        case .retroPattern: "Retro Pattern"
        case .goom: "GOOM"
        case .avs: "AVS Studio"
        case .milkDrop: "MilkDrop"
        }
    }
}

@MainActor
final class VisualizationRenderView: NSView {
    private(set) var frameData: VisualizationAudioData = .silent
    var mode: BuiltInVisualization = .spectrum { didSet { needsDisplay = true } }
    var avsPreset: AVSPreset? { didSet { needsDisplay = true } }
    var intensity: CGFloat = 0.7 { didSet { needsDisplay = true } }
    private var peakHold = PeakHoldEnvelope()
    private var animationPhase: CGFloat = 0
    var peakHoldBands: [Float] { peakHold.values }
    override var isFlipped: Bool { true }

    func update(_ data: VisualizationAudioData) {
        frameData = data
        if data.analysisFrame != nil { animationPhase += 0.045 }
        peakHold.update(data.analysisFrame?.bands)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.015, green: 0.02, blue: 0.035, alpha: 0.96).setFill(); bounds.fill()
        guard let frame = frameData.analysisFrame, !frame.bands.isEmpty else {
            if case let .unavailable(reason) = frameData { drawUnavailable(reason) }
            else { drawPaused() }
            return
        }
        switch mode {
        case .spectrum: drawSpectrum(frame.bands, mirrored: false, peaks: false)
        case .mirroredSpectrum: drawSpectrum(frame.bands, mirrored: true, peaks: false)
        case .classicPeakHold: drawSpectrum(frame.bands, peakBands: peakHold.values, mirrored: false, peaks: true)
        case .oscilloscope: drawWaveform(frame.waveform)
        case .radialSpectrum: drawRadial(frame.bands)
        case .starfield: drawStarfield(frame)
        case .artworkAmbience: drawAmbience(frame.bands)
        case .retroPattern: drawPattern(frame)
        case .goom: drawGoom(frame.bands)
        case .avs: avsPreset?.draw(frame, in: bounds) ?? drawSpectrum(frame.bands, mirrored: false, peaks: false)
        case .milkDrop: drawSpectrum(frame.bands, mirrored: false, peaks: false)
        }
        drawBadge()
    }

    private func drawSpectrum(_ bands: [Float], peakBands: [Float]? = nil, mirrored: Bool, peaks showPeaks: Bool) {
        let gap: CGFloat = 2
        let width = max(1, (bounds.width - CGFloat(bands.count - 1) * gap) / CGFloat(bands.count))
        for (index, value) in bands.enumerated() {
            let height = CGFloat(value) * (mirrored ? bounds.height * 0.45 : bounds.height * 0.82)
            let x = CGFloat(index) * (width + gap)
            let color = NSColor(calibratedHue: 0.34 - CGFloat(value) * 0.25, saturation: 0.9, brightness: 0.95, alpha: 0.92)
            color.setFill()
            if mirrored {
                CGRect(x: x, y: bounds.midY - height, width: width, height: height * 2).fill()
            } else {
                CGRect(x: x, y: bounds.maxY - height, width: width, height: height).fill()
                if showPeaks, let peakBands, peakBands.indices.contains(index) {
                    let y = bounds.maxY - CGFloat(peakBands[index]) * bounds.height * 0.82
                    CGRect(x: x, y: y, width: width, height: 2).fill()
                }
            }
        }
    }

    private func drawWaveform(_ samples: [Float]) {
        guard samples.count > 1 else { return }
        let path = NSBezierPath(); path.lineWidth = 2
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: CGFloat(index) / CGFloat(samples.count - 1) * bounds.width, y: bounds.midY + CGFloat(value) * bounds.height * 0.42)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        NSColor.systemGreen.setStroke(); path.stroke()
    }

    private func drawRadial(_ bands: [Float]) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let inner = min(bounds.width, bounds.height) * 0.17
        for (index, value) in bands.enumerated() {
            let angle = CGFloat(index) / CGFloat(bands.count) * .pi * 2
            let path = NSBezierPath()
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            let radius = inner + CGFloat(value) * min(bounds.width, bounds.height) * 0.32
            path.line(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            NSColor(calibratedHue: CGFloat(index) / CGFloat(bands.count), saturation: 0.75, brightness: 1, alpha: 0.9).setStroke(); path.lineWidth = 2; path.stroke()
        }
    }

    private func drawStarfield(_ frame: VisualizationAnalysisFrame) {
        for index in 0..<120 {
            let n = UInt64(index) &* 6364136223846793005
            let angle = CGFloat(n % 6283) / 1000
            let depth = CGFloat((n >> 12) % 1000) / 1000
            let beat = CGFloat(frame.bands[index % frame.bands.count])
            let radius = depth * min(bounds.width, bounds.height) * (0.3 + beat * 0.55)
            let point = CGPoint(x: bounds.midX + cos(angle) * radius, y: bounds.midY + sin(angle) * radius)
            NSColor(calibratedWhite: 0.55 + depth * 0.45, alpha: 0.8).setFill()
            CGRect(x: point.x, y: point.y, width: 1 + depth * 3, height: 1 + depth * 3).fill()
        }
    }

    private func drawAmbience(_ bands: [Float]) {
        let average = CGFloat(bands.reduce(0, +)) / CGFloat(max(1, bands.count))
        for ring in stride(from: 12, through: 1, by: -1) {
            let inset = CGFloat(ring) * 7
            NSColor(calibratedHue: 0.55 + average * 0.25, saturation: 0.75, brightness: 0.3 + average * 0.7, alpha: 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 22, yRadius: 22).fill()
        }
    }

    private func drawPattern(_ frame: VisualizationAnalysisFrame) {
        for index in 0..<24 {
            let value = CGFloat(frame.bands[(index * 2) % frame.bands.count])
            let inset = CGFloat(index) * 6 + value * 18
            NSColor(calibratedHue: CGFloat(index) / 24, saturation: 0.85, brightness: 0.9, alpha: 0.35).setStroke()
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset * 0.6)); path.lineWidth = 1.5; path.stroke()
        }
    }

    private func drawGoom(_ bands: [Float]) {
        guard !bands.isEmpty else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.18
        let strength = min(max(intensity, 0), 1)
        let count = 192

        for layer in (0..<5).reversed() {
            let depth = CGFloat(layer + 1) / 5
            let path = NSBezierPath()
            for step in 0...count {
                let progress = CGFloat(step) / CGFloat(count)
                let bandIndex = min(bands.count - 1, Int(progress * CGFloat(bands.count)))
                let level = CGFloat(bands[bandIndex].isFinite ? bands[bandIndex] : 0)
                let angle = progress * .pi * 2
                let lobe = sin(angle * CGFloat(5 + layer * 2) + animationPhase * (1 + depth))
                let audioPush = level * strength * min(bounds.width, bounds.height) * 0.28
                let wave = radius * (0.34 + depth * 0.1) * lobe * strength
                let pointRadius = radius + audioPush * (0.35 + depth * 0.65) + wave
                let point = CGPoint(x: center.x + cos(angle) * pointRadius, y: center.y + sin(angle) * pointRadius)
                step == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.close()
            NSColor(calibratedHue: (0.78 + animationPhase * 0.025 + depth * 0.16).truncatingRemainder(dividingBy: 1), saturation: 0.86, brightness: 0.94, alpha: 0.13 + depth * 0.1).setFill()
            path.fill()
            NSColor(calibratedHue: (0.48 + animationPhase * 0.018 + depth * 0.2).truncatingRemainder(dividingBy: 1), saturation: 0.72, brightness: 1, alpha: 0.24 + depth * 0.1).setStroke()
            path.lineWidth = 1 + depth * 2.5
            path.stroke()
        }
    }

    private func drawPaused() {
        let text = "VISUALIZATION PAUSED"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        drawBadge()
    }

    private func drawUnavailable(_ reason: String) {
        let title = "VISUALIZATION UNAVAILABLE"
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let reasonAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let titleSize = title.size(withAttributes: titleAttributes)
        let reasonSize = reason.size(withAttributes: reasonAttributes)
        title.draw(at: CGPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY - 12), withAttributes: titleAttributes)
        reason.draw(at: CGPoint(x: bounds.midX - reasonSize.width / 2, y: bounds.midY + 5), withAttributes: reasonAttributes)
    }

    private func drawBadge() {
        "LOCAL PCM • POST-EQ".draw(at: CGPoint(x: 10, y: 9), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.systemGreen])
    }
}

@MainActor
@Observable
final class VisualizationFrameStore {
    private(set) var data: VisualizationAudioData = .unavailable("This playback route does not expose PCM audio.")
    private(set) var inlineMode: InlineVisualizationMode = .spectrum
    var avsPreset: AVSPreset?
    private var peakHold = PeakHoldEnvelope()
    var peakHoldBands: [Float] { peakHold.values }
    private var framesTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?

    func update(_ value: VisualizationAudioData) {
        data = value
        peakHold.update(value.analysisFrame?.bands)
    }

    func unavailable(_ reason: String) { update(.unavailable(reason)) }

    func selectInlineMode(_ mode: InlineVisualizationMode) { inlineMode = mode }

    func toggleInlineMode() {
        inlineMode = inlineMode == .spectrum ? .waveform : .spectrum
    }

    func start(source: LocalPCMAudioAnalysisSource, coordinator: PlaybackCoordinator) {
        guard framesTask == nil else { return }
        framesTask = Task {
            try? await source.start()
            for await frame in source.frames() {
                guard !Task.isCancelled else { break }
                guard coordinator.activeProviderID == .localMedia,
                      coordinator.capabilities.contains(.pcmAudio),
                      coordinator.state.isPlaying else { continue }
                update(frame)
            }
        }
        routeTask = Task {
            while !Task.isCancelled {
                if coordinator.activeProviderID != .localMedia || !coordinator.capabilities.contains(.pcmAudio) {
                    unavailable(coordinator.activeProviderID == .localMedia
                        ? "Start local file playback to analyze post-EQ PCM."
                        : "The active playback provider does not expose decoded PCM.")
                } else if !coordinator.state.isPlaying {
                    update(.silent)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

@MainActor
final class VisualizationWindowController: NSWindowController, NSWindowDelegate {
    private let source: LocalPCMAudioAnalysisSource
    private let coordinator: PlaybackCoordinator
    private let visualizationFrames: VisualizationFrameStore
    private let renderView = VisualizationRenderView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
    private let contentView = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 396))
    private let presetControls = NSStackView()
    private let presetPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetCyclingButton = NSButton(checkboxWithTitle: "Cycle", target: nil, action: nil)
    private let settings: SettingsStore
    private let presetStore: MilkDropPresetStore
    private let avsPresetStore: AVSPresetStore
    private let relatedWindows: () -> [NSWindow]
    private let docking = WindowDockingController()
    private var customMilkDropPresets: [MilkDropPreset] = []
    private var customAVSPresets: [AVSPreset] = []
    private var presetImportWarnings: [String] = []
    private var avsPresetImportWarnings: [String] = []
    private var milkDropTextureRevision = 0
    private var milkDropTexturePayloadCache: [String: String] = [:]
    private var framesTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var presetCycleTask: Task<Void, Never>?
    private var milkDrop: MilkDropView?
    private var milkDropFailed = false

    init(
        source: LocalPCMAudioAnalysisSource,
        coordinator: PlaybackCoordinator,
        visualizationFrames: VisualizationFrameStore,
        settings: SettingsStore,
        presetStore: MilkDropPresetStore = MilkDropPresetStore(),
        avsPresetStore: AVSPresetStore = AVSPresetStore(),
        relatedWindows: @escaping () -> [NSWindow] = { [] }
    ) {
        self.source = source; self.coordinator = coordinator; self.visualizationFrames = visualizationFrames; self.settings = settings
        self.presetStore = presetStore; self.avsPresetStore = avsPresetStore; self.relatedWindows = relatedWindows
        let storedPresets = presetStore.allPresets()
        customMilkDropPresets = storedPresets.presets
        presetImportWarnings = storedPresets.warnings
        let storedAVSPresets = avsPresetStore.allPresets()
        customAVSPresets = storedAVSPresets.presets
        avsPresetImportWarnings = storedAVSPresets.warnings
        renderView.mode = BuiltInVisualization(rawValue: settings.selectedVisualization) ?? .spectrum
        renderView.avsPreset = customAVSPresets.indices.contains(settings.selectedAVSPreset) ? customAVSPresets[settings.selectedAVSPreset] : nil
        visualizationFrames.avsPreset = renderView.mode == .avs ? renderView.avsPreset : nil
        renderView.intensity = CGFloat(settings.visualizationIntensity)
        let window = NSWindow(contentRect: contentView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Macamp Visualization"
        window.contentView = contentView
        window.minSize = CGSize(width: 320, height: 180)
        window.setFrameAutosaveName("MacampVisualizationWindow")
        super.init(window: window)
        window.delegate = self
        configurePresetControls()
        updatePresetControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.close() }
        else { show() }
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
            start()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func select(_ mode: BuiltInVisualization) {
        settings.selectedVisualization = mode.rawValue
        renderView.mode = mode
        presetControls.isHidden = !mode.usesPresetControls
        milkDropFailed = false
        window?.title = "Macamp Visualization"
        if mode != .milkDrop { stopMilkDrop() }
        updatePresetControls()
        if mode == .avs { renderView.avsPreset = selectedAVSPreset }
        visualizationFrames.avsPreset = mode == .avs ? selectedAVSPreset : nil
    }

    func selectMilkDropPreset(at index: Int) {
        guard (0..<milkDropPresetCount).contains(index) else { return }
        settings.selectedMilkDropPreset = index
        select(.milkDrop)
        show()
    }

    var milkDropPresetTitles: [String] {
        MilkDropView.presets + customMilkDropPresets.map(\.title)
    }

    var milkDropPresetCount: Int { MilkDropView.presets.count + customMilkDropPresets.count }

    var milkDropImportWarnings: [String] { presetImportWarnings }

    var avsPresetTitles: [String] { customAVSPresets.map(\.title) }
    var avsImportWarnings: [String] { avsPresetImportWarnings }

    private var selectedAVSPreset: AVSPreset? {
        customAVSPresets.indices.contains(settings.selectedAVSPreset) ? customAVSPresets[settings.selectedAVSPreset] : nil
    }

    func selectAVSPreset(at index: Int) {
        guard customAVSPresets.indices.contains(index) else { return }
        settings.selectedAVSPreset = index
        renderView.avsPreset = selectedAVSPreset
        select(.avs)
        show()
    }

    func importAVSPresets() {
        let panel = NSOpenPanel()
        panel.title = "Import AVS Presets"
        panel.allowedContentTypes = [UTType(filenameExtension: "avs") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let imported = avsPresetStore.importPresets(from: panel.urls)
        let all = avsPresetStore.allPresets()
        customAVSPresets = all.presets
        avsPresetImportWarnings = imported.warnings + all.warnings
        updatePresetControls()
        guard imported.count > 0, !customAVSPresets.isEmpty else { return }
        settings.selectedAVSPreset = 0
        selectAVSPreset(at: settings.selectedAVSPreset)
    }

    func previousAVSPreset() { stepAVSPreset(by: -1) }
    func nextAVSPreset() { stepAVSPreset(by: 1) }

    private func stepAVSPreset(by offset: Int) {
        guard !customAVSPresets.isEmpty else { return }
        let selected = min(max(settings.selectedAVSPreset, 0), customAVSPresets.count - 1)
        selectAVSPreset(at: (selected + offset + customAVSPresets.count) % customAVSPresets.count)
    }

    func importMilkDropPresets() {
        let panel = NSOpenPanel()
        panel.title = "Import MilkDrop Presets"
        panel.allowedContentTypes = [UTType(filenameExtension: "milk") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let result = presetStore.importFiles(panel.urls)
        let all = presetStore.allPresets()
        customMilkDropPresets = all.presets
        presetImportWarnings = result.warnings + all.warnings
        updatePresetControls()
        settings.selectedMilkDropPreset = settings.selectedMilkDropPreset
        guard !result.presets.isEmpty else { return }
        settings.selectedMilkDropPreset = MilkDropView.presets.count
        select(.milkDrop)
        show()
    }

    func importMilkDropTextures() {
        let panel = NSOpenPanel()
        panel.title = "Import MilkDrop Textures"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let result = presetStore.importTextures(panel.urls)
        let all = presetStore.allPresets()
        presetImportWarnings = result.warnings + all.warnings
        if !result.names.isEmpty {
            milkDropTextureRevision += 1
            milkDropTexturePayloadCache.removeAll()
        }
    }

    func previousMilkDropPreset() { stepMilkDropPreset(by: -1) }
    func nextMilkDropPreset() { stepMilkDropPreset(by: 1) }

    private func stepMilkDropPreset(by offset: Int) {
        guard milkDropPresetCount > 0 else { return }
        let selected = min(max(settings.selectedMilkDropPreset, 0), milkDropPresetCount - 1)
        selectMilkDropPreset(at: (selected + offset + milkDropPresetCount) % milkDropPresetCount)
    }

    func applySettings() {
        source.configure(frameRate: settings.visualizationFrameRate)
        renderView.intensity = CGFloat(settings.visualizationIntensity)
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        stopMilkDrop()
        milkDropFailed = false
        window?.title = "Macamp Visualization"
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = window.screen else { return }
        let others = relatedWindows().filter { $0 !== window && $0.isVisible }
        let origin = docking.snappedOrigin(for: window.frame, near: others.map(\.frame), screen: screen.visibleFrame, scale: 1)
        if abs(origin.x - window.frame.origin.x) > 0.5 || abs(origin.y - window.frame.origin.y) > 0.5 {
            window.setFrameOrigin(origin)
        }
        docking.update(window: window)
    }

    private func configurePresetControls() {
        contentView.addSubview(renderView)
        presetControls.orientation = .horizontal
        presetControls.alignment = .centerY
        presetControls.distribution = .fill
        presetControls.spacing = 8
        presetControls.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        let previous = NSButton(title: "Previous", target: self, action: #selector(previousPresetAction))
        let next = NSButton(title: "Next", target: self, action: #selector(nextPresetAction))
        presetPicker.target = self
        presetPicker.action = #selector(presetPickerAction(_:))
        presetControls.addArrangedSubview(previous)
        presetControls.addArrangedSubview(presetPicker)
        presetControls.addArrangedSubview(next)
        presetCyclingButton.target = self
        presetCyclingButton.action = #selector(presetCyclingAction(_:))
        presetCyclingButton.state = settings.milkDropPresetCycling ? .on : .off
        presetControls.addArrangedSubview(presetCyclingButton)
        contentView.addSubview(presetControls)
        for view in [renderView, presetControls] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            presetControls.topAnchor.constraint(equalTo: contentView.topAnchor),
            presetControls.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            presetControls.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            presetControls.heightAnchor.constraint(equalToConstant: 36),
            renderView.topAnchor.constraint(equalTo: presetControls.bottomAnchor),
            renderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func updatePresetControls() {
        presetPicker.removeAllItems()
        let titles = renderView.mode == .avs ? avsPresetTitles : milkDropPresetTitles
        presetPicker.addItems(withTitles: titles)
        let requested = renderView.mode == .avs ? settings.selectedAVSPreset : settings.selectedMilkDropPreset
        let selected = min(max(requested, 0), max(0, titles.count - 1))
        presetPicker.selectItem(at: selected)
        presetControls.isHidden = !renderView.mode.usesPresetControls
    }

    @objc private func previousPresetAction() {
        if renderView.mode == .avs { previousAVSPreset() } else { previousMilkDropPreset() }
    }
    @objc private func nextPresetAction() {
        if renderView.mode == .avs { nextAVSPreset() } else { nextMilkDropPreset() }
    }
    @objc private func presetPickerAction(_ sender: NSPopUpButton) {
        if renderView.mode == .avs { selectAVSPreset(at: sender.indexOfSelectedItem) }
        else { selectMilkDropPreset(at: sender.indexOfSelectedItem) }
    }
    @objc private func presetCyclingAction(_ sender: NSButton) {
        settings.milkDropPresetCycling = sender.state == .on
        updatePresetCycling()
    }

    private func start() {
        applySettings()
        updatePresetCycling()
        framesTask?.cancel()
        framesTask = Task { [weak self] in
            guard let stream = self?.source.frames() else { return }
            for await frame in stream {
                guard !Task.isCancelled else { break }
                guard let self, self.canUsePCMRoute, self.coordinator.state.isPlaying else { continue }
                self.display(frame)
            }
        }
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.canUsePCMRoute {
                    let reason = self.coordinator.activeProviderID == .localMedia
                        ? "Start local file playback to analyze post-EQ PCM."
                        : "The active playback provider does not expose decoded PCM."
                    self.display(.unavailable(reason))
                } else if !self.coordinator.state.isPlaying {
                    self.display(.silent)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stop() {
        framesTask?.cancel(); framesTask = nil
        routeTask?.cancel(); routeTask = nil
        presetCycleTask?.cancel(); presetCycleTask = nil
    }

    private func updatePresetCycling() {
        presetCycleTask?.cancel()
        presetCycleTask = nil
        guard settings.milkDropPresetCycling else { return }
        presetCycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                guard self.window?.isVisible == true else { continue }
                if self.renderView.mode == .milkDrop { self.nextMilkDropPreset() }
                else if self.renderView.mode == .avs { self.nextAVSPreset() }
            }
        }
    }

    private func display(_ data: VisualizationAudioData) {
        renderView.update(data)
        guard window?.isMiniaturized == false, renderView.mode == .milkDrop, !milkDropFailed,
              let samples = data.analysisFrame?.pcm, !samples.isEmpty else {
            milkDrop?.webView.isHidden = true
            return
        }
        if milkDrop == nil {
            guard let view = MilkDropView(onFailure: { [weak self] in self?.handleMilkDropFailure() }) else {
                handleMilkDropFailure()
                return
            }
            view.webView.frame = renderView.bounds
            view.webView.autoresizingMask = [.width, .height]
            renderView.addSubview(view.webView)
            milkDrop = view
        }
        milkDrop?.webView.isHidden = false
        let preset = settings.selectedMilkDropPreset
        let index = (0..<MilkDropView.presets.count + customMilkDropPresets.count).contains(preset) ? preset : 0
        let customPreset = customMilkDropPresets.indices.contains(index - MilkDropView.presets.count)
            ? customMilkDropPresets[index - MilkDropView.presets.count]
            : nil
        let customJSON = customPreset?.rendererJSON
        let presetKey: String
        let textureJSON: String?
        if let customPreset {
            presetKey = "custom:\(customPreset.id):\(milkDropTextureRevision)"
            if let cached = milkDropTexturePayloadCache[customPreset.id] {
                textureJSON = cached
            } else {
                let payload = presetStore.texturePayload(for: customPreset.textureNames)
                milkDropTexturePayloadCache[customPreset.id] = payload
                textureJSON = payload
            }
        } else {
            presetKey = "builtin:\(index):\(milkDropTextureRevision)"
            textureJSON = nil
        }
        milkDrop?.render(samples: samples, presetIndex: index, customPresetJSON: customJSON, presetKey: presetKey, customTextureJSON: textureJSON)
    }

    private func stopMilkDrop() {
        milkDrop?.stop()
        milkDrop?.webView.removeFromSuperview()
        milkDrop = nil
    }

    private func handleMilkDropFailure() {
        stopMilkDrop()
        milkDropFailed = true
        window?.title = "Macamp Visualization — MilkDrop unavailable"
    }

    private var canUsePCMRoute: Bool {
        coordinator.activeProviderID == .localMedia && coordinator.capabilities.contains(.pcmAudio)
    }
}

extension VisualizationAudioData {
    var analysisFrame: VisualizationAnalysisFrame? {
        switch self {
        case let .analysis(frame): frame
        case let .simulated(frame): VisualizationAnalysisFrame(bands: frame.bands, waveform: frame.waveform)
        default: nil
        }
    }
}

private extension BuiltInVisualization {
    var usesPresetControls: Bool { self == .milkDrop || self == .avs }
}
