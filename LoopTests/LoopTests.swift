//
//  LoopTests.swift
//  LoopTests
//
//  Created by Darin Krauss on 9/18/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import XCTest

@testable import Loop

class LoopTests: XCTestCase {}

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
        XCTAssertEqual(tracker.summary(on: overdue).progress, 1)
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

    func testOpenPeriodStopsPredictingAfterTenUnconfirmedDays() {
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -12, to: today)!
        let tracker = store([.init(startDate: start)])

        XCTAssertEqual(tracker.phase(for: calendar.date(byAdding: .day, value: 4, to: start)!), .period)
        XCTAssertEqual(tracker.cycleDay(on: today), 13)
        XCTAssertNil(tracker.phase(for: today))
        XCTAssertNil(tracker.marker(for: today))
        XCTAssertNil(tracker.nextPeriodDate(from: today))
        XCTAssertNil(tracker.phase(for: calendar.date(byAdding: .day, value: 1, to: today)!))
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
