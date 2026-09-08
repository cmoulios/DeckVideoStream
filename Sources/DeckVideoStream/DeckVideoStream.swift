import AVFoundation
import CoreVideo
import Foundation
import Synchronization

/// One decoded frame handed to the consumer. The buffer is retained for as
/// long as the caller holds the struct; drop it after use so the decoder's
/// pool can recycle the surface.
public struct Frame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Presentation index in the source.
    public let index: Int
    public let presentationSeconds: Double
    /// false = the frame asked for wasn't resident; this is the nearest
    /// earlier one (a miss for health purposes).
    public let isExact: Bool
}

/// A predictive frame source for one video deck.
///
/// Threads:
///   • Any thread: `open`, `invalidate`, `info` — return immediately.
///   • Consumer (render) thread: `frame(at:)` — O(log n) table search plus
///     a short lock; never allocates, never waits on the worker.
///   • Worker (own serial queue, user-interactive): samples the oracle at
///     future host times, keeps the frames for those times decoded in a
///     ring, evicts the rest. Holds the ring lock only for pointer swaps,
///     never across an AVFoundation call.
public final class DeckVideoStream: @unchecked Sendable {
    public let configuration: Configuration
    public let health = StreamHealth()

    private let oracle: PositionOracle
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?   // worker-only

    // Guarded by `lock`.
    private let lock = NSLock()
    private var session: Session?
    private var generation: UInt64 = 0
    private var pendingURL: URL?

    // Worker-only.
    private var live: Reader?
    private var aux: Reader?
    private var lastEpoch: UInt64?
    private var idleSince: Double?

    // Consumer-thread-only health bookkeeping.
    private var lastRequestedIndex = -1
    private var lastDeliveredIndex = -1
    /// Consumer's latest request, for the worker's eviction floor.
    private let consumerIndex = Atomic<Int>(-1)

    /// Everything tied to one opened file. Replaced wholesale on open/close.
    private final class Session: @unchecked Sendable {
        let source: VideoSource
        let format: PixelFormat
        let ring: FrameRing
        let bytesPerFrame: Int
        let generation: UInt64
        init(source: VideoSource, format: PixelFormat, ringCapacity: Int, generation: UInt64) {
            self.source = source
            self.format = format
            self.ring = FrameRing(capacity: ringCapacity)
            self.bytesPerFrame = source.info.bytesPerFrame(format)
            self.generation = generation
        }
        var table: FrameTable { source.table }
    }

    /// A reader plus the presentation index it will emit next (nil after EOF).
    private struct Reader {
        let source: ReaderSource
        var nextIndex: Int?
        /// Index a start() failed at, so we don't retry it every pass.
        var failedAt: Int?
        /// Host time at which the current live restart began (latency gauge).
        var startedAt: Double?
        var startTarget: Int?
    }

    public init(configuration: Configuration = Configuration(),
                oracle: PositionOracle,
                label: String = "com.deckvideostream.worker") {
        self.configuration = configuration
        self.oracle = oracle
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    deinit {
        timer?.cancel()
    }

    // MARK: Control surface

    /// Static facts about the open file, nil until the open completes.
    public var info: SourceInfo? {
        lock.lock(); defer { lock.unlock() }
        return session?.source.info
    }

    /// The URL last passed to `open` (whether or not it has finished opening).
    public var currentURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return pendingURL
    }

