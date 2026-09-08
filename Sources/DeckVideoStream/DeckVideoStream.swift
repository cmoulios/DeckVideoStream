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
    public let budget: MemoryBudget

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
    private var pinReader: Reader?
    private var lastEpoch: UInt64?
    private var idleSince: Double?

    // Hints: written from any thread under `lock`, consumed by the worker.
    private var loopHint: LoopHint?
    private var cueHints: [Double] = []
    private var hintsChanged = false

    // Consumer-thread-only health bookkeeping.
    private var lastRequestedIndex = -1
    private var lastDeliveredIndex = -1
    /// Consumer's latest request, for the worker's eviction floor.
    private let consumerIndex = Atomic<Int>(-1)

    /// Frames kept past a run's sampled upper edge (see eviction).
    private static let evictionMarginFrames = 3
    /// A reader this far behind a missing frame continues instead of restarting.
    private static let forwardToleranceFrames = 16

    /// Everything tied to one opened file. Replaced wholesale on open/close.
    private final class Session: @unchecked Sendable {
        let source: VideoSource
        let format: PixelFormat
        let ring: FrameRing
        let pins = PinStore()
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
                budget: MemoryBudget = .shared,
                oracle: PositionOracle,
                label: String = "com.deckvideostream.worker") {
        self.configuration = configuration
        self.budget = budget
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

    /// The loop the deck is playing (nil = none). Same value is a no-op.
    public func setLoopHint(_ hint: LoopHint?) {
        lock.lock()
        let changed = hint != loopHint
        loopHint = hint
        if changed { hintsChanged = true }
        lock.unlock()
        if changed { queue.async { [self] in pass() } }
    }

    /// File times a jump is likely to land on (hot cues). Same value is a no-op.
    public func setCueHints(_ seconds: [Double]) {
        lock.lock()
        let changed = seconds != cueHints
        cueHints = seconds
        if changed { hintsChanged = true }
        lock.unlock()
        if changed { queue.async { [self] in pass() } }
    }

    /// Equivalent to the oracle's epoch changing.
    public func invalidate() {
        queue.async { [self] in
            lastEpoch = nil
            dropFuture()
        }
    }

    // MARK: Consumer surface

    /// What `lookup(at:)` resolved: the index the time maps to, and the
    /// frame served for it (exact, nearest-earlier, or none).
    public struct Lookup {
        public let requestedIndex: Int
        public let frame: Frame?
    }

    /// The frame for `fileSeconds` if resident, else the nearest earlier
    /// frame within `backscanFrames`, else nil. Never blocks on the worker.
    public func frame(at fileSeconds: Double) -> Frame? {
        lookup(at: fileSeconds)?.frame
    }

    /// `frame(at:)` plus the requested index, for consumers that keep
    /// their own expected/delivered accounting. nil = no file open.
    public func lookup(at fileSeconds: Double) -> Lookup? {
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
        var fromPin = false
        if buffer == nil, let pinned = session.pins.buffer(at: index) {
            buffer = pinned
            fromPin = true
        }
        if buffer == nil, let near = session.ring.nearest(atOrBefore: index, backscan: configuration.backscanFrames) {
            buffer = near.buffer
            hitIndex = near.index
            exact = false
        }
        if buffer == nil, let near = session.pins.nearest(atOrBefore: index, backscan: configuration.backscanFrames) {
            buffer = near.buffer
            hitIndex = near.index
            exact = false
            fromPin = true
        }
        lock.unlock()
        if fromPin { health.pinHits.wrappingAdd(1, ordering: .relaxed) }

        consumerIndex.store(index, ordering: .relaxed)
        if index != lastRequestedIndex {
            lastRequestedIndex = index
            health.expectedFrames.wrappingAdd(1, ordering: .relaxed)
        }
        guard let buffer else {
            health.misses.wrappingAdd(1, ordering: .relaxed)
            return Lookup(requestedIndex: index, frame: nil)
        }
        if hitIndex != lastDeliveredIndex {
            lastDeliveredIndex = hitIndex
            health.deliveredFrames.wrappingAdd(1, ordering: .relaxed)
        }
        if !exact { health.staleFrames.wrappingAdd(1, ordering: .relaxed) }
        let frame = Frame(pixelBuffer: buffer, index: hitIndex,
                          presentationSeconds: table.seconds(at: hitIndex), isExact: exact)
        return Lookup(requestedIndex: index, frame: frame)
    }

    // MARK: Worker

    private func install(_ new: Session?, generation gen: UInt64) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        let old = session
        session = new
        hintsChanged = true
        lock.unlock()
        if let old { releasePins(of: old) { _ in true } }
        teardownReaders()
        lastEpoch = nil
        idleSince = nil
        health.residentBytes.store(0, ordering: .relaxed)
        health.pinnedBytes.store(0, ordering: .relaxed)
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
        pinReader?.source.cancel()
        live = nil
        aux = nil
        pinReader = nil
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
        reconcilePins(session)
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
            if configuration.verbose { print("[dvs] swap live↔aux at \(missing)") }
            swap(&live, &aux)
        }
        serve(run: primary, reader: &live, session: session, isLive: true)
        if let secondary = runs.first(where: { $0 != primary && firstMissing(in: $0, session: session) != nil }) {
            let padded = max(0, secondary.lowerBound - cfg.runGapToleranceFrames)...secondary.upperBound
            serve(run: padded, reader: &aux, session: session, isLive: false)
        } else if aux != nil, runs.count == 1 {
            aux?.source.cancel()
            aux = nil
        }

        servePins(session)

        // Evict everything outside the runs (plus a little history behind
        // whatever the consumer last asked for). Pinned frames live in the
        // PinStore, untouched by this.
        // The sampling grid is not frame-aligned, so a run's edges flicker
        // by a frame between passes; keep a margin past each edge or the
        // edge frame is evicted and re-decoded (from its keyframe) forever.
        let behind = Int((cfg.lookbehindSeconds / frameDuration).rounded(.up)) + cfg.backscanFrames
        let ahead = Self.evictionMarginFrames
        let consumer = consumerIndex.load(ordering: .relaxed)
        lock.lock()
        session.ring.retain { index in
            if consumer >= 0, index <= consumer, index >= consumer - behind { return true }
            for run in runs where index >= run.lowerBound - behind && index <= run.upperBound + ahead { return true }
            return false
        }
        let pinned = session.pins.residentBytes
        let resident = session.ring.count * session.bytesPerFrame + pinned
        lock.unlock()
        health.residentBytes.store(resident, ordering: .relaxed)
        health.pinnedBytes.store(pinned, ordering: .relaxed)
    }

    /// First index in `run` that neither the ring nor a pin holds.
    private func firstMissing(in run: ClosedRange<Int>, session: Session) -> Int? {
        lock.lock(); defer { lock.unlock() }
        for i in run where !session.ring.contains(i) && session.pins.buffer(at: i) == nil { return i }
        return nil
    }

    // MARK: Pins

    /// Turn the current hints into pin ranges: one per cue point, and for
    /// the loop either the whole range or (over budget / under pressure)
    /// just its wrap-target head. Ranges whose hint went away are released.
    private func reconcilePins(_ session: Session) {
        lock.lock()
        let changed = hintsChanged
        hintsChanged = false
        let loop = loopHint
        let cues = cueHints
        lock.unlock()
        let pressure = budget.underPressure.load(ordering: .relaxed)
        guard changed || pressure else { return }

        let table = session.table
        let cfg = configuration
        let fps = 1 / max(table.nominalFrameDurationSeconds, 1.0 / 240)
        let pad = Int((cfg.hintPaddingSeconds * fps).rounded(.up))
        let head = Int((cfg.hintHeadSeconds * fps).rounded(.up))

        var wanted: [(key: PinStore.PinKey, first: Int, length: Int)] = []
        if let loop, loop.lengthSeconds > 0 {
            // Cover the wrap target early (see hintPaddingSeconds) AND the
            // horizon past loop-out: an affine oracle keeps predicting
            // frames beyond `out` right up to the wrap, and without them
            // pinned the live reader restarts there every cycle.
            let overshoot = Int((cfg.lookaheadSeconds * fps).rounded(.up)) + Self.evictionMarginFrames
            let inIndex = table.index(forSeconds: loop.inSeconds)
            let outIndex = min(table.count - 1, table.index(forSeconds: loop.outSeconds) + overshoot)
            let first = max(0, inIndex - pad)
            let fullLength = outIndex - first + 1
            let fullBytes = fullLength * session.bytesPerFrame
            let fits = !pressure && fullBytes <= cfg.pinBudgetBytes
            if fits {
                wanted.append((.loop(loop), first, fullLength))
            } else {
                wanted.append((.loopHead(loop), first, min(fullLength, pad + head)))
            }
        }
        for cue in cues {
            let index = table.index(forSeconds: cue)
            let first = max(0, index - pad)
            let last = min(table.count - 1, index + head)
            if last >= first { wanted.append((.cue(cue), first, last - first + 1)) }
        }

        // Release what's no longer wanted, then reserve budget for new ranges
        // (a loop that doesn't fit the shared budget degrades to its head).
        let wantedKeys = Set(wanted.map(\.key))
        releasePins(of: session) { !wantedKeys.contains($0.key) }
        for w in wanted {
            lock.lock()
            let exists = session.pins.range(for: w.key) != nil
            lock.unlock()
            if exists { continue }
            let first = w.first
            var length = w.length, key = w.key
            var bytes = length * session.bytesPerFrame
            if !budget.reserve(bytes) {
                // Over the shared budget: a loop degrades to its head, a
                // cue is skipped.
                guard case .loop(let hint) = key else { continue }
                key = .loopHead(hint)
                length = min(length, pad + head)
                bytes = length * session.bytesPerFrame
                guard budget.reserve(bytes) else { continue }
            }
            if configuration.verbose {
                print("[dvs] pin \(key) frames \(first)...\(first + length - 1) (\(bytes >> 20) MB)")
            }
            let range = PinStore.Range(key: key, first: first, length: length, bytesPerFrame: session.bytesPerFrame)
            lock.lock()
            session.pins.add(range)
            lock.unlock()
        }
        // A range the pin reader was filling may be gone.
        if let r = pinReader, let target = r.startTarget, findPinRange(session, containing: target) == nil {
            pinReader?.source.cancel()
            pinReader = nil
        }
    }

    private func findPinRange(_ session: Session, containing index: Int) -> PinStore.Range? {
        lock.lock(); defer { lock.unlock() }
        return session.pins.ranges.first { $0.contains(index) }
    }

    private func releasePins(of session: Session, where predicate: (PinStore.Range) -> Bool) {
        lock.lock()
        let removed = session.pins.remove(where: predicate)
        lock.unlock()
        for r in removed {
            budget.release(r.reservedBytes)
            if configuration.verbose { print("[dvs] unpin \(r.key)") }
        }
    }

    /// Fill incomplete pin ranges, one chunk per pass, on a third reader
    /// so the live and aux readers keep their sequential paths. Frames
    /// the ring already holds are copied across rather than re-decoded.
    private func servePins(_ session: Session) {
        lock.lock()
        let incomplete = session.pins.ranges.first { !$0.isComplete }
        lock.unlock()
        guard let range = incomplete else {
            if pinReader != nil { pinReader?.source.cancel(); pinReader = nil }
            return
        }
        // Copy over anything the live window already decoded.
        lock.lock()
        if let missing = range.firstMissing() {
            for i in missing...range.last where range.buffer(at: i) == nil {
                if let b = session.ring.buffer(at: i) { range.insert(b, at: i) }
            }
        }
        let missing = range.firstMissing()
        lock.unlock()
        guard let target = missing else { return }

        if pinReader == nil {
            pinReader = Reader(source: ReaderSource(source: session.source, pixelFormat: session.format), nextIndex: nil)
        }
        guard var r = pinReader else { return }
        defer { pinReader = r }
        let continues = r.nextIndex.map { $0 <= target && target - $0 <= Self.forwardToleranceFrames } ?? false
        if !continues {
            if r.failedAt == target { return }
            do {
                try r.source.start(atIndex: target)
                r.nextIndex = target
                r.failedAt = nil
                r.startTarget = target
                if configuration.verbose { print("[dvs] pin  restart → \(target) for \(range.key)") }
            } catch {
                r.failedAt = target
                r.nextIndex = nil
                return
            }
        }
        var decoded = 0
        while decoded < configuration.decodeChunk, let expected = r.nextIndex, expected <= range.last {
            guard let frame = r.source.next() else {
                r.nextIndex = nil
                r.failedAt = expected
                break
            }
            let index = session.table.index(for: frame.presentationTime)
            lock.lock()
            range.insert(frame.pixelBuffer, at: index)
            lock.unlock()
            r.nextIndex = index + 1
            decoded += 1
            health.decodedFrames.wrappingAdd(1, ordering: .relaxed)
        }
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

        // A reader just behind the missing frame keeps going: the frames in
        // between are needed anyway (or cheap), and a restart would pay the
        // GOP prefix again. Restart only when it is past the target or far
        // behind it.
        let continues: Bool = {
            guard let next = r.nextIndex else { return false }
            return next <= missing && missing - next <= Self.forwardToleranceFrames
        }()
        if !continues {
            if r.failedAt == missing { return }
            if configuration.verbose {
                print(String(format: "[dvs] %@ restart → %d (was next %@, run %d...%d, failedAt %@)",
                             isLive ? "live" : "aux ", missing,
                             r.nextIndex.map(String.init) ?? "nil", run.lowerBound, run.upperBound,
                             r.failedAt.map(String.init) ?? "nil"))
            }
            do {
                try r.source.start(atIndex: missing)
                r.nextIndex = missing
                r.failedAt = nil
                r.startedAt = isLive ? HostClock.seconds() : nil
                r.startTarget = isLive ? missing : nil
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
                if configuration.verbose {
                    print("[dvs] \(isLive ? "live" : "aux ") next() nil at expected \(expected) status \(String(describing: r.source.status)) error \(String(describing: r.source.error))")
                }
                r.nextIndex = nil
                r.failedAt = expected
                break
            }
            let index = table.index(for: frame.presentationTime)
            if configuration.verbose, index != expected {
                print("[dvs] \(isLive ? "live" : "aux ") emitted \(index) expected \(expected)")
            }
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
        releasePins(of: session) { _ in true }
        lock.lock()
        session.ring.removeAll()
        hintsChanged = true   // re-pin when the deck comes back
        lock.unlock()
        health.residentBytes.store(0, ordering: .relaxed)
        health.pinnedBytes.store(0, ordering: .relaxed)
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
