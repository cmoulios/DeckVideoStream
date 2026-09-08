import CoreVideo
import XCTest
@testable import DeckVideoStream

final class PinStoreTests: XCTestCase {
    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb!
    }

    func testRangeFillLookupAndRelease() {
        let store = PinStore()
        let hint = LoopHint(inSeconds: 1, outSeconds: 3)
        let range = PinStore.Range(key: .loop(hint), first: 10, length: 5, bytesPerFrame: 100)
        store.add(range)
        XCTAssertEqual(range.firstMissing(), 10)
        range.insert(buffer(), at: 10)
        range.insert(buffer(), at: 12)
        XCTAssertEqual(range.firstMissing(), 11)
        XCTAssertEqual(range.firstMissing(from: 12), 13)
        XCTAssertFalse(range.isComplete)
        XCTAssertNotNil(store.buffer(at: 12))
        XCTAssertNil(store.buffer(at: 11))
        XCTAssertEqual(store.nearest(atOrBefore: 11, backscan: 2)?.index, 10)
        XCTAssertEqual(store.residentBytes, 200)
        XCTAssertEqual(store.reservedBytes, 500)
        for i in [11, 13, 14] { range.insert(buffer(), at: i) }
        XCTAssertTrue(range.isComplete)
        let removed = store.remove { $0.key == .loop(hint) }
        XCTAssertEqual(removed.count, 1)
        XCTAssertNil(store.buffer(at: 10))
    }

    func testBudgetReserveRelease() {
        let budget = MemoryBudget(totalBytes: 1000)
        XCTAssertTrue(budget.reserve(600))
        XCTAssertFalse(budget.reserve(600))
        XCTAssertTrue(budget.reserve(400))
        budget.release(600)
        XCTAssertEqual(budget.pinnedBytes.load(ordering: .relaxed), 400)
    }
}
