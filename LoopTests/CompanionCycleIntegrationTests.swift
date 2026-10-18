import XCTest
@testable import Loop

private final class CycleProviderProbe: CompanionProvider {
    var requestCount = 0
    var handler: (([[String: Any]], [[String: Any]]) async throws -> CompanionCompletion)?
    var messages: [[String: Any]] = []
    var tools: [[String: Any]] = []

    func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion {
        requestCount += 1
        self.messages = messages
        self.tools = tools
        if let handler { return try await handler(messages, tools) }
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
        controller.send("Read my cycle tracker")
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
        controller.send("Read my cycle tracker")
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
        XCTAssertEqual(try store.load().dashboardMessage?.text, "Cycle context received.")
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
        controller.send("Be more direct, no emojis, and call me Michelle from now on.")
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        let action = try XCTUnwrap(controller.state.actions.first)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(try store.load().personality, "Be gently funny and call me sunshine.")
        await controller.approve(action.id)
        XCTAssertEqual(try store.load().personality, "Be direct, use no emojis, and call me Michelle.")
        let futureProvider = CycleProviderProbe()
        let reloaded = CompanionController(provider: futureProvider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        reloaded.clearConversation()
        reloaded.send("Hello")
        for _ in 0..<200 where reloaded.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue((futureProvider.messages.first?["content"] as? String)?.contains("call me Michelle") == true)
        reloaded.setDashboardVisible(true)
        try await waitForDashboard(reloaded)
        XCTAssertTrue((futureProvider.messages.first?["content"] as? String)?.contains("call me Michelle") == true)
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
        try controller.saveSettings(model: "example/model", reasoningEffort: .medium, personality: "Be kind", allowHealthData: false, key: "")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(controller.state.dashboardMessage)
        XCTAssertNil(try store.load().dashboardMessage)
    }
}
