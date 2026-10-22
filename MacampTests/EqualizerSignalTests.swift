import AVFoundation
import Foundation
import Testing
@testable import Macamp

@Suite("Local equalizer signal")
struct EqualizerSignalTests {
    private let sampleRate = 48_000.0

    @Test func localEqualizerChangesDecodedSignalAndBypassesCleanly() throws {
        let samples = makeSignal(frameCount: 48_000)
        let inputRMS = rms(samples)

        let flat = try render(samples, state: AudioEffectState(isEnabled: true))
        #expect(decibels(rms(flat) / inputRMS).magnitude < 0.15)

        var boostedState = AudioEffectState(isEnabled: true)
        boostedState.setGain(9, for: EqualizerBand.winamp10[4])
        let boosted = try render(samples, state: boostedState)
        let inputRatio = projection(samples, frequency: 1_000) / projection(samples, frequency: 100)
        let outputRatio = projection(boosted, frequency: 1_000) / projection(boosted, frequency: 100)
        #expect(decibels(outputRatio / inputRatio) > 6)

        let preamp = try render(samples, state: AudioEffectState(isEnabled: true, preampGain: 6))
        let preampGainDB = decibels(rms(preamp) / inputRMS)
        #expect(preampGainDB > 5.7)
        #expect(preampGainDB < 6.3)

        var bypassState = AudioEffectState(isEnabled: false, preampGain: 6)
        bypassState.setGain(9, for: EqualizerBand.winamp10[4])
        let bypassed = try render(samples, state: bypassState)
        #expect(decibels(rms(bypassed) / inputRMS).magnitude < 0.15)
    }

    private func render(_ input: [Float], state: AudioEffectState) throws -> [Float] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerBand.winamp10.count)
        engine.attach(player)
        engine.attach(equalizer)
        engine.connect(player, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        LocalFileEqualizerDSP.configure(equalizer, state: state)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2_048)

        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)))
        source.frameLength = AVAudioFrameCount(input.count)
        for channel in 0..<Int(format.channelCount) {
            guard let samples = source.floatChannelData?[channel] else {
                Issue.record("The offline test format must expose float PCM channels")
                return []
            }
            for index in input.indices { samples[index] = input[index] }
        }

        player.scheduleBuffer(source)
        try engine.start()
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        let output = try #require(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: 2_048
        ))
        var rendered: [Float] = []
        rendered.reserveCapacity(input.count)
        while rendered.count < input.count {
            let requested = AVAudioFrameCount(min(2_048, input.count - rendered.count))
            let status = try engine.renderOffline(requested, to: output)
            guard status == .success, let channel = output.floatChannelData?[0] else {
                throw ProviderError(code: .playbackFailed, message: "Offline AVAudioEngine render failed: \(status.rawValue)")
            }
            rendered.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        return rendered
    }

    private func makeSignal(frameCount: Int) -> [Float] {
        (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            return Float(0.08 * sin(2 * .pi * 100 * time) + 0.08 * sin(2 * .pi * 1_000 * time))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        let settled = samples.dropFirst(2_048).dropLast(2_048)
        return sqrt(settled.reduce(0.0) { $0 + Double($1 * $1) } / Double(settled.count))
    }

    private func projection(_ samples: [Float], frequency: Double) -> Double {
        let start = 2_048
        let end = samples.count - 2_048
        var inPhase = 0.0
        var quadrature = 0.0
        for frame in start..<end {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let value = Double(samples[frame])
            inPhase += value * cos(phase)
            quadrature += value * sin(phase)
        }
        let count = Double(end - start)
        return 2 * hypot(inPhase, quadrature) / count
    }

    private func decibels(_ ratio: Double) -> Double { 20 * log10(ratio) }
}
