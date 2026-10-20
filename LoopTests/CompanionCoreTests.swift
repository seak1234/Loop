import XCTest
#if canImport(Loop)
@testable import Loop
#else
@testable import CompanionCore
#endif

final class CompanionCoreTests: XCTestCase {
    private var reactionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var reactionNow: Date { ISO8601DateFormatter().date(from: "2026-10-20T18:00:00Z")! }
    private func reactionContext() -> [String: Any] {
        ["get_glucose_summary": ["encouragement": ["canCelebrateRecentTarget": true]],
         "today_and_recent_patterns": ["glucose": ["coverage": 0.95, "mean_mgdl": 110.0, "in_range": 0.98, "below_70": 0.0,
            "cv_percent": 12.0, "usual_cv_percent": 25.0, "lower_mgdl": 80.0, "upper_mgdl": 145.0,
            "latest_sample": CompanionDataContext.stamp(reactionNow.addingTimeInterval(-300))]]]
    }
    private func reactions(_ context: [String: Any], at date: Date? = nil) -> [CompanionDashboardDataEvent] {
        CompanionDashboardDataEvent.candidates(context: context, now: date ?? reactionNow, calendar: reactionCalendar)
    }

    func testDashboardRecordsAloneDoNotCreateADataReaction() {
        let context: [String: Any] = ["get_glucose_summary": ["sample_count": 72], "cycle": ["recordedPeriodCount": 3]]
        XCTAssertTrue(reactions(context).isEmpty)
        let plan = CompanionDashboardPlan.next(state: CompanionState(), history: [], allowed: [.motivation, .insight], canCelebrate: false, now: reactionNow)
        XCTAssertEqual(plan.kinds, [.motivation])
        XCTAssertEqual(plan.subject, .anticipation)
    }

    func testTodayGlucoseReactionsNeedCoverageFreshnessNoLowsAndRecentTargetEvidence() {
        let context = reactionContext()
        XCTAssertTrue(reactions(context).contains { $0.kind == .todayGlucose })
        XCTAssertTrue(reactions(context).contains { $0.kind == .steadierGlucose })
        let patterns = context["today_and_recent_patterns"] as! [String: Any]
        let glucose = patterns["glucose"] as! [String: Any]
        let invalid: [(String, Any)] = [("coverage", 0.2), ("below_70", 0.01), ("mean_mgdl", 55.0), ("lower_mgdl", 60.0),
            ("latest_sample", CompanionDataContext.stamp(reactionNow.addingTimeInterval(-3600))), ("mean_mgdl", Double.nan)]
        for (key, value) in invalid {
            var modified = context, updated = glucose
            updated[key] = value
            modified["today_and_recent_patterns"] = ["glucose": updated]
            XCTAssertFalse(reactions(modified).contains { $0.kind == .todayGlucose || $0.kind == .steadierGlucose })
        }
        var unsupported = context
        unsupported["get_glucose_summary"] = ["encouragement": ["canCelebrateRecentTarget": false]]
        XCTAssertTrue(reactions(unsupported).isEmpty)
    }

    func testHistoricalGlucoseReactionNeverCelebratesLowGMIAlone() {
        var context: [String: Any] = ["get_glucose_summary": ["encouragement": ["canCelebrateRecentTarget": true]]]
        var stats: [String: Any] = ["coverage_fraction": 0.95, "in_range_fraction": 0.95, "below_70_fraction": 0.0, "mean_mgdl": 120.0, "gmi_percent": 6.1804]
        var historical: [String: Any] = ["start": CompanionDataContext.stamp(reactionNow.addingTimeInterval(-14 * 86400)),
            "end": CompanionDataContext.stamp(reactionNow), "is_loading": false, "glucose": stats]
        context["glucose_statistics"] = historical
        XCTAssertTrue(reactions(context).contains { $0.kind == .longTermGlucose })
        stats["below_70_fraction"] = 0.03; stats["gmi_percent"] = 5.0
        historical["glucose"] = stats; context["glucose_statistics"] = historical
        XCTAssertFalse(reactions(context).contains { $0.kind == .longTermGlucose })
        stats["below_70_fraction"] = 0.0; historical["glucose"] = stats
        historical["start"] = CompanionDataContext.stamp(reactionNow.addingTimeInterval(-3 * 86400))
        context["glucose_statistics"] = historical
        XCTAssertTrue(reactions(context).contains { $0.kind == .longTermGlucose })
        stats["coverage_fraction"] = 0.75
        historical["glucose"] = stats; context["glucose_statistics"] = historical
        XCTAssertFalse(reactions(context).contains { $0.kind == .longTermGlucose })
    }

    func testCarbReactionsDescribeLogsAndDoNotCallAnEmptyMorningLowIntake() {
        var carbs: [String: Any] = ["today_grams": 10.0, "usual_same_time_grams": 60.0, "comparison_days": 4, "covers_today": true]
        var context: [String: Any] = ["today_and_recent_patterns": ["carbs": carbs]]
        let event = reactions(context).first { $0.kind == .carbsChanged }
        XCTAssertTrue(event?.observation.contains("logged") == true)
        XCTAssertTrue(event?.guidance.contains("not actual food intake") == true)
        let morning = ISO8601DateFormatter().date(from: "2026-10-20T08:00:00Z")!
        XCTAssertTrue(reactions(context, at: morning).isEmpty)
        carbs["today_grams"] = 100.0
        context["today_and_recent_patterns"] = ["carbs": carbs]
        XCTAssertTrue(reactions(context, at: morning).contains { $0.kind == .carbsChanged })
        carbs["covers_today"] = false
        context["today_and_recent_patterns"] = ["carbs": carbs]
        XCTAssertTrue(reactions(context).isEmpty)
        context["today_and_recent_patterns"] = ["carbs": ["latest_entry_grams": 45.0, "latest_entry_date": CompanionDataContext.stamp(reactionNow)]]
        XCTAssertTrue(reactions(context).contains { $0.kind == .carbEntry })
    }

    func testInsulinReactionsRequireComparableCoverageAndNeverCelebrateLessDelivery() {
        var insulin: [String: Any] = ["today_units": 8.0, "usual_same_time_units": 16.0, "coverage": 0.95, "comparison_days": 4]
        var context: [String: Any] = ["today_and_recent_patterns": ["insulin": insulin]]
        let event = reactions(context).first { $0.kind == .insulinChanged }
        XCTAssertTrue(event != nil)
        XCTAssertTrue(event?.guidance.contains("Neither less nor more insulin is a win") == true)
        insulin["coverage"] = 0.5
        context["today_and_recent_patterns"] = ["insulin": insulin]
        XCTAssertTrue(reactions(context).isEmpty)
    }

    func testPeriodReactionUsesLoggedStartWithoutInventingSymptomsOrOngoingBleeding() {
        let start = reactionNow.addingTimeInterval(-86400)
        let context: [String: Any] = ["cycle": ["recentPeriods": [["startDate": CompanionDataContext.stamp(start)]]]]
        let event = reactions(context).first { $0.kind == .periodDay }
        XCTAssertTrue(event?.observation.contains("Day 2 since") == true)
        XCTAssertTrue(event?.guidance.contains("not confirmed ongoing bleeding") == true)
        let future: [String: Any] = ["cycle": ["recentPeriods": [["startDate": CompanionDataContext.stamp(reactionNow.addingTimeInterval(3600))]]]]
        XCTAssertTrue(reactions(future).isEmpty)
    }

