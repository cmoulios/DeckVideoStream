import AVFoundation
import CoreMedia

/// Immutable per-file index of every video sample: presentation timestamps
/// in presentation order, the decode ordinal of each, and which frames are
/// sync samples. Built once at open; all lookups are binary searches and
/// allocation-free, so the render thread can call them.
public struct FrameTable: Sendable {
    public let timescale: CMTimeScale
    /// Presentation timestamps (in `timescale` units), ascending.
    public let pts: [Int64]
    /// Decode ordinal of each presentation-ordered frame (`decodeOrdinal[i]`
    /// is the position of frame `i` in the file's decode order).
    public let decodeOrdinal: [Int32]
    /// Presentation indices of full-sync samples, ascending.
    public let syncIndices: [Int32]
    /// How the table was built (diagnostic).
    public let builtWith: Builder
    /// Median PTS delta — robust to VFR jitter and to a few dropped
    /// frames. Computed once here: the worker reads it every pass.
    public let nominalFrameDurationSeconds: Double

    public init(timescale: CMTimeScale, pts: [Int64], decodeOrdinal: [Int32],
                syncIndices: [Int32], builtWith: Builder) {
        self.timescale = timescale
        self.pts = pts
        self.decodeOrdinal = decodeOrdinal
        self.syncIndices = syncIndices
        self.builtWith = builtWith
        if pts.count > 1 {
            var deltas = [Int64](); deltas.reserveCapacity(pts.count - 1)
            for i in 1..<pts.count { deltas.append(pts[i] - pts[i - 1]) }
            deltas.sort()
            nominalFrameDurationSeconds = Double(deltas[deltas.count / 2]) / Double(timescale)
        } else {
            nominalFrameDurationSeconds = 0
        }
    }

    public enum Builder: String, Sendable { case sampleCursor, passthroughReader }

    public var count: Int { pts.count }
    public var isEmpty: Bool { pts.isEmpty }
    public var hasBFrames: Bool {
        for (i, d) in decodeOrdinal.enumerated() where Int(d) != i { return true }
        return false
    }
    public var durationSeconds: Double {
        guard let last = pts.last else { return 0 }
        return Double(last) / Double(timescale) + nominalFrameDurationSeconds
    }

    public func seconds(at index: Int) -> Double {
        Double(pts[index]) / Double(timescale)
    }

    /// Exact presentation time of frame `index` (no floating-point round trip).
    public func time(at index: Int) -> CMTime {
        CMTime(value: pts[index], timescale: timescale)
    }

    /// Last frame whose presentation time is <= `seconds` (clamped to the
    /// table's range). O(log n), no allocation. Rounds to the nearest
    /// tick so a time that IS a frame's timestamp, arrived at through
    /// floating point, lands on that frame rather than the one before.
    public func index(forSeconds seconds: Double) -> Int {
        index(forTicks: Int64((seconds * Double(timescale)).rounded()))
    }

    /// Same lookup from an exact `CMTime` (rescaled if needed).
    public func index(for time: CMTime) -> Int {
        let ticks = time.timescale == timescale
            ? time.value
            : CMTimeConvertScale(time, timescale: timescale, method: .default).value
        return index(forTicks: ticks)
    }

