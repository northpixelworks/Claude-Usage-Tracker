import XCTest
@testable import Claude_Usage

@MainActor
final class UsageStatusCalculatorTests: XCTestCase {

    // MARK: - Used-Based Thresholds (showRemaining = false)

    func testUsedBasedThresholds_Safe() {
        // 0-69% used should be safe (green)
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 0, showRemaining: false),
            .safe
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 50, showRemaining: false),
            .safe
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 69, showRemaining: false),
            .safe
        )
    }

    func testUsedBasedThresholds_Moderate() {
        // 70-89% used should be moderate (yellow)
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 70, showRemaining: false),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 85, showRemaining: false),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 89, showRemaining: false),
            .moderate
        )
    }

    func testUsedBasedThresholds_Critical() {
        // 90-100% used should be critical (red)
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 90, showRemaining: false),
            .critical
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 95, showRemaining: false),
            .critical
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 100, showRemaining: false),
            .critical
        )
    }

    // MARK: - Remaining-Based Thresholds (showRemaining = true)

    func testRemainingBasedThresholds_Safe() {
        // >=30% remaining (0-70% used) should be safe
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 0, showRemaining: true),
            .safe
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 50, showRemaining: true),
            .safe
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 70, showRemaining: true),
            .safe
        )
    }

    func testRemainingBasedThresholds_Moderate() {
        // 10-29% remaining (71-90% used) should be moderate
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 71, showRemaining: true),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 85, showRemaining: true),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 90, showRemaining: true),
            .moderate
        )
    }

    func testRemainingBasedThresholds_Critical() {
        // <10% remaining (>90% used) should be critical
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 91, showRemaining: true),
            .critical
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 95, showRemaining: true),
            .critical
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 100, showRemaining: true),
            .critical
        )
    }

    // MARK: - Display Percentage Calculation

    func testGetDisplayPercentage_UsedMode() {
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 65, showRemaining: false),
            65.0
        )
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 0, showRemaining: false),
            0.0
        )
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 100, showRemaining: false),
            100.0
        )
    }

    func testGetDisplayPercentage_RemainingMode() {
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 65, showRemaining: true),
            35.0
        )
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 0, showRemaining: true),
            100.0
        )
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 100, showRemaining: true),
            0.0
        )
    }

    // MARK: - Edge Cases

    func testBoundaryConditions_UsedMode() {
        // Test exact boundary values for used-based thresholds
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 69.9, showRemaining: false),
            .safe
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 70.0, showRemaining: false),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 89.9, showRemaining: false),
            .moderate
        )
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 90.0, showRemaining: false),
            .critical
        )
    }

    func testBoundaryConditions_RemainingMode() {
        // Test exact boundary values for remaining-based thresholds
        // 31% remaining (69% used) = safe
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 69, showRemaining: true),
            .safe
        )
        // 30% remaining (70% used) = safe (30 is included in 30... range)
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 70, showRemaining: true),
            .safe
        )
        // 29% remaining (71% used) = moderate
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 71, showRemaining: true),
            .moderate
        )
        // 10% remaining (90% used) = moderate (10 is included in 10..<30 range)
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 90, showRemaining: true),
            .moderate
        )
        // 9% remaining (91% used) = critical
        XCTAssertEqual(
            UsageStatusCalculator.calculateStatus(usedPercentage: 91, showRemaining: true),
            .critical
        )
    }

    func testNegativePercentage() {
        // Should handle negative used percentages gracefully (edge case, shouldn't happen in practice)
        // With -10% used, remaining would be 110%, clamped to 110 (max doesn't apply here)
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: -10, showRemaining: true),
            110.0  // max(0, 100 - (-10)) = max(0, 110) = 110
        )
    }

    func testOverOneHundredPercentage() {
        // Should handle over 100% gracefully
        XCTAssertEqual(
            UsageStatusCalculator.getDisplayPercentage(usedPercentage: 110, showRemaining: true),
            0.0  // max(0, 100 - 110) = 0
        )
    }

    // MARK: - Fork: red only when ahead of the time curve

    private func pace(_ used: Double, _ t: Double, orange: Bool) -> UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: used, showRemaining: false, elapsedFraction: t, showOrange: orange
        )
    }

    func testPace_OrangeOff_RedOnlyWhenAhead() {
        XCTAssertEqual(pace(45, 0.5, orange: false), .safe)
        XCTAssertEqual(pace(49.9, 0.5, orange: false), .safe)
        XCTAssertEqual(pace(50, 0.5, orange: false), .safe)      // exactly on the curve
        XCTAssertEqual(pace(50.5, 0.5, orange: false), .critical) // projected 1.01
        XCTAssertEqual(pace(80, 0.5, orange: false), .critical)
        XCTAssertEqual(pace(95, 0.97, orange: false), .safe)     // high usage but behind curve
    }

    func testPace_OrangeOn_Bands() {
        XCTAssertEqual(pace(42, 0.5, orange: true), .safe)       // projected 0.84
        XCTAssertEqual(pace(42.5, 0.5, orange: true), .moderate) // projected 0.85
        XCTAssertEqual(pace(50, 0.5, orange: true), .moderate)   // projected 1.0
        XCTAssertEqual(pace(50.5, 0.5, orange: true), .critical) // projected 1.01
    }

    func testPace_WarmUpKept() {
        // 10% elapsed, projected 1.2 (< 1.5) -> falls back to used-based thresholds
        XCTAssertEqual(pace(12, 0.10, orange: false), .safe)
        // 10% elapsed, projected 1.6 -> pace rule applies early
        XCTAssertEqual(pace(16, 0.10, orange: false), .critical)
    }

    func testFallback_OrangeOff() {
        func s(_ used: Double, _ remaining: Bool) -> UsageStatusLevel {
            UsageStatusCalculator.calculateStatus(usedPercentage: used, showRemaining: remaining, showOrange: false)
        }
        XCTAssertEqual(s(75, false), .safe)
        XCTAssertEqual(s(89.9, false), .safe)
        XCTAssertEqual(s(90, false), .critical)
        XCTAssertEqual(s(90, true), .safe)       // 10% remaining
        XCTAssertEqual(s(91, true), .critical)
    }
}
