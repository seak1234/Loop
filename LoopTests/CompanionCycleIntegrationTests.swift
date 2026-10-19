import XCTest
@testable import Loop

private final class CycleProviderProbe: CompanionProvider {
    var requestCount = 0
    var discoveryCount = 0
    var discoveryFailure = false

    func discover(model: String, reasoningEffort: CompanionReasoningEffort, now: Date, excluding: [String]) async throws -> [CompanionDashboardFact] {
        discoveryCount += 1
        if discoveryFailure { throw CompanionError.invalid("Synthetic search failure") }
        return [CompanionDashboardFact(id: "synthetic-trial", fact: "A synthetic early human trial report, not real clinical news.",
            source: URL(string: "https://www.nih.gov/news-events/synthetic-trial")!, subject: .cellTherapy, topicKey: "synthetic-trial",
            publishedAt: String(ISO8601DateFormatter().string(from: now).prefix(10)), checkedAt: now,
            evidenceStage: "early-human-trial", region: "International research", isNews: true)]
    }

    var handler: (([[String: Any]], [[String: Any]]) async throws -> CompanionCompletion)?
    var messages: [[String: Any]] = []
    var tools: [[String: Any]] = []

    func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion {
        requestCount += 1
        self.messages = messages
        self.tools = tools
        if let handler { return try await handler(messages, tools) }
        if tools.isEmpty, let text = messages.last?["content"] as? String,
           let data = text.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           payload["allowed_message_kinds"] != nil {
            let fact = payload["curated_fact"] as? [String: Any] ?? [:]
            let allowed = payload["allowed_message_kinds"] as? [String] ?? []
            let kind = allowed.contains("curiosity") ? "curiosity" : (allowed.first ?? "motivation")
            let name = payload["address_by_name_this_time"] as? Bool == true ? (payload["preferred_name"] as? String ?? "") : ""
            let line = (name.isEmpty ? "" : name + ", ") + "a fresh diabetes question for visit \(requestCount)?"
            let json: [String: Any] = ["text": line, "kind": kind, "question": "What could we learn about this?", "factID": kind == "fact" ? (fact["id"] ?? NSNull()) : NSNull(), "topicID": NSNull()]
            let response = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            return CompanionCompletion(message: [:], text: response, calls: [])
        }
        return CompanionCompletion(message: ["role": "assistant", "content": "Cycle context received."],
                                   text: "Cycle context received.", calls: [])
    }
}

@MainActor
final class CompanionCycleIntegrationTests: XCTestCase {
    func testRealTrackerRecordsReachTheProviderBeforeItAnswers() async throws {
        let suite = "CompanionCycleIntegrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = CycleTrackingStore(defaults: defaults)
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        tracker.replacePeriodEntries(with: [.init(startDate: start, endDate: today)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var state = CompanionState()
        state.allowHealthData = true
        try store.save(state)
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker,
                                             keyReader: { "test-key-never-transmitted" })
        await controller.send("Read my cycle tracker")
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isThinking)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(provider.tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "get_cycle_context" })
        let output = try XCTUnwrap(provider.messages.first { $0["role"] as? String == "tool" }?["content"] as? String)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(payload["recordedPeriodCount"] as? Int, 1)
        XCTAssertEqual(payload["cycleDay"] as? Int, 3)
        XCTAssertEqual(payload["phase"] as? String, "period")
        XCTAssertEqual(payload["symptomDataAvailable"] as? Bool, false)
        XCTAssertEqual(controller.state.messages.last?.includesHealthData, true)
    }

    func testDisabledSharingReturnsPermissionStateWithoutPeriodData() async throws {
        let suite = "CompanionCycleIntegrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = CycleTrackingStore(defaults: defaults)
        tracker.startPeriod()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(CompanionState())
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker,
                                             keyReader: { "test-key-never-transmitted" })
        await controller.send("Read my cycle tracker")
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isThinking)
        let output = try XCTUnwrap(provider.messages.first { $0["role"] as? String == "tool" }?["content"] as? String)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(payload["status"] as? String, "error")
        XCTAssertTrue((payload["message"] as? String)?.contains("sharing is off") == true)
        XCTAssertNil(payload["recentPeriods"])
        XCTAssertEqual(controller.state.messages.last?.includesHealthData, false)
    }
}

