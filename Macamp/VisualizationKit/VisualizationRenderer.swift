import AppKit

enum BuiltInVisualization: String, CaseIterable, Identifiable, Sendable {
    case spectrum, oscilloscope, mirroredSpectrum, radialSpectrum, starfield, classicPeakHold, artworkAmbience, retroPattern
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
        }
    }
}

@MainActor
final class VisualizationRenderView: NSView {
    private(set) var frameData: VisualizationAudioData = .silent
    var mode: BuiltInVisualization = .spectrum { didSet { needsDisplay = true } }
    private var peaks = Array(repeating: Float.zero, count: 48)
    override var isFlipped: Bool { true }

    func update(_ data: VisualizationAudioData) {
        frameData = data
        if case let .simulated(frame) = data {
            for index in frame.bands.indices { peaks[index] = max(frame.bands[index], peaks[index] - 0.025) }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.015, green: 0.02, blue: 0.035, alpha: 0.96).setFill(); bounds.fill()
        guard case let .simulated(frame) = frameData else { drawPaused(); return }
        switch mode {
        case .spectrum: drawSpectrum(frame.bands, mirrored: false, peaks: false)
        case .mirroredSpectrum: drawSpectrum(frame.bands, mirrored: true, peaks: false)
        case .classicPeakHold: drawSpectrum(frame.bands, mirrored: false, peaks: true)
        case .oscilloscope: drawWaveform(frame.waveform)
        case .radialSpectrum: drawRadial(frame.bands)
        case .starfield: drawStarfield(frame)
        case .artworkAmbience: drawAmbience(frame.bands)
        case .retroPattern: drawPattern(frame)
        }
        drawBadge()
    }

    private func drawSpectrum(_ bands: [Float], mirrored: Bool, peaks showPeaks: Bool) {
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
                if showPeaks, peaks.indices.contains(index) {
                    let y = bounds.maxY - CGFloat(peaks[index]) * bounds.height * 0.82
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

    private func drawStarfield(_ frame: SimulatedFrame) {
        for index in 0..<120 {
            let n = UInt64(index) &* 6364136223846793005 &+ frame.seed
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

    private func drawPattern(_ frame: SimulatedFrame) {
        for index in 0..<24 {
            let value = CGFloat(frame.bands[(index * 2) % frame.bands.count])
            let inset = CGFloat(index) * 6 + value * 18
            NSColor(calibratedHue: CGFloat(index) / 24, saturation: 0.85, brightness: 0.9, alpha: 0.35).setStroke()
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset * 0.6)); path.lineWidth = 1.5; path.stroke()
        }
    }

    private func drawPaused() {
        let text = "VISUALIZATION PAUSED"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        drawBadge()
    }

    private func drawBadge() {
        "SIMULATED • NO PCM CAPTURE".draw(at: CGPoint(x: 10, y: 9), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.systemOrange])
    }
}

@MainActor
final class VisualizationWindowController: NSWindowController, NSWindowDelegate {
    private let source: SimulatedAudioAnalysisSource
    private let renderView = VisualizationRenderView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
    private let settings: SettingsStore
    private var framesTask: Task<Void, Never>?

    init(source: SimulatedAudioAnalysisSource, settings: SettingsStore) {
        self.source = source; self.settings = settings
        renderView.mode = BuiltInVisualization(rawValue: settings.selectedVisualization) ?? .spectrum
        let window = NSWindow(contentRect: renderView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Macamp Visualization — Simulated"
        window.contentView = renderView
        window.minSize = CGSize(width: 320, height: 180)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.close() }
        else { showWindow(nil); window.makeKeyAndOrderFront(nil); start() }
    }

    func select(_ mode: BuiltInVisualization) { settings.selectedVisualization = mode.rawValue; renderView.mode = mode }

    func applySettings() { source.configure(frameRate: settings.visualizationFrameRate, intensity: settings.visualizationIntensity) }

    func windowWillClose(_ notification: Notification) { stop() }

    private func start() {
        applySettings()
        framesTask?.cancel()
        framesTask = Task { [weak self] in
            guard let self else { return }
            try? await self.source.start()
            for await frame in self.source.frames() {
                guard !Task.isCancelled else { break }
                self.renderView.update(frame)
            }
        }
    }

    private func stop() {
        framesTask?.cancel(); framesTask = nil
        Task { await source.stop() }
    }
}
