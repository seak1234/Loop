import XCTest
@testable import Loop

final class GlucoseStatisticsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_006_400)
    private func reading(_ seconds: Double, _ value: Double) -> GlucoseStatisticsReading {
        .init(date: start.addingTimeInterval(seconds), mgdl: value)
    }
    private func calculate(_ readings: [GlucoseStatisticsReading], seconds: Double = 600, lower: Double = 70, upper: Double = 180) -> GlucoseStatistics {
        .calculate(readings: readings, start: start, end: start.addingTimeInterval(seconds), lower: lower, upper: upper)
    }
    private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000001 } ?? false }

    func testTimeWeightingAndPopulationDeviation() {
        let result = calculate([reading(0, 100), reading(100, 200)], seconds: 400)
        XCTAssertTrue(close(result.meanMGDL, 175))
        XCTAssertTrue(close(result.standardDeviationMGDL, sqrt(1875)))
        XCTAssertTrue(close(result.inRange, 0.25))
        XCTAssertTrue(close(result.aboveRange, 0.75))
        XCTAssertTrue(close(result.coefficientOfVariation, sqrt(1875) / 175 * 100))
    }

    func testGapsDuplicatesAndWindowClipping() {
        let result = calculate([reading(-150, 100), reading(600, 200), reading(600, 200), reading(1200, 400), reading(0, .nan)], seconds: 1200)
        XCTAssertTrue(close(result.coveredSeconds, 450))
        XCTAssertTrue(close(result.meanMGDL, (100 * 150 + 200 * 300) / 450))
        XCTAssertTrue(close(result.coverage, 0.375))
        XCTAssertEqual(result.readingCount, 1)
    }

    func testCustomRangeAndSevereThresholds() {
        let readings = [reading(0, 50), reading(300, 80), reading(600, 145), reading(900, 260)]
        let custom = calculate(readings, seconds: 1200, lower: 80, upper: 145)
        XCTAssertTrue(close(custom.inRange, 0.5))
        XCTAssertTrue(close(custom.belowRange, 0.25))
        XCTAssertTrue(close(custom.aboveRange, 0.25))
        XCTAssertTrue(close(custom.below54, 0.25))
        XCTAssertTrue(close(custom.above250, 0.25))
        let changed = calculate(readings, seconds: 1200, lower: 100, upper: 180)
        XCTAssertTrue(close(changed.inRange, 0.25))
        XCTAssertTrue(close(changed.belowRange, 0.5))
    }

    func testEmptyHistoryHasNoInventedValues() {
        let result = calculate([])
        XCTAssertNil(result.meanMGDL)
        XCTAssertNil(result.inRange)
        XCTAssertNil(result.coefficientOfVariation)
        XCTAssertNil(result.gmi)
        XCTAssertEqual(result.coverage, 0)
        let insulin = GlucoseInsulinStatistics.calculate(local: [], remoteBoluses: [], start: start, end: start.addingTimeInterval(86400))
        XCTAssertNil(insulin.total)
        XCTAssertNil(insulin.recordedDailyAverage)
    }

    func testGMINeedsFourteenDaysAndCoverage() {
        let seconds = 14.0 * 86400
        let readings = stride(from: 0.0, to: seconds, by: 300).map { reading($0, 150) }
        XCTAssertTrue(close(calculate(readings, seconds: seconds).gmi, 3.31 + 0.02392 * 150))
        XCTAssertNil(calculate(Array(readings.prefix(100)), seconds: seconds).gmi)
        XCTAssertNil(calculate(readings, seconds: 86400).gmi)
    }

    func testNightscoutMergeKeepsLocalAndFillsGaps() {
        let merged = GlucoseStatistics.merge(local: [reading(0, 100), reading(300, 110), reading(600, .nan)],
                                             remote: [reading(30, 200), reading(290, 220), reading(600, 120)])
        let result = calculate(merged, seconds: 900)
        XCTAssertEqual(result.readingCount, 3)
        XCTAssertTrue(close(result.meanMGDL, 110))
    }

    func testInsulinClipsBasalAndDoesNotDoubleCountMirroredBoluses() {
        let end = start.addingTimeInterval(3600)
        let basal = GlucoseStatisticsInsulin(start: start.addingTimeInterval(-3600), end: end, units: 2, kind: .basal)
        let bolus = GlucoseStatisticsInsulin(start: start.addingTimeInterval(600), end: start.addingTimeInterval(600), units: 3, kind: .bolus)
        let result = GlucoseInsulinStatistics.calculate(local: [basal, bolus], remoteBoluses: [bolus], start: start, end: end)
        XCTAssertTrue(close(result.basal, 1))
        XCTAssertTrue(close(result.bolus, 3))
        XCTAssertTrue(close(result.total, 4))
        XCTAssertTrue(close(result.basalPercentage, 25))
        XCTAssertTrue(close(result.coverage, 1))
        XCTAssertFalse(result.hasRemoteBolusOnlyDays)
    }

    func testRemoteInsulinOnlyOnMissingDaysAndNeverSuppliesBasal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: start)
        let local = GlucoseStatisticsInsulin(start: day, end: day.addingTimeInterval(86400), units: 12, kind: .basal)
        let mirrored = GlucoseStatisticsInsulin(start: day.addingTimeInterval(600), end: day.addingTimeInterval(600), units: 2, kind: .bolus)
        let remote = GlucoseStatisticsInsulin(start: day.addingTimeInterval(87000), end: day.addingTimeInterval(87000), units: 4, kind: .bolus)
        let result = GlucoseInsulinStatistics.calculate(local: [local], remoteBoluses: [mirrored, remote], start: day, end: day.addingTimeInterval(172800), calendar: calendar)
        XCTAssertTrue(close(result.total, 16))
        XCTAssertTrue(close(result.recordedDailyAverage, 8))
        XCTAssertTrue(close(result.coverage, 0.5))
        XCTAssertTrue(result.hasRemoteBolusOnlyDays)
        XCTAssertNil(result.basalPercentage)
    }

    func testInsulinCoverageUnionsIntervalsAndExcludesOutsideWindow() {
        let basal = GlucoseStatisticsInsulin(start: start, end: start.addingTimeInterval(600), units: 1, kind: .basal)
        let old = GlucoseStatisticsInsulin(start: start.addingTimeInterval(-600), end: start.addingTimeInterval(-600), units: 3, kind: .bolus)
        let future = GlucoseStatisticsInsulin(start: start.addingTimeInterval(600), end: start.addingTimeInterval(600), units: 3, kind: .bolus)
        let result = GlucoseInsulinStatistics.calculate(local: [basal, basal, old, future], remoteBoluses: [], start: start, end: start.addingTimeInterval(600))
        XCTAssertEqual(result.coverage, 1)
        XCTAssertNil(result.bolus)
    }

    func testStatisticsSettingsPersistAndKeepExistingRange() {
        let suite = "GlucoseStatisticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlucoseStatisticsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.days, 14)
        XCTAssertTrue(store.useNightscout)
        store.days = 30
        store.useNightscout = false
        let restored = GlucoseStatisticsSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.days, 30)
        XCTAssertFalse(restored.useNightscout)
        let range = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertTrue(range.updateBounds(lowerBoundMGDL: 80, upperBoundMGDL: 145))
        range.setEnabled(false)
        let samples = [reading(0, 90), reading(300, 160)]
        XCTAssertTrue(close(calculate(samples, lower: range.settings.lowerBoundMGDL, upper: range.settings.upperBoundMGDL).inRange, 0.5))
    }

    func testDayButtonsRecalculateTheSelectedWindow() {
        XCTAssertEqual(GlucoseStatisticsSettingsStore.periods, [3, 7, 14, 30, 90])
        let end = start.addingTimeInterval(90 * 86400)
        let readings = stride(from: 0.0, to: 90 * 86400, by: 300).map {
            reading($0, $0 >= 87 * 86400 ? 120 : 220)
        }
        for days in GlucoseStatisticsSettingsStore.periods {
            let windowStart = end.addingTimeInterval(-Double(days) * 86400)
            let result = GlucoseStatistics.calculate(readings: readings, start: windowStart, end: end, lower: 80, upper: 145)
            XCTAssertTrue(close(result.inRange, 3.0 / Double(days)))
            XCTAssertTrue(close(result.aboveRange, 1 - 3.0 / Double(days)))
            XCTAssertTrue(close(result.coverage, 1))
        }
    }

    func testRemovedOneDayPreferenceFallsBackToFourteenDays() {
        let suite = "GlucoseStatisticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "com.loopkit.Loop.GlucoseStatistics.days")
        XCTAssertEqual(GlucoseStatisticsSettingsStore(defaults: defaults).days, 14)
    }
}