@MainActor
final class CompanionDashboardIntegrationTests: XCTestCase {
    private func fixture(shareHealth: Bool) throws -> (CompanionStateStore, CycleTrackingStore, () -> Void) {
        let suite = "CompanionDashboardTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let tracker = CycleTrackingStore(defaults: defaults)
        tracker.startPeriod()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var state = CompanionState()
        state.allowHealthData = shareHealth
        state.personality = "Be gently funny and call me sunshine."
        state.preferredName = ""
        try store.save(state)
        return (store, tracker, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func waitForDashboard(_ controller: CompanionController) async throws {
        for _ in 0..<200 where controller.isRefreshingDashboard { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isRefreshingDashboard)
    }

    func testDashboardReadsAllContextCachesAndThrottlesRequests() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: true)
        defer { cleanup() }
        var initial = try store.load()
        initial.dashboardRotation = 2
        try store.save(initial)
        let provider = CycleProviderProbe()
        var queries: [String] = []
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
            dashboardHealthReader: { tool, start, end in
                queries.append(tool)
                XCTAssertEqual(end.timeIntervalSince(start), 6 * 3600)
                return ["fixture": tool]
            }, applicationIsActive: { true })
        let start = Date()
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertNil(controller.dashboardRefreshError)
        XCTAssertEqual(Set(queries), Set(["get_glucose_summary", "get_insulin_summary", "get_carb_entries"]))
        XCTAssertTrue(provider.tools.isEmpty)
        XCTAssertTrue((provider.messages[0]["content"] as? String)?.contains("call me sunshine") == true)
        let context = try XCTUnwrap(provider.messages[1]["content"] as? String)
        XCTAssertTrue(context.contains("recordedPeriodCount"))
        XCTAssertTrue(context.contains("local_time"))
        XCTAssertTrue(context.contains("time_zone"))
        XCTAssertEqual(try store.load().dashboardMessage?.text, "a fresh diabetes question for visit 1?")
        XCTAssertTrue(controller.state.messages.isEmpty)
        controller.requestDashboardRefresh(now: start.addingTimeInterval(60))
        XCTAssertEqual(provider.requestCount, 1)
        controller.dashboardDataDidChange()
        controller.requestDashboardRefresh(now: start.addingTimeInterval(301))
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.requestCount, 2)
        controller.setDashboardVisible(false)
        controller.requestDashboardRefresh(now: start.addingTimeInterval(2000))
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testDisabledSharingSendsOnlyTimeAndPersona() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        var readHealth = false
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
            dashboardHealthReader: { _, _, _ in readHealth = true; return [:] }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertFalse(readHealth)
        let content = try XCTUnwrap(provider.messages.last?["content"] as? String)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertNil(context["cycle"])
        XCTAssertNil(context["get_glucose_summary"])
        XCTAssertNil(context["get_insulin_summary"])
        XCTAssertNil(context["get_carb_entries"])
        XCTAssertEqual(controller.state.dashboardMessage?.includesHealthData, false)
    }

    func testPersonaChangedInChatPersistsAndReachesFutureChatAndDashboard() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        provider.handler = { messages, _ in
            if messages.last?["role"] as? String == "user" {
                let call = CompanionToolCall(id: "persona-test", name: "update_personality", arguments: Data(#"{"prompt":"Be direct, use no emojis, and call me Michelle."}"#.utf8))
                return CompanionCompletion(message: ["role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": String(decoding: call.arguments, as: UTF8.self)]]
                ]], text: "", calls: [call])
            }
            return CompanionCompletion(message: ["role": "assistant", "content": "Tap Apply to save."], text: "Tap Apply to save.", calls: [])
        }
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" })
        await controller.send("Be more direct, no emojis, and call me Michelle from now on.")
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        let action = try XCTUnwrap(controller.state.actions.first)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(try store.load().personality, "Be gently funny and call me sunshine.")
        await controller.approve(action.id)
        XCTAssertEqual(try store.load().personality, "Be direct, use no emojis, and call me Michelle.")
        let futureProvider = CycleProviderProbe()
        let reloaded = CompanionController(provider: futureProvider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        await reloaded.clearConversation()
        await reloaded.send("Hello")
        for _ in 0..<200 where reloaded.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue((futureProvider.messages.first?["content"] as? String)?.contains("call me Michelle") == true)
        reloaded.setDashboardVisible(true)
        try await waitForDashboard(reloaded)
        XCTAssertTrue((futureProvider.messages.first?["content"] as? String)?.contains("call me Michelle") == true)
    }

    func testRelevantMixAndNoveltyPersistAcrossRelaunch() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: true)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        var queries = 0
        for count in 1...5 {
            var saved = try store.load()
            saved.dashboardMessage?.generatedAt = Date().addingTimeInterval(-901)
            try store.save(saved)
            let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
                dashboardHealthReader: { _, _, _ in queries += 1; return [:] }, applicationIsActive: { true })
            controller.setDashboardVisible(true)
            try await waitForDashboard(controller)
            XCTAssertNil(controller.dashboardRefreshError)
            XCTAssertEqual(try store.load().dashboardGenerationCount, count)
            XCTAssertEqual(try store.load().dashboardRecentMessages?.count, count)
            XCTAssertEqual(queries, count * 3)
            let subjects = try store.load().dashboardRecentMessages?.compactMap(\.subject) ?? []
            XCTAssertEqual(Set(subjects).count, count)
            if count == 1 {
                XCTAssertEqual(controller.state.dashboardMessage?.kind, .fact)
                XCTAssertEqual(controller.dashboardFact?.id, "synthetic-trial")
                XCTAssertEqual(controller.dashboardFact?.evidenceStage, "early-human-trial")
            }
            controller.setDashboardVisible(false)
        }
    }

    func testDashboardFeedbackPersistsAndImmediatelyChangesTheNextMessage() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        let first = try XCTUnwrap(controller.state.dashboardMessage)
        XCTAssertEqual(first.sourceFact?.id, "synthetic-trial")
        await controller.rateDashboardMessage(.alreadyKnow, message: first)
        try await waitForDashboard(controller)
        XCTAssertTrue(try store.load().dashboardKnownFacts?.contains("synthetic-trial") == true)
        let second = try XCTUnwrap(controller.state.dashboardMessage)
        XCTAssertNotEqual(second.factID, first.factID)
        await controller.rateDashboardMessage(.less, message: second)
        try await waitForDashboard(controller)
        XCTAssertEqual(try store.load().dashboardSubjectPreferences?[second.subject!.rawValue], .less)
        XCTAssertNotEqual(controller.state.dashboardMessage?.subject, second.subject)
        // Feedback is attached to the card that was displayed, even if another card has since arrived.
        await controller.rateDashboardMessage(.more, message: first)
        try await waitForDashboard(controller)
        XCTAssertEqual(try store.load().dashboardSubjectPreferences?["cellTherapy"], .more)
        await controller.resetDashboardPreferences()
        try await waitForDashboard(controller)
        XCTAssertNil(try store.load().dashboardKnownFacts)
        XCTAssertNil(try store.load().dashboardSubjectPreferences)
        controller.setDashboardVisible(false)
    }

    func testPublicDiscoveriesCacheAcrossRelaunchAndCanBeDisabledWithoutHealthSharing() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        var controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 1)
        XCTAssertEqual(controller.dashboardFact?.id, "synthetic-trial")
        XCTAssertFalse(controller.state.allowHealthData)
        XCTAssertTrue(provider.tools.isEmpty)
        controller.setDashboardVisible(false)
        var saved = try store.load()
        saved.dashboardMessage?.generatedAt = Date().addingTimeInterval(-901)
        try store.save(saved)
        controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 1)
        try await controller.saveSettings(model: controller.state.model, reasoningEffort: .medium, personality: "Be warm", allowHealthData: false, key: "", enableT1DUpdates: false)
        try await waitForDashboard(controller)
        XCTAssertNil(try store.load().dashboardDiscoveries)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        XCTAssertEqual(provider.discoveryCount, 1)
        controller.setDashboardVisible(false)
    }

    func testFailedPublicSearchDoesNotInventNewsAndIsThrottled() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        provider.discoveryFailure = true
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 1)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        XCTAssertNotEqual(controller.state.dashboardMessage?.kind, .fact)
        XCTAssertNil(controller.dashboardRefreshError)
        controller.requestDashboardRefresh(now: Date().addingTimeInterval(901))
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 1)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        controller.setDashboardVisible(false)
    }

    func testEditableNamePersistsAndIsUsedOccasionally() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        var state = try store.load()
        state.preferredName = "Michelle"
        try store.save(state)
        let provider = CycleProviderProbe()
        for count in 0..<4 {
            state = try store.load()
            state.dashboardMessage?.generatedAt = Date().addingTimeInterval(-901)
            try store.save(state)
            let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
            controller.setDashboardVisible(true)
            try await waitForDashboard(controller)
            XCTAssertNil(controller.dashboardRefreshError)
            XCTAssertEqual(controller.state.dashboardMessage?.text.contains("Michelle"), count % 3 == 0)
            controller.setDashboardVisible(false)
        }
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" })
        try await controller.saveSettings(model: controller.state.model, reasoningEffort: .medium, personality: "Be warm", allowHealthData: false, key: "", preferredName: "  River  ")
        XCTAssertEqual(try store.load().displayName, "River")
        XCTAssertNil(try store.load().dashboardMessage)
    }

    func testRecentUserTopicsRequireSharingAndRespectOptOutAndClearing() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: true)
        defer { cleanup() }
        var state = try store.load()
        state.messages = [CompanionMessage(role: "user", text: "Could sleep affect my mornings?")]
        try store.save(state)
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
            dashboardHealthReader: { _, _, _ in [:] }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        var payload = try XCTUnwrap(provider.messages.last?["content"] as? String)
        XCTAssertTrue(payload.contains("Could sleep affect my mornings?"))
        try await controller.saveSettings(model: controller.state.model, reasoningEffort: .medium, personality: "Be warm", allowHealthData: true, key: "", useRecentChatsForDashboard: false)
        try await waitForDashboard(controller)
        payload = try XCTUnwrap(provider.messages.last?["content"] as? String)
        XCTAssertFalse(payload.contains("Could sleep affect my mornings?"))
        await controller.clearConversation()
        try await waitForDashboard(controller)
        XCTAssertTrue(try store.load().messages.isEmpty)
        controller.setDashboardVisible(false)
    }

    func testDashboardTapKeepsExactDisplayedTopicAndOpeningTurnIsReadOnly() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        let displayed = try XCTUnwrap(controller.state.dashboardMessage)
        controller.prepareDashboardDiscussion()
        controller.requestDashboardRefresh(now: Date().addingTimeInterval(901))
        try await waitForDashboard(controller)
        XCTAssertNotEqual(controller.state.dashboardMessage?.text, displayed.text)
        controller.setDashboardVisible(false)
        controller.beginChatSession()
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        let detail = provider.messages.compactMap { $0["content"] as? String }.first { $0.contains("The user tapped this exact dashboard") }
        XCTAssertTrue(detail?.contains(displayed.text) == true)
        XCTAssertEqual(controller.state.messages.first?.text, displayed.followUpQuestion)
        XCTAssertEqual(controller.state.messages.first?.dashboardOrigin, true)
        let names = provider.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), Set(["get_glucose_summary", "get_insulin_summary", "get_carb_entries", "get_cycle_context"]))
        XCTAssertTrue(controller.state.actions.isEmpty)
        controller.endChatSession()
    }

    func testSuggestedTopicsRegenerateOnEntryWithoutReadingHealthStores() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: true)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        provider.handler = { _, _ in
            let text = provider.requestCount == 1
                ? #"{"topics":[{"title":"Food labels","prompt":"Help me understand carb labels."},{"title":"Sleep and glucose","prompt":"How might sleep affect glucose?"}]}"#
                : #"{"topics":[{"title":"Exercise patterns","prompt":"Help me learn about exercise and glucose."},{"title":"Stress and glucose","prompt":"How might stress affect glucose?"}]}"#
            return CompanionCompletion(message: [:], text: text, calls: [])
        }
        var readHealth = false
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
            dashboardHealthReader: { _, _, _ in readHealth = true; return [:] })
        controller.beginChatSession()
        for _ in 0..<200 where controller.isGeneratingTopics { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.suggestedTopics.map(\.title), ["Food labels", "Sleep and glucose"])
        controller.endChatSession()
        controller.beginChatSession()
        for _ in 0..<200 where controller.isGeneratingTopics { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.suggestedTopics.map(\.title), ["Exercise patterns", "Stress and glucose"])
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertTrue(provider.tools.isEmpty)
        XCTAssertFalse(readHealth)
        XCTAssertTrue(controller.state.messages.isEmpty)
        XCTAssertTrue((provider.messages.first?["content"] as? String)?.contains("Food labels, Sleep and glucose") == true)
        controller.endChatSession()
    }

    func testCancelledDashboardResponseCannotRestoreHealthContext() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: true)
        defer { cleanup() }
        var initial = try store.load()
        initial.dashboardRotation = 2
        try store.save(initial)
        let provider = CycleProviderProbe()
        provider.handler = { _, _ in
            // Simulate a provider finishing despite cancellation.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return CompanionCompletion(message: [:], text: "An old health message", calls: [])
        }
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" },
            dashboardHealthReader: { _, _, _ in [:] }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        for _ in 0..<100 where provider.requestCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        controller.setDashboardVisible(false)
        try await controller.saveSettings(model: "example/model", reasoningEffort: .medium, personality: "Be kind", allowHealthData: false, key: "")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(controller.state.dashboardMessage)
        XCTAssertNil(try store.load().dashboardMessage)
    }
}


