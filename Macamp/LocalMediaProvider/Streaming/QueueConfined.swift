import Foundation

// Queue confinement helper adapted from hfyeomans/MacAmp (MIT), commit cb0c77f.

/// Protocol for types confined to a specific DispatchQueue.
/// Provides a debug-only assertion to verify queue confinement at runtime.
nonisolated protocol QueueConfined: AnyObject {
    /// The dispatch queue this object is confined to (set by owner, checked in debug builds).
    var confinementQueue: DispatchQueue? { get set }
}

nonisolated extension QueueConfined {
    /// Assert that the current code is executing on the confinement queue (debug builds only).
    func assertConfinement() {
        #if DEBUG
        if let queue = confinementQueue {
            dispatchPrecondition(condition: .onQueue(queue))
        }
        #endif
    }
}
