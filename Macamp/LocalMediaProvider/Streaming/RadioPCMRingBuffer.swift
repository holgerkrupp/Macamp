import Synchronization
import AVFoundation

nonisolated final class RadioRenderGate: @unchecked Sendable {
    let enabled = Atomic<Bool>(false)
}

nonisolated enum RadioAudioRenderer {
    private typealias RenderBlock = @Sendable (
        UnsafeMutablePointer<ObjCBool>,
        UnsafePointer<AudioTimeStamp>,
        AVAudioFrameCount,
        UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus

    static func makeSourceNode(
        format: AVAudioFormat,
        ring: RadioPCMRingBuffer,
        gate: RadioRenderGate
    ) -> AVAudioSourceNode {
        let renderBlock: RenderBlock = { _, _, frameCount, outputData in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let leftData = buffers[0].mData,
                  let rightData = buffers[1].mData else { return kAudio_ParamError }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            guard gate.enabled.load(ordering: .relaxed) else {
                for frame in 0..<count { left[frame] = 0; right[frame] = 0 }
                return noErr
            }
            let read = ring.read(left: left, right: right, frameCount: count)
            if read < count {
                for frame in read..<count { left[frame] = 0; right[frame] = 0 }
            }
            return noErr
        }
        return AVAudioSourceNode(format: format, renderBlock: renderBlock)
    }
}

/// Bounded single-producer/single-consumer PCM handoff for radio decode and render.
/// The AudioToolbox decoder writes on one serial queue; AVAudioSourceNode reads it
/// on the audio render thread. The render path allocates nothing and takes no locks.
nonisolated final class RadioPCMRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let writeHead = Atomic<UInt64>(0)
    private let readHead = Atomic<UInt64>(0)

    init(capacityFrames: Int = 48_000 * 8) {
        precondition(capacityFrames > 0)
        capacity = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { samples.deallocate() }

    @discardableResult
    func write(from source: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let written = writeHead.load(ordering: .relaxed)
        let consumed = readHead.load(ordering: .acquiring)
        let used = min(capacity, Int(written &- consumed))
        let count = min(frameCount, capacity - used)
        guard count > 0 else { return 0 }
        for frame in 0..<count {
            let destination = Int((written + UInt64(frame)) % UInt64(capacity)) * 2
            samples[destination] = source[frame * 2]
            samples[destination + 1] = source[frame * 2 + 1]
        }
        writeHead.store(written &+ UInt64(count), ordering: .releasing)
        return count
    }

    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let consumed = readHead.load(ordering: .relaxed)
        let written = writeHead.load(ordering: .acquiring)
        let available = min(capacity, Int(written &- consumed))
        let count = min(frameCount, available)
        guard count > 0 else { return 0 }
        for frame in 0..<count {
            let source = Int((consumed + UInt64(frame)) % UInt64(capacity)) * 2
            left[frame] = samples[source]
            right[frame] = samples[source + 1]
        }
        readHead.store(consumed &+ UInt64(count), ordering: .releasing)
        return count
    }

    var availableFrames: Int {
        let written = writeHead.load(ordering: .acquiring)
        let consumed = readHead.load(ordering: .acquiring)
        return min(capacity, Int(written &- consumed))
    }

    /// Call only after the render route is silenced and the decoder queue is stopped.
    func reset() {
        readHead.store(writeHead.load(ordering: .acquiring), ordering: .releasing)
    }
}