@MainActor
final class CompanionMealPhotoIntegrationTests: XCTestCase {
    func testMealChatRevisesEstimateWithCorrectionsAndAdditionalPhotosWithoutSaving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(CompanionState())
        let provider = CycleProviderProbe()
        var grams = 40
        provider.handler = { _, _ in
            CompanionCompletion(message: [:], text: "{\"updateForm\":true,\"message\":\"Here’s my estimate.\",\"estimate\":{\"food\":\"🌮\",\"grams\":\(grams),\"absorptionMinutes\":120,\"explanation\":\"Bread portion.\",\"assumptions\":\"Topping uncertain.\"}}", calls: [])
        }
        let controller = CompanionController(provider: provider, stateStore: store, keyReader: { "test-key" })
        let chat = CompanionMealConversation(controller: controller, maximumGrams: 250, absorptionRange: 900...28800, defaults: [7200, 10800, 14400])
        chat.send("Estimate this meal", jpeg: Data([1, 2, 3]))
        XCTAssertFalse(chat.canContinue)
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(chat.estimate?.grams, 40)
        XCTAssertTrue(chat.canContinue)
        XCTAssertTrue(provider.tools.isEmpty)
        XCTAssertEqual(provider.messages.count, 2)
        grams = 20
        chat.send("I’m eating half")
        XCTAssertFalse(chat.canContinue)
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(chat.estimate?.grams, 20)
        XCTAssertTrue(chat.canContinue)
        XCTAssertEqual(provider.messages.count, 4)
        let previousReply = try XCTUnwrap(provider.messages[2]["content"] as? String)
        XCTAssertTrue(previousReply.contains("40"))
        grams = 25
        chat.send("This photo shows the topping", jpeg: Data([4, 5, 6]))
        XCTAssertFalse(chat.canContinue)
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(chat.estimate?.grams, 25)
        XCTAssertEqual(chat.turns.filter { $0.jpeg != nil }.count, 2)
        XCTAssertEqual(provider.messages.count, 6)
        let parts = try XCTUnwrap(provider.messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual((parts.last?["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,BAUG")
        XCTAssertTrue(controller.state.messages.isEmpty)
        XCTAssertTrue(controller.state.actions.isEmpty)
        XCTAssertTrue(try store.load().messages.isEmpty)
        provider.handler = { _, _ in CompanionCompletion(message: [:], text: #"{"updateForm":true,"message":"How much of this will you eat?","estimate":null}"#, calls: []) }
        chat.send("Actually, the portion is different")
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(chat.estimate)
        XCTAssertFalse(chat.canContinue)
    }

    func testFailedOrCanceledRevisionBlocksContinueUntilRetriedOrDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        try store.save(CompanionState())
        let provider = CycleProviderProbe()
        let good = #"{"updateForm":true,"message":"Looks like toast.","estimate":{"food":"🌮","grams":20,"absorptionMinutes":120,"explanation":"Bread portion.","assumptions":"One slice."}}"#
        provider.handler = { _, _ in CompanionCompletion(message: [:], text: good, calls: []) }
        let controller = CompanionController(provider: provider, stateStore: store, keyReader: { "test-key" })
        let chat = CompanionMealConversation(controller: controller, maximumGrams: 250, absorptionRange: 900...28800, defaults: [7200, 10800, 14400])
        chat.send("Estimate", jpeg: Data([1]))
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        provider.handler = { _, _ in throw CompanionError.invalid("Offline") }
        chat.send("I am having twice as much")
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(chat.canContinue)
        XCTAssertTrue(chat.needsReply)
        XCTAssertNotNil(chat.error)
        chat.discardPending()
        XCTAssertTrue(chat.canContinue)
        provider.handler = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return CompanionCompletion(message: [:], text: good, calls: [])
        }
        chat.send("Another revision")
        chat.cancel()
        XCTAssertFalse(chat.canContinue)
        XCTAssertTrue(chat.needsReply)
        chat.discardPending()
        XCTAssertTrue(chat.canContinue)
    }
}
