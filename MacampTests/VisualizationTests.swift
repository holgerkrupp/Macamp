import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Macamp

@Suite
@MainActor
struct VisualizationTests {
    @Test func simulatedFramesAreDeterministic() {
        let coordinator = PlaybackCoordinator(playlistStore: makeIsolatedUnifiedPlaylistStore())
        let source = SimulatedAudioAnalysisSource(coordinator: coordinator)
        #expect(source.frame(at: 42, seed: 99) == source.frame(at: 42, seed: 99))
        #expect(source.frame(at: 43, seed: 99) != source.frame(at: 42, seed: 99))
    }

    @Test func presetRoundTrips() throws {
        let preset = VisualizationPreset(engineIdentifier: "spectrum", frameRate: 60, seed: 123)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(VisualizationPreset.self, from: data)
        #expect(try decoded.validated() == preset)
    }

    @Test func unsupportedPresetVersionIsRejected() {
        let preset = VisualizationPreset(version: 999, engineIdentifier: "future")
        #expect(throws: ProviderError.self) { try preset.validated() }
    }

    @Test func goomIsAvailableAndVisualizationModeSelectionPersists() throws {
        #expect(BuiltInVisualization(rawValue: "goom")?.title == "GOOM")
        #expect(BuiltInVisualization(rawValue: "avs")?.title == "AVS Studio")
        #expect(BuiltInVisualization(rawValue: "milkDrop")?.title == "MilkDrop")
        #expect(BuiltInVisualization.allCases.contains(.spectrum))
        let suite = "MacampVisualizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).selectedVisualization = BuiltInVisualization.goom.rawValue
        #expect(SettingsStore(defaults: defaults).selectedVisualization == "goom")
        SettingsStore(defaults: defaults).selectedAVSPreset = 2
        #expect(SettingsStore(defaults: defaults).selectedAVSPreset == 2)
    }

    @Test func milkDropPresetCyclingPreferencePersists() throws {
        let suite = "MacampMilkDropCycleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.milkDropPresetCycling)
        settings.milkDropPresetCycling = true
        #expect(SettingsStore(defaults: defaults).milkDropPresetCycling)
    }

    @Test func avsImportsLegacySimplePresetAndSkipsUnknownEffects() throws {
        var bytes = Array("Nullsoft AVS Preset 0.1\u{1A}".utf8)
        bytes.append(1) // Root clears the framebuffer.
        func appendInt(_ value: UInt32, to bytes: inout [UInt8]) {
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8((value >> 8) & 0xff))
            bytes.append(UInt8((value >> 16) & 0xff))
            bytes.append(UInt8((value >> 24) & 0xff))
        }
        appendInt(0, to: &bytes) // Simple effect.
        appendInt(12, to: &bytes) // flags, one color.
        appendInt(0, to: &bytes)
        appendInt(1, to: &bytes)
        appendInt(0x00ff00, to: &bytes)
        var scope: [UInt8] = [1]
        for expression in ["x=i;", "", "", "n=64;"] {
            scope.append(contentsOf: expression.utf8)
            scope.append(0)
        }
        appendInt(4, to: &scope) // Waveform source.
        appendInt(1, to: &scope)
        appendInt(0x00ffff, to: &scope)
        appendInt(1, to: &scope) // Line drawing.
        appendInt(36, to: &bytes)
        appendInt(UInt32(scope.count), to: &bytes)
        bytes.append(contentsOf: scope)
        var legacyScope = [UInt8](repeating: 0, count: 1_024)
        let legacyScripts = ["sc=0.2; x=-2*(i-0.5-v*sc*0.2); y=0.24+0.7*(i-0.5+v*sc*2);", "", "", "n=sqrt(w*w+h*h)/2;"]
        for (index, script) in legacyScripts.enumerated() {
            legacyScope.replaceSubrange((index * 256)..<(index * 256 + script.utf8.count), with: script.utf8)
        }
        var scopeTail: [UInt8] = []
        appendInt(4, to: &scopeTail)
        appendInt(1, to: &scopeTail)
        appendInt(0x00ffff, to: &scopeTail)
        appendInt(1, to: &scopeTail)
        legacyScope.append(contentsOf: scopeTail)
        appendInt(36, to: &bytes)
        appendInt(UInt32(legacyScope.count), to: &bytes)
        bytes.append(contentsOf: legacyScope)
        var nestedContents: [UInt8] = [0x80, 0, 0, 0, 0]
        var nestedSimple: [UInt8] = []
        appendInt(0, to: &nestedSimple)
        appendInt(12, to: &nestedSimple)
        appendInt(0, to: &nestedSimple)
        appendInt(1, to: &nestedSimple)
        appendInt(0xff0000, to: &nestedSimple)
        nestedContents.append(contentsOf: nestedSimple)
        appendInt(UInt32(bitPattern: -2), to: &bytes)
        appendInt(UInt32(nestedContents.count), to: &bytes)
        bytes.append(contentsOf: nestedContents)
        var disabledContents: [UInt8] = [0x82, 0x02, 0, 0, 0]
        disabledContents.append(contentsOf: nestedSimple)
        appendInt(UInt32(bitPattern: -2), to: &bytes)
        appendInt(UInt32(disabledContents.count), to: &bytes)
        bytes.append(contentsOf: disabledContents)
        appendInt(999, to: &bytes) // Unsupported effects are skipped.
        appendInt(0, to: &bytes)

