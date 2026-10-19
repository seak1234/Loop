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
            let greeting = payload["morning_greeting_required"] as? Bool == true ? (name.isEmpty ? "Good morning! " : "Good morning, " + name + "! ") : ""
            let line = greeting + "a fresh diabetes question for visit \(requestCount)?"
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
final class CompanionCycleSurfaceTests: XCTestCase {
    private func fixture(sharing: Bool) throws -> (CompanionController, CycleProviderProbe, CycleTrackingStore, () -> Void) {
        let suite = "CycleSurfaceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let tracker = CycleTrackingStore(defaults: defaults)
        tracker.startPeriod(on: Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var state = CompanionState()
        state.allowHealthData = sharing
        state.messages = [CompanionMessage(role: "user", text: "PRIVATE_GENERAL_CHAT_MARKER")]
        try store.save(state)
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, cycleJournal: CycleJournalStore(url: directory.appendingPathComponent("journal.json")),
                                             keyReader: { "test-key-never-transmitted" })
        return (controller, provider, tracker, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testCycleCardIsScopedAndDoesNotSendPersonalHistoryOrPeriodDates() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let templates = Dictionary(uniqueKeysWithValues: CompanionCycleCardPhase.allCases.map { ($0.rawValue, CompanionCycleCardMessage.topics(for: $0)[0]) })
        let response = String(decoding: try JSONEncoder().encode(templates), as: UTF8.self)
        provider.handler = { _, _ in
            CompanionCompletion(message: [:], text: response, calls: [])
        }
        let cards = try await controller.makeCycleCards()
        XCTAssertEqual(cards.count, 5)
        XCTAssertEqual(cards[.period]?.text, templates["period"]?.text)
        XCTAssertEqual(cards[.luteal]?.text, templates["luteal"]?.text)
        XCTAssertTrue(provider.tools.isEmpty)
        XCTAssertEqual(provider.messages.count, 2)
        let prompt = try XCTUnwrap(provider.messages.first?["content"] as? String)
        XCTAssertTrue(prompt.contains("ONLY about menstrual cycles"))
        let request = String(describing: provider.messages)
        XCTAssertFalse(request.contains("PRIVATE_GENERAL_CHAT_MARKER"))
        XCTAssertFalse(request.contains("recentPeriods"))
        XCTAssertEqual(controller.state.messages.count, 1)
    }

    func testRepeatedCycleCardsRetryThenChooseDifferentTopics() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        let templates = Dictionary(uniqueKeysWithValues: CompanionCycleCardPhase.allCases.map { ($0.rawValue, CompanionCycleCardMessage.topics(for: $0)[0]) })
        let response = String(decoding: try JSONEncoder().encode(templates), as: UTF8.self)
        provider.handler = { _, _ in CompanionCompletion(message: [:], text: response, calls: []) }
        let first = try await controller.makeCycleCards()
        let second = try await controller.makeCycleCards()
        XCTAssertEqual(provider.requestCount, 3)
        for phase in CompanionCycleCardPhase.allCases {
            XCTAssertFalse(first[phase]?.text == second[phase]?.text)
            XCTAssertFalse(first[phase]?.question == second[phase]?.question)
        }
        XCTAssertEqual(controller.state.cycleCardHistory?["period"]?.count, 2)
        XCTAssertEqual(controller.state.cycleCardGenerationCount, 2)
        XCTAssertTrue(String(describing: provider.messages).contains("avoid_previous_cards"))
        XCTAssertFalse(String(describing: provider.messages).contains("PRIVATE_GENERAL_CHAT_MARKER"))
    }

