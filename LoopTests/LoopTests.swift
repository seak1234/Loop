//
//  LoopTests.swift
//  LoopTests
//
//  Created by Darin Krauss on 9/18/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
import LoopKit

@testable import Loop

class LoopTests: XCTestCase {}

final class CarbAbsorptionTimeTests: XCTestCase {
    func testFifteenMinuteFavoriteCanBeSavedAndReopened() throws {
        var savedFood: NewFavoriteFood?
        let viewModel = AddEditFavoriteFoodViewModel(
            carbsQuantity: 12,
            foodType: "Glucose tablets",
            absorptionTime: .minutes(15),
            onSave: { savedFood = $0 }
        )
        viewModel.name = "Glucose tablets"
        viewModel.save()

        let food = try XCTUnwrap(savedFood)
        XCTAssertEqual(food.absorptionTime, .minutes(15))
        let storedFood = StoredFavoriteFood(
            name: food.name,
            carbsQuantity: food.carbsQuantity,
            foodType: food.foodType,
            absorptionTime: food.absorptionTime
        )
        let restoredFood = try JSONDecoder().decode(StoredFavoriteFood.self, from: JSONEncoder().encode(storedFood))
        let editor = AddEditFavoriteFoodViewModel(originalFavoriteFood: restoredFood, onSave: { _ in })

        XCTAssertEqual(editor.absorptionTime, .minutes(15))
        XCTAssertTrue(editor.absorptionRimesRange.contains(editor.absorptionTime))
    }

    func testFavoriteRejectsAbsorptionTimesOutsideSupportedRange() {
        for duration in [TimeInterval.minutes(14), .hours(8) + .minutes(15)] {
            var didSave = false
            let viewModel = AddEditFavoriteFoodViewModel(
                carbsQuantity: 12,
                foodType: "Glucose tablets",
                absorptionTime: duration,
                onSave: { _ in didSave = true }
            )
            viewModel.name = "Glucose tablets"
            viewModel.save()

            XCTAssertFalse(didSave)
        }
    }

    func testFifteenMinuteEstimateMovesAbsorptionEarlierWithoutChangingTotalCarbs() {
        let model = PiecewiseLinearAbsorption()
        let shortDuration = LoopConstants.minCarbAbsorptionTime
        let standardFastDuration = TimeInterval.minutes(30)
        let modeledTime = TimeInterval.minutes(10)

        let shortAbsorption = model.absorbedCarbs(of: 12, atTime: modeledTime, absorptionTime: shortDuration)
        let standardAbsorption = model.absorbedCarbs(of: 12, atTime: modeledTime, absorptionTime: standardFastDuration)

        XCTAssertGreaterThan(shortAbsorption, standardAbsorption)
        XCTAssertEqual(model.absorbedCarbs(of: 12, atTime: 0, absorptionTime: shortDuration), 0)
        XCTAssertEqual(model.absorbedCarbs(of: 12, atTime: standardFastDuration, absorptionTime: shortDuration), 12)
        XCTAssertEqual(model.absorbedCarbs(of: 12, atTime: standardFastDuration, absorptionTime: standardFastDuration), 12)
    }
}

