import XCTest
@testable import Loop

private final class CycleNoteServer {
    var rows: [String: [String: Any]] = [:]
    var requests: [URLRequest] = []
    var failRead = false
    var loseNextWriteResponse = false
    var ignoreNextWrite = false
    var permissionDenied = false
    var ignoreDiscoveryFilter = false
    var omitDiscovery = false
    var onRequest: ((URLRequest) -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onRequest?(request)
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let method = request.httpMethod ?? "GET"
        if permissionDenied { return response(request, status: 403, body: ["error": "synthetic secret must not leak"]) }
        if method == "GET" {
            if failRead { throw URLError(.notConnectedToInternet) }
            let result: [[String: Any]]
            if let id = query["find[_id]"] {
                result = rows[id].map { [$0] } ?? []
            } else if omitDiscovery { result = [] }
            else {
                let cursor = query["find[_id][$gt]"] ?? ""
                result = rows.keys.sorted().filter { id in
                    id > cursor && (ignoreDiscoveryFilter || ((rows[id]?["eventType"] as? String == "Note") && (rows[id]?["notes"] as? String ?? "").hasPrefix("[Cycle]")))
                }.prefix(Int(query["count"] ?? "1000")!).compactMap { rows[$0] }
            }
            return response(request, body: result)
        }
        if method == "POST" || method == "PUT" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if ignoreNextWrite { ignoreNextWrite = false }
            else { rows[body["_id"] as! String] = body }
            if loseNextWriteResponse { loseNextWriteResponse = false; throw URLError(.networkConnectionLost) }
            return response(request, body: [body])
        }
        if method == "DELETE" {
            rows.removeValue(forKey: request.url!.lastPathComponent)
            return response(request, body: ["deletedCount": 1])
        }
        return response(request, status: 400, body: [:])
    }
    private func response(_ request: URLRequest, status: Int = 200, body: Any) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func add(id: String = "100000000000000000000001", text: String = "[Cycle] From Nightscout") {
        rows[id] = ["_id": id, "eventType": "Note", "notes": text, "created_at": "2026-01-15T12:00:00.000Z"]
    }
    var writes: Int { requests.filter { ["POST", "PUT", "DELETE"].contains($0.httpMethod ?? "") }.count }
}

@MainActor
final class CycleNightscoutNoteSyncTests: XCTestCase {
    private func periodTracker(zone: String = "UTC") -> (CycleTrackingStore, () -> Void) {
        let suite = "CyclePeriodSyncTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return (CycleTrackingStore(defaults: defaults, calendar: calendar), { defaults.removePersistentDomain(forName: suite) })
    }

