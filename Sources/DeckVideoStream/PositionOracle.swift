import Foundation

/// How the stream learns where the deck will be. The host owns the clock:
/// `fileSeconds` answers "what file time will you be showing at this host
/// time?" and the stream samples it at future host times to decide what to
/// decode. Called on the stream's worker thread at a few hundred Hz; it must
/// be cheap, non-blocking, and safe to call off the main thread.
///
/// `epoch` is a monotone token the host bumps whenever the future changed
/// (a locate, loop exit, pitch change…). It is an optimisation, not a
/// correctness requirement: the stream re-samples `fileSeconds` every pass
/// anyway, so a missed bump only means a few frames were decoded for a
/// future that never came.
public struct PositionOracle: Sendable {
    public var fileSeconds: @Sendable (_ hostTime: HostTicks) -> Double?
    public var epoch: @Sendable () -> UInt64

    public init(fileSeconds: @escaping @Sendable (HostTicks) -> Double?,
                epoch: @escaping @Sendable () -> UInt64 = { 0 }) {
        self.fileSeconds = fileSeconds
        self.epoch = epoch
    }

    /// Never shows anything.
    public static let none = PositionOracle(fileSeconds: { _ in nil })
}

/// A loop the deck is (or is about to be) playing, in file seconds,
/// `outSeconds` exclusive. The stream pins the whole range when it fits
/// the budget, else just the wrap-target head, so a wrap never waits on
/// a decode. Because engines commonly apply a wrap a little early (a
/// prefill ring's depth ahead of the audible position), the pinned range
/// starts `Configuration.hintPaddingSeconds` before `inSeconds`.
public struct LoopHint: Hashable, Sendable {
    public var inSeconds: Double
    public var outSeconds: Double
    public init(inSeconds: Double, outSeconds: Double) {
        self.inSeconds = inSeconds
        self.outSeconds = outSeconds
    }
    public var lengthSeconds: Double { outSeconds - inSeconds }
}

public struct Configuration: Sendable {
    /// Decode format for sources without alpha; alpha sources are always BGRA.
    public var pixelFormat: PixelFormat = .nv12VideoRange
    /// How far past "now" the oracle is sampled and frames kept decoded.
    public var lookaheadSeconds: Double = 0.25
    /// How far behind "now" frames are kept (reverse/scratch raise this).
    public var lookbehindSeconds: Double = 0.05
    /// Ring slots (rounded up to a power of two). Bounds resident memory:
    /// slots × bytes per frame.
    public var ringCapacity: Int = 64
    /// Frames decoded per worker pass before re-checking the oracle.
    public var decodeChunk: Int = 8
    public var workerIntervalMilliseconds: Int = 4
    /// With the oracle answering nil this long, readers and ring are released.
    public var idleReleaseSeconds: Double = 5
    /// `frame(at:)` falls back to the nearest earlier frame within this many.
    public var backscanFrames: Int = 4
    /// Oracle samples closer than this (in frames) merge into one decode run.
    public var runGapToleranceFrames: Int = 2
    /// Pinned bytes this one stream may hold (the shared MemoryBudget caps
    /// the total across streams).
    public var pinBudgetBytes: Int = 1 << 30
    /// A pinned loop/cue range starts this far before the hinted point and
    /// extends this far past a cue point.
    public var hintPaddingSeconds: Double = 0.25
    /// Frames pinned after a cue point, and for a loop's wrap-target head
    /// when the whole loop doesn't fit.
    public var hintHeadSeconds: Double = 0.35
    /// Print worker decisions (restarts, swaps) to stdout. Diagnostics only.
    public var verbose: Bool = false

    public init() {}
}
