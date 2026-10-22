import Accelerate
import Foundation

@MainActor
enum VisualizationPCMAnalyzer {
    private static let transformSize = 2_048
    private static let bandCount = 48
    private static let waveformCount = 96
    private static let fftLog2 = vDSP_Length(log2(Double(transformSize)))
    private static let fftSetup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))

    static func analyze(_ frame: PCMFrame) -> VisualizationAnalysisFrame {
        let samples = frame.samples
        guard samples.count > 1, let fftSetup else {
            return VisualizationAnalysisFrame(bands: Array(repeating: 0, count: bandCount), waveform: Array(repeating: 0, count: waveformCount))
        }

        let count = min(samples.count, transformSize)
        var windowed = Array(repeating: Float.zero, count: transformSize)
        var hann = Array(repeating: Float.zero, count: count)
        vDSP_hann_window(&hann, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        for index in 0..<count { windowed[index] = samples[index] * hann[index] }

        var real = Array(repeating: Float.zero, count: transformSize / 2)
        var imaginary = Array(repeating: Float.zero, count: transformSize / 2)
        var magnitudes = Array(repeating: Float.zero, count: transformSize / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress, let imaginaryBase = imaginaryBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeBufferPointer { source in
                    guard let sourceBase = source.baseAddress else { return }
                    sourceBase.withMemoryRebound(to: DSPComplex.self, capacity: transformSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(transformSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(transformSize / 2))
                magnitudes[0] = 0 // The packed real FFT stores DC and Nyquist together here.
            }
        }

        // Log-spaced buckets give useful low-frequency detail without depending on
        // the playback provider's sample rate.
        let usableBins = max(2, transformSize / 2)
        let bands = (0..<bandCount).map { band -> Float in
            let lower = max(1, Int(pow(Double(usableBins), Double(band) / Double(bandCount))))
            let upper = min(usableBins, max(lower + 1, Int(pow(Double(usableBins), Double(band + 1) / Double(bandCount)))))
            let peakPower = magnitudes[lower..<upper].max() ?? 0
            return min(1, sqrt(max(0, peakPower)) * (4 / Float(transformSize)))
        }
        let waveform = (0..<waveformCount).map { index -> Float in
            let sampleIndex = min(samples.count - 1, index * (samples.count - 1) / (waveformCount - 1))
            return min(1, max(-1, samples[sampleIndex]))
        }
        return VisualizationAnalysisFrame(bands: bands, waveform: waveform)
    }
}
