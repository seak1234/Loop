import XCTest
#if canImport(Loop)
@testable import Loop
#else
@testable import CompanionCore
#endif

final class CompanionCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCycleQuestionsRequestTrackerContextBeforeModelResponse() {
        XCTAssertTrue(CompanionCycleIntent.matches("What cycle phase am I in?"))
        XCTAssertTrue(CompanionCycleIntent.matches("Can you read my PERIOD tracker?"))
        XCTAssertTrue(CompanionCycleIntent.matches("Could PMS explain these cravings?"))
        XCTAssertFalse(CompanionCycleIntent.matches("Help me set a glucose alert"))
    }

    func testDashboardRefreshCadenceAndRetryThrottle() {
        XCTAssertTrue(CompanionDashboardRefresh.isConcise("Small observations build diabetes know-how."))
        XCTAssertFalse(CompanionDashboardRefresh.isConcise(String(repeating: "x", count: 91)))
        XCTAssertFalse(CompanionDashboardRefresh.isConcise(Array(repeating: "one", count: 13).joined(separator: " ")))
        let oldStyle = CompanionDashboardMessage(text: "A longer company greeting", generatedAt: now, includesHealthData: false, styleVersion: nil)
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(oldStyle, now: now))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: oldStyle, lastAttempt: nil, dataChanged: false, now: now))
        let message = CompanionDashboardMessage(text: "Hello", generatedAt: now, includesHealthData: true)
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: nil, lastAttempt: nil, dataChanged: false, now: now))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(299)))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(300)))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: false, now: now.addingTimeInterval(899)))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: false, now: now.addingTimeInterval(900)))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: nil, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(60)))
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(message, now: now.addingTimeInterval(1800)))
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(message, now: now.addingTimeInterval(-1)))
    }

    func testDashboardUsesLocalDayAndLegacyStateStillLoads() throws {
        let midnight = cycleCalendar.startOfDay(for: now)
        let message = CompanionDashboardMessage(text: "Evening", generatedAt: midnight.addingTimeInterval(-600), includesHealthData: false)
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: nil, dataChanged: false, now: midnight, calendar: cycleCalendar))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CompanionState())) as! [String: Any]
        json.removeValue(forKey: "dashboardMessage")
        let legacy = try JSONDecoder().decode(CompanionState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.dashboardMessage)
    }

    func testDashboardRequestOmitsToolParameters() {
        let body = OpenRouterCompanionProvider.requestBody(model: "example/model", reasoningEffort: .medium, messages: [], tools: [])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        let chat = OpenRouterCompanionProvider.requestBody(model: "example/model", reasoningEffort: .medium, messages: [], tools: CompanionTools.definitions)
        XCTAssertEqual(chat["tool_choice"] as? String, "auto")
    }

    func testSuggestedTopicsRequireTwoDistinctShortTitlesAndPrompts() throws {
        let valid = #"{"topics":[{"title":"Food labels","prompt":"Help me understand carb labels."},{"title":"Sleep and glucose","prompt":"How might sleep affect glucose?"}]}"#
        XCTAssertEqual(try CompanionTopic.decodeSuggestions(valid).count, 2)
        XCTAssertThrowsError(try CompanionTopic.decodeSuggestions(#"{"topics":[{"title":"Food labels","prompt":"Learn."}]}"#))
        XCTAssertThrowsError(try CompanionTopic.decodeSuggestions(#"{"topics":[{"title":"Food labels","prompt":"Learn."},{"title":"food labels","prompt":"Learn more."}]}"#))
        XCTAssertThrowsError(try CompanionTopic.decodeSuggestions(#"{"topics":[{"title":"Pep talk","prompt":"Motivate me."},{"title":"Sleep and glucose","prompt":"Learn."}]}"#))
        XCTAssertThrowsError(try CompanionTopic.decodeSuggestions(#"{"topics":[{"title":"Food labels","prompt":""},{"title":"Sleep and glucose","prompt":"Learn."}]}"#))
    }

    private var cycleCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func cycleDate(_ days: Int) -> Date {
        cycleCalendar.date(byAdding: .day, value: days, to: cycleCalendar.startOfDay(for: now))!
    }

    func testMissingCycleHistoryDoesNotBecomeAnAssumedNormalCycle() {
        let context = CompanionCycleContext(asOf: now, cycleDay: nil, phase: .luteal, cycleLength: 28,
            nextPeriodStart: cycleDate(7), periods: [], calendar: cycleCalendar)
        XCTAssertFalse(context.hasLoggedPeriods)
        XCTAssertNil(context.cycleDay)
        XCTAssertEqual(context.phase, .unknown)
        XCTAssertNil(context.estimatedCycleLengthDays)
        XCTAssertNil(context.estimatedNextPeriodStart)
        XCTAssertFalse(context.symptomDataAvailable)
    }

    func testSinglePeriodLabelsCycleLengthAndPhaseAsEstimates() {
        let context = CompanionCycleContext(asOf: now, cycleDay: 21, phase: .luteal, cycleLength: 28,
            nextPeriodStart: cycleDate(8), periods: [.init(startDate: cycleDate(-20), endDate: cycleDate(-16))], calendar: cycleCalendar)
        XCTAssertTrue(context.phaseIsEstimate)
        XCTAssertEqual(context.phase, .luteal)
        XCTAssertEqual(context.cycleLengthBasis, "app_default_not_personal_history")
        XCTAssertEqual(context.usableRecordedIntervalDays, [])
        XCTAssertEqual(context.estimatedNextPeriodStart, cycleDate(8))
    }

    func testConfirmedBleedingIsDifferentFromEstimatedHormonalPhase() {
        let context = CompanionCycleContext(asOf: now, cycleDay: 3, phase: .period, cycleLength: 28,
            nextPeriodStart: cycleDate(26), periods: [.init(startDate: cycleDate(-2), endDate: cycleDate(0))], calendar: cycleCalendar)
        XCTAssertFalse(context.phaseIsEstimate)
        XCTAssertEqual(context.phaseBasis, "within_user_logged_period_start_and_end")
        XCTAssertFalse(context.periodEndNotLogged)
    }

    func testFuturePeriodEndDoesNotConfirmBleeding() {
        let context = CompanionCycleContext(asOf: now, cycleDay: 3, phase: .period, cycleLength: 28,
            nextPeriodStart: cycleDate(26), periods: [.init(startDate: cycleDate(-2), endDate: cycleDate(2))], calendar: cycleCalendar)
        XCTAssertTrue(context.phaseIsEstimate)
        XCTAssertTrue(context.periodEndNotLogged)
        XCTAssertNil(context.recentPeriods.first?.endDate)
    }

    func testUnclosedOverduePeriodDoesNotClaimOngoingBleedingOrProjectAnotherCycle() {
        let context = CompanionCycleContext(asOf: now, cycleDay: 41, phase: .unknown, cycleLength: 28,
            nextPeriodStart: cycleDate(5), periods: [.init(startDate: cycleDate(-40), endDate: nil)], calendar: cycleCalendar)
        XCTAssertTrue(context.periodEndNotLogged)
        XCTAssertEqual(context.phase, .unknown)
        XCTAssertNil(context.estimatedNextPeriodStart)
        XCTAssertTrue(context.notes.contains { $0.contains("does not establish continued bleeding") })
    }

    func testCycleContextBoundsHistoryAndExcludesFuturePeriodStarts() {
        var records = (0..<8).map { index in
            CompanionCycleContext.Period(startDate: cycleDate(-index * 28), endDate: cycleDate(-index * 28 + 4))
        }
        records.append(.init(startDate: cycleDate(28), endDate: nil))
        let context = CompanionCycleContext(asOf: now, cycleDay: 1, phase: .period, cycleLength: 28,
            nextPeriodStart: cycleDate(28), periods: records, calendar: cycleCalendar)
        XCTAssertEqual(context.recordedPeriodCount, 8)
        XCTAssertEqual(context.recentPeriods.count, 6)
        XCTAssertEqual(context.usableRecordedIntervalDays, Array(repeating: 28, count: 6))
        XCTAssertEqual(context.cycleLengthBasis, "calendar_estimate_from_logged_start_intervals")
        XCTAssertFalse(context.recentPeriods.contains { $0.startDate > now })
    }

    func testCyclePayloadContainsSourcesButNoInventedSymptomsOrInsulinMeasurements() throws {
        let context = CompanionCycleContext(asOf: now, cycleDay: 2, phase: .period, cycleLength: 28,
            nextPeriodStart: cycleDate(27), periods: [.init(startDate: cycleDate(-1), endDate: nil)], calendar: cycleCalendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let value = try JSONSerialization.jsonObject(with: encoder.encode(context)) as! [String: Any]
        XCTAssertEqual(value["symptomDataAvailable"] as? Bool, false)
        XCTAssertNil(value["energy"])
        XCTAssertNil(value["cravings"])
        XCTAssertNil(value["insulinResistance"])
        XCTAssertEqual((value["generalEducation"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(context.phaseIsEstimate)
        XCTAssertEqual(context.phaseBasis, "period_start_logged_end_unconfirmed")
    }

    func testGPT61MediumIsSentAsModelAndSeparateReasoningParameter() {
        let body = OpenRouterCompanionProvider.requestBody(model: "openai/gpt-6.1-sol", reasoningEffort: .medium,
            messages: [["role": "user", "content": "Hello"]], tools: [])
        XCTAssertEqual(body["model"] as? String, "openai/gpt-6.1-sol")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "medium")
        XCTAssertEqual(body["max_tokens"] as? Int, 16384)
    }

    func testProviderDefaultDoesNotSendAnUnsupportedEffort() {
        let body = OpenRouterCompanionProvider.requestBody(model: "example/model", reasoningEffort: .providerDefault,
            messages: [], tools: [])
        XCTAssertNil(body["reasoning"])
    }

    func testModelMetadataFiltersEffortsAndIncompatibleModels() throws {
        let data = Data(#"{"id":"openai/gpt-6.1-sol","name":"GPT-6.1 Sol","supported_parameters":["tools","reasoning"],"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"reasoning":{"supported_efforts":["low","medium","high","xhigh","max"],"mandatory":true}}"#.utf8)
        let model = try JSONDecoder().decode(CompanionModel.self, from: data)
        XCTAssertTrue(model.isChatToolModel)
        XCTAssertEqual(model.efforts, [.providerDefault, .low, .medium, .high, .xhigh, .max])
        var incompatible = model
        incompatible.id += ":batch"
        XCTAssertFalse(incompatible.isChatToolModel)
        incompatible = model; incompatible.supported_parameters = []
        XCTAssertFalse(incompatible.isChatToolModel)
        incompatible = model; incompatible.architecture = .init(input_modalities: ["text"], output_modalities: ["image"])
        XCTAssertFalse(incompatible.isChatToolModel)
    }

    func testMissingAndNullEffortMetadataHaveDifferentMeanings() throws {
        let omitted = try JSONDecoder().decode(CompanionModel.Reasoning.self, from: Data(#"{"mandatory":false}"#.utf8))
        let nullable = try JSONDecoder().decode(CompanionModel.Reasoning.self, from: Data(#"{"mandatory":true,"supported_efforts":null}"#.utf8))
        var model = CompanionModel.gpt61
        model.reasoning = omitted
        XCTAssertEqual(model.efforts, [.providerDefault])
        model.reasoning = nullable
        XCTAssertTrue(model.efforts.contains(.medium))
        XCTAssertFalse(model.efforts.contains(.none))
    }

    func testLegacySettingsKeepChosenModelAndUseProviderDefault() throws {
        var original = CompanionState()
        original.model = "openai/gpt-5.2"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "reasoningEffort")
        let restored = try JSONDecoder().decode(CompanionState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.model, "openai/gpt-5.2")
        XCTAssertNil(restored.reasoningEffort)
        XCTAssertEqual(CompanionState().model, "openai/gpt-6.1-sol")
        XCTAssertEqual(CompanionState().reasoningEffort, .medium)
    }

    private func falling() -> CompanionRule {
        CompanionRule(kind: .fallingGlucose, title: "Falling", belowMGDL: 120,
                      rateMGDLPerMinute: 2, windowMinutes: 10, cooldownMinutes: 30)
    }

    private func points(_ values: [Double], ending: Date? = nil) -> [CompanionGlucosePoint] {
        let end = ending ?? now
        return values.enumerated().map { index, value in
            CompanionGlucosePoint(date: end.addingTimeInterval(Double(index - values.count + 1) * 300), mgdl: value)
        }
    }

    func testFallingConditionUsesThresholdAndMeasuredRate() {
        var runtime = CompanionRuleRuntime()
        XCTAssertTrue(CompanionRuleEvaluator.evaluate(falling(), points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
        XCTAssertEqual(runtime.lastFired, now)
        runtime = CompanionRuleRuntime()
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(falling(), points: points([150, 135, 120]), carbDates: [], now: now, runtime: &runtime))
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(falling(), points: points([119, 118, 117]), carbDates: [], now: now, runtime: &runtime))
    }

    func testInvalidOrInsufficientDataCannotTrigger() {
        var runtime = CompanionRuleRuntime()
        for sampleSet in [points([145, 115]), points([145, 130, 115], ending: now.addingTimeInterval(-601)),
                          points([145, 130, .nan]), points([145, 130, 19])] {
            XCTAssertFalse(CompanionRuleEvaluator.evaluate(falling(), points: sampleSet, carbDates: [], now: now, runtime: &runtime))
            XCTAssertNil(runtime.lastFired)
        }
        let gaps = [CompanionGlucosePoint(date: now.addingTimeInterval(-600), mgdl: 150),
                    CompanionGlucosePoint(date: now.addingTimeInterval(-60), mgdl: 120),
                    CompanionGlucosePoint(date: now, mgdl: 110)]
        XCTAssertNil(CompanionRuleEvaluator.slope(points: gaps, windowMinutes: 10, now: now))
        var duplicate = points([145, 130, 115])
        duplicate.append(duplicate[1])
        XCTAssertNil(CompanionRuleEvaluator.slope(points: duplicate, windowMinutes: 10, now: now))
        XCTAssertNil(CompanionRuleEvaluator.slope(points: points([145, 130, 115], ending: now.addingTimeInterval(900)), windowMinutes: 10, now: now))
    }

    func testLatchingAndCooldownSurviveRepeatedSamplesAndClear() {
        var runtime = CompanionRuleRuntime()
        let rule = falling()
        XCTAssertTrue(CompanionRuleEvaluator.evaluate(rule, points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(rule, points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
        let later = now.addingTimeInterval(3600)
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(rule, points: points([145, 130, 115], ending: later), carbDates: [], now: later, runtime: &runtime))
        let clear = later.addingTimeInterval(600)
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(rule, points: points([110, 120, 130], ending: clear), carbDates: [], now: clear, runtime: &runtime))
        XCTAssertFalse(runtime.latched)
        let next = clear.addingTimeInterval(600)
        XCTAssertTrue(CompanionRuleEvaluator.evaluate(rule, points: points([145, 130, 115], ending: next), carbDates: [], now: next, runtime: &runtime))
    }

    func testCooldownPreventsNewEpisodeFromImmediatelyRepeating() {
        var runtime = CompanionRuleRuntime(lastEvaluated: nil, lastFired: now.addingTimeInterval(-600), latched: false)
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(falling(), points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
    }

    func testMissedCarbsRespectsLookbackAndDoesNotTreatFutureEntriesAsMeals() {
        let rule = CompanionRule(kind: .missedCarbs, title: "Check meal", rateMGDLPerMinute: 2,
                                 windowMinutes: 10, carbLookbackMinutes: 60, cooldownMinutes: 30)
        var runtime = CompanionRuleRuntime()
        XCTAssertTrue(CompanionRuleEvaluator.evaluate(rule, points: points([110, 125, 140]), carbDates: [], now: now, runtime: &runtime))
        runtime = CompanionRuleRuntime()
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(rule, points: points([110, 125, 140]), carbDates: [now.addingTimeInterval(-1800)], now: now, runtime: &runtime))
        runtime = CompanionRuleRuntime()
        XCTAssertTrue(CompanionRuleEvaluator.evaluate(rule, points: points([110, 125, 140]), carbDates: [now.addingTimeInterval(60), now.addingTimeInterval(-7200)], now: now, runtime: &runtime))
    }

    func testDisabledRulesAndDailyRemindersNeverBecomeGlucoseAlerts() {
        var rule = falling()
        rule.enabled = false
        var runtime = CompanionRuleRuntime()
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(rule, points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
        let daily = CompanionRule(kind: .dailySummary, title: "Review", hour: 21, minute: 0, timeZone: "America/Detroit")
        XCTAssertNoThrow(try daily.validate())
        XCTAssertFalse(CompanionRuleEvaluator.evaluate(daily, points: points([145, 130, 115]), carbDates: [], now: now, runtime: &runtime))
    }

    func testAmbiguousAndOutOfRangeRulesAreRejected() {
        XCTAssertThrowsError(try CompanionRule(kind: .fallingGlucose, title: "Under 120").validate())
        var rule = falling()
        rule.rateMGDLPerMinute = -2
        XCTAssertThrowsError(try rule.validate())
        rule = falling(); rule.windowMinutes = 5
        XCTAssertThrowsError(try rule.validate())
        rule = falling(); rule.cooldownMinutes = 0
        XCTAssertThrowsError(try rule.validate())
        rule = falling(); rule.belowMGDL = .infinity
        XCTAssertThrowsError(try rule.validate())
        XCTAssertThrowsError(try CompanionRule(kind: .dailySummary, title: "Review", hour: 25, minute: 0, timeZone: "America/Detroit").validate())
        XCTAssertThrowsError(try CompanionRule(kind: .dailySummary, title: "Review", hour: 21, minute: 0, timeZone: "invalid").validate())
    }

    func testCarbDraftRejectsInventedInvalidAmountsOrStaleTimes() {
        XCTAssertNoThrow(try CompanionCarbDraft(grams: 20, date: now, absorptionHours: 3).validate(now: now))
        XCTAssertThrowsError(try CompanionCarbDraft(grams: 0, date: now, absorptionHours: 3).validate(now: now))
        XCTAssertThrowsError(try CompanionCarbDraft(grams: .nan, date: now, absorptionHours: 3).validate(now: now))
        XCTAssertThrowsError(try CompanionCarbDraft(grams: 20, date: now.addingTimeInterval(-13 * 3600), absorptionHours: 3).validate(now: now))
        XCTAssertThrowsError(try CompanionCarbDraft(grams: 20, date: now, absorptionHours: 0).validate(now: now))
    }

    func testStateRoundTripPreservesProposalsAndDeduplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var state = CompanionState()
        let rule = falling()
        state.rules = [rule]
        state.runtime[rule.id.uuidString] = CompanionRuleRuntime(lastEvaluated: now, lastFired: now, latched: true)
        state.messages = [CompanionMessage(role: "user", text: "Be direct")]
        state.actions = [CompanionAction(title: "Review", rule: rule)]
        try store.save(state)
        let restored = try store.load()
        XCTAssertEqual(restored.rules, [rule])
        XCTAssertEqual(restored.runtime[rule.id.uuidString]?.lastFired, now)
        XCTAssertEqual(restored.runtime[rule.id.uuidString]?.latched, true)
        XCTAssertEqual(restored.actions.first?.status, .pending)
        XCTAssertEqual(restored.messages.first?.text, "Be direct")
        XCTAssertFalse(restored.allowHealthData)
        XCTAssertEqual(restored.reasoningEffort, .medium)
    }

    func testUnreadableHistoryIsNotSilentlyReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try CompanionStateStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
