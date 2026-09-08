import Dispatch
import Synchronization

/// Byte budget shared by every stream in a process, plus the system
/// memory-pressure signal. Pinned frames are IOSurface-backed and are NOT
/// charged to the process footprint (see docs/spikes-2026-09.md), so this
/// accounting is the only place the number exists — log `residentBytes`.
public final class MemoryBudget: Sendable {
    public static let shared = MemoryBudget()

    /// Total pinned bytes allowed across all streams. Settable live.
    public let totalBytes: Atomic<Int>
    /// Pinned bytes currently held by all streams.
    public let pinnedBytes = Atomic<Int>(0)
    /// Set while the system reports memory pressure; streams shed pins
    /// down to their wrap-target heads and stop growing until it clears.
    public let underPressure = Atomic<Bool>(false)

    private let source: DispatchSourceMemoryPressure

    public init(totalBytes: Int = 1_500 << 20) {
        self.totalBytes = Atomic(totalBytes)
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: DispatchQueue(label: "com.deckvideostream.memorypressure"))
        source.setEventHandler { [weak self, source] in
            guard let self else { return }
            let event = source.data
            if event.contains(.warning) || event.contains(.critical) {
                self.underPressure.store(true, ordering: .relaxed)
            } else if event.contains(.normal) {
                self.underPressure.store(false, ordering: .relaxed)
            }
        }
        source.resume()
    }

    deinit { source.cancel() }

    /// Try to take `bytes` from the budget; false (nothing taken) if it
    /// doesn't fit.
    func reserve(_ bytes: Int) -> Bool {
        var current = pinnedBytes.load(ordering: .relaxed)
        let limit = totalBytes.load(ordering: .relaxed)
        while true {
            guard current + bytes <= limit else { return false }
            let (exchanged, original) = pinnedBytes.compareExchange(
                expected: current, desired: current + bytes, ordering: .relaxed)
            if exchanged { return true }
            current = original
        }
    }

    func release(_ bytes: Int) {
        pinnedBytes.wrappingSubtract(bytes, ordering: .relaxed)
    }
}