    private func periodDate(_ day: String) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return CycleDay.date(day, calendar: calendar)!
    }

    func testPeriodDatesUploadWithoutAnyJournalNotesAndRestoreAnEmptyPhone() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [
            .init(startDate: periodDate("2025-12-18"), endDate: periodDate("2025-12-22")),
            .init(startDate: periodDate("2026-01-15"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        XCTAssertEqual(server.rows.count, 2)
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertTrue(server.rows.values.allSatisfy { ($0["notes"] as! String).contains("Cycle record: period") })
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (empty, clearEmpty) = periodTracker(); defer { clearEmpty() }
        let restore = CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: empty)
        try await restore.run()
        XCTAssertEqual(empty.periodHistorySyncNotes().map(\.period), tracker.periodHistorySyncNotes().map(\.period))
        XCTAssertEqual(empty.cycleLength, tracker.cycleLength)
        XCTAssertEqual(empty.cycleDay(on: periodDate("2026-01-20")), 6)
        XCTAssertTrue(empty.isPeriodInProgress)
        XCTAssertTrue(second.state.notes.isEmpty)
        XCTAssertEqual(server.writes, 2)
        try await restore.run()
        XCTAssertEqual(server.rows.count, 2)
        XCTAssertEqual(server.writes, 2)
    }

    func testExistingMatchingPeriodsOnAnotherPhoneLinkWithoutDuplicates() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (other, clearOther) = periodTracker(zone: "America/Los_Angeles"); defer { clearOther() }
        other.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        try await CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: other).run()
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(server.writes, 1)
        XCTAssertEqual(other.periodEntries.count, 1)
        XCTAssertEqual(other.periodHistorySyncNotes().first?.period?.startDay, "2026-01-15")
    }

    func testConcurrentFirstPeriodUploadUsesTheSameIDDespiteDiscoveryOmission() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (other, clearOther) = periodTracker(zone: "America/Los_Angeles"); defer { clearOther() }
        other.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        server.omitDiscovery = true
        try await CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: other).run()
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(server.writes, 1)
        XCTAssertTrue(second.state.notes.isEmpty)
        XCTAssertEqual(second.state.noteSync?.conflictCopies, 0)
        XCTAssertEqual(other.periodEntries.count, 1)
    }

    func testPreviouslyUnsharedPeriodsWithDifferentEndDatesKeepBothVersions() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (other, clearOther) = periodTracker(); defer { clearOther() }
        other.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-20"))])
        try await CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: other).run()
        XCTAssertEqual(other.periodHistorySyncNotes().first?.period?.endDay, "2026-01-19")
        XCTAssertEqual(second.state.notes.count, 1)
        XCTAssertTrue(second.state.notes[0].text.contains("2026-01-20"))
        XCTAssertEqual(server.rows.count, 1)
    }

    func testPeriodStartEndCorrectionsAndDeletionsSyncBothWays() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.startPeriod(on: periodDate("2026-01-15"))
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let id = server.rows.keys.first!
        tracker.endCurrentPeriod(on: periodDate("2026-01-19"))
        try await sync.run()
        XCTAssertTrue((server.rows[id]!["notes"] as! String).contains("Period end: 2026-01-19"))
        server.rows[id]!["notes"] = (server.rows[id]!["notes"] as! String).replacingOccurrences(of: "Period end: 2026-01-19", with: "Period end: 2026-01-20")
        try await sync.run()
        XCTAssertEqual(tracker.periodHistorySyncNotes().first?.period?.endDay, "2026-01-20")
        var entry = tracker.periodEntries[0]; entry.startDate = periodDate("2026-01-14")
        tracker.replacePeriodEntries(with: [entry])
        try await sync.run()
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content.period?.startDay, "2026-01-14")
        tracker.replacePeriodEntries(with: [])
        try await sync.run()
        XCTAssertTrue(server.rows.isEmpty)
        tracker.startPeriod(on: periodDate("2026-01-15"))
        try await sync.run()
        server.rows.removeAll()
        try await sync.run()
        XCTAssertTrue(tracker.periodEntries.isEmpty)
        XCTAssertTrue(journal.state.periodSyncNotes?.isEmpty == true)
    }

    func testLocalAndRemotePeriodHistoryMergeWhenEachHasMissingRecords() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2025-12-18"), endDate: periodDate("2025-12-22"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (other, clearOther) = periodTracker(); defer { clearOther() }
        other.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        try await CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: other).run()
        XCTAssertEqual(other.periodEntries.count, 2)
        XCTAssertEqual(server.rows.count, 2)
        try await sync.run()
        XCTAssertEqual(tracker.periodEntries.count, 2)
    }

    func testPeriodUploadRetriesAfterOfflineAndLostResponseWithReloadedJournal() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.startPeriod(on: periodDate("2026-01-15"))
        var sync = base; sync.periodTracker = tracker
        server.failRead = true
        do { try await sync.run(); XCTFail("Expected offline failure") } catch { }
        XCTAssertEqual(tracker.periodEntries.count, 1)
        XCTAssertEqual(journal.state.periodSyncNotes?.count, 1)
        server.failRead = false; server.loseNextWriteResponse = true
        do { try await sync.run(); XCTFail("Expected lost response") } catch { }
        XCTAssertEqual(server.rows.count, 1)
        let reloaded = CycleJournalStore(url: journal.url)
        try await CycleNightscoutNoteSync(journal: reloaded, client: sync.client, isCurrent: { true }, periodTracker: tracker).run()
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(server.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(tracker.periodEntries.count, 1)
    }

    func testPeriodEditDuringUploadRemainsQueuedAndDoesNotRevertTheTracker() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.startPeriod(on: periodDate("2026-01-15"))
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        tracker.endCurrentPeriod(on: periodDate("2026-01-19"))
        var changed = false
        server.onRequest = { request in
            if request.httpMethod == "PUT", !changed {
                changed = true
                var entry = tracker.periodEntries[0]; entry.endDate = self.periodDate("2026-01-20")
                tracker.replacePeriodEntries(with: [entry])
            }
        }
        try await sync.run()
        XCTAssertEqual(tracker.periodHistorySyncNotes().first?.period?.endDay, "2026-01-20")
        server.onRequest = nil
        try await sync.run()
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows.values.first!).content.period?.endDay, "2026-01-20")
    }

    func testPeriodConflictKeepsRemoteDatesAndAVisibleLocalReviewNote() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.startPeriod(on: periodDate("2026-01-15"))
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        tracker.endCurrentPeriod(on: periodDate("2026-01-19"))
        let id = server.rows.keys.first!
        server.rows[id]!["notes"] = (server.rows[id]!["notes"] as! String).replacingOccurrences(of: "Period end: ongoing", with: "Period end: 2026-01-20")
        try await sync.run()
        XCTAssertEqual(tracker.periodHistorySyncNotes().first?.period?.endDay, "2026-01-20")
        XCTAssertEqual(journal.state.notes.count, 1)
        XCTAssertTrue(journal.state.notes[0].text.contains("2026-01-19"))
        XCTAssertNil(journal.state.notes[0].period)
        XCTAssertEqual(journal.state.noteSync?.conflictCopies, 1)
        try await sync.run()
        XCTAssertEqual(server.rows.count, 2)
    }

    func testMalformedAndOverlappingPeriodNotesPreserveTheExistingTracker() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-15"), endDate: periodDate("2026-01-19"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let original = tracker.periodEntries
        let id = server.rows.keys.first!, body = server.rows[id]!["notes"] as! String
        for invalid in ["2026-02-30", "2026-01-14", "2099-01-20"] {
            server.rows[id]!["notes"] = body.replacingOccurrences(of: "Period end: 2026-01-19", with: "Period end: " + invalid)
            do { try await sync.run(); XCTFail("Expected invalid dates") } catch { }
            XCTAssertEqual(tracker.periodEntries, original)
        }
        server.rows[id]!["notes"] = body
        var overlapping = server.rows[id]!
        overlapping["_id"] = "100000000000000000000099"
        overlapping["notes"] = body.replacingOccurrences(of: "Period start: 2026-01-15", with: "Period start: 2026-01-18")
        server.rows["100000000000000000000099"] = overlapping
        do { try await sync.run(); XCTFail("Expected overlapping dates") } catch { }
        XCTAssertEqual(tracker.periodEntries, original)
    }

    func testRemovingPeriodFooterCannotSilentlyDeleteTrackerHistory() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(); defer { clear() }
        tracker.startPeriod(on: periodDate("2026-01-15"))
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let id = server.rows.keys.first!
        server.rows[id]!["notes"] = "[Cycle] Period history"
        do { try await sync.run(); XCTFail("Expected missing footer") } catch { }
        XCTAssertEqual(tracker.periodEntries.count, 1)
    }

    func testRestoredDatesKeepTheirCivilDayAcrossTimeZonesAndRepairNoteContext() async throws {
        let (journal, server, base) = try fixture(); defer { cleanup(journal) }
        let (tracker, clear) = periodTracker(zone: "Pacific/Kiritimati"); defer { clear() }
        tracker.replacePeriodEntries(with: [.init(startDate: periodDate("2026-01-14"), endDate: periodDate("2026-01-18"))])
        var sync = base; sync.periodTracker = tracker
        try await sync.run()
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let (other, clearOther) = periodTracker(zone: "America/Los_Angeles"); defer { clearOther() }
        server.add(text: "[Cycle] Restored context")
        try await CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true }, periodTracker: other).run()
        XCTAssertEqual(other.periodHistorySyncNotes().first?.period, tracker.periodHistorySyncNotes().first?.period)
        XCTAssertEqual(other.periodHistorySyncNotes().first?.period?.startDay, "2026-01-15")
        XCTAssertEqual(second.state.notes.first?.cycleContext?.cycleDay, 1)
    }

    func testTagOnlyNotePersistsWithoutInventedText() throws {
        let (journal, _, _) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: " \n ", tags: [.cramps, .cramps],
            cycleContext: .init(cycleDay: 2, phase: .period, phaseDay: 2))
        XCTAssertEqual(note.text, "")
        XCTAssertEqual(note.tags, [.cramps])
        XCTAssertEqual(note.displayText, CycleNoteTag.cramps.title)
        let reloaded = CycleJournalStore(url: journal.url)
        XCTAssertEqual(reloaded.state.notes, [note])
        XCTAssertThrowsError(try journal.saveNote(id: note.id, date: date, text: "", tags: []))
        XCTAssertEqual(journal.state.notes, [note])
        XCTAssertThrowsError(try journal.saveNote(date: Date().addingTimeInterval(86400), text: "", tags: [.sleep]))
    }

    func testOriginalQuickPickTagsPersistAndSyncWithCycleContext() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let context = CycleNoteContext(cycleDay: 2, phase: .period, phaseDay: 2)
        let note = try journal.saveNote(date: date, text: "", tags: [.resistant, .cramps], cycleContext: context)
        try await sync.run()
        let id = remoteID(journal, note.id)
        let decoded = try CycleNightscoutNoteClient.decode(server.rows[id]!)
        XCTAssertEqual(Set(decoded.content.tags), Set([.resistant, .cramps]))
        XCTAssertEqual(decoded.content.cycleContext, context)
        XCTAssertEqual(decoded.content.text, "")
        XCTAssertTrue(note.displayText.contains("Felt more insulin resistant"))
        let reloaded = CycleJournalStore(url: journal.url)
        XCTAssertEqual(reloaded.state.notes.first?.tags, note.tags)
    }

    func testTagOnlyNoteSyncsAndEditsInBothDirections() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "", tags: [.cramps])
        try await sync.run()
        let id = remoteID(journal, note.id)
        let uploaded = try CycleNightscoutNoteClient.decode(server.rows[id]!)
        XCTAssertEqual(uploaded.content.text, "")
        XCTAssertEqual(uploaded.content.tags, [.cramps])
        server.rows[id]!["notes"] = (server.rows[id]!["notes"] as! String)
            .replacingOccurrences(of: "Cycle tags: cramps", with: "Cycle tags: sleep, stress") + "\n"
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.text, "")
        XCTAssertEqual(journal.state.notes.first?.tags, [.sleep, .stress])
        _ = try journal.saveNote(id: note.id, date: date, text: "Slept poorly", tags: [.sleep])
        try await sync.run()
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content.text, "Slept poorly")
        _ = try journal.saveNote(id: note.id, date: date, text: "", tags: [.sleep])
        try await sync.run()
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content.text, "")
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(journal.state.notes.count, 1)
    }

    func testEmptyNightscoutNotesNeedAtLeastOneTag() throws {
        let (journal, server, _) = try fixture(); defer { cleanup(journal) }
        server.add(text: "[Cycle]   ")
        var raw = server.rows.values.first!
        XCTAssertThrowsError(try CycleNightscoutNoteClient.decode(raw))
        raw["notes"] = "[Cycle]\n\nCycle tags: \nCycle time zone: UTC"
        XCTAssertThrowsError(try CycleNightscoutNoteClient.decode(raw))
        raw["notes"] = "[Cycle]\n\nCycle tags: sleep\nCycle time zone: UTC\n"
        let decoded = try CycleNightscoutNoteClient.decode(raw)
        XCTAssertEqual(decoded.content.text, "")
        XCTAssertEqual(decoded.content.tags, [.sleep])
    }

    private let configuration = CycleNightscoutConfiguration(siteURL: URL(string: "https://example.invalid/nightscout?token=synthetic-token")!, apiSecret: "synthetic-secret")
    private var date: Date { Date(timeIntervalSince1970: 1_768_478_400) }

    private func fixture() throws -> (CycleJournalStore, CycleNoteServer, CycleNightscoutNoteSync) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = CycleJournalStore(url: folder.appendingPathComponent("journal.json"))
        try journal.update { $0.noteSync = .init(enabledSourceID: configuration.sourceID) }
        let server = CycleNoteServer()
        let client = CycleNightscoutNoteClient(configuration: configuration, transport: server.send)
        let sync = CycleNightscoutNoteSync(journal: journal, client: client, isCurrent: { true })
        return (journal, server, sync)
    }
    private func cleanup(_ journal: CycleJournalStore) { try? FileManager.default.removeItem(at: journal.url.deletingLastPathComponent()) }
    private func remoteID(_ journal: CycleJournalStore, _ id: UUID) -> String {
        journal.state.noteSync!.sites[configuration.sourceID]!.links.first { $0.localID == id }!.remoteID
    }

    func testRoundTripEditsTagsAndDeletesBothWays() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Cramps after lunch", tags: [.cramps, .sleep],
            cycleContext: .init(cycleDay: 20, phase: .luteal, phaseDay: 5))
        try await sync.run()
        XCTAssertEqual(server.rows.count, 1)
        let id = remoteID(journal, note.id)
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content, CycleNoteSyncContent(note))
        _ = try journal.saveNote(id: note.id, date: date, text: "Better after resting", tags: [.sleep])
        try await sync.run()
        XCTAssertTrue((server.rows[id]!["notes"] as! String).contains("Better after resting"))
        server.rows[id]!["notes"] = "[Cycle] Edited in Nightscout"
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.text, "Edited in Nightscout")
        server.rows.removeValue(forKey: id)
        try await sync.run()
        XCTAssertTrue(journal.state.notes.isEmpty)
        server.add()
        try await sync.run()
        XCTAssertEqual(journal.state.notes.count, 1)
        try journal.deleteNote(journal.state.notes[0].id)
        try await sync.run()
        XCTAssertTrue(server.rows.isEmpty)
        XCTAssertTrue(journal.state.noteSync!.sites[configuration.sourceID]!.links.isEmpty)
    }

    func testLostCreateResponseSurvivesRelaunchWithoutDuplicates() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Retry me", tags: [])
        server.loseNextWriteResponse = true
        do { try await sync.run(); XCTFail("Expected network failure") } catch { }
        XCTAssertEqual(server.rows.count, 1)
        let reloaded = CycleJournalStore(url: journal.url)
        let retry = CycleNightscoutNoteSync(journal: reloaded, client: sync.client, isCurrent: { true })
        try await retry.run()
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(reloaded.state.notes.count, 1)
        XCTAssertEqual(server.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testConcurrentEditsKeepBothVersions() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Original", tags: [])
        try await sync.run()
        let id = remoteID(journal, note.id)
        _ = try journal.saveNote(id: note.id, date: date, text: "Local edit", tags: [.stress])
        server.rows[id]!["notes"] = "[Cycle] Remote edit"
        try await sync.run()
        XCTAssertEqual(Set(journal.state.notes.map(\.text)), Set(["Local edit", "Remote edit"]))
        XCTAssertEqual(journal.state.noteSync?.conflictCopies, 1)
        try await sync.run()
        XCTAssertEqual(server.rows.count, 2)
        XCTAssertEqual(journal.state.notes.count, 2)
    }

    func testDeletionVersusEditPreservesEditedVersion() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Original", tags: [])
        try await sync.run()
        let id = remoteID(journal, note.id)
        try journal.deleteNote(note.id)
        server.rows[id]!["notes"] = "[Cycle] Keep remote edit"
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.text, "Keep remote edit")
        _ = try journal.saveNote(id: note.id, date: date, text: "Keep local edit", tags: [])
        server.rows.removeValue(forKey: id)
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.text, "Keep local edit")
        XCTAssertFalse(journal.state.notes.contains { $0.id == note.id })
        try await sync.run()
        XCTAssertEqual(server.rows.count, 1)
    }

    func testFailedReadsAndListOmissionsNeverDeleteNotes() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Keep me", tags: [])
        try await sync.run()
        server.omitDiscovery = true
        try await sync.run()
        XCTAssertEqual(journal.state.notes.count, 1)
        server.failRead = true
        let writes = server.writes
        do { try await sync.run(); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(journal.state.notes.count, 1)
        XCTAssertEqual(server.writes, writes)
    }

    func testDisabledOrChangedConnectionMakesNoRequests() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Private", tags: [])
        try journal.update { $0.noteSync?.enabledSourceID = nil }
        do { try await sync.run(); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(server.requests.isEmpty)
        try journal.update { $0.noteSync?.enabledSourceID = configuration.sourceID }
        let paused = CycleNightscoutNoteSync(journal: journal, client: sync.client, isCurrent: { false })
        do { try await paused.run(); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testConsentRevokedDuringReadPreventsWritesAndImports() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        server.add()
        server.onRequest = { _ in try! journal.update { $0.noteSync?.enabledSourceID = nil } }
        do { try await sync.run(); XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertEqual(server.writes, 0)
    }

    func testPermissionErrorDoesNotLeakCredentials() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Keep me", tags: [])
        server.permissionDenied = true
        do { try await sync.run(); XCTFail("Expected failure") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("denied"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic"))
        }
        XCTAssertEqual(server.writes, 0)
        XCTAssertEqual(journal.state.notes.count, 1)
    }

    func testSuccessfulStatusWithoutPersistedWriteIsNotAcknowledged() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Must persist", tags: [])
        server.ignoreNextWrite = true
        do { try await sync.run(); XCTFail("Expected verification failure") } catch { }
        XCTAssertFalse(journal.state.noteSync!.sites[configuration.sourceID]!.links[0].acknowledged)
        try await sync.run()
        XCTAssertEqual(server.rows.count, 1)
        XCTAssertEqual(journal.state.notes.count, 1)
    }

    func testOrdinaryTreatmentsAreNeverImportedOrModified() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        server.add(text: "Ordinary note")
        server.rows["200000000000000000000001"] = ["_id": "200000000000000000000001", "eventType": "Correction Bolus", "insulin": 1]
        try await sync.run()
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertEqual(server.writes, 0)
        server.ignoreDiscoveryFilter = true
        do { try await sync.run(); XCTFail("Expected validation failure") } catch { }
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertEqual(server.writes, 0)
    }

    func testDiscoveryPaginatesAndFindsOldNotes() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        for index in 1...1001 {
            server.add(id: String(format: "%024x", index))
        }
        let records = try await sync.client.discover()
        XCTAssertEqual(records.count, 1001)
        XCTAssertEqual(server.requests.count, 2)
        let queries = server.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertTrue(queries[0].contains { $0.name == "find[_id][$gt]" })
        XCTAssertTrue(queries[1].contains { $0.name == "find[_id][$gt]" && $0.value == String(format: "%024x", 1000) })
        XCTAssertTrue(server.requests.allSatisfy { $0.url!.path == "/nightscout/api/v1/treatments" })
        XCTAssertTrue(queries[0].contains { $0.name == "token" && $0.value == "synthetic-token" })
        XCTAssertEqual(server.requests[0].value(forHTTPHeaderField: "api-secret")?.count, 40)
    }

    func testLocalEditDuringUploadIsNotLost() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "First", tags: [])
        server.onRequest = { request in
            if request.httpMethod == "POST" { _ = try! journal.saveNote(id: note.id, date: self.date, text: "Edited while uploading", tags: []) }
        }
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.text, "Edited while uploading")
        server.onRequest = nil
        try await sync.run()
        let id = remoteID(journal, note.id)
        XCTAssertTrue((server.rows[id]!["notes"] as! String).contains("Edited while uploading"))
    }

    func testLegacyJournalLoadsWithSyncOff() throws {
        let (journal, _, _) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Private old note", tags: [])
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.url)) as! [String: Any]
        json.removeValue(forKey: "noteSync")
        try JSONSerialization.data(withJSONObject: json).write(to: journal.url)
        let loaded = CycleJournalStore(url: journal.url)
        XCTAssertNil(loaded.failure)
        XCTAssertNil(loaded.state.noteSync)
        XCTAssertEqual(loaded.state.notes.count, 1)
    }

    func testTwoDevicesShareEditsAndDeletionsWithoutDuplicates() async throws {
        let (first, server, sync) = try fixture(); defer { cleanup(first) }
        let (second, _, _) = try fixture(); defer { cleanup(second) }
        let secondSync = CycleNightscoutNoteSync(journal: second, client: sync.client, isCurrent: { true })
        let note = try first.saveNote(date: date, text: "Shared note", tags: [.cramps])
        try await sync.run()
        try await secondSync.run()
        XCTAssertEqual(second.state.notes.count, 1)
        let imported = second.state.notes[0]
        _ = try second.saveNote(id: imported.id, date: date, text: "Changed on second device", tags: [.sleep])
        try await secondSync.run()
        try await sync.run()
        XCTAssertEqual(first.state.notes.first?.id, note.id)
        XCTAssertEqual(first.state.notes.first?.text, "Changed on second device")
        XCTAssertEqual(first.state.notes.first?.tags, [.sleep])
        XCTAssertEqual(server.rows.count, 1)
        try first.deleteNote(note.id)
        try await sync.run()
        try await secondSync.run()
        XCTAssertTrue(second.state.notes.isEmpty)
        XCTAssertTrue(server.rows.isEmpty)
    }

    func testLostUpdateAndDeleteResponsesCanBeRetried() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Before", tags: [])
        try await sync.run()
        _ = try journal.saveNote(id: note.id, date: date, text: "After", tags: [])
        server.loseNextWriteResponse = true
        do { try await sync.run(); XCTFail("Expected lost response") } catch { }
        try await sync.run()
        XCTAssertEqual(journal.state.notes.count, 1)
        XCTAssertEqual(journal.state.notes.first?.text, "After")
        XCTAssertEqual(server.rows.count, 1)
        // A server deletion that succeeded before the client could acknowledge it.
        try journal.deleteNote(note.id)
        server.rows.removeAll()
        try await sync.run()
        XCTAssertTrue(journal.state.noteSync!.sites[configuration.sourceID]!.links.isEmpty)
    }

    func testUnchangedSyncUsesOneDiscoveryRequest() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "No change", tags: [])
        try await sync.run()
        server.requests = []
        try await sync.run()
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.writes, 0)
    }

    func testRemovingMarkerOrAddingDosingDataDoesNotDeleteLocalNote() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Keep me", tags: [])
        try await sync.run()
        let id = remoteID(journal, note.id)
        server.rows[id]!["notes"] = "Marker removed"
        let writes = server.writes
        do { try await sync.run(); XCTFail("Expected invalid note") } catch { }
        XCTAssertEqual(journal.state.notes.first?.text, "Keep me")
        server.rows[id]!["notes"] = "[Cycle] Has insulin"
        server.rows[id]!["insulin"] = 1
        do { try await sync.run(); XCTFail("Expected invalid note") } catch { }
        XCTAssertEqual(journal.state.notes.first?.text, "Keep me")
        XCTAssertEqual(server.writes, writes)
    }

    func testInvalidDatesAndFootersAreRejected() throws {
        let (journal, server, _) = try fixture(); defer { cleanup(journal) }
        server.add()
        var raw = server.rows.values.first!
        raw["created_at"] = "2099-01-01T12:00:00Z"
        XCTAssertThrowsError(try CycleNightscoutNoteClient.decode(raw))
        raw["created_at"] = "2026-01-15T12:00:00Z"
        raw["notes"] = "[Cycle] Note\n\nCycle tags: invented\nCycle time zone: UTC"
        XCTAssertThrowsError(try CycleNightscoutNoteClient.decode(raw))
        raw["notes"] = "[Cycle] Note\n\nCycle tags: sleep\nCycle time zone: invalid/zone"
        XCTAssertThrowsError(try CycleNightscoutNoteClient.decode(raw))
    }

    func testCycleAndPhaseDaysAreEditableInBothDirections() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let original = CycleNoteContext(cycleDay: 20, phase: .luteal, phaseDay: 5)
        let note = try journal.saveNote(date: date, text: "My observation", tags: [], cycleContext: original)
        try await sync.run()
        let id = remoteID(journal, note.id)
        var body = server.rows[id]!["notes"] as! String
        XCTAssertTrue(body.contains("Cycle day: 20\nCycle phase: luteal\nPhase day: 5\nCycle timing: estimated"))
        body = body.replacingOccurrences(of: "Cycle day: 20", with: "Cycle day: 21")
            .replacingOccurrences(of: "Cycle phase: luteal", with: "Cycle phase: follicular")
            .replacingOccurrences(of: "Phase day: 5", with: "Phase day: 3")
            .replacingOccurrences(of: "Cycle timing: estimated", with: "Cycle timing: reported")
        server.rows[id]!["notes"] = body
        try await sync.run()
        XCTAssertEqual(journal.state.notes.first?.cycleContext, .init(cycleDay: 21, phase: .follicular, phaseDay: 3, isEstimated: false))
        let updated = CycleNoteContext(cycleDay: 22, phase: .ovulation, phaseDay: 2)
        _ = try journal.saveNote(id: note.id, date: date, text: "My observation", tags: [], cycleContext: updated)
        try await sync.run()
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content.cycleContext, updated)
        XCTAssertEqual(journal.state.notes.count, 1)
    }

    func testContextOnlyConflictKeepsBothVersions() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Same words", tags: [], cycleContext: .init(cycleDay: 20, phase: .luteal, phaseDay: 5))
        try await sync.run()
        let id = remoteID(journal, note.id)
        _ = try journal.saveNote(id: note.id, date: date, text: note.text, tags: [], cycleContext: .init(cycleDay: 21, phase: .luteal, phaseDay: 6))
        server.rows[id]!["notes"] = (server.rows[id]!["notes"] as! String).replacingOccurrences(of: "Phase day: 5", with: "Phase day: 4")
        try await sync.run()
        XCTAssertEqual(journal.state.notes.count, 2)
        XCTAssertEqual(Set(journal.state.notes.compactMap { $0.cycleContext?.phaseDay }), Set([4, 6]))
    }

    func testLegacyNotesGetContextOnlyWhenFirstShared() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        _ = try journal.saveNote(date: date, text: "Legacy note", tags: [])
        XCTAssertNil(journal.state.notes[0].cycleContext)
        let context = CycleNoteContext(cycleDay: 10, phase: .follicular, phaseDay: 5)
        let enriching = CycleNightscoutNoteSync(journal: journal, client: sync.client, isCurrent: { true }, contextForNote: { _ in context })
        try await enriching.run()
        XCTAssertEqual(journal.state.notes[0].cycleContext, context)
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows.values.first!).content.cycleContext, context)
        let changedTracker = CycleNightscoutNoteSync(journal: journal, client: sync.client, isCurrent: { true }, contextForNote: { _ in .init(cycleDay: 99) })
        try await changedTracker.run()
        XCTAssertEqual(journal.state.notes[0].cycleContext, context)
    }

    func testTrackerContextUsesCalendarPhaseBoundaries() throws {
        let suite = "NoteContext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tracker = CycleTrackingStore(defaults: defaults, calendar: calendar)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        XCTAssertEqual(tracker.noteContext(on: start), CycleNoteContext())
        tracker.replacePeriodEntries(with: [.init(startDate: start, endDate: calendar.date(byAdding: .day, value: 4, to: start)!)])
        let cases: [(Int, CycleNoteContext.Phase, Int, Bool)] = [
            (1, .period, 1, false), (5, .period, 5, false), (6, .follicular, 1, true),
            (12, .follicular, 7, true), (13, .ovulation, 1, true), (15, .ovulation, 3, true),
            (16, .luteal, 1, true), (28, .luteal, 13, true), (29, .period, 1, true)
        ]
        for (day, phase, phaseDay, estimated) in cases {
            let date = calendar.date(byAdding: .day, value: day - 1, to: start)!
            let value = tracker.noteContext(on: date)
            XCTAssertEqual(value.cycleDay, day == 29 ? 1 : day)
            XCTAssertEqual(value.phase, phase)
            XCTAssertEqual(value.phaseDay, phaseDay)
            XCTAssertEqual(value.isEstimated, estimated)
        }
    }

    func testPendingPeriodResolvesUnknownNotesToTheDisplayedCycleDay() throws {
        let suite = "PendingNoteContext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tracker = CycleTrackingStore(defaults: defaults, calendar: calendar)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        tracker.replacePeriodEntries(with: [.init(startDate: start)])
        let secondDay = calendar.date(byAdding: .day, value: 1, to: start)!
        var note = CycleJournalNote(day: CycleDay.key(secondDay, calendar: calendar), occurredAt: secondDay,
            timeZone: "UTC", text: "More insulin resistant", tags: [])
        for saved in [nil, CycleNoteContext(), CycleNoteContext(cycleDay: 2)] as [CycleNoteContext?] {
            note.cycleContext = saved
            let resolved = tracker.noteContext(for: note)
            XCTAssertEqual(resolved.cycleDay, tracker.summary(on: secondDay).cycleDay)
            XCTAssertEqual(resolved.cycleDay, 2)
            XCTAssertEqual(resolved.phase, .period)
            XCTAssertEqual(resolved.phaseDay, 2)
            XCTAssertFalse(resolved.summaryText.contains("unknown"))
        }
        // Continue to use the calendar when the next period is still awaiting a log.
        let pendingNext = calendar.date(byAdding: .day, value: 29, to: start)!
        note.day = CycleDay.key(pendingNext, calendar: calendar); note.occurredAt = pendingNext; note.cycleContext = nil
        XCTAssertEqual(tracker.noteContext(for: note).cycleDay, tracker.summary(on: pendingNext).cycleDay)
        XCTAssertEqual(tracker.noteContext(for: note).cycleDay, 2)
    }

    func testUnknownContextIsRepairedAndSyncsWithoutOverwritingSavedValues() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let legacy = try journal.saveNote(date: date, text: "Old note", tags: [], cycleContext: CycleNoteContext())
        let explicit = CycleNoteContext(cycleDay: 20, phase: .luteal, phaseDay: 5)
        let manual = try journal.saveNote(date: date, text: "Saved context", tags: [], cycleContext: explicit)
        try await sync.run()
        let derived = CycleNoteContext(cycleDay: 2, phase: .period, phaseDay: 2)
        try journal.fillMissingCycleContexts { ($0.cycleContext ?? CycleNoteContext()).fillingMissing(from: derived) }
        XCTAssertEqual(journal.state.notes.first { $0.id == legacy.id }?.cycleContext, derived)
        XCTAssertEqual(journal.state.notes.first { $0.id == manual.id }?.cycleContext, explicit)
        try await sync.run()
        let id = remoteID(journal, legacy.id)
        XCTAssertEqual(try CycleNightscoutNoteClient.decode(server.rows[id]!).content.cycleContext, derived)
        XCTAssertEqual(journal.state.notes.count, 2)
    }

    func testInvalidCycleContextCannotBeSaved() throws {
        let (journal, _, _) = try fixture(); defer { cleanup(journal) }
        XCTAssertThrowsError(try journal.saveNote(date: date, text: "Bad day", tags: [], cycleContext: .init(cycleDay: 0)))
        XCTAssertThrowsError(try journal.saveNote(date: date, text: "Bad phase day", tags: [], cycleContext: .init(cycleDay: 3, phase: .luteal, phaseDay: 4)))
        XCTAssertThrowsError(try journal.saveNote(date: date, text: "Missing phase", tags: [], cycleContext: .init(cycleDay: 3, phaseDay: 2)))
        XCTAssertTrue(journal.state.notes.isEmpty)
    }

    func testSoftDeletedNightscoutRecordsAreNotResurrected() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Delete remotely", tags: [])
        try await sync.run()
        let id = remoteID(journal, note.id)
        server.rows[id]!["isValid"] = false
        let writes = server.writes
        try await sync.run()
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertTrue(journal.state.noteSync!.sites[configuration.sourceID]!.links.isEmpty)
        try await sync.run()
        XCTAssertTrue(journal.state.notes.isEmpty)
        XCTAssertEqual(server.writes, writes)
    }

    func testReadOnlyNightscoutNotesCannotBeOverwritten() async throws {
        let (journal, server, sync) = try fixture(); defer { cleanup(journal) }
        let note = try journal.saveNote(date: date, text: "Original", tags: [])
        try await sync.run()
        let id = remoteID(journal, note.id)
        server.rows[id]!["isReadOnly"] = true
        _ = try journal.saveNote(id: note.id, date: date, text: "Keep local edit", tags: [])
        let writes = server.writes
        do { try await sync.run(); XCTFail("Expected read-only refusal") } catch { }
        XCTAssertEqual(server.writes, writes)
        XCTAssertEqual(journal.state.notes.first?.text, "Keep local edit")
        try journal.deleteNote(note.id)
        do { try await sync.run(); XCTFail("Expected read-only refusal") } catch { }
        XCTAssertEqual(server.writes, writes)
        XCTAssertEqual(server.rows.count, 1)
    }

    func testFooterRoundTripPreservesCivilDateAndUserText() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        let note = CycleJournalNote(day: CycleDay.key(date, calendar: calendar), occurredAt: date, timeZone: calendar.timeZone.identifier,
            text: "First line\n\nSecond line [Cycle] with unicode 🌙", tags: [.cravings, .cramps])
        let content = CycleNoteSyncContent(note)
        let raw: [String: Any] = ["_id": "100000000000000000000001", "eventType": "Note", "notes": CycleNightscoutNoteClient.render(content), "created_at": "2026-01-15T12:00:00.000Z"]
        // Use the payload date as authority, even when a Nightscout user changes it.
        let decoded = try CycleNightscoutNoteClient.decode(raw)
        XCTAssertEqual(decoded.content.text, note.text)
        XCTAssertEqual(decoded.content.tags, note.tags)
        XCTAssertEqual(decoded.content.timeZone, note.timeZone)
        XCTAssertEqual(decoded.content.day, "2026-01-15")
    }
}
