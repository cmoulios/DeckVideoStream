import CoreVideo
import XCTest
@testable import DeckVideoStream

final class FrameRingTests: XCTestCase {
    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testInsertLookupOverwriteAndEvict() {
        let ring = FrameRing(capacity: 4)
        XCTAssertEqual(ring.capacity, 4)
        ring.insert(buffer(), at: 10)
        ring.insert(buffer(), at: 11)
        XCTAssertNotNil(ring.buffer(at: 10))
        XCTAssertNil(ring.buffer(at: 14))          // same slot as 10, different index
        XCTAssertEqual(ring.count, 2)
        ring.insert(buffer(), at: 14)              // overwrites 10
        XCTAssertNil(ring.buffer(at: 10))
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.nearest(atOrBefore: 13, backscan: 4)?.index, 11)
        XCTAssertNil(ring.nearest(atOrBefore: 13, backscan: 1))
        ring.retain { $0 >= 14 }
        XCTAssertEqual(ring.count, 1)
        XCTAssertTrue(ring.contains(14))
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
    }
}