        let preset = try AVSPresetParser.parse(Data(bytes), fileName: "Green bars.avs")

        #expect(preset.title == "Green bars")
        #expect(preset.simpleEffects.count == 2)
        #expect(preset.simpleEffects.first?.colors == [0x00ff00])
        #expect(preset.scopeEffects.count == 2)
        #expect(preset.scopeEffects.first?.waveform == true)
        #expect(preset.scopeEffects.first?.drawLines == true)
        #expect(preset.scopeEffects.first?.equationsSupported == true)
        #expect(preset.scopeEffects.last?.equationsSupported == true)
        #expect(preset.unsupportedEffectCount == 1)
        #expect(throws: AVSPresetError.self) { try AVSPresetParser.parse(Data(bytes.dropLast()), fileName: "truncated.avs") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampAVSImport-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("chosen-folder", isDirectory: true)
        let nestedFolder = sourceFolder.appendingPathComponent("nested", isDirectory: true)
        let store = AVSPresetStore(directory: root.appendingPathComponent("stored", isDirectory: true))
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(bytes).write(to: nestedFolder.appendingPathComponent("Folder preset.avs"))
        let imported = store.importPresets(from: [sourceFolder])
        let restored = store.allPresets()
        #expect(imported.count == 1)
        #expect(restored.presets.map(\.title) == ["Folder preset"])
        #expect(restored.warnings.contains { $0.contains("unsupported effect") })
    }

    @Test func avsSuperScopeExpressionSubsetEvaluatesPureMathOnly() {
        let program = AVSExpressionProgram("x=cos(i*2*$PI); y=if(above(v,0),v,-v);")
        var variables = ["i": 0.5, "v": -0.25]

        #expect(program.isValid)
        #expect(program.run(&variables))
        #expect(abs((variables["x"] ?? 0) + 1) < 0.0001)
        #expect(variables["y"] == 0.25)
        #expect(!AVSExpressionProgram("x=fetch(1);").isValid)
    }

    @Test func milkDropPresetParserConvertsOrderedEquationsToBundledRendererFormat() throws {
        let preset = try MilkDropPresetParser.parse(text: """
        [preset00]
        fDecay=0.96
        zoom=1.02
        per_frame_2=a.zoom=1.02;
        per_frame_1=a.wave_r=0.5;
        per_pixel_1=a.warp=a.warp+0.01;
        wave_0_per_frame_1=a.r=1;
        wave_0_per_point_1=a.x=a.x+0.01;
        shape_0_enabled=1
        shape_0_sides=6
        shape_0_textured=1
        shape_0_per_frame_2=a.rad=0.25;
        shape_0_init_1=a.x=0.5;
        """, fileName: "Test.milk")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(preset.rendererJSON.utf8)) as? [String: Any])
        let baseValues = try #require(payload["baseVals"] as? [String: Double])
        let waves = try #require(payload["waves"] as? [[String: Any]])
        let firstWave = try #require(waves.first)
        let shapes = try #require(payload["shapes"] as? [[String: Any]])
        let firstShape = try #require(shapes.first)
        let shapeValues = try #require(firstShape["baseVals"] as? [String: Double])

        #expect(preset.title == "Test")
        #expect(baseValues["decay"] == 0.96)
        #expect(baseValues["zoom"] == 1.02)
        #expect(payload["frame_eqs_str"] as? String == "a.wave_r=0.5; a.zoom=1.02;")
        #expect(payload["pixel_eqs_str"] as? String == "a.warp=a.warp+0.01;")
        #expect(firstWave["frame_eqs_str"] as? String == "a.r=1;")
        #expect(firstWave["point_eqs_str"] as? String == "a.x=a.x+0.01;")
        #expect(shapeValues["enabled"] == 1)
        #expect(shapeValues["sides"] == 6)
        #expect(shapeValues["textured"] == 1)
        #expect(firstShape["init_eqs_str"] as? String == "a.x=0.5;")
        #expect(firstShape["frame_eqs_str"] as? String == "a.rad=0.25;")
    }

    @Test func milkDropPresetParserRejectsMissingSectionsAndUnsafeEquations() {
        #expect(throws: MilkDropPresetError.self) {
            try MilkDropPresetParser.parse(text: "zoom=1.0", fileName: "invalid.milk")
        }
        #expect(throws: MilkDropPresetError.self) {
            try MilkDropPresetParser.parse(text: "[preset00]\nper_frame_1=window.location=1;", fileName: "unsafe.milk")
        }
    }

    @Test func milkDropPresetStoreCopiesAndRestoresUserPresets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampMilkDrop-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("stored", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceDirectory.appendingPathComponent("Orbit.milk")
        try "[preset00]\nzoom=1.01\nper_frame_1=a.zoom=1.01;\n".write(to: source, atomically: true, encoding: .utf8)
        let store = MilkDropPresetStore(directory: storeDirectory)

        let imported = store.importFiles([source])
        let restored = store.allPresets()

        #expect(imported.presets.map(\.title) == ["Orbit"])
        #expect(imported.warnings.isEmpty)
        #expect(restored.presets.map(\.title) == ["Orbit"])
        #expect(restored.warnings.isEmpty)
    }

    @Test func milkDropImportsCustomShaderAndNamedTexture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacampMilkDropShader-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let storeDirectory = root.appendingPathComponent("stored", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("Shader.milk")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[preset00]\nzoom=1.0\nwarp_1=`sampler sampler_custom;\nwarp_2=`shader_body\nwarp_3=`{\nwarp_4=`ret = tex2D(sampler_custom, uv).xyz;\nwarp_5=`}\n".write(to: source, atomically: true, encoding: .utf8)
        let store = MilkDropPresetStore(directory: storeDirectory)
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: 0.5, green: 0.1, blue: 0.7, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let png = NSMutableData()
        let image = try #require(context?.makeImage())
        let imageDestination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, image, nil)
        #expect(CGImageDestinationFinalize(imageDestination))
        let textureURL = sourceDirectory.appendingPathComponent("custom.png")
        try (png as Data).write(to: textureURL)

        let imported = store.importFiles([source])
        let textures = store.importTextures([textureURL])
        let restored = store.allPresets()
        let importedPreset = try #require(imported.presets.first)
        let presetData = Data(importedPreset.rendererJSON.utf8)
        let presetObject = try #require(JSONSerialization.jsonObject(with: presetData) as? [String: Any])

        #expect(imported.presets.count == 1)
        #expect(imported.presets[0].textureNames == ["custom"])
        #expect((presetObject["warp"] as? String)?.contains("uniform sampler2D sampler_custom;") == true)
        #expect((presetObject["warp"] as? String)?.contains("texture(sampler_custom, uv)") == true)
        #expect(textures.names == ["custom"])
        let texturePayload = try #require(JSONSerialization.jsonObject(with: Data(store.texturePayload(for: ["custom"]).utf8)) as? [String: [String: Any]])
        #expect((texturePayload["custom"]?["data"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(restored.warnings.isEmpty)
    }

    @Test func pcmAnalyzerReturnsSafeSilence() {
        let silent = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: Array(repeating: 0, count: 2_048), sampleRate: 44_100))
        #expect(silent.bands.count == 48)
        #expect(silent.waveform.count == 96)
        #expect(silent.bands.allSatisfy { $0.isFinite && $0 == 0 })
        #expect(silent.waveform.allSatisfy { $0.isFinite && $0 == 0 })
        #expect(silent.pcm == Array(repeating: Float.zero, count: 1_024))

        let short = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: [0.25], sampleRate: 48_000))
        #expect(short.bands.count == 48)
        #expect(short.waveform.count == 96)
        #expect(short.bands.allSatisfy { $0.isFinite })
        #expect(short.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
    }

    @Test func visualizerPCMRetainsTheNewestContiguousSamples() {
        let samples = (0..<2_048).map { Float($0) / 2_048 }
        let frame = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: samples, sampleRate: 48_000))
        #expect(frame.pcm == Array(samples.suffix(1_024)))
    }

    @Test func classicPeakHoldConsumesAnalyzedPCMFramesAndClearsWhenUnavailable() {
        let bands = [Float](arrayLiteral: 0.8, 0.25, 0.05)
        let view = VisualizationRenderView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        view.mode = .classicPeakHold
        view.update(.analysis(VisualizationAnalysisFrame(bands: bands, waveform: [0, 0.5, 0])))

        #expect(view.peakHoldBands == bands)

        view.update(.analysis(VisualizationAnalysisFrame(bands: [0.1, 0.1, 0.1], waveform: [0, 0, 0])))
        #expect(abs(view.peakHoldBands[0] - 0.775) < 0.0001)
        #expect(abs(view.peakHoldBands[1] - 0.225) < 0.0001)

        view.update(.unavailable("Hosted audio does not expose PCM."))
        #expect(view.peakHoldBands.isEmpty)
    }

    @Test func inlineVisualizationModeCanSwitchAndPeakHoldClearsOnSilence() {
        let store = VisualizationFrameStore()
        store.update(.analysis(VisualizationAnalysisFrame(bands: [0.5, 0.2], waveform: [0, 0.5, 0])))
        #expect(store.peakHoldBands == [0.5, 0.2])

        store.selectInlineMode(.waveform)
        #expect(store.inlineMode == .waveform)
        store.toggleInlineMode()
        #expect(store.inlineMode == .spectrum)

        store.update(.silent)
        #expect(store.peakHoldBands.isEmpty)
    }

    @Test func pcmAnalyzerPlacesTonesInExpectedLogBands() {
        let sampleCount = 2_048
        let frequencies: [(hertz: Double, expectedBand: Int)] = [
            (100, 10), (1_000, 26), (10_000, 42)
        ]

        for sampleRate in [44_100.0, 48_000.0] {
            for tone in frequencies {
                let samples = (0..<sampleCount).map { index in
                    Float(0.7 * sin(2 * Double.pi * tone.hertz * Double(index) / sampleRate))
                }
                let frame = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: samples, sampleRate: sampleRate))
                let dominantBand = frame.bands.indices.max(by: { frame.bands[$0] < frame.bands[$1] })!

                #expect(abs(dominantBand - tone.expectedBand) <= 2, "\(tone.hertz) Hz at \(sampleRate) Hz peaked in band \(dominantBand)")
                #expect(frame.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
                #expect(frame.waveform.count == 96)
                #expect(frame.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
            }
        }
    }
}
