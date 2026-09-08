import Synchronization

/// Relaxed atomic counters, written on the render thread (`frame(at:)`)
/// and the worker, read by whatever health poller the host runs.
public final class StreamHealth: Sendable {
    /// `frame(at:)` asked for a different index than the previous call.
    public let expectedFrames = Atomic<UInt64>(0)
    /// `frame(at:)` returned a different index than the previous call.
    public let deliveredFrames = Atomic<UInt64>(0)
    /// `frame(at:)` had nothing at all to return.
    public let misses = Atomic<UInt64>(0)
    /// `frame(at:)` served an earlier frame than asked for.
    public let staleFrames = Atomic<UInt64>(0)
    /// Live reader restarted at a keyframe (discontinuity or first fill).
    public let coldStarts = Atomic<UInt64>(0)
    public let decodedFrames = Atomic<UInt64>(0)
    public let epochChanges = Atomic<UInt64>(0)
    /// Longest "needed and missing" → "in ring" for the live run.
    public let worstDecodeLatencyNanos = Atomic<UInt64>(0)
    public let residentBytes = Atomic<Int>(0)

    public init() {}

    public func takeWorstDecodeLatencyNanos() -> UInt64 {
        worstDecodeLatencyNanos.exchange(0, ordering: .relaxed)
    }

    func raiseLatency(_ nanos: UInt64) {
        var current = worstDecodeLatencyNanos.load(ordering: .relaxed)
        while nanos > current {
            let (exchanged, original) = worstDecodeLatencyNanos.compareExchange(
                expected: current, desired: nanos, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
}
