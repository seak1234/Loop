import Foundation
import CryptoKit

/// Uses only the existing v1 treatment API. No server plugin or schema change.
struct CycleNightscoutNoteClient {
    enum SyncError: LocalizedError {
        case unavailable, permission, invalidRecord, incomplete, readOnly
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Cycle notes couldn't sync. They remain saved on this device; try again when connected."
            case .permission: return "Nightscout denied access. Cycle note sync needs permission to read, create, update and delete treatments."
            case .invalidRecord: return "A marked Nightscout note has an unsupported date, tag or format. Review notes starting with [Cycle] in Nightscout."
            case .incomplete: return "Nightscout returned an incomplete set of cycle notes. No missing notes were treated as deleted."
            case .readOnly: return "A marked Nightscout note is read-only. Unlock it in Nightscout before changing or deleting it here."
            }
        }
    }
    struct Record {
        var id: String
        var content: CycleNoteSyncContent
        var raw: [String: Any]
    }
    let configuration: CycleNightscoutConfiguration
    var transport: CycleNightscoutHistory.Transport = CycleNightscoutHistory.load
    static let pageSize = 1000

    static func validID(_ value: String) -> Bool {
        value.count == 24 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Stable, valid Mongo ObjectId, persisted before POST. Retries target one record.
    static func remoteID(localID: UUID, sourceID: String) -> String {
        String(SHA256.hash(data: Data((sourceID + ":cycle-note:" + localID.uuidString).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    /// Two phones uploading the same previously unshared period target one record.
    /// The link retains this ID if the logged start date is subsequently corrected.
    static func periodRemoteID(startDay: String, sourceID: String) -> String {
        String(SHA256.hash(data: Data((sourceID + ":cycle-period:" + startDay).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    static func calendarRemoteID(day: String, sourceID: String) -> String {
        String(SHA256.hash(data: Data((sourceID + ":cycle-day:" + day).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    func request(method: String = "GET", id: String? = nil, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        if let id, !Self.validID(id) { throw SyncError.invalidRecord }
        // Share the existing credential/URL rules, but omit the history date filter.
        var request = try CycleNightscoutHistory(configuration: configuration).request(endpoint: "treatments", start: .distantPast, end: Date())
        guard var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw SyncError.unavailable }
        url.path = String(url.path.dropLast("treatments.json".count)) + "treatments" + (id.map { "/" + $0 } ?? "")
        let token = url.queryItems?.filter { $0.name == "token" } ?? []
        url.queryItems = query + token
        request.url = url.url
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            if [401, 403].contains(response.statusCode) { throw SyncError.permission }
            guard (200..<300).contains(response.statusCode), data.count <= 8_000_000 else { throw SyncError.unavailable }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as SyncError { throw error }
        catch { throw SyncError.unavailable } // Never expose URLs, credentials or server bodies.
    }

    private func list(_ query: [URLQueryItem]) async throws -> [[String: Any]] {
        let data = try await send(request(query: query))
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SyncError.incomplete }
        return rows
    }

    /// Cursor pagination avoids skip support and Nightscout's default recent-date window.
    /// Validate server ordering/filters before using any response.
    func discover() async throws -> [Record] {
        var cursor = "000000000000000000000000"
        var result: [Record] = []
        for _ in 0..<100 {
            let rows = try await list([
                .init(name: "find[_id][$gt]", value: cursor),
                .init(name: "find[eventType]", value: "Note"),
                .init(name: "find[notes]", value: "/^\\[Cycle\\]/"),
                .init(name: "sort[_id]", value: "asc"),
                .init(name: "count", value: String(Self.pageSize))
            ])
            guard rows.count <= Self.pageSize else { throw SyncError.incomplete }
            for raw in rows {
                guard let id = raw["_id"] as? String, Self.validID(id), id > cursor else { throw SyncError.incomplete }
                cursor = id
                if raw["isDeleted"] as? Bool == true || raw["isValid"] as? Bool == false { continue }
                let record = try Self.decode(raw)
                result.append(record)
            }
            if rows.count < Self.pageSize { return result }
        }
        throw SyncError.incomplete
    }

    /// A missing ID is trusted only after a successful exact-ID query, never a list omission.
    func lookup(_ id: String) async throws -> Record? {
        guard Self.validID(id) else { throw SyncError.invalidRecord }
        let rows = try await list([.init(name: "find[_id]", value: id), .init(name: "count", value: "2")])
        guard rows.count <= 1 else { throw SyncError.incomplete }
        guard let raw = rows.first else { return nil }
        guard raw["_id"] as? String == id else { throw SyncError.incomplete }
        if raw["isDeleted"] as? Bool == true || raw["isValid"] as? Bool == false { return nil }
        return try Self.decode(raw)
    }

    func write(id: String, content: CycleNoteSyncContent, existing: Record?) async throws {
        if existing?.raw["isReadOnly"] as? Bool == true { throw SyncError.readOnly }
        var body = existing?.raw ?? [:]
        body["_id"] = id
        body["eventType"] = "Note"
        if body["enteredBy"] == nil { body["enteredBy"] = "Loop Cycle Journal" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        body["created_at"] = formatter.string(from: content.occurredAt)
        body["date"] = content.occurredAt.timeIntervalSince1970 * 1000
        body["utcOffset"] = (TimeZone(identifier: content.timeZone)?.secondsFromGMT(for: content.occurredAt) ?? 0) / 60
        body["notes"] = Self.render(content)
        _ = try await send(request(method: existing == nil ? "POST" : "PUT", body: body))
        guard let saved = try await lookup(id), saved.content == content else { throw SyncError.unavailable }
    }

    func delete(_ record: Record) async throws {
        if record.raw["isReadOnly"] as? Bool == true { throw SyncError.readOnly }
        _ = try await send(request(method: "DELETE", id: record.id))
        guard try await lookup(record.id) == nil else { throw SyncError.unavailable }
    }

    static func render(_ content: CycleNoteSyncContent) -> String {
        var text = "[Cycle] " + content.text + "\n\nCycle tags: " + content.tags.map(\.rawValue).joined(separator: ", ") + "\nCycle time zone: " + content.timeZone
        if let context = content.cycleContext {
            text += "\nCycle day: " + (context.cycleDay.map(String.init) ?? "unknown")
            text += "\nCycle phase: " + (context.phase?.rawValue ?? "unknown")
            text += "\nPhase day: " + (context.phaseDay.map(String.init) ?? "unknown")
            text += "\nCycle timing: " + (context.isEstimated ? "estimated" : "reported")
        }
        if let period = content.period {
            text += "\nCycle record: period"
            text += "\nPeriod start: " + period.startDay
            text += "\nPeriod end: " + (period.endDay ?? "ongoing")
        }
        if content.isCalendarDay == true {
            text += "\nCycle record: day"
            text += "\nCycle date: " + content.day
        }
        return text
    }

    static func decode(_ raw: [String: Any], now: Date = Date()) throws -> Record {
        guard let id = raw["_id"] as? String, validID(id), raw["eventType"] as? String == "Note",
              raw["isDeleted"] as? Bool != true, raw["isValid"] as? Bool != false,
              let body = raw["notes"] as? String, body.hasPrefix("[Cycle]"),
              let dateString = raw["created_at"] as? String else { throw SyncError.invalidRecord }
        for key in ["insulin", "carbs"] {
            if let value = raw[key], !(value is NSNull) {
                guard let amount = Double(String(describing: value)), amount == 0 else { throw SyncError.invalidRecord }
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: dateString)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? formatter.date(from: dateString), date <= now.addingTimeInterval(1),
              date >= Date(timeIntervalSince1970: -2_208_988_800) else { throw SyncError.invalidRecord }
        // Preserve the leading separator until the footer has been parsed: a
        // tag-only note has no body before that separator.
        var text = String(body.dropFirst("[Cycle]".count))
        if let end = text.lastIndex(where: { !$0.isWhitespace }) { text = String(text[...end]) }
        else { text = "" }
        var zone = TimeZone.current
        var tags: [CycleNoteTag] = []
        var context: CycleNoteContext?
        var period: CyclePeriodSyncContent?
        var calendarDay: String?
        // A readable footer survives Nightscout's ordinary note editor. Notes entered
        // there need only the [Cycle] prefix; the footer is optional.
        if let footer = text.range(of: "\n\nCycle tags: ", options: .backwards) {
            let lines = text[footer.upperBound...].components(separatedBy: "\nCycle time zone: ")
            guard lines.count == 2 else { throw SyncError.invalidRecord }
            let details = lines[1].components(separatedBy: "\n")
            guard let zoneName = details.first, let savedZone = TimeZone(identifier: zoneName) else { throw SyncError.invalidRecord }
            if details.count > 1 {
                guard [5, 7, 8].contains(details.count), details[1].hasPrefix("Cycle day: "), details[2].hasPrefix("Cycle phase: "),
                      details[3].hasPrefix("Phase day: "), details[4].hasPrefix("Cycle timing: ") else { throw SyncError.invalidRecord }
                func day(_ line: String, prefix: String) throws -> Int? {
                    let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).lowercased()
                    if value == "unknown" { return nil }
                    guard let number = Int(value), (1...10000).contains(number) else { throw SyncError.invalidRecord }
                    return number
                }
                let phase = String(details[2].dropFirst("Cycle phase: ".count)).trimmingCharacters(in: .whitespaces).lowercased()
                let timing = String(details[4].dropFirst("Cycle timing: ".count)).trimmingCharacters(in: .whitespaces).lowercased()
                guard (phase == "unknown" || CycleNoteContext.Phase(rawValue: phase) != nil),
                      ["estimated", "reported"].contains(timing) else { throw SyncError.invalidRecord }
                let value = CycleNoteContext(cycleDay: try day(details[1], prefix: "Cycle day: "), phase: CycleNoteContext.Phase(rawValue: phase),
                    phaseDay: try day(details[3], prefix: "Phase day: "), isEstimated: timing == "estimated")
                guard value.isValid else { throw SyncError.invalidRecord }
                context = value
                if details.count == 7 {
                    guard details[5] == "Cycle record: day", details[6].hasPrefix("Cycle date: ") else { throw SyncError.invalidRecord }
                    calendarDay = String(details[6].dropFirst("Cycle date: ".count))
                }
                if details.count == 8 {
                    guard details[5] == "Cycle record: period", details[6].hasPrefix("Period start: "),
                          details[7].hasPrefix("Period end: ") else { throw SyncError.invalidRecord }
                    let end = String(details[7].dropFirst("Period end: ".count))
                    let record = CyclePeriodSyncContent(startDay: String(details[6].dropFirst("Period start: ".count)),
                        endDay: end == "ongoing" ? nil : end)
                    guard record.isValid(timeZone: savedZone.identifier, now: now) else { throw SyncError.invalidRecord }
                    period = record
                }
            }
            let values = lines[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.allSatisfy({ CycleNoteTag(rawValue: $0) != nil }) else { throw SyncError.invalidRecord }
            tags = CycleNoteTag.allCases.filter { values.contains($0.rawValue) }
            zone = savedZone
            text = String(text[..<footer.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !tags.isEmpty), text.count <= 6000 else { throw SyncError.invalidRecord }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        var note = CycleJournalNote(day: CycleDay.key(date, calendar: calendar), occurredAt: date, timeZone: zone.identifier, text: text, tags: tags)
        note.cycleContext = context
        note.period = period
        if let calendarDay {
            guard calendarDay == note.day else { throw SyncError.invalidRecord }
            note.isCalendarDay = true
        }
        return Record(id: id, content: CycleNoteSyncContent(note), raw: raw)
    }
}

/// All journal changes happen on the UI actor, re-reading current local state after
/// every network suspension. The v1 API has no atomic compare-and-swap operation.
@MainActor
struct CycleNightscoutNoteSync {
    let journal: CycleJournalStore
    let client: CycleNightscoutNoteClient
    var isCurrent: () -> Bool
    var contextForNote: (CycleJournalNote) -> CycleNoteContext = { _ in CycleNoteContext() }
    var periodTracker: CycleTrackingStore?
    var syncCalendarDays = true
    var calendarNow: () -> Date = Date.init
    private var sourceID: String { client.configuration.sourceID }

    private func check() throws {
        try Task.checkCancellation()
        guard journal.state.noteSync?.enabledSourceID == sourceID, isCurrent() else { throw CancellationError() }
        if let periodTracker { try journal.stagePeriodHistory(periodTracker.periodHistorySyncNotes()) }
    }

    private func change(_ edit: (inout CycleJournalState, inout CycleNoteSyncState, inout CycleNoteSyncSite) -> Void) throws {
        try check()
        try journal.update { state in
            var sync = state.noteSync ?? CycleNoteSyncState()
            var site = sync.sites[sourceID] ?? CycleNoteSyncSite()
            edit(&state, &sync, &site)
            sync.sites[sourceID] = site
            state.noteSync = sync
        }
    }

    func run() async throws {
        try check()
        // Complete discovery before importing anything; failed/truncated lists do not
        // produce local deletions. Known records are also read individually below.
        let remoteNotes = try await client.discover()
        try check()
        try await reconcile(remoteNotes.filter { $0.content.isCalendarDay != true }, calendarDays: false)
        try check()
        if let periodTracker {
            try periodTracker.restorePeriodHistory(from: journal.state.periodSyncNotes ?? [])
            try journal.update { $0.periodTrackerSnapshot = periodTracker.periodHistorySyncNotes() }
            try journal.fillMissingCycleContexts { periodTracker.noteContext(for: $0) }
        }
        if syncCalendarDays {
            try await reconcile(remoteNotes.filter { $0.content.isCalendarDay == true }, calendarDays: true)
        }
        try change { _, _, site in site.lastSyncedAt = Date() }
    }

    private func reconcile(_ remoteNotes: [CycleNightscoutNoteClient.Record], calendarDays: Bool) async throws {
        let discovered = Dictionary(uniqueKeysWithValues: remoteNotes.map { ($0.id, $0) })
        try change { state, _, site in
            for remote in remoteNotes where !site.links.contains(where: { $0.remoteID == remote.id }) {
                if remote.content.isCalendarDay == true,
                   let note = state.calendarSyncNotes?.first(where: { candidate in candidate.day == remote.content.day && !site.links.contains(where: { $0.localID == candidate.id }) }),
                   let index = state.synchronizedNotes.firstIndex(where: { $0.id == note.id }) {
                    state.synchronizedNotes[index] = remote.content.note(id: note.id, source: "cycle-calendar")
                    site.links.append(.init(localID: note.id, remoteID: remote.id, base: remote.content, acknowledged: true))
                    continue
                }
                // Two existing phones may already have the same logged period.
                // Link that record rather than importing another copy.
                if let period = remote.content.period,
                   let note = state.synchronizedNotes.first(where: { candidate in candidate.period?.startDay == period.startDay && !site.links.contains(where: { $0.localID == candidate.id }) }) {
                    let sameDates = note.period == period
                    if sameDates, let index = state.synchronizedNotes.firstIndex(where: { $0.id == note.id }) {
                        state.synchronizedNotes[index] = remote.content.note(id: note.id, source: note.source)
                    }
                    site.links.append(.init(localID: note.id, remoteID: remote.id,
                        base: sameDates ? remote.content : CycleNoteSyncContent(note), acknowledged: sameDates))
                    continue
                }
                var note = remote.content.note()
                if note.cycleContext == nil { note.cycleContext = contextForNote(note) }
                state.synchronizedNotes.append(note)
                site.links.append(.init(localID: note.id, remoteID: remote.id, base: remote.content, acknowledged: true))
            }
        }
        let calendarPeriods = periodTracker?.periodHistorySyncNotes()
        let calendarTime = calendarNow()
        if calendarDays, let periodTracker {
            try journal.stageCalendarDays(periodTracker.calendarHistorySyncNotes(through: calendarTime))
        }
        // Register pending creates durably before sending them. Leave failed requests
        // linked so a retry can look up the exact ID instead of creating duplicates.
        try change { state, _, site in
            for index in state.synchronizedNotes.indices where (state.synchronizedNotes[index].isCalendarDay == true) == calendarDays && !site.links.contains(where: { $0.localID == state.synchronizedNotes[index].id }) {
                if state.synchronizedNotes[index].cycleContext == nil { state.synchronizedNotes[index].cycleContext = contextForNote(state.synchronizedNotes[index]) }
                let note = state.synchronizedNotes[index]
                let remoteID = note.isCalendarDay == true ? CycleNightscoutNoteClient.calendarRemoteID(day: note.day, sourceID: sourceID)
                    : note.period.map { CycleNightscoutNoteClient.periodRemoteID(startDay: $0.startDay, sourceID: sourceID) }
                        ?? CycleNightscoutNoteClient.remoteID(localID: note.id, sourceID: sourceID)
                site.links.append(.init(localID: note.id, remoteID: remoteID, base: CycleNoteSyncContent(note), acknowledged: false))
            }
        }
        let ids = journal.state.noteSync?.sites[sourceID]?.links.filter { ($0.base.isCalendarDay == true) == calendarDays }.map(\.localID) ?? []
        for id in ids {
            try check()
            guard let link = journal.state.noteSync?.sites[sourceID]?.links.first(where: { $0.localID == id }) else { continue }
            if link.acknowledged, discovered[link.remoteID]?.content == link.base,
               journal.state.synchronizedNotes.first(where: { $0.id == id }).map(CycleNoteSyncContent.init) == link.base {
                continue
            }
            let remote = try await client.lookup(link.remoteID)
            try check()
            let local = journal.state.synchronizedNotes.first { $0.id == id }.map(CycleNoteSyncContent.init)
            if let remote {
                // Removing the history footer must not silently erase tracker data.
                guard (link.base.period == nil) == (remote.content.period == nil),
                      (link.base.isCalendarDay == true) == (remote.content.isCalendarDay == true) else { throw CycleNightscoutNoteClient.SyncError.invalidRecord }
                let remoteChanged = remote.content != link.base
                if let local, local.isCalendarDay == true {
                    // These records describe the calendar. Period-history changes
                    // refresh derived context while preserving text added remotely.
                    var target = remote.content
                    target.cycleContext = local.cycleContext
                    if target != remote.content { try await client.write(id: link.remoteID, content: target, existing: remote) }
                    try change { state, _, _ in
                        if let index = state.synchronizedNotes.firstIndex(where: { $0.id == id }) {
                            state.synchronizedNotes[index] = target.note(id: id, source: "cycle-calendar")
                        }
                    }
                    try acknowledge(link, content: target)
                } else if !link.acknowledged, let period = local?.period, period == remote.content.period {
                    // A concurrent first upload can have another phone's timestamp
                    // or time zone while representing exactly the same civil dates.
                    try change { state, _, _ in
                        if let index = state.synchronizedNotes.firstIndex(where: { $0.id == id }) {
                            state.synchronizedNotes[index] = remote.content.note(id: id)
                        }
                    }
                    try acknowledge(link, content: remote.content)
                } else if local == remote.content {
                    try acknowledge(link, content: remote.content)
                } else if let local {
                    if !remoteChanged {
                        try await client.write(id: link.remoteID, content: local, existing: remote)
                        try acknowledge(link, content: local)
                    } else {
                        try change { state, sync, site in
                            if local != link.base || !link.acknowledged {
                                state.synchronizedNotes.append(local.conflictNote())
                                sync.conflictCopies += 1
                            }
                            if let index = state.synchronizedNotes.firstIndex(where: { $0.id == id }) {
                                let original = state.synchronizedNotes[index]
                                var replacement = remote.content.note(id: id, source: original.source)
                                replacement.createdAt = original.createdAt
                                state.synchronizedNotes[index] = replacement
                            }
                            if let index = site.links.firstIndex(where: { $0.localID == id }) {
                                site.links[index].base = remote.content; site.links[index].acknowledged = true
                            }
                        }
                    }
                } else if remoteChanged {
                    // Local deletion versus remote edit: keep the edited version.
                    try change { state, sync, site in
                        state.synchronizedNotes.append(remote.content.note(id: id)); sync.conflictCopies += 1
                        if let index = site.links.firstIndex(where: { $0.localID == id }) {
                            site.links[index].base = remote.content; site.links[index].acknowledged = true
                        }
                    }
                } else {
                    try await client.delete(remote)
                    try unlink(link)
                }
            } else if let local {
                if !link.acknowledged || local.isCalendarDay == true {
                    try await client.write(id: link.remoteID, content: local, existing: nil)
                    try acknowledge(link, content: local)
                } else {
                    // Remote deletion versus a local edit: keep a new, unlinked copy.
                    try change { state, sync, site in
                        if local != link.base {
                            state.synchronizedNotes.append(local.note(source: "user")); sync.conflictCopies += 1
                        }
                        state.synchronizedNotes.removeAll { $0.id == id }
                        site.links.removeAll { $0.localID == id }
                    }
                }
            } else { try unlink(link) }
        }
        try check()
        if calendarDays, let periodTracker {
            let current = periodTracker.periodHistorySyncNotes()
            // A period edit made during a backfill is queued by the controller.
            // Do not report that older calendar context as fully synchronized.
            guard current.map(\.id) == calendarPeriods?.map(\.id),
                  current.map(\.period) == calendarPeriods?.map(\.period) else { throw CancellationError() }
            let through = periodTracker.calendarHistorySyncNotes(through: calendarTime).last?.day
            try change { _, _, site in site.calendarSyncedThrough = through }
        }
    }

    private func acknowledge(_ link: CycleNoteSyncLink, content: CycleNoteSyncContent) throws {
        try change { _, _, site in
            if let index = site.links.firstIndex(where: { $0.localID == link.localID }) {
                site.links[index].base = content; site.links[index].acknowledged = true
            }
        }
    }
    private func unlink(_ link: CycleNoteSyncLink) throws {
        try change { _, _, site in site.links.removeAll { $0.localID == link.localID } }
    }
}
