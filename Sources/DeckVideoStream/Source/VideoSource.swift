import AVFoundation
import CoreMedia

/// Static facts about an opened video track.
public struct SourceInfo: Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let codec: String
    public let frameCount: Int
    public let durationSeconds: Double
    public let nominalFrameRate: Double
    public let hasAlpha: Bool
    public let hasBFrames: Bool
    public let keyframeCount: Int
    public let gop: FrameTable.GOPStats
    public let canProvideSampleCursors: Bool
    public let tableBuilder: FrameTable.Builder
    /// Wall time spent in `open` (asset load + table build), seconds.
    public let openSeconds: Double

    public func bytesPerFrame(_ format: PixelFormat) -> Int {
        format.bytesPerFrame(width: width, height: height)
    }
}

public enum VideoSourceError: Error {
    case noVideoTrack(URL)
    case noFormatDescription(URL)
}

/// An opened file: the asset, its first video track, and the frame table.
/// Immutable after `open`; safe to share between the worker and readers.
public final class VideoSource: @unchecked Sendable {
    public let url: URL
    public let asset: AVURLAsset
    public let track: AVAssetTrack
    public let table: FrameTable
    public let info: SourceInfo

    private init(url: URL, asset: AVURLAsset, track: AVAssetTrack, table: FrameTable, info: SourceInfo) {
        self.url = url; self.asset = asset; self.track = track; self.table = table; self.info = info
    }

    public static func open(_ url: URL) async throws -> VideoSource {
        let t0 = HostClock.seconds()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VideoSourceError.noVideoTrack(url) }
        let (descriptions, nominalRate, naturalSize) = try await track.load(.formatDescriptions, .nominalFrameRate, .naturalSize)
        let (canCursor, segments) = try await track.load(.canProvideSampleCursors, .segments)
        guard let desc = descriptions.first else { throw VideoSourceError.noFormatDescription(url) }

        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        var hasAlpha = false
        if let contains = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool {
            hasAlpha = contains
        }
        if CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_AlphaChannelMode) != nil {
            hasAlpha = true
        }

        let table = try FrameTable.build(track: track, asset: asset, segments: segments, canProvideSampleCursors: canCursor)
        let info = SourceInfo(
            url: url,
            width: Int(dims.width), height: Int(dims.height),
            codec: fourCC(subtype),
            frameCount: table.count,
            durationSeconds: table.durationSeconds,
            nominalFrameRate: nominalRate > 0 ? Double(nominalRate) : (table.nominalFrameDurationSeconds > 0 ? 1 / table.nominalFrameDurationSeconds : 0),
            hasAlpha: hasAlpha,
            hasBFrames: table.hasBFrames,
            keyframeCount: table.syncIndices.count,
            gop: table.gopStats(),
            canProvideSampleCursors: canCursor,
            tableBuilder: table.builtWith,
            openSeconds: HostClock.seconds() - t0)
        _ = naturalSize
        return VideoSource(url: url, asset: asset, track: track, table: table, info: info)
    }
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
}

/// `mach_absolute_time` ticks — the clock family audio engines anchor to.
public typealias HostTicks = UInt64

public enum HostClock {
    /// Monotonic seconds (CLOCK_UPTIME_RAW — same family as mach_absolute_time).
    public static func seconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    public static func now() -> HostTicks { mach_absolute_time() }

    /// Seconds per tick; numer/denom is not 1:1 on every machine.
    public static let secondsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    public static func ticks(adding seconds: Double, to base: HostTicks) -> HostTicks {
        let delta = seconds / secondsPerTick
        if delta >= 0 { return base &+ HostTicks(delta) }
        let back = HostTicks(-delta)
        return back > base ? 0 : base - back
    }

    /// Signed seconds from `from` to `to`.
    public static func seconds(from: HostTicks, to: HostTicks) -> Double {
        to >= from ? Double(to - from) * secondsPerTick : -Double(from - to) * secondsPerTick
    }
}