    func testDataReactionCadenceAndDeduplicationSurviveRelaunch() throws {
        let event = reactions(reactionContext()).first!
        var state = CompanionState()
        XCTAssertEqual(CompanionDashboardDataEvent.next([event], state: state, history: [], now: reactionNow), event)
        state.dashboardDataReactionAt = reactionNow
        state.dashboardDataEvents = [event.id: reactionNow, "kind:" + event.kind.rawValue: reactionNow]
        state = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertNil(CompanionDashboardDataEvent.next([event], state: state, history: [], now: reactionNow.addingTimeInterval(2 * 3600)))
        XCTAssertNil(CompanionDashboardDataEvent.next([event], state: state, history: [], now: reactionNow.addingTimeInterval(2 * 86400)))
        let next = CompanionDashboardDataEvent(id: "new", kind: .carbEntry, observation: "New recorded entry", guidance: "Describe logs")
        let previous = CompanionDashboardMessage(text: "An observed window", generatedAt: reactionNow, includesHealthData: true, kind: .insight, subject: .dailyLife)
        let ordinary = (1...3).map { CompanionDashboardMessage(text: "You've got this!", generatedAt: reactionNow.addingTimeInterval(Double($0) * 3600), includesHealthData: false, kind: .motivation, subject: .pepTalk) }
        XCTAssertNil(CompanionDashboardDataEvent.next([next], state: state, history: [previous] + ordinary.prefix(2), now: reactionNow.addingTimeInterval(4 * 3600)))
        XCTAssertEqual(CompanionDashboardDataEvent.next([next], state: state, history: [previous] + ordinary, now: reactionNow.addingTimeInterval(4 * 3600)), next)
        let plan = CompanionDashboardPlan.next(state: state, history: [previous] + ordinary, allowed: [.motivation, .insight], canCelebrate: false, now: reactionNow.addingTimeInterval(4 * 3600), dataEvent: next)
        XCTAssertEqual(plan.subject, .dailyLife)
        XCTAssertEqual(plan.kinds, [.insight])
    }

    func testSameTimeCarbComparisonsIgnoreExpiredCachesAndUnloggedDays() {
        let periods = CompanionDashboardObservations.windows(now: reactionNow, calendar: reactionCalendar)
        let entries = periods.dropFirst().map { CompanionDashboardObservations.Carb(date: $0.0.addingTimeInterval(3600), grams: 60) }
            + [.init(date: reactionNow, grams: 10)]
        let full = CompanionDashboardObservations.carbs(entries, availableFrom: periods.last!.0, now: reactionNow, calendar: reactionCalendar)
        XCTAssertEqual(full["today_grams"] as? Double, 10)
        XCTAssertEqual(full["usual_same_time_grams"] as? Double, 60)
        XCTAssertEqual(full["comparison_days"] as? Int, 6)
        let expired = CompanionDashboardObservations.carbs(entries, availableFrom: periods[1].0, now: reactionNow, calendar: reactionCalendar)
        XCTAssertNil(expired["usual_same_time_grams"])
        let empty = CompanionDashboardObservations.carbs([], availableFrom: periods.last!.0, now: reactionNow, calendar: reactionCalendar)
        XCTAssertNil(empty["usual_same_time_grams"])
    }