    func testOfflineCycleCardsRotateAndRememberHistoryAfterRelaunch() async throws {
        let (_, provider, tracker, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { nil })
        var questions = Set<String>()
        for _ in 0..<8 {
            let cards = try await controller.makeCycleCards()
            questions.insert(cards[.period]!.question)
        }
        XCTAssertEqual(questions.count, 8)
        XCTAssertEqual(provider.requestCount, 0)
        let saved = try store.load()
        XCTAssertEqual(saved.cycleCardGenerationCount, 8)
        let previous = saved.cycleCardHistory?["period"]?.last
        let restarted = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { nil })
        let next = try await restarted.makeCycleCards()
        XCTAssertFalse(next[.period]?.question == previous?.question)
    }

    func testRepeatedDashboardMessagesRetryThenUseFreshCopy() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        provider.handler = { messages, _ in
            let content = messages.first(where: { $0["role"] as? String == "user" })?["content"] as! String
            let context = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
            let greeting = context["morning_greeting_required"] as? Bool == true ? "Good morning, Michelle! " : "Hey, Michelle! "
            let value = ["text": greeting + "Your questions deserve room here.", "kind": "motivation", "question": "Can we explore a question together?"]
            return CompanionCompletion(message: [:], text: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), calls: [])
        }
        controller.setDashboardVisible(true)
        for _ in 0..<200 where controller.isRefreshingDashboard { try await Task.sleep(nanoseconds: 10_000_000) }
        let first = try XCTUnwrap(controller.state.dashboardMessage)
        controller.requestDashboardRefresh(now: Date().addingTimeInterval(901))
        for _ in 0..<200 where controller.isRefreshingDashboard { try await Task.sleep(nanoseconds: 10_000_000) }
        let second = try XCTUnwrap(controller.state.dashboardMessage)
        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertFalse(CompanionMessageVariety.isRepeat(second.text, recent: [first.text], name: "Michelle"))
        XCTAssertFalse(first.followUpQuestion == second.followUpQuestion)
        XCTAssertEqual(controller.state.dashboardRecentMessages?.count, 2)
        XCTAssertTrue(String(describing: provider.messages).contains("variety_focus"))
        XCTAssertFalse(String(describing: provider.messages).contains("PRIVATE_GENERAL_CHAT_MARKER"))
    }

    func testShortcutHistoryRejectsRepeatedTopicsOnLaterVisits() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        provider.handler = { _, _ in
            CompanionCompletion(message: [:], text: #"{"topics":[{"title":"Food labels","prompt":"How can I read a food label?"},{"title":"Sleep connections","prompt":"How can sleep affect glucose?"}]}"#, calls: [])
        }
        controller.beginChatSession()
        for _ in 0..<200 where controller.isGeneratingTopics { try await Task.sleep(nanoseconds: 10_000_000) }
        let first = controller.suggestedTopics
        controller.endChatSession()
        controller.beginChatSession()
        for _ in 0..<200 where controller.isGeneratingTopics { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(controller.suggestedTopics.count, 2)
        XCTAssertTrue(controller.suggestedTopics.allSatisfy { !CompanionMessageVariety.isRepeat($0.title, recent: first.map(\.title)) })
        XCTAssertEqual(controller.state.recentSuggestedTopics?.count, 4)
        controller.endChatSession()
    }

    func testDashboardMorningFallbackIsWelcomingBeforeAnyNetworkReply() throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let text = controller.dashboardText(now: morning)
        XCTAssertTrue(text.hasPrefix("Good morning"))
        XCTAssertFalse(text.hasPrefix("Michelle"))
        XCTAssertTrue(CompanionDashboardRefresh.isConcise(text))
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testCardPhaseMatchesCurrentAndProjectedCycleAndUpdatedPeriodDates() throws {
        let (controller, _, tracker, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (offset, phase) in [(0, CompanionCycleCardPhase.period), (3, .follicular), (10, .ovulation), (13, .luteal),
                                (28, .period), (31, .follicular), (38, .ovulation), (41, .luteal)] {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            XCTAssertEqual(controller.cycleCardPhase(on: date), phase)
        }
        let oldStart = calendar.date(byAdding: .day, value: -20, to: today)!
        let oldEnd = calendar.date(byAdding: .day, value: -16, to: today)!
        tracker.replacePeriodEntries(with: [.init(startDate: oldStart, endDate: oldEnd)])
        XCTAssertEqual(controller.cycleCardPhase(on: today), .luteal)
        tracker.startPeriod(on: today)
        XCTAssertEqual(controller.cycleCardPhase(on: today), .period)
        tracker.replacePeriodEntries(with: [])
        XCTAssertEqual(controller.cycleCardPhase(on: today), .unknown)
    }

    func testPhaseCardValidationRejectsMissingOrUnrelatedPhaseContent() throws {
        var templates = Dictionary(uniqueKeysWithValues: CompanionCycleCardPhase.allCases.map { ($0.rawValue, CompanionCycleCardMessage.topics(for: $0)[0]) })
        let valid = String(decoding: try JSONEncoder().encode(templates), as: UTF8.self)
        XCTAssertEqual(try CompanionCycleCardMessage.decodePhaseCards(valid).count, 5)
        templates["luteal"] = nil
        let missing = String(decoding: try JSONEncoder().encode(templates), as: UTF8.self)
        XCTAssertThrowsError(try CompanionCycleCardMessage.decodePhaseCards(missing))
        templates["luteal"] = CompanionCycleCardMessage.topics[0]
        let generic = String(decoding: try JSONEncoder().encode(templates), as: UTF8.self)
        XCTAssertThrowsError(try CompanionCycleCardMessage.decodePhaseCards(generic))
    }

    func testCycleChatWithoutSharingKeepsOnlyItsOwnConversation() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        let reply = try await controller.replyToCycleConversation([
            CompanionMessage(role: "assistant", text: "PRIVATE_OLD_HEALTH_MARKER", includesHealthData: true),
            CompanionMessage(role: "user", text: "How does my cycle relate to T1D?")
        ])
        XCTAssertEqual(reply.includesHealthData, false)
        XCTAssertEqual(provider.messages.count, 2)
        XCTAssertTrue(provider.tools.isEmpty)
        let request = String(describing: provider.messages)
        XCTAssertFalse(request.contains("PRIVATE_GENERAL_CHAT_MARKER"))
        XCTAssertFalse(request.contains("PRIVATE_OLD_HEALTH_MARKER"))
        XCTAssertFalse(request.contains("recordedPeriodCount"))
        XCTAssertEqual(controller.state.messages.count, 1)
    }

    func testCycleChatWithSharingIncludesRealTrackerAndDisplayedEstimate() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let reply = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Tell me about this phase.")])
        XCTAssertEqual(reply.includesHealthData, true)
        let names = provider.tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(names.contains("get_glucose_summary"))
        XCTAssertFalse(names.contains("save_cycle_note"))
        XCTAssertFalse(names.contains("propose_automation"))
        let snapshot = try XCTUnwrap(provider.messages.dropFirst().first?["content"] as? String)
        XCTAssertTrue(snapshot.contains("\"recordedPeriodCount\":1"))
        XCTAssertTrue(snapshot.contains("\"cycleDay\":3"))
        XCTAssertTrue(snapshot.contains("continuing calendar estimate"))
        XCTAssertFalse(String(describing: provider.messages).contains("PRIVATE_GENERAL_CHAT_MARKER"))
    }

    func testCycleChatRejectsUnexpectedActions() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: false)
        defer { cleanup() }
        provider.handler = { _, _ in
            CompanionCompletion(message: [:], text: "", calls: [CompanionToolCall(id: "unexpected", name: "propose_carb_entry", arguments: Data("{}".utf8))])
        }
        var rejected = false
        do { _ = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "What is PMS?")]) }
        catch { rejected = true }
        XCTAssertTrue(rejected)
        XCTAssertTrue(controller.state.actions.isEmpty)
    }

    func testCycleCardRejectsOverlongOrEmptyGeneratedMessages() throws {
        XCTAssertThrowsError(try CompanionCycleCardMessage.decode(#"{"text":"","question":"What is PMS?"}"#))
        let invalid = String(decoding: try JSONEncoder().encode(CompanionCycleCardMessage(text: String(repeating: "a", count: 141), question: "What is PMS?")), as: UTF8.self)
        XCTAssertThrowsError(try CompanionCycleCardMessage.decode(invalid))
        for topic in CompanionCycleCardMessage.topics {
            let encoded = String(decoding: try JSONEncoder().encode(topic), as: UTF8.self)
            XCTAssertEqual(try CompanionCycleCardMessage.decode(encoded).question, topic.question)
        }
    }
    func testJournalPersistsEditsAndDeletesOutsideChat() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let journal = controller.cycleJournal
        let date = Date().addingTimeInterval(-60)
        let saved = try journal.saveNote(date: date, text: "  More sensitive today  ", tags: [.sensitive, .sensitive])
        XCTAssertEqual(saved.tags, [.sensitive])
        let reloaded = CycleJournalStore(url: journal.url)
        XCTAssertEqual(reloaded.state.notes.first?.text, "More sensitive today")
        try reloaded.saveNote(id: saved.id, date: date, text: "Correction: after exercise", tags: [.exercise])
        XCTAssertEqual(reloaded.state.notes.count, 1)
        try reloaded.deleteNote(saved.id)
        XCTAssertTrue(CycleJournalStore(url: journal.url).state.notes.isEmpty)
        XCTAssertEqual(controller.state.messages.count, 1)
    }

    func testJournalRejectsInvalidWritesAndPreservesCorruptHistory() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let journal = controller.cycleJournal
        XCTAssertThrowsError(try journal.saveNote(date: Date().addingTimeInterval(86400), text: "Future", tags: []))
        XCTAssertThrowsError(try journal.saveNote(date: Date(), text: "   ", tags: []))
        XCTAssertThrowsError(try journal.saveNote(date: Date(), text: String(repeating: "a", count: 6001), tags: []))
        try journal.update { $0.allowMochiRead = true }
        let original = Data("unreadable journal".utf8)
        try original.write(to: journal.url)
        let broken = CycleJournalStore(url: journal.url)
        XCTAssertTrue(broken.failure != nil)
        XCTAssertThrowsError(try broken.saveNote(date: Date(), text: "Overwrite", tags: []))
        XCTAssertEqual(try Data(contentsOf: journal.url), original)
    }

    func testMochiWritesRequireSeparatePermissionAndReturnRealSavedID() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let journal = controller.cycleJournal
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let args = try JSONSerialization.data(withJSONObject: ["date": date, "text": "Cravings after dinner", "tags": ["cravings"]])
        var requested = false
        provider.handler = { _, tools in
            if journal.state.allowMochiWrite { XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "save_cycle_note" }) }
            if !requested {
                requested = true
                return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": "save", "type": "function", "function": ["name": "save_cycle_note", "arguments": String(decoding: args, as: UTF8.self)]]]], text: "", calls: [.init(id: "save", name: "save_cycle_note", arguments: args)])
            }
            return CompanionCompletion(message: ["role": "assistant", "content": "Saved."], text: "Saved.", calls: [])
        }
        // Permission to read health data alone does not permit note writes.
        var denied = false
        do { _ = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Save a cycle note")]) }
        catch { denied = true }
        XCTAssertTrue(denied)
        XCTAssertTrue(journal.state.notes.isEmpty)
        try journal.update { $0.allowMochiWrite = true }
        requested = false
        let reply = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Save a note: cravings after dinner")])
        XCTAssertEqual(reply.cycleNoteIDs?.first, journal.state.notes.first?.id)
        XCTAssertEqual(journal.state.notes.first?.source, "mochi")
        let first = journal.state.notes[0]
        let duplicate = try journal.saveNote(date: first.occurredAt, text: first.text, tags: first.tags, source: "mochi")
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(journal.state.notes.count, 1)
    }

    func testAddToCalendarSavesTodayWithoutJournalReadPermission() async throws {
        let (controller, provider, tracker, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        try controller.cycleJournal.update { $0.allowMochiWrite = true }
        let report = "I'm just really insulin resistant today."
        let arguments = try JSONSerialization.data(withJSONObject: ["date": "today", "text": report, "tags": ["resistant"]])
        provider.handler = { messages, tools in
            let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertTrue(names.contains("save_cycle_note"))
            XCTAssertFalse(names.contains("get_cycle_journal"))
            XCTAssertTrue((messages.first?["content"] as? String ?? "").lowercased().contains("add this to my calendar"))
            if provider.requestCount == 1 {
                return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": "save-today", "type": "function", "function": ["name": "save_cycle_note", "arguments": String(decoding: arguments, as: UTF8.self)]]]], text: "", calls: [.init(id: "save-today", name: "save_cycle_note", arguments: arguments)])
            }
            return CompanionCompletion(message: [:], text: "Saved your note for today.", calls: [])
        }
        let reply = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: report + " Add this to my calendar")])
        let saved = try XCTUnwrap(controller.cycleJournal.state.notes.first)
        XCTAssertEqual(saved.day, CycleDay.key(Date()))
        XCTAssertEqual(saved.text, report)
        XCTAssertEqual(saved.tags, [.resistant])
        XCTAssertEqual(saved.cycleContext, tracker.noteContext(on: saved.occurredAt))
        XCTAssertEqual(reply.cycleNoteIDs, [saved.id])
        XCTAssertEqual(controller.cycleJournal.state.notes.count, 1)
    }

    func testInvalidJournalReadCanRecoverToLatestCalendarSaveRequest() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        try controller.cycleJournal.update { $0.allowMochiRead = true; $0.allowMochiWrite = true }
        provider.handler = { messages, _ in
            let name: String
            let args: [String: Any]
            switch provider.requestCount {
            case 1:
                name = "get_cycle_journal"
                args = ["start": "today", "end": "tonight"]
            case 2:
                XCTAssertTrue(controller.cycleJournal.state.notes.isEmpty)
                let payload = try XCTUnwrap(messages.last?["content"] as? String)
                XCTAssertTrue(payload.contains("not_completed"))
                XCTAssertTrue(payload.contains("past journal range"))
                name = "save_cycle_note"
                args = ["date": "today", "text": "I'm just really insulin resistant today.", "tags": ["resistant"]]
            default:
                return CompanionCompletion(message: [:], text: "Saved your note for today.", calls: [])
            }
            let arguments = try JSONSerialization.data(withJSONObject: args)
            let id = "call-\(provider.requestCount)"
            return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": id, "type": "function", "function": ["name": name, "arguments": String(decoding: arguments, as: UTF8.self)]]]], text: "", calls: [.init(id: id, name: name, arguments: arguments)])
        }
        let reply = try await controller.replyToCycleConversation([
            CompanionMessage(role: "user", text: "Which symptoms stand out across my period phase?"),
            CompanionMessage(role: "user", text: "I'm just really insulin resistant today. Add this to my calendar")
        ])
        XCTAssertEqual(provider.requestCount, 3)
        XCTAssertEqual(controller.cycleJournal.state.notes.count, 1)
        XCTAssertEqual(reply.cycleNoteIDs, controller.cycleJournal.state.notes.map(\.id))
    }

    func testFutureNoteDateIsRejectedBeforeModelCorrectsItToToday() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        try controller.cycleJournal.update { $0.allowMochiWrite = true }
        provider.handler = { messages, _ in
            if provider.requestCount == 3 { return CompanionCompletion(message: [:], text: "Saved.", calls: []) }
            if provider.requestCount == 2 {
                XCTAssertTrue(controller.cycleJournal.state.notes.isEmpty)
                XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("not_completed"))
            }
            let date = provider.requestCount == 1
                ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)) : "today"
            let args = try JSONSerialization.data(withJSONObject: ["date": date, "text": "Cravings today", "tags": ["cravings"]])
            let id = "save-\(provider.requestCount)"
            return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": id, "type": "function", "function": ["name": "save_cycle_note", "arguments": String(decoding: args, as: UTF8.self)]]]], text: "", calls: [.init(id: id, name: "save_cycle_note", arguments: args)])
        }
        let reply = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Save cravings for today")])
        XCTAssertEqual(controller.cycleJournal.state.notes.count, 1)
        XCTAssertEqual(controller.cycleJournal.state.notes.first?.day, CycleDay.key(Date()))
        XCTAssertEqual(reply.cycleNoteIDs?.count, 1)
    }

    func testJournalReadIsScopedAndContainsNoGraphOrUnrelatedChat() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let journal = controller.cycleJournal
        try journal.update { $0.allowMochiRead = true }
        try journal.saveNote(date: Date().addingTimeInterval(-60), text: "JOURNAL_REPORT", tags: [.cravings])
        var read = false
        let start = Calendar.current.startOfDay(for: Date())
        let args = try JSONSerialization.data(withJSONObject: ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: Date())])
        provider.handler = { messages, _ in
            if !read {
                read = true
                return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": "read", "type": "function", "function": ["name": "get_cycle_journal", "arguments": String(decoding: args, as: UTF8.self)]]]], text: "", calls: [.init(id: "read", name: "get_cycle_journal", arguments: args)])
            }
            let payload = messages.last?["content"] as? String ?? ""
            XCTAssertTrue(payload.contains("JOURNAL_REPORT"))
            XCTAssertTrue(payload.contains("user_report") || payload.contains("User notes are reports"))
            XCTAssertFalse(String(describing: messages).contains("PRIVATE_GENERAL_CHAT_MARKER"))
            return CompanionCompletion(message: [:], text: "Read your note.", calls: [])
        }
        _ = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Read today's notes")])
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testConsentRevokedDuringProviderRequestPreventsSaving() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        try controller.cycleJournal.update { $0.allowMochiWrite = true }
        provider.handler = { _, _ in
            try controller.cycleJournal.update { $0.allowMochiWrite = false }
            return CompanionCompletion(message: [:], text: "", calls: [.init(id: "late", name: "save_cycle_note", arguments: Data("{}".utf8))])
        }
        var rejected = false
        do { _ = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Save a cycle note")]) }
        catch { rejected = true }
        XCTAssertTrue(rejected)
        XCTAssertTrue(controller.cycleJournal.state.notes.isEmpty)
    }

    func testWeightedGlucoseCoverageDoesNotFillGapsOrFutureTime() throws {
        let start = CycleDay.date("2026-01-01")!
        let end = start.addingTimeInterval(1800)
        let points = [CycleGlucoseReading(date: start, mgdl: 100), .init(date: start.addingTimeInterval(300), mgdl: 200), .init(date: start.addingTimeInterval(1200), mgdl: 300)]
        let summary = CycleDailySummary.make(start: start, end: end, now: end, readings: points, range: { _ in (80, 180) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        XCTAssertEqual(summary.coveredSeconds, 900)
        XCTAssertEqual(summary.meanMGDL, 200)
        XCTAssertEqual(summary.timeInRange, 1.0 / 3.0)
        XCTAssertNil(summary.insulinUnits)
        let partial = CycleDailySummary.make(start: start, end: end, now: start.addingTimeInterval(60), readings: [points[0]], range: { _ in nil }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        XCTAssertEqual(partial.coveredSeconds, 60)
        XCTAssertTrue(partial.isPartialDay)
        XCTAssertFalse(partial.usableForPatterns)
    }

    func testCivilDaysAndDSTUseActualDayLength() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        XCTAssertNil(CycleDay.date("2026-02-30", calendar: calendar))
        let start = calendar.startOfDay(for: CycleDay.date("2026-03-08", calendar: calendar)!)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let readings = stride(from: 0.0, to: end.timeIntervalSince(start), by: 300).map { CycleGlucoseReading(date: start.addingTimeInterval($0), mgdl: 110) }
        let summary = CycleDailySummary.make(start: start, end: end, now: end, readings: readings, range: { _ in (80, 180) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0, calendar: calendar)
        XCTAssertEqual(summary.daySeconds, 23 * 3600)
        XCTAssertEqual(summary.coverage, 1)
        XCTAssertEqual(summary.day, "2026-03-08")
    }

    private func patternFixture() -> (Calendar, [Date], Date, CycleJournalState) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let starts = ["2026-01-01", "2026-01-29", "2026-02-26"].map { CycleDay.date($0, calendar: calendar)! }
        let now = CycleDay.date("2026-03-20", calendar: calendar)!
        var state = CycleJournalState()
        for start in starts.prefix(2) {
            for day in 1...28 {
                let date = calendar.date(byAdding: .day, value: day - 1, to: start)!
                let summary = CycleDailySummary(day: CycleDay.key(date, calendar: calendar), timeZone: "UTC", capturedAt: now, isPartialDay: false, coveredSeconds: 86400, daySeconds: 86400,
                    meanMGDL: (21...25).contains(day) ? 160 : 110, timeInRange: nil, insulinUnits: nil, insulinRecordCount: 0, carbGrams: nil, carbEntryCount: 0, glucose: [])
                state.summaries.append(summary)
            }
            let date = calendar.date(byAdding: .day, value: 22, to: start)!
            state.notes.append(CycleJournalNote(day: CycleDay.key(date, calendar: calendar), occurredAt: date, timeZone: "UTC", text: "Cravings", tags: [.cravings]))
        }
        return (calendar, starts, now, state)
    }

    func testPatternsCountDistinctCyclesAndLinkOriginalEvidence() throws {
        let (calendar, starts, now, state) = patternFixture()
        let insights = CyclePatternEngine.insights(starts: starts, estimatedLength: 28, journal: state, now: now, calendar: calendar)
        XCTAssertEqual(insights.count, 2)
        let glucose = insights.first { $0.basis == "recorded_glucose" }!
        XCTAssertEqual(glucose.evidence.count, 2)
        XCTAssertEqual(glucose.evidence[0].days.count, 5)
        XCTAssertEqual(glucose.noteIDs.count, 2)
        let notes = insights.first { $0.basis == "user_report" }!
        XCTAssertTrue(notes.text.contains("2 previous cycles"))
        XCTAssertEqual(notes.noteIDs.count, 2)
    }

    func testPatternsRejectPoorCoverageContradictionsAndUnconfirmedNewCycles() throws {
        let (calendar, starts, now, original) = patternFixture()
        var state = original
        for index in state.summaries.indices where state.summaries[index].day >= "2026-01-29" { state.summaries[index].coveredSeconds = 1000 }
        XCTAssertFalse(CyclePatternEngine.insights(starts: starts, estimatedLength: 28, journal: state, now: now, calendar: calendar).contains { $0.basis == "recorded_glucose" })
        state = original
        for index in state.summaries.indices where state.summaries[index].day >= "2026-02-18" { state.summaries[index].meanMGDL = 80 }
        XCTAssertFalse(CyclePatternEngine.insights(starts: starts, estimatedLength: 28, journal: state, now: now, calendar: calendar).contains { $0.basis == "recorded_glucose" })
        let overdue = calendar.date(byAdding: .day, value: 40, to: starts.last!)!
        XCTAssertTrue(CyclePatternEngine.insights(starts: starts, estimatedLength: 28, journal: original, now: overdue, calendar: calendar).isEmpty)
        XCTAssertTrue(CyclePatternEngine.insights(starts: [], estimatedLength: 28, journal: original, now: now, calendar: calendar).isEmpty)
    }

    func testDeletingEvidenceAndEditingPeriodDatesRecalculatesPatterns() throws {
        let (calendar, starts, now, original) = patternFixture()
        var state = original
        state.notes = []
        XCTAssertFalse(CyclePatternEngine.insights(starts: starts, estimatedLength: 28, journal: state, now: now, calendar: calendar).contains { $0.basis == "user_report" })
        let moved = starts.dropLast() + [calendar.date(byAdding: .day, value: 10, to: starts.last!)!]
        let recalculated = CyclePatternEngine.insights(starts: Array(moved), estimatedLength: 28, journal: original, now: now, calendar: calendar)
        XCTAssertFalse(recalculated.contains { $0.text.contains("averaged higher") })
        XCTAssertFalse(recalculated.contains { $0.noteIDs == original.notes.map(\.id) })
        let before = CyclePatternEngine.comparisons(starts: starts, summaries: original.summaries, notes: original.notes, alignment: .beforePeriod, now: now, calendar: calendar)
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before.first?.days.last?.offset, -1)
        XCTAssertFalse(before.contains { $0.isCurrent })
    }

    func testRetentionNeverReplacesGoodHistoryWithGaps() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let (_, _, _, state) = patternFixture()
        let good = state.summaries[0]
        try controller.cycleJournal.retain([good])
        var worse = good; worse.coveredSeconds = 0; worse.meanMGDL = nil
        try controller.cycleJournal.retain([worse])
        XCTAssertEqual(controller.cycleJournal.state.summaries.first?.meanMGDL, good.meanMGDL)
        try controller.cycleJournal.update { $0.retainDailySummaries = false }
        try controller.cycleJournal.retain([state.summaries[1]])
        XCTAssertEqual(controller.cycleJournal.state.summaries.count, 1)
    }

    func testPeriodHistoryAllowsFirstEntryButRejectsOverlapsAndFutureDates() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let first = calendar.date(byAdding: .day, value: -30, to: today)!
        let end = calendar.date(byAdding: .day, value: -26, to: today)!
        let valid = [CycleTrackingStore.PeriodEntry(startDate: first, endDate: end)]
        XCTAssertNil(CycleTrackingStore.historyValidationError(valid))
        XCTAssertTrue(CycleTrackingStore.historyValidationError(valid + [.init(startDate: first, endDate: end)]) != nil)
        XCTAssertTrue(CycleTrackingStore.historyValidationError(valid + [.init(startDate: calendar.date(byAdding: .day, value: -28, to: today)!, endDate: end)]) != nil)
        XCTAssertTrue(CycleTrackingStore.historyValidationError([.init(startDate: today.addingTimeInterval(86400))]) != nil)
        XCTAssertTrue(CycleTrackingStore.historyValidationError([.init(startDate: first), .init(startDate: today)]) != nil)
        let suite = "FirstHistory." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = CycleTrackingStore(defaults: defaults)
        XCTAssertTrue(tracker.periodEntries.isEmpty)
        tracker.replacePeriodEntries(with: valid)
        XCTAssertEqual(CycleTrackingStore(defaults: defaults).periodEntries.count, 1)
    }
    func testRevokedJournalAccessDoesNotResendJournalDerivedReplies() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let reply = try await controller.replyToCycleConversation([
            CompanionMessage(role: "assistant", text: "PRIVATE_JOURNAL_MARKER", includesHealthData: true, includesCycleJournal: true),
            CompanionMessage(role: "user", text: "Explain cycle phases generally")
        ])
        XCTAssertFalse(String(describing: provider.messages).contains("PRIVATE_JOURNAL_MARKER"))
        XCTAssertEqual(reply.includesCycleJournal, false)
    }

    func testSameWordsAtDifferentTimesCanBeSeparateNotes() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let date = Date().addingTimeInterval(-3600)
        try controller.cycleJournal.saveNote(date: date, text: "Felt low", tags: [.lows], source: "mochi")
        try controller.cycleJournal.saveNote(date: date.addingTimeInterval(1800), text: "Felt low", tags: [.lows], source: "mochi")
        XCTAssertEqual(controller.cycleJournal.state.notes.count, 2)
    }

    func testNightscoutRequestsAreAuthenticatedReadOnlyAndDateBounded() throws {
        let configuration = CycleNightscoutConfiguration(siteURL: URL(string: "https://example.invalid/diabetes")!, apiSecret: "password")
        let reader = CycleNightscoutHistory(configuration: configuration)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try reader.request(endpoint: "entries", start: start, end: start.addingTimeInterval(3600))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/diabetes/api/v1/entries.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-secret"), "5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8")
        XCTAssertFalse(request.url!.absoluteString.contains("password"))
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "find[date][$gte]" }?.value, "1700000000000")
        XCTAssertEqual(items.first { $0.name == "find[type]" }?.value, "sgv")
        XCTAssertThrowsError(try reader.request(endpoint: "profile", start: start, end: start.addingTimeInterval(1)))
    }

    func testNightscoutDecodingDeduplicatesAndExcludesMeterDeletedAndInvalidReadings() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let millis = date.timeIntervalSince1970 * 1000
        let records: [[String: Any]] = [
            ["type": "sgv", "date": millis, "sgv": 110],
            ["type": "sgv", "date": millis, "sgv": 110],
            ["type": "mbg", "date": millis + 300000, "sgv": 200],
            ["type": "sgv", "date": millis + 300000, "sgv": true],
            ["type": "sgv", "date": millis + 300000, "sgv": 0],
            ["type": "sgv", "date": millis + 300000, "sgv": 120, "isDeleted": true],
            ["type": "sgv", "date": millis + 600000, "sgv": "125"],
            ["type": "sgv", "date": millis + 3600000, "sgv": 130]
        ]
        let readings = CycleNightscoutHistory.glucose(records, start: date, end: date.addingTimeInterval(3600))
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings.map(\.mgdl), [110, 125])
    }

    func testNightscoutMealsAndBolusesDoNotCountDuplicatesOrBasalRatesAsUnits() throws {
        let date = Date().addingTimeInterval(-3600)
        let stamp = ISO8601DateFormatter().string(from: date)
        let records: [[String: Any]] = [
            ["_id": "a", "syncIdentifier": "meal", "created_at": stamp, "eventType": "Meal Bolus", "carbs": 30, "insulin": 2],
            ["_id": "b", "syncIdentifier": "meal", "created_at": stamp, "eventType": "Meal Bolus", "carbs": 30, "insulin": 2],
            ["_id": "c", "created_at": stamp, "eventType": "Temp Basal", "absolute": 1.5, "duration": 30, "insulin": 99],
            ["_id": "d", "created_at": stamp, "eventType": "Correction Bolus", "insulin": 5, "isDeleted": true],
            ["_id": "e", "created_at": stamp, "eventType": "Correction Bolus", "insulin": -2]
        ]
        let amounts = CycleNightscoutHistory.amounts(records, start: date.addingTimeInterval(-1), end: Date())
        XCTAssertEqual(amounts.boluses.count, 1)
        XCTAssertEqual(amounts.boluses.first?.amount, 2)
        XCTAssertEqual(amounts.carbs.count, 1)
        XCTAssertEqual(amounts.carbs.first?.amount, 30)
    }

    func testSaturatedNightscoutResponsesSplitBeforeFiltering() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var reader = CycleNightscoutHistory(configuration: .init(siteURL: URL(string: "https://example.invalid")!, apiSecret: "synthetic"))
        reader.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.path.contains("treatments") { return (Data("[]".utf8), response) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let lower = Double(items.first { $0.name == "find[date][$gte]" }!.value!)!
            let upper = Double(items.first { $0.name == "find[date][$lt]" }!.value!)!
            let rows: [[String: Any]] = upper - lower > 3_600_000
                ? Array(repeating: ["type": "mbg", "date": lower, "sgv": 100], count: CycleNightscoutHistory.pageSize)
                : [["type": "sgv", "date": lower + 60000, "sgv": 110]]
            return (try JSONSerialization.data(withJSONObject: rows), response)
        }
        let batch = try await reader.fetch(start: start, end: start.addingTimeInterval(7200))
        XCTAssertTrue(batch.complete)
        XCTAssertEqual(batch.glucose?.count, 2)
    }

    func testNightscoutTreatmentFailureDoesNotDiscardGlucose() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var reader = CycleNightscoutHistory(configuration: .init(siteURL: URL(string: "https://example.invalid")!, apiSecret: "synthetic"))
        reader.transport = { request in
            let status = request.url!.path.contains("treatments") ? 403 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            let records: [[String: Any]] = [["type": "sgv", "date": start.timeIntervalSince1970 * 1000, "sgv": 110]]
            return (try JSONSerialization.data(withJSONObject: records), response)
        }
        let batch = try await reader.fetch(start: start, end: start.addingTimeInterval(3600))
        XCTAssertEqual(batch.glucose?.count, 1)
        XCTAssertNil(batch.boluses)
        XCTAssertFalse(batch.complete)
    }

    func testNightscoutIgnoringRangeLimitsFailsWithoutPublishingTruncatedHistory() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var reader = CycleNightscoutHistory(configuration: .init(siteURL: URL(string: "https://example.invalid")!, apiSecret: "synthetic"))
        reader.transport = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let rows: [[String: Any]] = request.url!.path.contains("treatments") ? [] : Array(repeating: ["type": "sgv", "date": start.timeIntervalSince1970 * 1000, "sgv": 110], count: CycleNightscoutHistory.pageSize)
            return (try JSONSerialization.data(withJSONObject: rows), response)
        }
        let batch = try await reader.fetch(start: start, end: start.addingTimeInterval(3))
        XCTAssertNil(batch.glucose)
        XCTAssertFalse(batch.complete)
    }

    func testNightscoutMergesWithoutDoubleCountingAndPreservesFullLocalInsulin() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date().addingTimeInterval(-86400))
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let points = stride(from: 0.0, to: end.timeIntervalSince(start), by: 300).map { CycleGlucoseReading(date: start.addingTimeInterval($0), mgdl: 110) }
        let local = CycleDailySummary.make(start: start, end: end, now: Date(), readings: points, range: { _ in (80, 180) }, insulin: 20, insulinRecords: 12, carbs: 30, carbEntries: 1)
        try controller.cycleJournal.retain([local])
        let batch = CycleNightscoutBatch(glucose: points, boluses: [.init(date: start, amount: 2)], carbs: [.init(date: start, amount: 30)])
        let remote = batch.summaries(start: start, end: end, now: Date(), range: { _ in (80, 180) })
        XCTAssertEqual(remote.first?.insulinIsPartial, true)
        try controller.cycleJournal.retain(remote)
        let merged = controller.cycleJournal.summary(on: start)!
        XCTAssertEqual(merged.glucoseSource, "Nightscout")
        XCTAssertEqual(merged.insulinUnits, 20)
        XCTAssertFalse(merged.insulinIsPartial == true)
        XCTAssertEqual(merged.carbGrams, 30)
        XCTAssertEqual(merged.carbSource, "Nightscout")
        // A later local refresh cannot double counts or replace equally covered Nightscout glucose.
        try controller.cycleJournal.retain([local])
        XCTAssertEqual(controller.cycleJournal.summary(on: start)?.glucoseSource, "Nightscout")
        XCTAssertEqual(controller.cycleJournal.summary(on: start)?.carbGrams, 30)
    }

    func testNightscoutOlderDaysRetainBolusOnlyProvenance() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date().addingTimeInterval(-180 * 86400))
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let batch = CycleNightscoutBatch(glucose: [.init(date: start, mgdl: 110)], boluses: [.init(date: start, amount: 2)], carbs: [])
        try controller.cycleJournal.retain(batch.summaries(start: start, end: end, now: Date(), range: { _ in nil }))
        let saved = CycleJournalStore(url: controller.cycleJournal.url).summary(on: start)!
        XCTAssertEqual(saved.insulinUnits, 2)
        XCTAssertEqual(saved.insulinIsPartial, true)
        XCTAssertEqual(saved.insulinSource, "Nightscout")
        XCTAssertNil(saved.carbGrams)
    }
    func testTimeInRangeUsesDisplayBoundsAndUpdatesWithoutRefetching() throws {
        let suite = "CycleDisplayRange." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GlucoseGraphSettingsStore(defaults: defaults)
        let start = CycleDay.date("2026-01-01")!
        let end = start.addingTimeInterval(900)
        let readings = [90.0, 130, 170].enumerated().map { CycleGlucoseReading(date: start.addingTimeInterval(Double($0.offset) * 300), mgdl: $0.element) }
        // An older treatment-target calculation must not determine today's display metric.
        let summary = CycleDailySummary.make(start: start, end: end, now: end, readings: readings, range: { _ in (80, 110) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        XCTAssertEqual(summary.timeInRange, 1.0 / 3.0)
        XCTAssertEqual(summary.timeInRange(using: settings.settings), 2.0 / 3.0)
        XCTAssertEqual(summary.glucose.count, 1) // The graph alone cannot reconstruct the exact percentage.
        XCTAssertTrue(settings.updateBounds(lowerBoundMGDL: 100, upperBoundMGDL: 145))
        XCTAssertEqual(summary.timeInRange(using: settings.settings), 1.0 / 3.0)
        settings.setEnabled(false) // Hiding the graph shading does not change the configured range.
        XCTAssertEqual(summary.timeInRange(using: settings.settings), 1.0 / 3.0)
    }

    func testDisplayRangeIncludesBoundariesAndExactDurationsSurviveSaving() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let start = CycleDay.date("2026-01-01")!
        let end = start.addingTimeInterval(1200)
        let readings = [79.0, 80, 145, 146].enumerated().map { CycleGlucoseReading(date: start.addingTimeInterval(Double($0.offset) * 300), mgdl: $0.element) }
        let summary = CycleDailySummary.make(start: start, end: end, now: end, readings: readings, range: { _ in (80, 145) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        try controller.cycleJournal.retain([summary])
        let saved = CycleJournalStore(url: controller.cycleJournal.url).state.summaries[0]
        XCTAssertEqual(saved.timeInRange(using: .default), 0.5)
        XCTAssertEqual(saved.glucoseDurations?.map(\.seconds).reduce(0, +), 1200)
        XCTAssertFalse(saved.needsDisplayRangeRefresh)
    }

    func testLegacyTreatmentTargetIsUnknownUntilExactHistoryRefreshes() throws {
        let (controller, _, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let start = CycleDay.date("2026-01-01")!
        let end = start.addingTimeInterval(600)
        let readings = [CycleGlucoseReading(date: start, mgdl: 100), .init(date: start.addingTimeInterval(300), mgdl: 160)]
        let refreshed = CycleDailySummary.make(start: start, end: end, now: end, readings: readings, range: { _ in (80, 145) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        var legacy = refreshed
        legacy.glucoseDurations = nil
        legacy.timeInRange = 0.95
        legacy.glucoseSource = "Nightscout"
        try controller.cycleJournal.retain([legacy])
        let saved = CycleJournalStore(url: controller.cycleJournal.url).state.summaries[0]
        XCTAssertTrue(saved.needsDisplayRangeRefresh)
        XCTAssertNil(saved.timeInRange(using: .default))
        // Equally covered exact local records can replace a legacy remote snapshot.
        try controller.cycleJournal.retain([refreshed])
        XCTAssertEqual(controller.cycleJournal.state.summaries[0].timeInRange(using: .default), 0.5)
    }

    func testMochiReceivesTimeInRangeFromCurrentDisplaySettings() async throws {
        let (controller, provider, _, cleanup) = try fixture(sharing: true)
        defer { cleanup() }
        let bounds = GlucoseGraphSettingsStore.shared.settings
        let glucose = (bounds.lowerBoundMGDL + bounds.upperBoundMGDL) / 2
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let end = start.addingTimeInterval(300)
        let summary = CycleDailySummary.make(start: start, end: end, now: end, readings: [.init(date: start, mgdl: glucose)], range: { _ in (glucose + 1, glucose + 2) }, insulin: nil, insulinRecords: 0, carbs: nil, carbEntries: 0)
        XCTAssertEqual(summary.timeInRange, 0)
        try controller.cycleJournal.update { $0.allowMochiRead = true }
        try controller.cycleJournal.retain([summary])
        let args = try JSONSerialization.data(withJSONObject: ["start": ISO8601DateFormatter().string(from: start), "end": ISO8601DateFormatter().string(from: end)])
        var didRead = false
        provider.handler = { messages, _ in
            if !didRead {
                didRead = true
                return CompanionCompletion(message: ["role": "assistant", "tool_calls": [["id": "range", "type": "function", "function": ["name": "get_cycle_journal", "arguments": String(decoding: args, as: UTF8.self)]]]], text: "", calls: [.init(id: "range", name: "get_cycle_journal", arguments: args)])
            }
            let data = Data((messages.last?["content"] as! String).utf8)
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let records = payload["dailySummaries"] as! [[String: Any]]
            XCTAssertEqual(records[0]["timeInRange"] as? Double, 1)
            XCTAssertNil(records[0]["glucoseDurations"])
            XCTAssertEqual((payload["displayRangeMGDL"] as? [String: Double])?["lower"], bounds.lowerBoundMGDL)
            return CompanionCompletion(message: [:], text: "Used your display range.", calls: [])
        }
        _ = try await controller.replyToCycleConversation([CompanionMessage(role: "user", text: "Read my cycle glucose records")])
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
        XCTAssertTrue(try store.load().dashboardMessage?.text.hasSuffix("a fresh diabetes question for visit 1?") == true)
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

    func testPersonalMessagesPersistAcrossRelaunchWithoutDiscoveries() async throws {
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
            XCTAssertEqual(controller.state.dashboardMessage?.kind, .motivation)
            XCTAssertNil(controller.dashboardFact)
            XCTAssertEqual(provider.discoveryCount, 0)
            controller.setDashboardVisible(false)
        }
    }

    func testDashboardDismissalBlocksRequestsAndPersistsAcrossRelaunch() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        let controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        let closedAt = Date()
        await controller.dismissDashboard(now: closedAt)
        controller.setDashboardVisible(true)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertTrue(try store.load().isDashboardDismissed(at: closedAt.addingTimeInterval(3599)))
        let reloaded = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        reloaded.setDashboardVisible(true)
        XCTAssertEqual(provider.requestCount, 0)
        reloaded.requestDashboardRefresh(now: closedAt.addingTimeInterval(3600))
        try await waitForDashboard(reloaded)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertNil(reloaded.dashboardRefreshError)
        reloaded.setDashboardVisible(false)
        controller.setDashboardVisible(false)
    }

    func testDashboardNeverFetchesPublicDiscoveriesEvenWithLegacyPreferences() async throws {
        let (store, tracker, cleanup) = try fixture(shareHealth: false)
        defer { cleanup() }
        let provider = CycleProviderProbe()
        var controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 0)
        XCTAssertNil(controller.dashboardFact)
        XCTAssertFalse(controller.state.allowHealthData)
        XCTAssertTrue(provider.tools.isEmpty)
        controller.setDashboardVisible(false)
        var saved = try store.load()
        saved.dashboardMessage?.generatedAt = Date().addingTimeInterval(-901)
        try store.save(saved)
        controller = CompanionController(provider: provider, stateStore: store, cycleStore: tracker, keyReader: { "test-only" }, applicationIsActive: { true })
        controller.setDashboardVisible(true)
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 0)
        try await controller.saveSettings(model: controller.state.model, reasoningEffort: .medium, personality: "Be warm", allowHealthData: false, key: "", enableT1DUpdates: false)
        try await waitForDashboard(controller)
        XCTAssertNil(try store.load().dashboardDiscoveries)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        XCTAssertEqual(provider.discoveryCount, 0)
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
        XCTAssertEqual(provider.discoveryCount, 0)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        XCTAssertNotEqual(controller.state.dashboardMessage?.kind, .fact)
        XCTAssertNil(controller.dashboardRefreshError)
        controller.requestDashboardRefresh(now: Date().addingTimeInterval(901))
        try await waitForDashboard(controller)
        XCTAssertEqual(provider.discoveryCount, 0)
        XCTAssertNil(controller.state.dashboardMessage?.sourceFact)
        controller.setDashboardVisible(false)
    }

    func testEditableNamePersistsAndIsUsedInEveryDashboardMessage() async throws {
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
            XCTAssertEqual(controller.state.dashboardMessage?.text.contains("Michelle"), true)
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
