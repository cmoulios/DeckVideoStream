import XCTest
@testable import DeckVideoStream

final class DecodePlannerTests: XCTestCase {
    func testContiguousSamplesFormOneRun() {
        XCTAssertEqual(DecodePlanner.runs(from: [5, 6, 7, 8], gapTolerance: 2), [5...8])
    }

    func testFastTempoGapsMergeWithinTolerance() {
        // ratio 1.25: 10, 11, 12, 14, 15, 16, 17, 19
        XCTAssertEqual(DecodePlanner.runs(from: [10, 11, 12, 14, 15, 16, 17, 19], gapTolerance: 2), [10...19])
    }

    func testLoopWrapMakesTwoRuns() {
        XCTAssertEqual(DecodePlanner.runs(from: [100, 101, 102, 20, 21, 22], gapTolerance: 2), [20...22, 100...102])
    }

    func testDuplicatesAndNegativesIgnored() {
        XCTAssertEqual(DecodePlanner.runs(from: [3, 3, -1, 4], gapTolerance: 0), [3...4])
        XCTAssertEqual(DecodePlanner.runs(from: [], gapTolerance: 0), [])
    }
}