    func testDailyGlucoseObservationsAreTimeWeightedAndJSONSafeWithMissingData() throws {
        let start = reactionCalendar.startOfDay(for: reactionNow)
        let points = stride(from: 0.0, to: reactionNow.timeIntervalSince(start), by: 300).map {
            GlucoseStatisticsReading(date: start.addingTimeInterval($0), mgdl: 110)
        }
        let data = CompanionDashboardObservations.glucose(points, now: reactionNow, calendar: reactionCalendar, lower: 80, upper: 145)
        XCTAssertEqual(data["mean_mgdl"] as? Double, 110)
        XCTAssertEqual(data["coverage"] as? Double, 1)
        XCTAssertEqual(data["below_70"] as? Double, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(data))
        let missing = CompanionDashboardObservations.glucose([], now: reactionNow, calendar: reactionCalendar, lower: 80, upper: 145)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(missing))
        XCTAssertTrue(missing["mean_mgdl"] is NSNull)
    }

    func testSameClockComparisonsRespectLocalDaysAcrossDST() {
        var calendar = reactionCalendar
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-02T17:00:00Z")!
        let windows = CompanionDashboardObservations.windows(now: now, calendar: calendar)
        XCTAssertEqual(windows.count, 7)
        for (start, end) in windows {
            XCTAssertEqual(calendar.component(.hour, from: start), 0)
            XCTAssertEqual(calendar.component(.hour, from: end), 12)
        }
        XCTAssertEqual(windows[1].1.timeIntervalSince(windows[1].0), 13 * 3600)
    }

    private final class DashboardVoiceProvider: CompanionProvider {
        var replies: [Result<CompanionCompletion, Error>]
        var requests: [[[String: Any]]] = []

        init(_ replies: [Result<CompanionCompletion, Error>]) { self.replies = replies }

        func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion {
            XCTAssertTrue(tools.isEmpty)
            requests.append(messages)
            guard !replies.isEmpty else { throw CompanionError.invalid("Unexpected extra model call.") }
            return try replies.removeFirst().get()
        }
    }

    private func dashboardDraft(_ text: String, kind: String = "motivation") throws -> CompanionCompletion {
        let json = try JSONSerialization.data(withJSONObject: ["text": text, "kind": kind, "question": "Can we talk about this?"])
        return CompanionCompletion(message: [:], text: String(decoding: json, as: UTF8.self), calls: [])
    }

    private func voiceReview(impact: String = "confidence", encouragement: String, energizing: Bool = true,
                             grounded: Bool = true, natural: Bool = true) throws -> CompanionCompletion {
        let json = try JSONSerialization.data(withJSONObject: ["impact": impact, "encouragement": encouragement,
            "energizing": energizing, "grounded": grounded, "natural": natural])
        return CompanionCompletion(message: [:], text: String(decoding: json, as: UTF8.self), calls: [])
    }

    private func reviewedSuggestion(_ provider: DashboardVoiceProvider, subject: CompanionDashboardSubject = .companionship) async throws -> CompanionDashboardSuggestion? {
        try await provider.dashboardSuggestion(model: "test-model", reasoningEffort: .providerDefault,
            messages: [["role": "user", "content": "synthetic private context, not for voice review"]],
            plan: CompanionDashboardPlan(subject: subject, kinds: [.motivation, .insight], fact: nil, callbackStory: nil),
            topicIDs: [], recentTexts: [], recentQuestions: [], name: "Michelle", useName: true, morningGreetingRequired: false)
    }

    func testDirectAffirmationsAreAcceptedWithoutAnAchievementOrLesson() async throws {
        for text in ["You are amazing!", "You're amazing!", "You got this!", "You've got this!", "Choo choo! You're unstoppable today!"] {
            let provider = DashboardVoiceProvider([
                .success(try dashboardDraft(text)),
                .success(try voiceReview(impact: "affirmation", encouragement: text))
            ])
            let result = try await reviewedSuggestion(provider, subject: .pepTalk)
            XCTAssertEqual(result?.text, text)
            XCTAssertEqual(provider.requests.count, 2)
        }
    }

    func testRetiredT1DIdentityLoadsButCannotReturnThroughRotationOrCallbacks() throws {
        var legacy = CompanionDashboardMessage(text: "T1D is in my little story, too.", generatedAt: now,
            includesHealthData: false, kind: .motivation, subject: .sharedT1D)
        legacy.styleVersion = 20
        var state = CompanionState()
        state.dashboardRecentMessages = [legacy]
        state = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.dashboardRecentMessages?.first?.subject, .sharedT1D)
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(state.dashboardRecentMessages!.first!, now: now))
        state.dashboardSubjectLastShown = Dictionary(uniqueKeysWithValues: CompanionDashboardSubject.allCases
            .filter { $0 != .littleAdventure }.map { ($0.rawValue, now) })
        var story = CompanionDashboardMessage(text: "A retired imaginary T1D story.", generatedAt: now.addingTimeInterval(-86400),
            includesHealthData: false, kind: .motivation, subject: .littleAdventure)
        story.styleVersion = 20
        state.rememberCharacterStory(story)
        state.dashboardAdventureCount = 2
        let plan = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation], canCelebrate: false, now: now)
        XCTAssertEqual(plan.subject, .littleAdventure)
        XCTAssertNil(plan.callbackStory)
        for index in 0..<24 {
            let fallback = CompanionMessageVariety.dashboardFallback(index: index, name: "", morning: false)
            XCTAssertFalse(fallback.text.localizedCaseInsensitiveContains("T1D"))
            XCTAssertFalse(fallback.text.localizedCaseInsensitiveContains("diabetes"))
            XCTAssertFalse(fallback.subject == .sharedT1D)
        }
    }

    func testPassiveDraftIsReplacedOnlyAfterSubstantiveVoiceReview() async throws {
        let passive = "Hey Michelle, I smoothed out a tiny leaf blanket for us tonight. Just here rooting for you, very quietly."
        let optimistic = "You can learn tricky things without getting them right first time. Tiny teammate, enormous enthusiasm."
        let provider = DashboardVoiceProvider([
            .success(try dashboardDraft(passive)),
            .success(try voiceReview(impact: "none", encouragement: "", energizing: false)),
            .success(try dashboardDraft(optimistic)),
            .success(try voiceReview(encouragement: "You can learn tricky things without getting them right first time."))
        ])
        let result = try await reviewedSuggestion(provider)
        XCTAssertEqual(result?.text, optimistic)
        XCTAssertEqual(provider.requests.count, 4)
        for request in [provider.requests[1], provider.requests[3]] {
            XCTAssertEqual(request.first?["content"] as? String, CompanionDashboardVoice.reviewInstructions)
            let quoted = try JSONSerialization.jsonObject(with: Data((request.last?["content"] as! String).utf8)) as! [String: String]
            XCTAssertEqual(Set(quoted.keys), Set(["text", "subject"]))
            XCTAssertFalse(quoted.values.contains { $0.contains("synthetic private context") })
        }
    }

    func testJokeWithMissingSetupIsRetriedWithASelfContainedMessage() async throws {
        let confusing = "You're worth every bit of this enthusiasm. Both paws up! Balance briefly unavailable."
        let clear = "You're amazing! I cheered so hard I landed on my bottom. Still cheering!"
        let provider = DashboardVoiceProvider([
            .success(try dashboardDraft(confusing)),
            .success(try voiceReview(impact: "affirmation", encouragement: "You're worth every bit of this enthusiasm.", natural: false)),
            .success(try dashboardDraft(clear)),
            .success(try voiceReview(impact: "affirmation", encouragement: "You're amazing!"))
        ])
        let result = try await reviewedSuggestion(provider, subject: .smallDelight)
        XCTAssertEqual(result?.text, clear)
        XCTAssertEqual(provider.requests.count, 4)
        let repair = provider.requests[2].last?["content"] as? String ?? ""
        XCTAssertTrue(repair.contains("include the action that caused the mishap"))
        for index in 0..<24 {
            let fallback = CompanionMessageVariety.dashboardFallback(index: index, name: "Michelle", morning: false)
            XCTAssertFalse(fallback.text.contains("Balance briefly unavailable"))
        }
    }

    func testVoiceReviewFailureNeverDisplaysAnUnreviewedDraft() async throws {
        let draft = try dashboardDraft("A little company for whatever comes next. Scooting over. Scooting too far. Back again.")
        let invalidReviews: [Result<CompanionCompletion, Error>] = [
            .success(CompanionCompletion(message: [:], text: "not JSON", calls: [])),
            .failure(CompanionError.invalid("Synthetic review failure"))
        ]
        for review in invalidReviews {
            let provider = DashboardVoiceProvider([.success(draft), review,
                .success(draft), .success(try voiceReview(impact: "none", encouragement: "", energizing: false))])
            let result = try await reviewedSuggestion(provider)
            XCTAssertNil(result)
            let fallback = result ?? CompanionMessageVariety.dashboardFallback(index: 0, name: "", morning: false)
            XCTAssertFalse(fallback.text == "A little company for whatever comes next. Scooting over. Scooting too far. Back again.")
            XCTAssertTrue(CompanionDashboardRefresh.isConcise(fallback.text))
            XCTAssertTrue(provider.requests.count <= 4)
        }
    }

    func testVoiceReviewRetriesAreBoundedAndRequireAnActualEncouragingSpan() async throws {
        let passive = try dashboardDraft("Just here rooting for you, very quietly.")
        let fabricatedEvidence = try voiceReview(encouragement: "You can learn something new.")
        let provider = DashboardVoiceProvider([.success(passive), .success(fabricatedEvidence), .success(passive), .success(fabricatedEvidence)])
        let result = try await reviewedSuggestion(provider)
        XCTAssertNil(result)
        XCTAssertEqual(provider.requests.count, 4)
        XCTAssertTrue(provider.replies.isEmpty)
        for review in [
            try voiceReview(impact: "none", encouragement: "You can learn.").text,
            try voiceReview(encouragement: "You can learn.", energizing: false).text,
            try voiceReview(encouragement: "You can learn.", grounded: false).text,
            try voiceReview(encouragement: "You can learn.", natural: false).text,
            try voiceReview(encouragement: "").text
        ] {
            XCTAssertFalse(CompanionDashboardVoice.Review.accepts(review, text: "You can learn."))
        }
    }

    func testClinicalObservationsDoNotNeedToSoundEnergizing() async throws {
        let text = "The sensor reports a warning. Its status needs attention."
        for subject in [CompanionDashboardSubject.dailyLife, .deviceStatus, .glucoseWins] {
            let provider = DashboardVoiceProvider([.success(try dashboardDraft(text, kind: "insight"))])
            let result = try await reviewedSuggestion(provider, subject: subject)
            XCTAssertEqual(result?.text, text)
            XCTAssertEqual(provider.requests.count, 1)
        }
    }

    func testOrdinaryCopyOnAHealthTopicStillNeedsVoiceReview() async throws {
        let draft = try dashboardDraft("Just here rooting for you, very quietly.")
        let review = try voiceReview(impact: "none", encouragement: "", energizing: false)
        let provider = DashboardVoiceProvider([.success(draft), .success(review), .success(draft), .success(review)])
        let result = try await reviewedSuggestion(provider, subject: .dailyLife)
        XCTAssertNil(result)
        XCTAssertEqual(provider.requests.count, 4)
    }

    func testVoiceReviewCancellationStopsRetries() async throws {
        let provider = DashboardVoiceProvider([.success(try dashboardDraft("You can learn tricky things. Your tiny teammate is excited.")), .failure(CancellationError())])
        do {
            _ = try await reviewedSuggestion(provider)
            XCTAssertTrue(false)
        } catch is CancellationError { }
        catch { XCTAssertTrue(false) }
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testOldBuiltInPersonalityMigratesWithoutReplacingCustomPreferences() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CompanionStateStore(url: url)
        let old = "Talk like a kind, down-to-earth friend. Use simple words, contractions and a little gentle humor when it fits. Help me make sense of diabetes without lecturing, canned pep talks or guilt."
        let previous = "Help me feel optimistic, capable and excited about possibilities. Make encouragement direct and personal, with affectionate humor and harmless clumsiness. Use simple words and contractions. Be honest about difficulties and health data. Match my actual question and mood; give comfort when I need it. Avoid passive reassurance, generic slogans, invented achievements and pressure to be productive."
        let custom = "Use short answers and no emojis. Give me quiet company when I request it."
        for personality in [old, previous, custom] {
            var state = CompanionState()
            state.personality = personality
            state.preferredName = "A saved name"
            state.allowHealthData = true
            try store.save(state)
            let loaded = try store.load()
            XCTAssertEqual(loaded.personality, personality == custom ? personality : CompanionPersona.defaultPreferences)
            XCTAssertEqual(loaded.preferredName, "A saved name")
            XCTAssertTrue(loaded.allowHealthData)
        }
    }

    func testDeviceFreshnessRejectsMissingFutureAndStaleDates() {
        XCTAssertEqual(CompanionDataContext.freshness(nil, now: now)["is_fresh"] as? Bool, false)
        XCTAssertEqual(CompanionDataContext.freshness(now.addingTimeInterval(1), now: now)["is_fresh"] as? Bool, false)
        XCTAssertEqual(CompanionDataContext.freshness(now.addingTimeInterval(-601), now: now)["is_fresh"] as? Bool, false)
        XCTAssertEqual(CompanionDataContext.freshness(now.addingTimeInterval(-60), now: now)["is_fresh"] as? Bool, true)
    }

    func testSensorLifecycleMatchesConfiguredDeviceAndPreservesEndMeaning() {
        let start = now.addingTimeInterval(-3600)
        let events = [CompanionDataContext.SensorEvent(date: start, kind: "sensorStart", deviceIdentifier: "configured", lifetime: 7200, warmup: 1800),
            CompanionDataContext.SensorEvent(date: now, kind: "sensorStart", deviceIdentifier: "another-device", lifetime: 100, warmup: 10),
            CompanionDataContext.SensorEvent(date: now.addingTimeInterval(10), kind: "sensorEnd", deviceIdentifier: "configured")]
        let lifecycle = CompanionDataContext.sensorLifecycle(events, identifiers: ["configured"], now: now)
        XCTAssertEqual(lifecycle["expected_session_end"] as? String, CompanionDataContext.stamp(start.addingTimeInterval(7200)))
        XCTAssertEqual(lifecycle["expected_warmup_end"] as? String, CompanionDataContext.stamp(start.addingTimeInterval(1800)))
        XCTAssertNil(lifecycle["recorded_end"])
        XCTAssertNil(lifecycle["deviceIdentifier"])
        XCTAssertEqual(CompanionDataContext.sensorLifecycle(events, identifiers: [], now: now)["status"] as? String, "unknown")
    }

    func testPumpLifecycleExcludesRawCredentialsAndKeepsNominalExpiryDistinct() throws {
        let raw: [String: Any] = ["sessionToken": "secret-do-not-share", "password": "private", "podState": ["expiresAt": now, "address": "private-serial"]]
        let value = CompanionDataContext.pumpLifecycle(raw)
        XCTAssertEqual(value["nominal_expiration"] as? String, CompanionDataContext.stamp(now))
        XCTAssertNil(value["reported_session_end"])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-do-not-share"))
        XCTAssertFalse(encoded.contains("private"))
    }

    func testRecordPagesExposeTruncationAndResumeWithoutLosingRows() throws {
        let rows = (0..<405).map { ["index": $0 as Any] }
        let first = try CompanionDataContext.page(rows, offset: 0, now: now)
        let second = try CompanionDataContext.page(rows, offset: first["next_offset"] as! Int, now: now)
        let last = try CompanionDataContext.page(rows, offset: second["next_offset"] as! Int, now: now)
        XCTAssertEqual((first["records"] as? [[String: Any]])?.count, 200)
        XCTAssertEqual((second["records"] as? [[String: Any]])?.count, 200)
        XCTAssertEqual((last["records"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(last["has_more"] as? Bool, false)
        XCTAssertTrue(last["next_offset"] is NSNull)
        XCTAssertThrowsError(try CompanionDataContext.page(rows, offset: -1, now: now))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["unknown": CompanionDataContext.finite(.nan)]))
    }

    func testDeviceTopicRequiresActualAttentionAndKeepsShortFreshness() {
        let status: [String: Any] = ["cgm": ["configured": true, "lifecycle": ["expected_session_end": CompanionDataContext.stamp(now.addingTimeInterval(3600))]]]
        XCTAssertTrue(CompanionDataContext.deviceNeedsAttention(status, now: now))
        XCTAssertFalse(CompanionDataContext.deviceNeedsAttention(["cgm": ["configured": true, "lifecycle_progress": ["fraction_complete": 0.99]]], now: now))
        let plan = CompanionDashboardPlan.next(state: CompanionState(), history: [], allowed: [.motivation, .insight], canCelebrate: false, now: now, deviceAttention: true)
        XCTAssertEqual(plan.subject, .deviceStatus)
        let message = CompanionDashboardMessage(text: "A supported device status", generatedAt: now, includesHealthData: true, kind: .motivation, subject: .deviceStatus)
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(message, now: now.addingTimeInterval(300)))
    }

    func testDashboardRejectsDifferentWordingOfTheSameCareWorkTheme() throws {
        let previous = "Hi, Michelle. Keeping track of all the gear and endless micro-choices takes real effort, and I see you showing up."
        let paraphrase = "The invisible work of caring for diabetes counts, Michelle, even when nobody notices it."
        XCTAssertFalse(CompanionMessageVariety.isRepeat(paraphrase, recent: [previous], name: "Michelle"))
        XCTAssertTrue(CompanionMessageVariety.isDashboardRepeat(paraphrase, recent: [previous], name: "Michelle"))
        XCTAssertTrue(CompanionMessageVariety.isDashboardRepeat("Hey, Michelle! There's plenty of unseen planning behind diabetes care.", recent: [previous], name: "Michelle"))
        XCTAssertFalse(CompanionMessageVariety.isDashboardRepeat("You can choose what we talk about next, Michelle.", recent: [previous], name: "Michelle"))
        let raw = String(decoding: try JSONEncoder().encode(["text": paraphrase, "kind": "motivation", "question": "Can we talk about the work of care?"]), as: UTF8.self)
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [previous], name: "Michelle", useName: true))
    }

    func testDashboardPurposesRotateAndSurviveStateReload() throws {
        var state = CompanionState()
        var history: [CompanionDashboardMessage] = []
        var subjects: [CompanionDashboardSubject] = []
        for index in 0..<8 {
            let date = now.addingTimeInterval(Double(index))
            let plan = CompanionDashboardPlan.next(state: state, history: history, allowed: [.motivation], canCelebrate: false, now: date)
            XCTAssertFalse(subjects.contains(plan.subject))
            XCTAssertEqual(plan.kinds, [.motivation])
            subjects.append(plan.subject)
            history.append(CompanionDashboardMessage(text: "Message \(index)", generatedAt: date, includesHealthData: false, subject: plan.subject))
            state.dashboardRecentMessages = history
            state = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        }
        XCTAssertEqual(subjects.count, 8)
        XCTAssertTrue(subjects.contains(.littleAdventure))
        XCTAssertTrue(subjects.contains(.smallDelight))
        XCTAssertTrue(subjects.contains(.pepTalk))
        XCTAssertTrue(subjects.contains(.anticipation))
        XCTAssertTrue(subjects.contains(.determination))
        let retired: Set<CompanionDashboardSubject> = [.questions, .records, .perspective, .preferences, .routines, .privacy, .clarity, .effort, .sharedT1D]
        XCTAssertTrue(retired.isDisjoint(with: subjects))
        let plan = CompanionDashboardPlan.next(state: state, history: state.dashboardRecentMessages ?? [], allowed: [.motivation], canCelebrate: false, now: now.addingTimeInterval(15))
        XCTAssertEqual(plan.subject, subjects.first)
        state.dashboardSubjectLastShown = [plan.subject.rawValue: now.addingTimeInterval(16)]
        let next = CompanionDashboardPlan.next(state: state, history: history, allowed: [.motivation], canCelebrate: false, now: now.addingTimeInterval(17))
        XCTAssertFalse(next.subject == plan.subject)
    }

    func testDashboardRejectsDetachedScreenReflections() throws {
        let rejected = [
            "A screen only catches tiny glimpses of real life, never the whole picture.",
            "Good morning! A single reading is one moment, not the whole picture.",
            "Your graph only shows glimpses of your life, Michelle.",
            "Numbers can't tell the whole story.",
            "A single reading is only part of your life."
        ]
        let accepted = [
            "You've got this! I jumped up to cheer and landed on my bottom. Still cheering!",
            "One tiny heart for you. Slightly squished from all the hugs.",
            "Recent readings are in target. A little happy dance is definitely happening.",
            "The sensor isn't sending readings. Let's check its reported status together."
        ]
        for text in rejected + accepted {
            let raw = String(decoding: try JSONEncoder().encode(["text": text, "kind": "motivation", "question": "Can we talk about this?"]), as: UTF8.self)
            if rejected.contains(text) {
                XCTAssertTrue(CompanionDashboardVoice.isDetachedReflection(text))
                XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
            } else {
                XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
            }
        }
    }

    func testCheeringPropsDoNotReplaceOneRepeatedMessageWithAnother() {
        let recent = ["Absolutely rooting for you. Made a whole banner. Briefly got trapped in it."]
        XCTAssertTrue(CompanionMessageVariety.isDashboardRepeat("Today's cheering section is tiny but wildly enthusiastic. The pom-poms are bigger than me.", recent: recent, name: ""))
        XCTAssertFalse(CompanionMessageVariety.isDashboardRepeat("I saved you the comfy spot. Testing it took most of my afternoon.", recent: recent, name: ""))
    }

    func testEarlierDashboardVoiceIsInvalidatedAfterUpdate() {
        var message = CompanionDashboardMessage(text: "You're worth every bit of this enthusiasm. Both paws up! Balance briefly unavailable.",
            generatedAt: now, includesHealthData: false, kind: .motivation, subject: .smallDelight)
        message.styleVersion = 21
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(message, now: now))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: nil, dataChanged: false, now: now))
    }

    func testGlucosePraiseHasACooldownAndRequiresEvidence() {
        let win = CompanionDashboardMessage(text: "Supported window", generatedAt: now, includesHealthData: true, subject: .glucoseWins)
        let recent = [win]
        let supported = CompanionDashboardPlan.next(state: CompanionState(), history: recent, allowed: [.motivation, .insight], canCelebrate: true, now: now)
        XCTAssertFalse(supported.subject == .glucoseWins)
        let unsupported = CompanionDashboardPlan.next(state: CompanionState(), history: [], allowed: [.motivation], canCelebrate: true, now: now)
        XCTAssertFalse(unsupported.subject == .glucoseWins)
    }

    func testCharacterMemoryIsBoundedPersistsAndHonorsHealthSharing() throws {
        var state = CompanionState()
        state.allowHealthData = true
        for index in 0..<10 {
            state.rememberCharacterStory(CompanionDashboardMessage(text: "Imaginary project \(index)",
                generatedAt: now.addingTimeInterval(Double(index)), includesHealthData: index == 9,
                kind: .motivation, subject: .littleAdventure))
        }
        state.rememberCharacterStory(CompanionDashboardMessage(text: "An actual health observation", generatedAt: now,
            includesHealthData: true, kind: .insight, subject: .dailyLife))
        state = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        let later = now.addingTimeInterval(10)
        XCTAssertEqual(state.characterStories(now: later).count, 8)
        XCTAssertEqual(state.characterStories(now: later).first?.text, "Imaginary project 2")
        state.allowHealthData = false
        XCTAssertEqual(state.characterStories(now: later).count, 7)
        XCTAssertFalse(state.characterStories(now: later).contains { $0.includesHealthData })
        XCTAssertTrue(state.characterStories(now: now.addingTimeInterval(8 * 86400)).isEmpty)
        XCTAssertTrue(state.characterStories(now: now.addingTimeInterval(-1)).isEmpty)
    }

    func testStoryCallbacksAreOccasionalAndUseAnActualEarlierDay() {
        var state = CompanionState()
        state.dashboardSubjectLastShown = [CompanionDashboardSubject.anticipation.rawValue: now]
        let story = CompanionDashboardMessage(text: "My tiny sign fell over.", generatedAt: now.addingTimeInterval(-86400),
            includesHealthData: false, kind: .motivation, subject: .littleAdventure)
        state.rememberCharacterStory(story)
        state.dashboardAdventureCount = 2
        var plan = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation], canCelebrate: false, now: now)
        XCTAssertEqual(plan.subject, .littleAdventure)
        XCTAssertEqual(plan.callbackStory?.text, story.text)
        state.dashboardAdventureCount = 3
        plan = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation], canCelebrate: false, now: now)
        XCTAssertNil(plan.callbackStory)
        state.dashboardAdventureCount = 5
        state.dashboardCharacterMessages = [CompanionDashboardMessage(text: "A brand new story", generatedAt: now,
            includesHealthData: false, kind: .motivation, subject: .littleAdventure)]
        plan = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation], canCelebrate: false, now: now)
        XCTAssertNil(plan.callbackStory)
    }

    func testOrdinaryMessagesHaveTimeToBreatheWhileHealthInsightsStayFresh() {
        let story = CompanionDashboardMessage(text: "My tiny sign now stands up.", generatedAt: now,
            includesHealthData: false, kind: .motivation, subject: .littleAdventure)
        XCTAssertTrue(CompanionDashboardRefresh.isDisplayable(story, now: now.addingTimeInterval(899)))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: story, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(300)))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: story, lastAttempt: now, dataChanged: false, now: now.addingTimeInterval(900)))
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(story, now: now.addingTimeInterval(900)))
        let insight = CompanionDashboardMessage(text: "A supported recent observation.", generatedAt: now,
            includesHealthData: true, kind: .insight, subject: .dailyLife)
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: insight, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(120)))
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(insight, now: now.addingTimeInterval(300)))
    }

    func testDashboardFallbacksUsuallyOmitTheName() {
        var beginnings = Set<String>()
        var namedOrdinaryMessages = 0
        for index in 0..<24 {
            for morning in [false, true] {
                let message = CompanionMessageVariety.dashboardFallback(index: index, name: "Michelle", morning: morning)
                XCTAssertTrue(message.text.components(separatedBy: "Michelle").count <= 2)
                XCTAssertTrue(CompanionDashboardRefresh.isConcise(message.text))
                XCTAssertFalse(CompanionDashboardVoice.isDetachedReflection(message.text))
                let retired: Set<CompanionDashboardSubject> = [.questions, .records, .perspective, .preferences, .routines, .privacy, .clarity, .effort, .sharedT1D]
                XCTAssertFalse(message.subject.map { retired.contains($0) } ?? true)
                XCTAssertTrue(message.subject != nil)
                if morning { XCTAssertTrue(message.text.hasPrefix("Good morning, Michelle!")) }
                else {
                    beginnings.insert(String(message.text.prefix(4)))
                    if message.text.contains("Michelle") { namedOrdinaryMessages += 1 }
                }
            }
        }
        XCTAssertTrue(beginnings.count > 4)
        XCTAssertTrue(namedOrdinaryMessages > 0 && namedOrdinaryMessages < 12)
    }

    func testNameIsOptionalAndCannotOccurMoreThanOnce() throws {
        let middle = #"{"text":"You can choose, Michelle, what we talk about next.","kind":"motivation","question":"Can we focus on my priorities?"}"#
        let suffix = middle.replacingOccurrences(of: "You can choose, Michelle, what we talk about next.", with: "You can choose what we talk about next, Michelle.")
        for raw in [middle, suffix] {
            XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        }
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(middle.replacingOccurrences(of: "next.", with: "next, Michelle."), allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
    }

    func testNameUseIsOccasionalAndHasARecentMessageCooldown() {
        XCTAssertTrue(CompanionDashboardNaming.canUseName("Michelle", index: 5, morning: false, recent: []))
        XCTAssertFalse(CompanionDashboardNaming.canUseName("Michelle", index: 6, morning: false, recent: []))
        let recent = ["I saved you a spot, Michelle.", "A little story", "Another little story"]
        XCTAssertFalse(CompanionDashboardNaming.canUseName("Michelle", index: 10, morning: false, recent: recent))
        XCTAssertFalse(CompanionDashboardNaming.canUseName("Michelle", index: 10, morning: true, recent: recent))
        XCTAssertTrue(CompanionDashboardNaming.canUseName("An", index: 5, morning: false, recent: ["A banana."]))
        XCTAssertFalse(CompanionDashboardNaming.canUseName("", index: 0, morning: true, recent: []))
        let fallback = CompanionMessageVariety.dashboardFallback(index: 10, name: "Michelle", morning: true, recent: recent)
        XCTAssertTrue(fallback.text.hasPrefix("Good morning!"))
        XCTAssertFalse(fallback.text.contains("Michelle"))
    }

    func testMessageNoveltyRejectsGreetingAndSynonymSwaps() throws {
        let recent = ["Hey, Michelle! I'm happy to see you checking in."]
        XCTAssertTrue(CompanionMessageVariety.isRepeat("Hi Michelle, I'm glad to see you check in!", recent: recent, name: "Michelle"))
        XCTAssertTrue(CompanionMessageVariety.isRepeat("Happy to see you here.", recent: ["Glad to see you today."]))
        XCTAssertTrue(CompanionMessageVariety.isRepeat("What could I notice about sleep during the luteal phase?",
            recent: ["What can I notice about sleep in the luteal phase?"]))
        XCTAssertFalse(CompanionMessageVariety.isRepeat("Your questions deserve space here.", recent: recent, name: "Michelle"))
        let raw = #"{"text":"Hi Michelle, I'm glad to see you check in!","kind":"motivation","question":"Can I ask about my readings?","factID":null,"topicID":null}"#
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: recent, name: "Michelle", useName: true))
    }

    func testCycleFallbackPoolHasEightDistinctValidTopicsPerPhase() throws {
        for phase in CompanionCycleCardPhase.allCases {
            let cards = CompanionCycleCardMessage.topics(for: phase)
            XCTAssertTrue(cards.count >= 8)
            XCTAssertEqual(Set(cards.map(\.question)).count, cards.count)
            for card in cards {
                let json = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
                XCTAssertNoThrow(try CompanionCycleCardMessage.decode(json))
                if phase != .unknown {
                    XCTAssertTrue(card.text.localizedCaseInsensitiveContains(phase.rawValue))
                    XCTAssertTrue(card.question.localizedCaseInsensitiveContains(phase.rawValue))
                }
            }
        }
    }

    func testFallbackDashboardMessagesRotateWithoutRepeatingRecentContent() throws {
        var recent: [String] = []
        for index in 0..<12 {
            let message = CompanionMessageVariety.dashboardFallback(index: index, name: "Michelle", morning: false, recent: recent)
            XCTAssertTrue(CompanionDashboardRefresh.isConcise(message.text))
            XCTAssertFalse(CompanionMessageVariety.isRepeat(message.text, recent: recent, name: "Michelle"))
            recent.append(message.text)
        }
        XCTAssertEqual(Set(recent).count, 12)
        let morning = CompanionMessageVariety.dashboardFallback(index: 0, name: "Michelle", morning: true)
        XCTAssertTrue(morning.text.hasPrefix("Good morning, Michelle!"))
        XCTAssertTrue(CompanionDashboardRefresh.isConcise(morning.text))
    }

    func testTopicFallbacksAvoidRecentQuestionsAcrossVisits() throws {
        let previous = Array(CompanionTopic.fallbackTopics.prefix(12))
        let next = CompanionTopic.freshFallback(index: 0, recent: previous)
        XCTAssertEqual(next.count, 2)
        XCTAssertTrue(next.allSatisfy { !CompanionMessageVariety.isRepeat($0.prompt, recent: previous.map(\.prompt)) })
        XCTAssertEqual(Set(next.map(\.title)).count, 2)
    }
    func testMealEstimateRequiresCompleteBoundedProposal() throws {
        let valid = #"{"food":"🌮","grams":42,"absorptionMinutes":180,"explanation":"Mixed meal estimate.","assumptions":"Assumes one cup of rice; sauce is uncertain."}"#
        let estimate = try CompanionMealEstimate.parse(valid, maximumGrams: 250, absorptionRange: 900...28800)
        XCTAssertEqual(estimate.grams, 42)
        XCTAssertEqual(estimate.absorptionMinutes, 180)
        for invalid in [valid.replacingOccurrences(of: "42", with: "251"),
                        valid.replacingOccurrences(of: "42", with: "42.5"),
                        valid.replacingOccurrences(of: "42", with: "-1"),
                        valid.replacingOccurrences(of: "180", with: "181"),
                        valid.replacingOccurrences(of: "180", with: "0"),
                        valid.replacingOccurrences(of: "180", with: "495"),
                        valid.replacingOccurrences(of: "🌮", with: ""),
                        "{\"unavailable\":true}", "not JSON"] {
            XCTAssertThrowsError(try CompanionMealEstimate.parse(invalid, maximumGrams: 250, absorptionRange: 900...28800))
        }
        XCTAssertThrowsError(try CompanionMealEstimate.parse(valid, maximumGrams: 250, absorptionRange: 900...7200))
        XCTAssertNoThrow(try CompanionMealEstimate.parse(valid.replacingOccurrences(of: "42", with: "0"), maximumGrams: 250, absorptionRange: 900...28800))
    }

    func testMealChatReplyValidatesUpdatedEstimatesAndAllowsClarification() throws {
        let estimate = #"{"food":"🌮","grams":20,"absorptionMinutes":120,"explanation":"Bread portion.","assumptions":"Assumes one slice."}"#
        let reply = try CompanionMealReply.parse("{\"updateForm\":true,\"message\":\"Looks like toast.\",\"estimate\":" + estimate + "}", maximumGrams: 250, absorptionRange: 900...28800)
        XCTAssertEqual(reply.estimate?.grams, 20)
        let clarification = try CompanionMealReply.parse(#"{"updateForm":true,"message":"How much will you eat?","estimate":null}"#, maximumGrams: 250, absorptionRange: 900...28800)
        XCTAssertNil(clarification.estimate)
        XCTAssertThrowsError(try CompanionMealReply.parse(#"{"updateForm":true,"message":"No estimate field"}"#, maximumGrams: 250, absorptionRange: 900...28800))
        XCTAssertThrowsError(try CompanionMealReply.parse("{\"updateForm\":true,\"message\":\"Here you go.\",\"estimate\":" + estimate.replacingOccurrences(of: "20,", with: "999,") + "}", maximumGrams: 250, absorptionRange: 900...28800))
        let user = CompanionMealTurn(text: "Half this portion", jpeg: Data([1, 2, 3]))
        let parts = user.apiMessage["content"] as? [[String: Any]]
        XCTAssertEqual((parts?.last?["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AQID")
        let assistant = CompanionMealTurn(text: "Human-readable explanation", reply: reply)
        let canonical = assistant.apiMessage["content"] as? String ?? ""
        XCTAssertNoThrow(try CompanionMealReply.parse(canonical, maximumGrams: 250, absorptionRange: 900...28800))
    }

    func testMealExplanationReplyExplicitlyPreservesFormAndSurvivesHistoryEncoding() throws {
        let text = #"{"message":"The sauce is uncertain.","updateForm":false,"estimate":null}"#
        let reply = try CompanionMealReply.parse(text, maximumGrams: 250, absorptionRange: 900...28800)
        XCTAssertFalse(reply.updateForm)
        let turn = CompanionMealTurn(text: reply.message, reply: reply)
        let history = turn.apiMessage["content"] as? String ?? ""
        XCTAssertTrue(history.contains("\"estimate\":null"))
        XCTAssertNoThrow(try CompanionMealReply.parse(history, maximumGrams: 250, absorptionRange: 900...28800))
        XCTAssertThrowsError(try CompanionMealReply.parse(#"{"message":"Missing update flag","estimate":null}"#, maximumGrams: 250, absorptionRange: 900...28800))
    }

    func testMealFoodTypesAreLimitedToExistingIconsAndDateChangesAreBounded() throws {
        let valid = #"{"food":"🍽","grams":12,"absorptionMinutes":120,"explanation":"Portion estimate.","assumptions":"Sauce uncertain."}"#
        XCTAssertEqual(try CompanionMealEstimate.parse(valid, maximumGrams: 250, absorptionRange: 900...28800).food, "🍽️")
        XCTAssertThrowsError(try CompanionMealEstimate.parse(valid.replacingOccurrences(of: "🍽", with: "Toast"), maximumGrams: 250, absorptionRange: 900...28800))
        XCTAssertThrowsError(try CompanionMealEstimate.parse(valid.replacingOccurrences(of: "🍽", with: "🍞"), maximumGrams: 250, absorptionRange: 900...28800))
        let manual = valid.replacingOccurrences(of: "\"grams\":12", with: "\"grams\":12.5")
        XCTAssertNoThrow(try CompanionMealEstimate.parse(manual, maximumGrams: 250, absorptionRange: 900...28800, preservingGrams: 12.5))
        XCTAssertThrowsError(try CompanionMealEstimate.parse(manual, maximumGrams: 250, absorptionRange: 900...28800))
        let dated = valid.replacingOccurrences(of: "\"food\":", with: "\"mealTime\":\"2026-10-18T12:00:00Z\",\"food\":")
        let date = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        XCTAssertNoThrow(try CompanionMealEstimate.parse(dated, maximumGrams: 250, absorptionRange: 900...28800, dateRange: date.addingTimeInterval(-3600)...date.addingTimeInterval(3600)))
        XCTAssertThrowsError(try CompanionMealEstimate.parse(dated, maximumGrams: 250, absorptionRange: 900...28800))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCycleQuestionsRequestTrackerContextBeforeModelResponse() {
        XCTAssertTrue(CompanionCycleIntent.matches("What cycle phase am I in?"))
        XCTAssertTrue(CompanionCycleIntent.matches("Can you read my PERIOD tracker?"))
        XCTAssertTrue(CompanionCycleIntent.matches("Could PMS explain these cravings?"))
        XCTAssertFalse(CompanionCycleIntent.matches("Help me set a glucose alert"))
    }

    func testDashboardRefreshCadenceAndRetryThrottle() {
        XCTAssertTrue(CompanionDashboardRefresh.isConcise("Small observations build diabetes know-how."))
        XCTAssertFalse(CompanionDashboardRefresh.isConcise(String(repeating: "x", count: 141)))
        XCTAssertFalse(CompanionDashboardRefresh.isConcise(Array(repeating: "one", count: 25).joined(separator: " ")))
        let oldStyle = CompanionDashboardMessage(text: "A longer company greeting", generatedAt: now, includesHealthData: false, styleVersion: nil)
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(oldStyle, now: now))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: oldStyle, lastAttempt: nil, dataChanged: false, now: now))
        let message = CompanionDashboardMessage(text: "Hello", generatedAt: now, includesHealthData: true)
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: nil, lastAttempt: nil, dataChanged: false, now: now))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(119)))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(120)))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: false, now: now.addingTimeInterval(299)))
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: message, lastAttempt: now, dataChanged: false, now: now.addingTimeInterval(300)))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: nil, lastAttempt: now, dataChanged: true, now: now.addingTimeInterval(60)))
        XCTAssertFalse(CompanionDashboardRefresh.isDisplayable(message, now: now.addingTimeInterval(300)))
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

    func testDashboardOnlyOffersPersonalEncouragementOrSupportedInsights() {
        XCTAssertEqual(CompanionDashboardKind.eligible(healthEvidence: false, recentChat: true, history: []), [.motivation])
        let repeated = (0..<4).map { _ in CompanionDashboardMessage(text: "Hello", generatedAt: now, includesHealthData: false, kind: .motivation) }
        XCTAssertEqual(CompanionDashboardKind.eligible(healthEvidence: true, recentChat: true, history: repeated), [.motivation, .insight])
    }

    func testDashboardDismissalPersistsAndExpiresAtConfiguredDuration() throws {
        var state = CompanionState()
        XCTAssertEqual(state.dashboardSnoozeDuration, 60)
        XCTAssertFalse(state.isDashboardDismissed(at: now))
        state.dashboardDismissedAt = now
        let restored = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.isDashboardDismissed(at: now.addingTimeInterval(3599)))
        XCTAssertFalse(restored.isDashboardDismissed(at: now.addingTimeInterval(3600)))
        state.dashboardSnoozeMinutes = 15
        XCTAssertTrue(state.isDashboardDismissed(at: now.addingTimeInterval(899)))
        XCTAssertFalse(state.isDashboardDismissed(at: now.addingTimeInterval(900)))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        legacy.removeValue(forKey: "dashboardSnoozeMinutes")
        legacy.removeValue(forKey: "dashboardDismissedAt")
        let decoded = try JSONDecoder().decode(CompanionState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.dashboardSnoozeDuration, 60)
        XCTAssertFalse(decoded.isDashboardDismissed(at: now))
    }

    func testDashboardAcceptsWarmNamedMessagesOutsideMorning() throws {
        let named = #"{"text":"Hey, Michelle! It’s good to see you check in.","kind":"motivation","question":"Can we look at my recent readings?","factID":null,"topicID":null}"#
        XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(named, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        let unnamed = named.replacingOccurrences(of: "Hey, Michelle!", with: "Hey there!")
        XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(unnamed, allowedKinds: [.motivation], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
    }

    func testDashboardNamesAndTapQuestionsAreValidated() throws {
        let raw = #"{"text":"Good morning, Michelle! What makes mornings different?","kind":"curiosity","question":"What can affect glucose in the morning?","factID":null,"topicID":null}"#
        XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.curiosity], factID: "fact", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.curiosity], factID: "fact", topicIDs: [], recentTexts: [], name: "Michelle", useName: false))
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.fact], factID: "fact", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.curiosity], factID: "fact", topicIDs: [], recentTexts: ["Good morning, Michelle! What makes mornings different!"], name: "Michelle", useName: true))
        let banana = raw.replacingOccurrences(of: "Good morning, Michelle! What makes mornings different?", with: "Can meals feel more predictable?")
        XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(banana, allowedKinds: [.curiosity], factID: "fact", topicIDs: [], recentTexts: [], name: "An", useName: false))
    }

    func testDashboardRejectsBareNameAndRequiresMorningGreetingWhenDue() throws {
        let raw = #"{"text":"Michelle, let's explore insulin.","kind":"curiosity","question":"How does insulin work?","factID":null,"topicID":null}"#
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(raw, allowedKinds: [.curiosity], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        let nameOnly = raw.replacingOccurrences(of: "Michelle, let's explore insulin.", with: "Michelle!")
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(nameOnly, allowedKinds: [.curiosity], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true))
        let ordinary = raw.replacingOccurrences(of: "Michelle, let's explore insulin.", with: "Let's explore how insulin works.")
        XCTAssertThrowsError(try CompanionDashboardSuggestion.decode(ordinary, allowedKinds: [.curiosity], factID: "", topicIDs: [], recentTexts: [], name: "", useName: false, morningGreetingRequired: true))
        let welcome = raw.replacingOccurrences(of: "Michelle, let's explore insulin.", with: "Good morning, Michelle! Let's explore how insulin works.")
        XCTAssertNoThrow(try CompanionDashboardSuggestion.decode(welcome, allowedKinds: [.curiosity], factID: "", topicIDs: [], recentTexts: [], name: "Michelle", useName: true, morningGreetingRequired: true))
    }

    func testMorningGreetingUsesLocalTimeAndIsDueOncePerDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        XCTAssertFalse(CompanionDashboardGreeting.isDue(lastGreeting: nil, now: date(19, 4), calendar: calendar))
        XCTAssertTrue(CompanionDashboardGreeting.isDue(lastGreeting: nil, now: date(19, 5), calendar: calendar))
        XCTAssertTrue(CompanionDashboardGreeting.isDue(lastGreeting: date(18, 9), now: date(19, 11), calendar: calendar))
        XCTAssertFalse(CompanionDashboardGreeting.isDue(lastGreeting: date(19, 7), now: date(19, 11), calendar: calendar))
        XCTAssertFalse(CompanionDashboardGreeting.isDue(lastGreeting: nil, now: date(19, 12), calendar: calendar))
        let morning = date(19, 9)
        let cached = CompanionDashboardMessage(text: "Let's explore insulin.", generatedAt: morning.addingTimeInterval(-60), includesHealthData: false)
        XCTAssertTrue(CompanionDashboardRefresh.isDue(message: cached, lastAttempt: nil, dataChanged: false, now: morning, morningGreetingRequired: true))
        XCTAssertFalse(CompanionDashboardRefresh.isDue(message: cached, lastAttempt: morning.addingTimeInterval(-60), dataChanged: false, now: morning, morningGreetingRequired: true))
    }

    func testNameDefaultsAndDashboardMemoryLoadFromLegacyState() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CompanionState())) as! [String: Any]
        object.removeValue(forKey: "preferredName")
        object.removeValue(forKey: "useRecentChatsForDashboard")
        let restored = try JSONDecoder().decode(CompanionState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.displayName, "Michelle")
        var state = restored
        state.preferredName = ""
        XCTAssertEqual(state.displayName, "")
    }

    private func discovery(_ id: String, subject: CompanionDashboardSubject = .cellTherapy, news: Bool = false) -> CompanionDashboardFact {
        CompanionDashboardFact(id: id, fact: "A synthetic public research discovery, not a real medical finding.",
            source: URL(string: "https://www.nih.gov/news-events/" + id)!, subject: subject, topicKey: id,
            publishedAt: String(ISO8601DateFormatter().string(from: now).prefix(10)), checkedAt: now,
            evidenceStage: news ? "early-human-trial" : "background", region: "International research", isNews: news)
    }

    func testPersonalDashboardNeverSelectsCachedDiscoveriesOrLearningTopics() throws {
        var state = CompanionState()
        state.dashboardDiscoveries = [discovery("study-one"), discovery("device-two", subject: .devices)]
        state = try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(state))
        let personal = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation, .insight], canCelebrate: false, now: now)
        XCTAssertEqual(personal.kinds, [.motivation])
        XCTAssertNil(personal.fact)
        XCTAssertEqual(personal.subject, .anticipation)
        let welcome = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation], canCelebrate: false, now: now)
        XCTAssertEqual(welcome.kinds, [.motivation])
        XCTAssertEqual(welcome.subject, .anticipation)
        XCTAssertNil(welcome.fact)
        let win = CompanionDashboardPlan.next(state: state, history: [], allowed: [.motivation, .insight], canCelebrate: true, now: now)
        XCTAssertEqual(win.subject, .glucoseWins)
    }

    func testNewsNeedsRetrievedCitationDateRegionAndFreshness() throws {
        let item = discovery("trial-result", news: true)
        let raw = String(decoding: try JSONEncoder().encode(["items": [item]]), as: UTF8.self)
        let contents = [CompanionDashboardFact.sourceKey(item.source): "Published " + item.publishedAt!]
        XCTAssertEqual(try CompanionDashboardFact.decodeDiscoveries(raw, citations: [], sourceContents: contents, now: now).count, 0)
        XCTAssertEqual(try CompanionDashboardFact.decodeDiscoveries(raw, citations: [item.source], now: now).count, 0)
        let accepted = try CompanionDashboardFact.decodeDiscoveries(raw, citations: [item.source], sourceContents: contents, now: now)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.evidenceStage, "early-human-trial")
        var unavailable = item
        unavailable.evidenceStage = "approved"
        unavailable.region = nil
        let unqualified = String(decoding: try JSONEncoder().encode(["items": [unavailable]]), as: UTF8.self)
        XCTAssertEqual(try CompanionDashboardFact.decodeDiscoveries(unqualified, citations: [item.source], sourceContents: contents, now: now).count, 0)
        XCTAssertFalse(item.isUsable(now: now.addingTimeInterval(86401)))
        var old = item
        old.publishedAt = "2020-01-01"
        XCTAssertFalse(old.isUsable(now: now))
        old.publishedAt = "2099-01-01"
        XCTAssertFalse(old.isUsable(now: now))
        XCTAssertFalse(CompanionDashboardFact.safeSource(URL(string: "https://nih.gov.attacker.example/story")!))
        XCTAssertFalse(CompanionDashboardFact.safeSource(URL(string: "http://www.nih.gov/story")!))
        XCTAssertFalse(CompanionDashboardFact.safeSource(URL(string: "https://www.nih.gov/")!))
        XCTAssertFalse(CompanionDashboardFact.sourceKey(URL(string: "https://www.nih.gov/story?id=1")!) == CompanionDashboardFact.sourceKey(URL(string: "https://www.nih.gov/story?id=2")!))
        XCTAssertEqual(CompanionDashboardFact.sourceKey(URL(string: "https://www.nih.gov/story?utm_source=test#part")!), "https://www.nih.gov/story")
    }

    func testPublicSearchIsSeparateBoundedAndHasNoAppTools() {
        let body = OpenRouterCompanionProvider.requestBody(model: "example/model", reasoningEffort: .medium,
            messages: [["role": "user", "content": "Public T1D research only"]], tools: [OpenRouterCompanionProvider.discoverySearchTool])
        XCTAssertEqual(body["max_tool_calls"] as? Int, 2)
        let tools = body["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["type"] as? String, "openrouter:web_search")
        XCTAssertNil(tools.first?["function"])
        let ordinary = OpenRouterCompanionProvider.requestBody(model: "example/model", reasoningEffort: .medium, messages: [], tools: CompanionTools.definitions)
        XCTAssertNil(ordinary["max_tool_calls"])
    }

    private func recentEncouragementPoints(_ value: Double = 105) -> [CompanionGlucosePoint] {
        (0..<7).map { CompanionGlucosePoint(date: now.addingTimeInterval(Double($0 - 6) * 300), mgdl: value) }
    }

    func testGlucosePraiseRequiresFreshCoveredReadingsInConfiguredTarget() {
        XCTAssertTrue(CompanionGlucoseEncouragement(points: recentEncouragementPoints(), now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(), now: now, lower: 100, upper: 110, sourceIsReliable: false).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(), now: now, lower: nil, upper: nil).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: [], now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: Array(recentEncouragementPoints().suffix(3)), now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(), now: now.addingTimeInterval(900), lower: 100, upper: 110).canCelebrateRecentTarget)
    }

    func testGlucosePraiseDoesNotCelebrateLowsHighsGapsOrRapidFalls() {
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(65), now: now, lower: 60, upper: 80).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(180), now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        var gapped = recentEncouragementPoints()
        gapped.remove(at: 3)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: gapped, now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        var falling = recentEncouragementPoints(110)
        falling[6].mgdl = 100
        XCTAssertFalse(CompanionGlucoseEncouragement(points: falling, now: now, lower: 100, upper: 110).canCelebrateRecentTarget)
        XCTAssertFalse(CompanionGlucoseEncouragement(points: recentEncouragementPoints(), now: now, lower: 100, upper: 110, safetyFloor: 110).canCelebrateRecentTarget)
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
