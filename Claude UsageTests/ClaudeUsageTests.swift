import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeUsageTests: XCTestCase {

    // MARK: - Status Level Tests (Deprecated Property - uses remaining-based thresholds)

    func testStatusLevelSafe() {
        // statusLevel uses remaining-based thresholds: safe when remaining >= 20%
        let usage = createUsage(sessionPercentage: 0)  // 100% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage.effectiveSessionPercentage, showRemaining: true), .safe)

        let usage25 = createUsage(sessionPercentage: 25)  // 75% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage25.effectiveSessionPercentage, showRemaining: true), .safe)

        let usage80 = createUsage(sessionPercentage: 80)  // 20% remaining (exact boundary)
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage80.effectiveSessionPercentage, showRemaining: true), .safe)
    }

    func testStatusLevelModerate() {
        // statusLevel uses remaining-based thresholds: moderate when 10% <= remaining < 20%
        let usage81 = createUsage(sessionPercentage: 81)  // 19% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage81.effectiveSessionPercentage, showRemaining: true), .moderate)

        let usage85 = createUsage(sessionPercentage: 85)  // 15% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage85.effectiveSessionPercentage, showRemaining: true), .moderate)

        let usage90 = createUsage(sessionPercentage: 90)  // 10% remaining (exact boundary)
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage90.effectiveSessionPercentage, showRemaining: true), .moderate)
    }

    func testStatusLevelCritical() {
        // statusLevel uses remaining-based thresholds: critical when remaining < 10%
        let usage91 = createUsage(sessionPercentage: 91)  // 9% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage91.effectiveSessionPercentage, showRemaining: true), .critical)

        let usage95 = createUsage(sessionPercentage: 95)  // 5% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage95.effectiveSessionPercentage, showRemaining: true), .critical)

        let usage100 = createUsage(sessionPercentage: 100)  // 0% remaining
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: usage100.effectiveSessionPercentage, showRemaining: true), .critical)
    }

    // MARK: - Empty Usage Tests

    func testEmptyUsage() {
        let empty = ClaudeUsage.empty

        XCTAssertEqual(empty.sessionTokensUsed, 0)
        XCTAssertEqual(empty.sessionPercentage, 0)
        XCTAssertEqual(empty.weeklyTokensUsed, 0)
        XCTAssertEqual(empty.weeklyPercentage, 0)
        XCTAssertEqual(UsageStatusCalculator.calculateStatus(usedPercentage: empty.effectiveSessionPercentage, showRemaining: true), .safe)
        XCTAssertNil(empty.costUsed)
        XCTAssertNil(empty.costLimit)
    }

    // MARK: - Codable Tests

    func testEncodeDecode() throws {
        let original = createUsage(sessionPercentage: 45.5)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ClaudeUsage.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Helpers

    private func createUsage(sessionPercentage: Double) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(sessionPercentage * 1000),
            sessionLimit: 100000,
            sessionPercentage: sessionPercentage,
            sessionResetTime: Date().addingTimeInterval(3600),
            weeklyTokensUsed: 500000,
            weeklyLimit: 1000000,
            weeklyPercentage: 50,
            weeklyResetTime: Date().addingTimeInterval(86400),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }
}