    /// Switch to `url` (nil = close). Same URL is a no-op. Returns the
    /// generation the open will install under. The file is opened and
    /// indexed asynchronously; `frame(at:)` returns nil until then.
    @discardableResult
    public func open(_ url: URL?) -> UInt64 {
        lock.lock()
        if url == pendingURL { let g = generation; lock.unlock(); return g }
        generation &+= 1
        let gen = generation
        pendingURL = url
        lock.unlock()

        queue.async { [self] in
            teardownReaders()
            install(nil, generation: gen)
        }
        guard let url else { return gen }
        let format = configuration.pixelFormat
        let capacity = configuration.ringCapacity
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let source: VideoSource
            do {
                source = try await VideoSource.open(url)
            } catch {
                return
            }
            let fmt: PixelFormat = source.info.hasAlpha ? .bgra8 : format
            let session = Session(source: source, format: fmt, ringCapacity: capacity, generation: gen)
            self.queue.async { self.install(session, generation: gen) }
        }
        return gen
    }

    /// Equivalent to the oracle's epoch changing.
    public func invalidate() {
        queue.async { [self] in
            lastEpoch = nil
            dropFuture()
        }
    }

    // MARK: Consumer surface

    /// The frame for `fileSeconds` if resident, else the nearest earlier
    /// frame within `backscanFrames`, else nil. Never blocks on the worker.
    public func frame(at fileSeconds: Double) -> Frame? {
        lock.lock()
        guard let session else {
            lock.unlock()
            return nil
        }
        let table = session.table
        let index = table.index(forSeconds: fileSeconds)
        var hitIndex = index
        var exact = true
        var buffer = session.ring.buffer(at: index)
        if buffer == nil, let near = session.ring.nearest(atOrBefore: index, backscan: configuration.backscanFrames) {
            buffer = near.buffer
            hitIndex = near.index
            exact = false
        }
        lock.unlock()

        consumerIndex.store(index, ordering: .relaxed)
        if index != lastRequestedIndex {
            lastRequestedIndex = index
            health.expectedFrames.wrappingAdd(1, ordering: .relaxed)
        }
        guard let buffer else {
            health.misses.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        if hitIndex != lastDeliveredIndex {
            lastDeliveredIndex = hitIndex
            health.deliveredFrames.wrappingAdd(1, ordering: .relaxed)
        }
        if !exact { health.staleFrames.wrappingAdd(1, ordering: .relaxed) }
        return Frame(pixelBuffer: buffer, index: hitIndex,
                     presentationSeconds: table.seconds(at: hitIndex), isExact: exact)
    }

    // MARK: Worker

    private func install(_ new: Session?, generation gen: UInt64) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        session = new
        lock.unlock()
        teardownReaders()
        lastEpoch = nil
        idleSince = nil
        health.residentBytes.store(0, ordering: .relaxed)
        setTimerActive(new != nil)
        if new != nil { pass() }
    }

    private func setTimerActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.milliseconds(configuration.workerIntervalMilliseconds)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.pass() }
            t.resume()
            timer = t
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    private func teardownReaders() {
        live?.source.cancel()
        aux?.source.cancel()
        live = nil
        aux = nil
    }

    private func currentSession() -> Session? {
        lock.lock(); defer { lock.unlock() }
        guard let session, session.generation == generation else { return nil }
        return session
    }

    /// One worker pass: sample, plan, decode, evict.
    private func pass() {
        guard let session = currentSession() else { return }
        let cfg = configuration
        let table = session.table

        let epoch = oracle.epoch()
        if let last = lastEpoch, last != epoch {
            health.epochChanges.wrappingAdd(1, ordering: .relaxed)
            dropFuture()
        }
        lastEpoch = epoch

        // Sample the oracle across the horizon, one sample per source frame.
        let now = HostClock.now()
        let frameDuration = max(table.nominalFrameDurationSeconds, 1.0 / 240)
        func sample(_ dt: Double) -> Int? {
            guard let s = oracle.fileSeconds(HostClock.ticks(adding: dt, to: now)) else { return nil }
            return table.index(forSeconds: s)
        }
        guard let nowIndex = sample(0) else {
            idle(session)
            return
        }
        idleSince = nil
        var samples = [nowIndex]
        samples.reserveCapacity(Int((cfg.lookaheadSeconds + cfg.lookbehindSeconds) / frameDuration) + 2)
        var t = -cfg.lookbehindSeconds
        while t < 0 {
            if let i = sample(t) { samples.append(i) }
            t += frameDuration
        }
        t = frameDuration
        while t <= cfg.lookaheadSeconds {
            if let i = sample(t) { samples.append(i) }
            t += frameDuration
        }
        let runs = DecodePlanner.runs(from: samples, gapTolerance: cfg.runGapToleranceFrames)
        guard let primary = runs.first(where: { $0.contains(nowIndex) }) ?? runs.first else { return }

        // Live run first; then one secondary run (a loop wrap inside the
        // horizon) on the auxiliary reader, so the live reader never leaves
        // its sequential path. When the wrap arrives, the aux reader IS the
        // sequential path: swap rather than restart.
        if let missing = firstMissing(in: primary, session: session),
           live?.nextIndex != missing, aux?.nextIndex == missing {
            swap(&live, &aux)
        }
        serve(run: primary, reader: &live, session: session, isLive: true)
        if let secondary = runs.first(where: { $0 != primary && firstMissing(in: $0, session: session) != nil }) {
            serve(run: secondary, reader: &aux, session: session, isLive: false)
        } else if aux != nil, runs.count == 1 {
            aux?.source.cancel()
            aux = nil
        }

        // Evict everything outside the runs (plus a little history behind
        // whatever the consumer last asked for).
        let behind = Int((cfg.lookbehindSeconds / frameDuration).rounded(.up)) + cfg.backscanFrames
        let consumer = consumerIndex.load(ordering: .relaxed)
        lock.lock()
        session.ring.retain { index in
            if consumer >= 0, index <= consumer, index >= consumer - behind { return true }
            for run in runs where index >= run.lowerBound - behind && index <= run.upperBound { return true }
            return false
        }
        let resident = session.ring.count * session.bytesPerFrame
        lock.unlock()
        health.residentBytes.store(resident, ordering: .relaxed)
    }

    private func firstMissing(in run: ClosedRange<Int>, session: Session) -> Int? {
        lock.lock(); defer { lock.unlock() }
        for i in run where !session.ring.contains(i) { return i }
        return nil
    }

    private func serve(run: ClosedRange<Int>, reader: inout Reader?, session: Session, isLive: Bool) {
        guard let missing = firstMissing(in: run, session: session) else { return }
        let table = session.table
        guard missing < table.count else { return }
        if reader == nil {
            reader = Reader(source: ReaderSource(source: session.source, pixelFormat: session.format), nextIndex: nil)
        }
        guard var r = reader else { return }
        defer { reader = r }

        if r.nextIndex != missing {
            if r.failedAt == missing { return }
            do {
                try r.source.start(atIndex: missing)
                r.nextIndex = missing
                r.failedAt = nil
                r.startedAt = HostClock.seconds()
                r.startTarget = missing
                if isLive { health.coldStarts.wrappingAdd(1, ordering: .relaxed) }
            } catch {
                r.failedAt = missing
                r.nextIndex = nil
                return
            }
        }

        var decoded = 0
        while decoded < configuration.decodeChunk, let expected = r.nextIndex, expected <= run.upperBound {
            guard let frame = r.source.next() else {
                // EOF or reader error: don't spin on it.
                r.nextIndex = nil
                r.failedAt = expected
                break
            }
            let index = table.index(for: frame.presentationTime)
            lock.lock()
            session.ring.insert(frame.pixelBuffer, at: index)
            lock.unlock()
            r.nextIndex = index + 1
            decoded += 1
            health.decodedFrames.wrappingAdd(1, ordering: .relaxed)
            if isLive, let target = r.startTarget, index >= target, let started = r.startedAt {
                health.raiseLatency(UInt64(max(0, HostClock.seconds() - started) * 1e9))
                r.startedAt = nil
                r.startTarget = nil
            }
        }
    }

    /// Oracle says "show nothing": after `idleReleaseSeconds` release the
    /// readers and every frame, keep the index. Cheap to resume.
    private func idle(_ session: Session) {
        let now = HostClock.seconds()
        guard let since = idleSince else {
            idleSince = now
            return
        }
        guard now - since >= configuration.idleReleaseSeconds else { return }
        teardownReaders()
        lock.lock()
        let hadFrames = session.ring.count > 0
        session.ring.removeAll()
        lock.unlock()
        if hadFrames { health.residentBytes.store(0, ordering: .relaxed) }
    }

    /// The future changed: release frames past the consumer's position so
    /// memory doesn't sit on a timeline that no longer exists. The next
    /// pass re-plans from the oracle regardless.
    private func dropFuture() {
        guard let session = currentSession() else { return }
        let consumer = consumerIndex.load(ordering: .relaxed)
        guard consumer >= 0 else { return }
        lock.lock()
        session.ring.retain { $0 <= consumer }
        lock.unlock()
    }
}
