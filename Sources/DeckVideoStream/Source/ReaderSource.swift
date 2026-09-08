import AVFoundation
import CoreMedia
import CoreVideo

/// One decoded frame in presentation order.
public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public var seconds: Double { presentationTime.seconds }
}

public enum ReaderSourceError: Error {
    case cannotAddOutput
    case startFailed(String)
    case notStarted
}

/// Backend A: `AVAssetReader` + `AVAssetReaderTrackOutput` with pixel-buffer
/// output settings. AVFoundation does demux, hardware decode, B-frame
/// reordering and pixel-format conversion; frames come out in presentation
/// order from the keyframe at or before the requested start.
///
/// Not seekable: a discontinuity is a `start(atSeconds:)`, which builds a
/// new reader (`restart` mode), or — when `randomAccess` is on — a
/// `reset(forReadingTimeRanges:)` on the existing output once the current
/// range is exhausted (`reset` mode). Single-threaded by contract: one
/// owner drives `start`/`next`/`cancel`.
public final class ReaderSource: @unchecked Sendable {
    public let source: VideoSource
    public let pixelFormat: PixelFormat
    public let randomAccess: Bool

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    public private(set) var restartCount = 0
    public private(set) var resetCount = 0

    public init(source: VideoSource, pixelFormat: PixelFormat, randomAccess: Bool = false) {
        self.source = source
        self.pixelFormat = pixelFormat
        self.randomAccess = randomAccess
    }

    public var outputSettings: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.osType,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
    }

    /// Tear down any current reader and start a new one at `atSeconds`.
    /// Returns wall seconds spent creating + starting (not the first decode).
    @discardableResult
    public func start(atSeconds: Double, endSeconds: Double? = nil) throws -> Double {
        try start(at: timeRange(startSeconds: atSeconds, endSeconds: endSeconds))
    }

    /// Start at an exact frame boundary from the table.
    @discardableResult
    public func start(atIndex index: Int, endIndex: Int? = nil) throws -> Double {
        let t = source.table
        let end = endIndex.map { $0 < t.count ? t.time(at: $0) : .positiveInfinity } ?? .positiveInfinity
        return try start(at: CMTimeRange(start: t.time(at: index), end: end))
    }

    @discardableResult
    public func start(at range: CMTimeRange) throws -> Double {
        let t0 = HostClock.seconds()
        cancel()
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = randomAccess
        guard reader.canAdd(output) else { throw ReaderSourceError.cannotAddOutput }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else {
            throw ReaderSourceError.startFailed(reader.error?.localizedDescription ?? "unknown")
        }
        self.reader = reader
        self.output = output
        restartCount += 1
        return HostClock.seconds() - t0
    }

    /// `randomAccess` only: after `next()` has returned nil for the current
    /// range, retarget the same reader. Returns wall seconds spent.
    @discardableResult
    public func reset(toSeconds: Double, endSeconds: Double? = nil) throws -> Double {
        try reset(to: timeRange(startSeconds: toSeconds, endSeconds: endSeconds))
    }

    @discardableResult
    public func reset(toIndex index: Int) throws -> Double {
        try reset(to: CMTimeRange(start: source.table.time(at: index), end: .positiveInfinity))
    }

    @discardableResult
    public func reset(to range: CMTimeRange) throws -> Double {
        guard let output, randomAccess else { throw ReaderSourceError.notStarted }
        let t0 = HostClock.seconds()
        output.reset(forReadingTimeRanges: [NSValue(timeRange: range)])
        resetCount += 1
        return HostClock.seconds() - t0
    }

    /// Next frame in presentation order, or nil at the end of the range / on error.
    public func next() -> DecodedFrame? {
        guard let output else { return nil }
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return next() }
        return DecodedFrame(pixelBuffer: image, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// `randomAccess` only: tell the reader no further ranges are coming.
    public func markConfigurationFinished() {
        output?.markConfigurationAsFinal()
    }

    public var status: AVAssetReader.Status? { reader?.status }
    public var error: Error? { reader?.error }

    public func cancel() {
        if let reader, reader.status == .reading { reader.cancelReading() }
        reader = nil
        output = nil
    }

    private func timeRange(startSeconds: Double, endSeconds: Double?) -> CMTimeRange {
        let scale = source.table.timescale
        let start = CMTime(seconds: max(0, startSeconds), preferredTimescale: scale)
        let end = endSeconds.map { CMTime(seconds: $0, preferredTimescale: scale) } ?? .positiveInfinity
        return CMTimeRange(start: start, end: end)
    }
}
