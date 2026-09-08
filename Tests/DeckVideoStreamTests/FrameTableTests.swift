import XCTest
@testable import DeckVideoStream

final class FrameTableTests: XCTestCase {
    // 10 frames at 24 fps (timescale 24000, 1001 per frame), keyframes at 0 and 6.
    private let table = FrameTable(
        timescale: 24000,
        pts: (0..<10).map { Int64($0) * 1001 },
        decodeOrdinal: [0, 2, 1, 3, 5, 4, 6, 8, 7, 9],
        syncIndices: [0, 6],
        builtWith: .sampleCursor)

    func testIndexForSecondsIsNearestAtOrBefore() {
        XCTAssertEqual(table.index(forSeconds: 0), 0)
        XCTAssertEqual(table.index(forSeconds: 1001.0 / 24000 * 3 + 0.001), 3)
        XCTAssertEqual(table.index(forSeconds: 1001.0 / 24000 * 3 - 0.001), 2)
        XCTAssertEqual(table.index(forSeconds: 99), 9)
        XCTAssertEqual(table.index(forSeconds: -1), 0)
    }

    func testKeyframeLookups() {
        XCTAssertEqual(table.keyframeIndex(atOrBefore: 0), 0)
        XCTAssertEqual(table.keyframeIndex(atOrBefore: 5), 0)
        XCTAssertEqual(table.keyframeIndex(atOrBefore: 6), 6)
        XCTAssertEqual(table.keyframeIndex(atOrBefore: 9), 6)
        XCTAssertEqual(table.nextKeyframeIndex(after: 0), 6)
        XCTAssertEqual(table.nextKeyframeIndex(after: 6), 10)
    }

    func testGOPStatsAndBFrames() {
        let g = table.gopStats()
        XCTAssertEqual(g.gopCount, 2)
        XCTAssertEqual(g.maxFrames, 6)
        XCTAssertEqual(g.maxStartIndex, 0)
        XCTAssertTrue(table.hasBFrames)
        XCTAssertEqual(table.nominalFrameDurationSeconds, 1001.0 / 24000, accuracy: 1e-9)
    }
}