final class CycleTrackingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "CycleTrackingStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        calendar = nil
        super.tearDown()
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func store(_ entries: [CycleTrackingStore.PeriodEntry]) -> CycleTrackingStore {
        let store = CycleTrackingStore(defaults: defaults, calendar: calendar)
        store.replacePeriodEntries(with: entries)
        return store
    }

    func testLoggedCycleDoesNotResetWhenEstimatePasses() {
        let tracker = store([.init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5))])
        let overdue = day(2026, 1, 29)

        XCTAssertEqual(tracker.cycleDay(on: overdue), 29)
        XCTAssertNil(tracker.phase(for: overdue))
        XCTAssertNil(tracker.marker(for: overdue))
        XCTAssertNil(tracker.nextPeriodDate(from: overdue))
        XCTAssertEqual(tracker.summary(on: overdue).cycleDay, 1)
        XCTAssertEqual(tracker.summary(on: overdue).progress, 1.0 / 28)
    }

    func testPendingPeriodSummaryKeepsEstimatedPhaseAndCycleDay() {
        for endDate in [nil, day(2026, 1, 5)] {
            let tracker = store([.init(startDate: day(2026, 1, 1), endDate: endDate)])
            let recordedEntries = tracker.periodEntries

            for cycle in [1, 2, 12] {
                for (offset, cycleDay, phaseName) in [
                    (0, 1, "Period"), (5, 6, "Follicular"),
                    (13, 14, "Ovulation"), (15, 16, "Luteal"), (27, 28, "Luteal")
                ] {
                    let date = calendar.date(byAdding: .day, value: cycle * 28 + offset, to: day(2026, 1, 1))!
                    let summary = tracker.summary(on: date)

                    XCTAssertEqual(summary.cycleDay, cycleDay)
                    XCTAssertEqual(summary.phaseName, phaseName)
                    XCTAssertEqual(summary.detail, phaseName)
                    XCTAssertEqual(summary.progress, Double(cycleDay) / 28)
                    XCTAssertEqual(summary.phaseTransitions!, [5.0 / 28, 12.0 / 28, 15.0 / 28])
                }
            }

            XCTAssertEqual(tracker.periodEntries, recordedEntries)
            XCTAssertEqual(tracker.isPeriodInProgress, endDate == nil)
        }
    }

    func testLoggingNewPeriodReanchorsEstimatedSummary() {
        let tracker = store([.init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5))])
        let date = day(2026, 2, 2)
        XCTAssertEqual(tracker.summary(on: date).cycleDay, 5)

        tracker.startPeriod(on: date)

        XCTAssertEqual(tracker.summary(on: date).cycleDay, 1)
        XCTAssertEqual(tracker.summary(on: date).phaseName, "Period")
        XCTAssertEqual(tracker.summary(on: date).nextPhaseDetail, "Confirm period end")
        XCTAssertEqual(tracker.periodEntries.last?.startDate, date)
    }

    func testCalendarRepeatsEstimatedCyclesBeyondTheFirstPrediction() {
        let tracker = store([.init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5))])

        for cycle in [1, 2, 12] {
            let offset = cycle * 28
            let predictedStart = calendar.date(byAdding: .day, value: offset, to: day(2026, 1, 1))!
            let predictedOvulation = calendar.date(byAdding: .day, value: offset + 13, to: day(2026, 1, 1))!

            XCTAssertEqual(tracker.calendarPhase(for: predictedStart), .period)
            XCTAssertEqual(tracker.calendarMarker(for: predictedStart), .period)
            XCTAssertEqual(tracker.calendarPhase(for: predictedOvulation), .ovulation)
            XCTAssertEqual(tracker.calendarMarker(for: predictedOvulation), .ovulation)
        }

        XCTAssertEqual(tracker.cycleDay(on: day(2026, 1, 29)), 29)
        XCTAssertNil(tracker.phase(for: day(2026, 1, 29)))
    }

    func testRecordedPeriodReplacesCalendarProjection() {
        let tracker = store([
            .init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5)),
            .init(startDate: day(2026, 2, 2), endDate: day(2026, 2, 6))
        ])

        XCTAssertEqual(tracker.calendarPhase(for: day(2026, 2, 2)), .period)
        XCTAssertEqual(tracker.calendarMarker(for: day(2026, 2, 2)), .period)
        XCTAssertEqual(tracker.calendarPhase(for: day(2026, 2, 1)), .luteal)
    }

    func testHistoricalCycleUsesItsRecordedLength() {
        let tracker = store([
            .init(startDate: day(2025, 11, 6), endDate: day(2025, 11, 10)),
            .init(startDate: day(2025, 12, 4), endDate: day(2025, 12, 8)),
            .init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5)),
            .init(startDate: day(2026, 2, 5), endDate: day(2026, 2, 9))
        ])

        let lateJanuary = day(2026, 1, 30)
        XCTAssertEqual(tracker.cycleLength, 30)
        XCTAssertEqual(tracker.summary(on: lateJanuary).cycleLength, 35)
        XCTAssertEqual(tracker.cycleDay(on: lateJanuary), 30)
        XCTAssertEqual(tracker.phase(for: lateJanuary), .luteal)
        XCTAssertEqual(tracker.nextPeriodDate(from: lateJanuary), day(2026, 2, 5))
        XCTAssertEqual(tracker.summary(on: lateJanuary).phaseTransitions!, [5.0 / 35, 19.0 / 35, 22.0 / 35])
    }

    func testOpenPeriodContinuesPredictingAfterTenUnconfirmedDays() {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -12, to: today)!
        let tracker = store([.init(startDate: start)])

        XCTAssertEqual(tracker.phase(for: calendar.date(byAdding: .day, value: 4, to: start)!), .period)
        XCTAssertEqual(tracker.cycleDay(on: today), 13)
        XCTAssertEqual(tracker.phase(for: today), .ovulation)
        XCTAssertEqual(tracker.marker(for: today), .fertile)
        XCTAssertEqual(tracker.nextPeriodDate(from: today), calendar.date(byAdding: .day, value: 28, to: start)!)
        XCTAssertEqual(tracker.phase(for: calendar.date(byAdding: .day, value: 1, to: today)!), .ovulation)
        XCTAssertNotNil(tracker.summary(on: today).phaseTransitions)
    }

    func testStartingPeriodKeepsFuturePhasesAndRepeatingCalendarPredictions() {
        let today = calendar.startOfDay(for: Date())
        let tracker = store([])
        tracker.startPeriod(on: today)

        for cycle in [0, 1, 2, 12] {
            let offset = cycle * 28
            let predictedStart = calendar.date(byAdding: .day, value: offset, to: today)!
            let follicularDay = calendar.date(byAdding: .day, value: offset + 5, to: today)!
            let ovulationDay = calendar.date(byAdding: .day, value: offset + 13, to: today)!
            let lutealDay = calendar.date(byAdding: .day, value: offset + 15, to: today)!

            XCTAssertEqual(tracker.calendarPhase(for: predictedStart), .period)
            XCTAssertEqual(tracker.calendarMarker(for: predictedStart), .period)
            XCTAssertEqual(tracker.calendarPhase(for: follicularDay), .follicular)
            XCTAssertEqual(tracker.calendarPhase(for: ovulationDay), .ovulation)
            XCTAssertEqual(tracker.calendarMarker(for: ovulationDay), .ovulation)
            XCTAssertEqual(tracker.calendarPhase(for: lutealDay), .luteal)
        }

        XCTAssertEqual(tracker.daysUntilNextPeriod(from: today), 28)
        XCTAssertEqual(tracker.summary(on: today).phaseTransitions!, [5.0 / 28, 12.0 / 28, 15.0 / 28])
        XCTAssertTrue(tracker.isPeriodInProgress)
        XCTAssertEqual(tracker.periodEntries.count, 1)
        XCTAssertNil(tracker.periodEntries.first?.endDate)
    }

    func testLoggingPeriodEndUpdatesCurrentAndFuturePeriodEstimates() {
        let today = calendar.startOfDay(for: Date())
        let previousStart = calendar.date(byAdding: .day, value: -28, to: today)!
        let previousEnd = calendar.date(byAdding: .day, value: 1, to: previousStart)!
        let tracker = store([.init(startDate: previousStart, endDate: previousEnd)])
        tracker.startPeriod(on: today)

        let currentThirdDay = calendar.date(byAdding: .day, value: 2, to: today)!
        let nextThirdDay = calendar.date(byAdding: .day, value: 30, to: today)!
        XCTAssertEqual(tracker.periodLength, 2)
        XCTAssertEqual(tracker.calendarPhase(for: currentThirdDay), .follicular)
        XCTAssertEqual(tracker.calendarPhase(for: nextThirdDay), .follicular)

        tracker.endCurrentPeriod(on: calendar.date(byAdding: .day, value: 7, to: today)!)

        XCTAssertFalse(tracker.isPeriodInProgress)
        XCTAssertEqual(tracker.periodLength, 5)
        XCTAssertEqual(tracker.calendarPhase(for: currentThirdDay), .period)
        XCTAssertEqual(tracker.calendarMarker(for: currentThirdDay), .period)
        XCTAssertEqual(tracker.calendarPhase(for: nextThirdDay), .period)
        XCTAssertEqual(tracker.calendarMarker(for: nextThirdDay), .period)
        XCTAssertEqual(tracker.daysUntilNextPeriod(from: today), 28)
        XCTAssertEqual(tracker.summary(on: today).phaseTransitions!, [8.0 / 28, 12.0 / 28, 15.0 / 28])
    }

    func testLongRecordedPeriodKeepsItsDaysAndSkipsEmptyFollicularPhase() {
        let tracker = store([.init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 12))])

        XCTAssertEqual(tracker.phase(for: day(2026, 1, 12)), .period)
        XCTAssertEqual(tracker.marker(for: day(2026, 1, 12)), .period)
        XCTAssertEqual(tracker.phase(for: day(2026, 1, 13)), .ovulation)
        XCTAssertEqual(tracker.summary(on: day(2026, 1, 12)).phaseTransitions!, [12.0 / 28, 12.0 / 28, 15.0 / 28])
    }

    func testEstimatedFertileWindowStartsFiveDaysBeforeOvulation() {
        let tracker = store([.init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5))])

        XCTAssertNil(tracker.marker(for: day(2026, 1, 8)))
        XCTAssertEqual(tracker.marker(for: day(2026, 1, 9)), .fertile)
        XCTAssertEqual(tracker.marker(for: day(2026, 1, 14)), .ovulation)
        XCTAssertEqual(tracker.marker(for: day(2026, 1, 15)), .fertile)
        XCTAssertNil(tracker.marker(for: day(2026, 1, 16)))
    }

    func testOverlappingEntriesUseTheMostRecentStart() {
        let tracker = store([
            .init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 12)),
            .init(startDate: day(2026, 1, 10), endDate: day(2026, 1, 14))
        ])

        XCTAssertEqual(tracker.cycleDay(on: day(2026, 1, 9)), 9)
        XCTAssertEqual(tracker.cycleDay(on: day(2026, 1, 10)), 1)
        XCTAssertEqual(tracker.marker(for: day(2026, 1, 10)), .period)
    }

    func testVeryIrregularRecordedCycleDoesNotClaimAnOvulationDay() {
        let tracker = store([
            .init(startDate: day(2026, 1, 1), endDate: day(2026, 1, 5)),
            .init(startDate: day(2026, 4, 1), endDate: day(2026, 4, 5))
        ])
        let date = day(2026, 2, 15)

        XCTAssertNil(tracker.phase(for: date))
        XCTAssertNil(tracker.marker(for: date))
        XCTAssertNil(tracker.summary(on: date).phaseTransitions)
    }
}

extension XCTestCase {
    
    func waitOnMain(timeout: TimeInterval = 1.0, file: StaticString = #file, function: String = #function, line: UInt = #line) {
        let exp = expectation(description: function)
        var fulfilled = false
        DispatchQueue.main.async {
            fulfilled = true
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        XCTAssertTrue(fulfilled, "Failed to wait on main in \(function)", file: file, line: line)
    }

}
