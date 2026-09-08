import CoreVideo

/// Output pixel format for decoded frames.
///
/// `bgra8` is what the hardware decoder can hand straight to CoreImage /
/// Metal with no further conversion on the consumer side, at 4 B/px.
/// `nv12VideoRange` (biplanar 4:2:0) is what the decoder produces natively,
/// at 1.5 B/px — 2.67× more frames per byte of cache, at the cost of a
/// YCbCr→RGB step wherever the frame is sampled (CoreImage does this on
/// the GPU automatically for `CIImage(cvPixelBuffer:)`).
public enum PixelFormat: String, Sendable, CaseIterable {
    case bgra8
    case nv12VideoRange

    public var osType: OSType {
        switch self {
        case .bgra8: return kCVPixelFormatType_32BGRA
        case .nv12VideoRange: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    /// Nominal bytes for one frame at the given size (ignores row padding).
    public func bytesPerFrame(width: Int, height: Int) -> Int {
        switch self {
        case .bgra8: return width * height * 4
        case .nv12VideoRange: return width * height * 3 / 2
        }
    }
}