    public func index(forTicks target: Int64) -> Int {
        guard !pts.isEmpty else { return 0 }
        var lo = 0, hi = pts.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pts[mid] <= target { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Presentation index of the sync sample at or before `index`.
    public func keyframeIndex(atOrBefore index: Int) -> Int {
        var lo = 0, hi = syncIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Int(syncIndices[mid]) <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? 0 : Int(syncIndices[lo - 1])
    }

    /// Presentation index of the first sync sample after `index`, or `count`.
    public func nextKeyframeIndex(after index: Int) -> Int {
        var lo = 0, hi = syncIndices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Int(syncIndices[mid]) <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo < syncIndices.count ? Int(syncIndices[lo]) : count
    }

    public struct GOPStats: Sendable {
        public let gopCount: Int
        public let minFrames: Int
        public let medianFrames: Int
        public let maxFrames: Int
        /// Presentation index of the keyframe that starts the longest GOP.
        public let maxStartIndex: Int
    }

    public func gopStats() -> GOPStats {
        guard !syncIndices.isEmpty else {
            return GOPStats(gopCount: 0, minFrames: 0, medianFrames: 0, maxFrames: 0, maxStartIndex: 0)
        }
        var lengths = [(len: Int, start: Int)]()
        for (k, s) in syncIndices.enumerated() {
            let end = k + 1 < syncIndices.count ? Int(syncIndices[k + 1]) : count
            lengths.append((end - Int(s), Int(s)))
        }
        let sorted = lengths.sorted { $0.len < $1.len }
        let worst = sorted.last!
        return GOPStats(
            gopCount: lengths.count,
            minFrames: sorted.first!.len,
            medianFrames: sorted[sorted.count / 2].len,
            maxFrames: worst.len,
            maxStartIndex: worst.start)
    }
}

// MARK: - Building

public enum FrameTableError: Error {
    case noSamples
    case cannotRead(String)
}

extension FrameTable {
    /// One pass over the track's samples in decode order. Uses sample
    /// cursors when the asset provides them (local files always do); falls
    /// back to a passthrough `AVAssetReader` otherwise.
    ///
    /// Sample cursors report timestamps on the track's MEDIA timeline;
    /// everything a consumer sees (AVAssetReader output, AVPlayer time,
    /// the audio position) is on the ASSET timeline, after the track's edit
    /// list. YouTube-sourced H.264 carries a one-frame edit that hides the
    /// B-frame delay, so the two differ by exactly one frame. `segments`
    /// (the track's `AVAssetTrackSegment`s) map media → asset time; samples
    /// outside every segment are unreachable and are dropped.
    public static func build(track: AVAssetTrack, asset: AVAsset, segments: [AVAssetTrackSegment],
                             canProvideSampleCursors: Bool) throws -> FrameTable {
        if canProvideSampleCursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            return try build(cursor: cursor, segments: segments)
        }
        return try buildWithPassthroughReader(track: track, asset: asset)
    }

    /// Media time → asset time through the edit list; nil when no edit
    /// covers the sample.
    static func assetTime(forMediaTime media: CMTime, segments: [AVAssetTrackSegment]) -> CMTime? {
        guard !segments.isEmpty else { return media }
        for seg in segments where !seg.isEmpty {
            let m = seg.timeMapping
            if CMTimeRangeContainsTime(m.source, time: media) || media == m.source.end && seg === segments.last {
                let offset = CMTimeSubtract(media, m.source.start)
                let scaled: CMTime
                if m.source.duration == m.target.duration || m.source.duration.seconds == 0 {
                    scaled = offset
                } else {
                    scaled = CMTimeMultiplyByFloat64(offset, multiplier: m.target.duration.seconds / m.source.duration.seconds)
                }
                return CMTimeConvertScale(CMTimeAdd(m.target.start, scaled), timescale: media.timescale, method: .default)
            }
        }
        return nil
    }

    static func build(cursor: AVSampleCursor, segments: [AVAssetTrackSegment]) throws -> FrameTable {
        var entries = [(pts: Int64, decode: Int32, sync: Bool)]()
        var timescale: CMTimeScale = 0
        var ordinal: Int32 = 0
        while true {
            let mediaPTS = cursor.presentationTimeStamp
            if timescale == 0 { timescale = mediaPTS.timescale }
            let sync = cursor.currentSampleSyncInfo
            defer { ordinal += 1 }
            if let pts = assetTime(forMediaTime: mediaPTS, segments: segments) {
                // Rescale defensively in case a track mixes timescales.
                let value = pts.timescale == timescale
                    ? pts.value
                    : CMTimeConvertScale(pts, timescale: timescale, method: .default).value
                entries.append((value, ordinal, sync.sampleIsFullSync.boolValue))
            }
            if cursor.stepInDecodeOrder(byCount: 1) != 1 { break }
        }
        guard !entries.isEmpty else { throw FrameTableError.noSamples }
        return assemble(entries: entries, timescale: timescale, builder: .sampleCursor)
    }

    static func buildWithPassthroughReader(track: AVAssetTrack, asset: AVAsset) throws -> FrameTable {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FrameTableError.cannotRead("cannot add passthrough output") }
        reader.add(output)
        guard reader.startReading() else {
            throw FrameTableError.cannotRead(reader.error?.localizedDescription ?? "startReading failed")
        }
        defer { reader.cancelReading() }
        var entries = [(pts: Int64, decode: Int32, sync: Bool)]()
        var timescale: CMTimeScale = 0
        var ordinal: Int32 = 0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if timescale == 0 { timescale = pts.timescale }
            var sync = true
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
               let first = attachments.first,
               let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                sync = !notSync
            }
            let value = pts.timescale == timescale
                ? pts.value
                : CMTimeConvertScale(pts, timescale: timescale, method: .default).value
            entries.append((value, ordinal, sync))
            ordinal += 1
        }
        guard !entries.isEmpty else { throw FrameTableError.noSamples }
        return assemble(entries: entries, timescale: timescale, builder: .passthroughReader)
    }

    private static func assemble(entries: [(pts: Int64, decode: Int32, sync: Bool)],
                                 timescale: CMTimeScale, builder: Builder) -> FrameTable {
        let ordered = entries.sorted { $0.pts < $1.pts }
        var pts = [Int64](); pts.reserveCapacity(ordered.count)
        var decode = [Int32](); decode.reserveCapacity(ordered.count)
        var sync = [Int32]()
        for (i, e) in ordered.enumerated() {
            pts.append(e.pts)
            decode.append(e.decode)
            if e.sync { sync.append(Int32(i)) }
        }
        return FrameTable(timescale: timescale, pts: pts, decodeOrdinal: decode, syncIndices: sync, builtWith: builder)
    }
}
