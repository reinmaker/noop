import XCTest
import StrandAnalytics
@testable import Strand

/// Yoop's deep and REM priors for the sleep recipe, and only on its own path.
final class YoopStagePriorsTests: XCTestCase {

    func testThePriorsApplyOnTheYoopPathAndAreZeroElsewhere() {
        let saved = (SleepStagerV2.deepLogShift, SleepStagerV2.remLogShift)
        defer { (SleepStagerV2.deepLogShift, SleepStagerV2.remLogShift) = saved }
        IntelligenceEngine.applyYoopStagePriors(true)
        XCTAssertEqual(SleepStagerV2.deepLogShift, IntelligenceEngine.yoopDeepLogShift)
        XCTAssertEqual(SleepStagerV2.remLogShift, IntelligenceEngine.yoopRemLogShift)
        IntelligenceEngine.applyYoopStagePriors(false)
        XCTAssertEqual(SleepStagerV2.deepLogShift, 0)
        XCTAssertEqual(SleepStagerV2.remLogShift, 0)
    }

    /// The shifts are small corrections to the recipe's priors (the whole scan of 0 to 1.2 moved deep from 16 % to
    /// 44 % on the wearer's nights); a larger value would be a different recipe.
    func testTheShiftsAreSmall() {
        XCTAssertTrue((0...0.5).contains(IntelligenceEngine.yoopDeepLogShift))
        XCTAssertTrue((0...0.5).contains(IntelligenceEngine.yoopRemLogShift))
    }
}
