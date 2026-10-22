import Foundation
import Combine

/// Civil dates stay attached to the day the user chose, including after travel.
enum CycleDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components), self.key(date, calendar: calendar) == key else { return nil }
        return date
    }
}

enum CycleNoteTag: String, Codable, CaseIterable, Identifiable {
    case sensitive, resistant, highs, lows, variable, cravings, sleep, stress, exercise, illness, cramps, lowEnergy
    var id: String { rawValue }
    // Both note entry points share this list. Keep legacy cases decodable so
    // existing notes and Nightscout entries retain their saved tags.
    static let availableTags: [Self] = [.sensitive, .resistant, .cravings, .stress, .exercise, .illness]
    var title: String {
        switch self {
        case .sensitive: return "Felt more insulin sensitive"
        case .resistant: return "Felt more insulin resistant"
        case .highs: return "More highs"
        case .lows: return "More lows"
        case .variable: return "Variable glucose"
        case .cravings: return "Cravings"
        case .sleep: return "Sleep"
        case .stress: return "Stress"
        case .exercise: return "Exercise"
        case .illness: return "Illness"
        case .cramps: return "Cramps"
        case .lowEnergy: return "Low energy"
        }
    }

    var symbolName: String {
        switch self {
        case .sensitive: return "arrow.down.right"
        case .resistant: return "arrow.up.right"
        case .highs: return "arrow.up"
        case .lows: return "arrow.down"
        case .variable: return "waveform.path"
        case .cravings: return "fork.knife"
        case .sleep: return "moon.fill"
        case .stress: return "cloud.bolt"
        case .exercise: return "figure.walk"
        case .illness: return "thermometer"
        case .cramps: return "bolt.fill"
        case .lowEnergy: return "battery.25percent"
        }
    }
}

struct CycleJournalNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var day: String
    var occurredAt: Date
    var timeZone: String
    var text: String
    var tags: [CycleNoteTag]
    var source: String = "user"
    var createdAt = Date()
    var updatedAt = Date()
    var cycleContext: CycleNoteContext?
    /// Present only on the dedicated Nightscout period-history notes.
    var period: CyclePeriodSyncContent?
    /// An automatically maintained calendar-day note, even without journal text.
    var isCalendarDay: Bool?

    var displayText: String {
        text.isEmpty ? tags.map(\.title).joined(separator: " · ") : text
    }
}

/// Civil dates preserve the logged calendar days across devices and time zones.
struct CyclePeriodSyncContent: Codable, Equatable {
    var startDay: String
    var endDay: String?

    func isValid(timeZone: String, now: Date = Date()) -> Bool {
        guard let zone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = CycleDay.key(now, calendar: calendar)
        guard startDay.count == 10, CycleDay.date(startDay, calendar: calendar) != nil, startDay <= today else { return false }
        guard let endDay else { return true }
        return endDay.count == 10 && CycleDay.date(endDay, calendar: calendar) != nil && endDay >= startDay && endDay <= today
    }
}

/// Note-level context travels with the note, independently of period history.
struct CycleNoteContext: Codable, Equatable {
    enum Phase: String, Codable, CaseIterable, Identifiable {
        case period, follicular, ovulation, luteal
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    var cycleDay: Int?
    var phase: Phase?
    var phaseDay: Int?
    var isEstimated = true

    var isValid: Bool {
        [cycleDay, phaseDay].allSatisfy { $0.map { (1...10000).contains($0) } ?? true }
            && (phaseDay == nil || phase != nil)
            && (cycleDay == nil || phaseDay == nil || phaseDay! <= cycleDay!)
    }

    func fillingMissing(from tracker: CycleNoteContext) -> CycleNoteContext {
        // A saved day may be a deliberate override. Do not mix its phase with
        // calendar values from a different cycle day.
        if let cycleDay, let trackerDay = tracker.cycleDay, cycleDay != trackerDay { return self }
        var result = self
        if result.cycleDay == nil { result.cycleDay = tracker.cycleDay }
        if result.phase == nil {
            result.phase = tracker.phase
            if tracker.phase != nil { result.isEstimated = tracker.isEstimated }
        }
        if result.phaseDay == nil, result.phase == tracker.phase {
            result.phaseDay = tracker.phaseDay
        }
        return result.isValid ? result : self
    }
    var summaryText: String {
        let day = cycleDay.map { "Cycle day \($0)" } ?? "Cycle day unknown"
        let phaseName = phase?.title ?? "Phase unknown"
        let withinPhase = phaseDay.map { " · Phase day \($0)" } ?? " · Phase day unknown"
        return day + " · " + phaseName + withinPhase + (isEstimated ? " · Estimated" : " · Logged/reported")
    }
}

/// Optional in journal state so journals saved before note sync remain readable.
struct CycleNoteSyncState: Codable, Equatable {
    var enabledSourceID: String?
    var sites: [String: CycleNoteSyncSite] = [:]
    var conflictCopies = 0
}

struct CycleNoteSyncSite: Codable, Equatable {
    var links: [CycleNoteSyncLink] = []
    var lastSyncedAt: Date?
    var calendarSyncedThrough: String?
}

struct CycleNoteSyncContent: Codable, Equatable {
    var day: String
    var occurredAt: Date
    var timeZone: String
    var text: String
    var tags: [CycleNoteTag]
    var cycleContext: CycleNoteContext?
    var period: CyclePeriodSyncContent?
    var isCalendarDay: Bool?

    init(_ note: CycleJournalNote) {
        day = note.day
        occurredAt = Date(timeIntervalSince1970: floor(note.occurredAt.timeIntervalSince1970 * 1000) / 1000)
        timeZone = note.timeZone
        text = note.text; tags = note.tags
        cycleContext = note.cycleContext
        period = note.period
        isCalendarDay = note.isCalendarDay
    }

    func note(id: UUID = UUID(), source: String = "nightscout") -> CycleJournalNote {
        var result = CycleJournalNote(day: day, occurredAt: occurredAt, timeZone: timeZone, text: text, tags: tags, source: source)
        result.id = id
        result.cycleContext = cycleContext
        result.period = period
        result.isCalendarDay = isCalendarDay
        return result
    }

    func conflictNote() -> CycleJournalNote {
        var result = note(source: "user")
        if let period {
            result.text += "\n\nPeriod history conflict: " + period.startDay + " through " + (period.endDay ?? "ongoing") + ". Review period history."
            result.period = nil
        }
        if isCalendarDay == true {
            result.text += "\n\nCalendar context conflict for " + day + ". " + (cycleContext?.summaryText ?? "")
            result.isCalendarDay = nil
        }
        return result
    }
}

struct CycleNoteSyncLink: Codable, Equatable {
    var localID: UUID
    var remoteID: String
    var base: CycleNoteSyncContent
    /// Persisted before sending a create, so a lost response can be retried safely.
    var acknowledged: Bool
}

struct CycleGlucoseReading: Codable, Equatable {
    var date: Date
    var mgdl: Double
}

struct CycleGlucoseDuration: Codable, Equatable {
    var mgdl: Double
    var seconds: Double
}

struct CycleDailySummary: Codable, Identifiable, Equatable {
    var id: String { day }
    var day: String
    var timeZone: String
    var capturedAt: Date
    var isPartialDay: Bool
    var coveredSeconds: Double
    var daySeconds: Double
    var meanMGDL: Double?
    /// Snapshot at collection; use timeInRange(using:) to apply current glucose statistics settings.
    var timeInRange: Double?
    var insulinUnits: Double?
    var insulinRecordCount: Int
    var carbGrams: Double?
    var carbEntryCount: Int
    var glucose: [CycleGlucoseReading]
    var glucoseSource: String?
    var insulinSource: String?
    var carbSource: String?
    /// A successful query covered this entire day's elapsed carb history.
    /// Missing on legacy records; false for failed queries and expired caches.
    var carbHistoryIsComplete: Bool?
    var insulinIsPartial: Bool?
    /// Exact observed durations grouped by glucose value, independent of the downsampled trace.
    var glucoseDurations: [CycleGlucoseDuration]?
    var needsDisplayRangeRefresh: Bool { coveredSeconds > 0 && glucoseDurations == nil }

    func timeInRange(using settings: GlucoseGraphSettings) -> Double? {
        guard let glucoseDurations else { return nil }
        let observed = glucoseDurations.filter { $0.mgdl.isFinite && $0.mgdl > 0 && $0.seconds.isFinite && $0.seconds > 0 }
        let total = observed.map(\.seconds).reduce(0, +)
        guard total > 0 else { return nil }
        let inRange = observed.filter { (settings.lowerBoundMGDL...settings.upperBoundMGDL).contains($0.mgdl) }.map(\.seconds).reduce(0, +)
        return inRange / total
    }
    var coverage: Double { min(1, max(0, coveredSeconds / max(1, daySeconds))) }
    var usableForPatterns: Bool { !isPartialDay && coverage >= 0.7 && meanMGDL != nil }

    static func make(start: Date, end: Date, now: Date, readings: [CycleGlucoseReading],
                     range: (Date) -> (Double, Double)?, insulin: Double?, insulinRecords: Int,
                     carbs: Double?, carbEntries: Int, calendar: Calendar = .current,
                     carbHistoryIsComplete: Bool = false) -> Self {
        let valid = readings.filter { $0.date >= start && $0.date < min(now, end) && $0.mgdl.isFinite && $0.mgdl > 0 }
            .sorted { $0.date < $1.date }
        // A reading represents at most five minutes. Gaps never become in-range time.
        var seconds = 0.0, total = 0.0, inRange = 0.0, rangeSeconds = 0.0
        var bins: [Int: CycleGlucoseReading] = [:]
        var durations: [Double: Double] = [:]
        for (index, reading) in valid.enumerated() {
            let next = index + 1 < valid.count ? valid[index + 1].date : end
            let duration = max(0, min(300, min(now, min(end, next)).timeIntervalSince(reading.date)))
            seconds += duration
            total += reading.mgdl * duration
            if duration > 0 { durations[reading.mgdl, default: 0] += duration }
            if let (lower, upper) = range(reading.date), lower.isFinite, upper.isFinite, lower <= upper {
                rangeSeconds += duration
                if (lower...upper).contains(reading.mgdl) { inRange += duration }
            }
            bins[Int(reading.date.timeIntervalSince(start) / 900)] = reading
        }
        return Self(day: CycleDay.key(start, calendar: calendar), timeZone: calendar.timeZone.identifier,
                    capturedAt: now, isPartialDay: end > now, coveredSeconds: seconds,
                    daySeconds: end.timeIntervalSince(start), meanMGDL: seconds > 0 ? total / seconds : nil,
                    timeInRange: rangeSeconds >= seconds * 0.99 && seconds > 0 ? inRange / seconds : nil,
                    insulinUnits: insulin, insulinRecordCount: insulinRecords, carbGrams: carbs,
                    carbEntryCount: carbEntries, glucose: bins.keys.sorted().compactMap { bins[$0] },
                    carbHistoryIsComplete: carbHistoryIsComplete,
                    glucoseDurations: durations.keys.sorted().map { CycleGlucoseDuration(mgdl: $0, seconds: durations[$0]!) })
    }
}

struct CycleJournalState: Codable {
    var version = 1
    var notes: [CycleJournalNote] = []
    var summaries: [CycleDailySummary] = []
    var allowMochiRead = false
    var allowMochiWrite = false
    var showPersonalReminders = false
    var retainDailySummaries = true
    var hiddenInsights: [String: Date] = [:]
    var displayRangeHistoryVersion: Int?
    var nightscoutSourceID: String?
    var nightscoutGlucoseSyncedAt: Date?
    var nightscoutTreatmentsSyncedAt: Date?
    var noteSync: CycleNoteSyncState?
    /// Internal backing records; period history is edited through the tracker.
    var periodSyncNotes: [CycleJournalNote]?
    var periodTrackerSnapshot: [CycleJournalNote]?
    var calendarSyncNotes: [CycleJournalNote]?
    var calendarGeneratedDays: [String]?

    var synchronizedNotes: [CycleJournalNote] {
        get { notes + (periodSyncNotes ?? []) + (calendarSyncNotes ?? []) }
        set {
            notes = newValue.filter { $0.period == nil && $0.isCalendarDay != true }
            periodSyncNotes = newValue.filter { $0.period != nil }
            calendarSyncNotes = newValue.filter { $0.isCalendarDay == true }
        }
    }
}

/// Journal transactions are independent of chat history and preserve unreadable files.
final class CycleJournalStore: ObservableObject {
    static let shared: CycleJournalStore = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return CycleJournalStore(url: root.appendingPathComponent("CycleJournal/journal.json"))
    }()
    @Published private(set) var state = CycleJournalState()
    @Published private(set) var failure: String?
    let url: URL

    init(url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(CycleJournalState.self, from: Data(contentsOf: url))
                guard saved.version == 1 else { throw CompanionError.invalid("This journal needs a newer app version.") }
                state = saved
            }
            failure = nil
        } catch { failure = "Your saved cycle journal could not be read. It has been preserved. \(error.localizedDescription)" }
    }

    func update(_ change: (inout CycleJournalState) throws -> Void) throws {
        guard failure == nil else { throw CompanionError.invalid(failure!) }
        var next = state
        try change(&next)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        state = next
    }

    @discardableResult
    func saveNote(id: UUID? = nil, date: Date, text: String, tags: [CycleNoteTag], source: String = "user", now: Date = Date(), cycleContext: CycleNoteContext? = nil) throws -> CycleJournalNote {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Edits use the note's original civil calendar, including after travel.
        let savedZone = state.notes.first(where: { $0.id == id }).flatMap { TimeZone(identifier: $0.timeZone) }
        let zone = savedZone ?? .current
        var calendar = Calendar.current
        calendar.timeZone = zone
        guard (!text.isEmpty || !tags.isEmpty), text.count <= 6000, date <= now,
              CycleDay.date(CycleDay.key(date, calendar: calendar), calendar: calendar) != nil else { throw CompanionError.invalid("Choose a past or current date, then add text or select at least one tag. Text can be up to 6,000 characters.") }
        guard cycleContext?.isValid != false else { throw CompanionError.invalid("Cycle and phase days must be positive numbers, and phase day cannot exceed cycle day. Choose a phase when entering its day.") }
        var note = CycleJournalNote(day: CycleDay.key(date, calendar: calendar), occurredAt: date, timeZone: zone.identifier,
                                    text: text, tags: CycleNoteTag.allCases.filter { tags.contains($0) }, source: source)
        note.cycleContext = cycleContext
        try update { state in
            if let id {
                guard let existing = state.notes.first(where: { $0.id == id }) else { throw CompanionError.invalid("This note was deleted. Close the editor and try again.") }
                note.id = id; note.createdAt = existing.createdAt; note.source = existing.source
                if cycleContext == nil, note.day == existing.day { note.cycleContext = existing.cycleContext }
            } else if source == "mochi", let existing = state.notes.first(where: { $0.day == note.day && abs($0.occurredAt.timeIntervalSince(date)) < 1 && $0.text == text && $0.tags == note.tags && $0.source == source }) {
                // Provider retries must not duplicate a saved note.
                note = existing
                return
            }
            note.updatedAt = now
            state.notes.removeAll { $0.id == note.id }
            state.notes.append(note)
        }
        return note
    }

    func deleteNote(_ id: UUID) throws { try update { $0.notes.removeAll { $0.id == id } } }

    /// Compare with the last tracker snapshot so an empty, newly installed tracker
    /// never erases downloaded history. Changes queue in the same durable journal.
    func stagePeriodHistory(_ entries: [CycleJournalNote]) throws {
        let previous = state.periodTrackerSnapshot ?? []
        if state.periodTrackerSnapshot != nil,
           previous.map(\.id) == entries.map(\.id), previous.map(\.period) == entries.map(\.period) { return }
        try update { state in
            var notes = state.periodSyncNotes ?? []
            for old in previous where !entries.contains(where: { $0.id == old.id }) {
                notes.removeAll { $0.id == old.id }
            }
            for entry in entries {
                let old = previous.first { $0.id == entry.id }
                guard old == nil || old?.period != entry.period else { continue }
                if let index = notes.firstIndex(where: { $0.id == entry.id }) {
                    var replacement = notes[index]
                    replacement.period = entry.period
                    replacement.day = entry.day
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: replacement.timeZone) ?? .current
                    if let date = CycleDay.date(entry.day, calendar: calendar) {
                        replacement.occurredAt = calendar.startOfDay(for: date)
                    }
                    replacement.updatedAt = Date()
                    notes[index] = replacement
                } else { notes.append(entry) }
            }
            state.periodSyncNotes = notes
            state.periodTrackerSnapshot = entries
        }
    }

    func fillMissingCycleContexts(using resolve: (CycleJournalNote) -> CycleNoteContext) throws {
        let repaired = state.notes.map { note -> CycleJournalNote in
            let context = resolve(note)
            guard context.isValid, context != (note.cycleContext ?? CycleNoteContext()) else { return note }
            var result = note
            result.cycleContext = context
            result.updatedAt = Date()
            return result
        }
        guard repaired != state.notes else { return }
        try update { $0.notes = repaired }
    }

    func stageCalendarDays(_ days: [CycleJournalNote]) throws {
        var saved = state.calendarSyncNotes ?? []
        let generated = days.map(\.day)
        let unsupported = Set(state.calendarGeneratedDays ?? []).subtracting(generated)
        for index in saved.indices where unsupported.contains(saved[index].day) {
            saved[index].cycleContext = CycleNoteContext()
        }
        for day in days {
            if let index = saved.firstIndex(where: { $0.day == day.day }) {
                // Preserve the civil time zone and any remote text/tags. Only
                // calendar-derived timing changes when period history is corrected.
                if saved[index].cycleContext != day.cycleContext {
                    saved[index].cycleContext = day.cycleContext
                    saved[index].updatedAt = Date()
                }
            } else { saved.append(day) }
        }
        guard saved != (state.calendarSyncNotes ?? []) || generated != state.calendarGeneratedDays else { return }
        try update { $0.calendarSyncNotes = saved; $0.calendarGeneratedDays = generated }
    }

    func calendarContext(on date: Date, calendar: Calendar = .current) -> CycleNoteContext? {
        state.calendarSyncNotes?.first { $0.day == CycleDay.key(date, calendar: calendar) }?.cycleContext
    }

    func calendarDayIsSynced(_ day: String, trackerContext: CycleNoteContext) -> Bool {
        guard let source = state.noteSync?.enabledSourceID, let site = state.noteSync?.sites[source],
              let note = state.calendarSyncNotes?.first(where: { $0.day == day }),
              trackerContext.cycleDay == nil || trackerContext == note.cycleContext else { return false }
        return site.links.contains { $0.localID == note.id && $0.acknowledged && $0.base == CycleNoteSyncContent(note) }
    }
    func notes(on date: Date) -> [CycleJournalNote] {
        state.notes.filter { $0.day == CycleDay.key(date) }.sorted { $0.occurredAt < $1.occurredAt }
    }
    func summary(on date: Date) -> CycleDailySummary? { state.summaries.first { $0.day == CycleDay.key(date) } }

    func retain(_ summaries: [CycleDailySummary]) throws {
        guard state.retainDailySummaries else { return }
        try update { state in
            for incoming in summaries {
                var summary = incoming
                if let old = state.summaries.first(where: { $0.day == summary.day }) {
                    if old.coveredSeconds > summary.coveredSeconds || (old.coveredSeconds == summary.coveredSeconds && old.glucoseSource == "Nightscout" && summary.glucoseSource != "Nightscout" && (old.glucoseDurations != nil || summary.glucoseDurations == nil)) {
                        summary.coveredSeconds = old.coveredSeconds
                        summary.daySeconds = old.daySeconds
                        summary.meanMGDL = old.meanMGDL
                        summary.timeInRange = old.timeInRange
                        summary.glucose = old.glucose
                        summary.glucoseDurations = old.glucoseDurations
                        summary.glucoseSource = old.glucoseSource
                        summary.timeZone = old.timeZone
                        summary.isPartialDay = old.isPartialDay
                    }
                    if (summary.insulinRecordCount == 0 && old.insulinRecordCount > 0) || (summary.insulinIsPartial == true && old.insulinIsPartial != true && old.insulinUnits != nil) {
                        summary.insulinUnits = old.insulinUnits; summary.insulinRecordCount = old.insulinRecordCount
                        summary.insulinSource = old.insulinSource; summary.insulinIsPartial = old.insulinIsPartial
                    }
                    // Fewer records can mean a deletion or an expired/failed store.
                    // Only a complete refresh of the same source may remove carbs.
                    let sameCarbSource = (summary.carbSource ?? "Local records") == (old.carbSource ?? "Local records")
                    let replacesCarbs = summary.carbHistoryIsComplete == true && sameCarbSource
                    if !replacesCarbs && (summary.carbEntryCount < old.carbEntryCount || (summary.carbEntryCount == old.carbEntryCount && old.carbSource == "Nightscout" && summary.carbSource != "Nightscout")) {
                        summary.carbGrams = old.carbGrams; summary.carbEntryCount = old.carbEntryCount
                        summary.carbSource = old.carbSource
                        summary.carbHistoryIsComplete = old.carbHistoryIsComplete
                    }
                }
                state.summaries.removeAll { $0.day == summary.day }
                state.summaries.append(summary)
            }
            // Keep a year of compact daily records; notes are retained until deleted.
            state.summaries = Array(state.summaries.sorted { $0.day < $1.day }.suffix(400))
        }
    }
}

enum CycleComparisonAlignment: String, CaseIterable, Identifiable {
    case cycleDay, beforePeriod
    var id: String { rawValue }
    var title: String { self == .cycleDay ? "Cycle day" : "Before next period" }
}

struct CycleAlignedDay: Identifiable {
    var id: String { day }
    var day: String
    var offset: Int
    var summary: CycleDailySummary?
    var notes: [CycleJournalNote]
}

struct CycleComparison: Identifiable {
    var id: String { start }
    var start: String
    var isCurrent: Bool
    var days: [CycleAlignedDay]
}

struct CycleWindowEvidence: Codable {
    var cycleStart: String
    var days: [String]
    var meanMGDL: Double
    var baselineMGDL: Double
    var baselineDays: [String]
    var insulinPerRecordedDay: Double?
    var baselineInsulinPerRecordedDay: Double?
    var insulinDays = 0
    var baselineInsulinDays = 0
    var carbsPerLoggedDay: Double?
    var baselineCarbsPerLoggedDay: Double?
    var carbDays = 0
    var baselineCarbDays = 0
}

struct CycleInsight: Codable, Identifiable {
    var id: String
    var text: String
    var noteIDs: [UUID]
    var supportingDays: [String]
    var evidence: [CycleWindowEvidence]
    var basis: String
}

/// Transparent within-person comparisons, never a diagnosis or dosing algorithm.
enum CyclePatternEngine {
    static func comparisons(starts: [Date], summaries: [CycleDailySummary], notes: [CycleJournalNote],
                            alignment: CycleComparisonAlignment, now: Date = Date(), calendar: Calendar = .current) -> [CycleComparison] {
        let anchors = Array(Set(starts.map { calendar.startOfDay(for: $0) })).filter { $0 <= now }.sorted()
        guard !anchors.isEmpty else { return [] }
        let summaryMap = Dictionary(summaries.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let noteMap = Dictionary(grouping: notes, by: \.day)
        return anchors.indices.suffix(6).compactMap { index in
            let start = anchors[index]
            let next = index + 1 < anchors.count ? anchors[index + 1] : nil
            let length = next.flatMap { calendar.dateComponents([.day], from: start, to: $0).day }
            if let length, !(15...60).contains(length) { return nil }
            if alignment == .beforePeriod && next == nil { return nil }
            let last = next.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? calendar.startOfDay(for: now)
            guard let elapsed = calendar.dateComponents([.day], from: start, to: last).day, elapsed >= 0 else { return nil }
            let days: [CycleAlignedDay] = (0...min(59, elapsed)).compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                let key = CycleDay.key(date, calendar: calendar)
                return CycleAlignedDay(day: key, offset: alignment == .cycleDay ? day + 1 : day - (length ?? 0),
                                       summary: summaryMap[key], notes: noteMap[key] ?? [])
            }
            return CycleComparison(start: CycleDay.key(start, calendar: calendar), isCurrent: next == nil, days: days)
        }
    }

    static func insights(starts: [Date], estimatedLength: Int, journal: CycleJournalState,
                         now: Date = Date(), calendar: Calendar = .current) -> [CycleInsight] {
        let cycles = comparisons(starts: starts, summaries: journal.summaries, notes: journal.notes, alignment: .cycleDay, now: now, calendar: calendar)
        guard let current = cycles.last, current.isCurrent,
              let start = CycleDay.date(current.start, calendar: calendar),
              let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day,
              elapsed >= 0, elapsed < estimatedLength, !journal.notes.isEmpty || !journal.summaries.isEmpty else { return [] }
        let day = elapsed + 1
        // Five-day windows tolerate small timing changes. Current cycle never supports its own prediction.
        let previous = cycles.filter { !$0.isCurrent }
        let window = max(1, day - 2)...(day + 2)
        var results: [CycleInsight] = []
        for tag in CycleNoteTag.allCases {
            let matching = previous.map { cycle in
                cycle.days.filter { window.contains($0.offset) }.flatMap(\.notes).filter { $0.tags.contains(tag) }
            }.filter { !$0.isEmpty }
            guard !matching.isEmpty else { continue }
            let notes = matching.flatMap { $0 }
            let count = matching.count
            let prefix = count == 1 ? "In a previous cycle, you noted" : "In \(count) previous cycles, you noted"
            results.append(CycleInsight(id: current.start + ":" + tag.rawValue,
                text: "\(prefix) ‘\(tag.title.lowercased())’ around cycle days \(window.lowerBound)–\(window.upperBound). These are your reports; this cycle may differ.",
                noteIDs: notes.map(\.id), supportingDays: Array(Set(notes.map(\.day))).sorted(), evidence: [], basis: "user_report"))
        }
        if results.isEmpty, let last = previous.last {
            let notes = last.days.filter { window.contains($0.offset) }.flatMap(\.notes)
            if !notes.isEmpty {
                results.append(CycleInsight(id: current.start + ":recall", text: "You left notes around these days last cycle. Take a look at what you noticed then.",
                    noteIDs: notes.map(\.id), supportingDays: Array(Set(notes.map(\.day))).sorted(), evidence: [], basis: "user_report"))
            }
        }
        let evidence: [CycleWindowEvidence] = previous.compactMap { cycle in
            let matched = cycle.days.filter { window.contains($0.offset) && $0.summary?.usableForPatterns == true }
            let baseline = cycle.days.filter { !window.contains($0.offset) && $0.summary?.usableForPatterns == true }
            // Product heuristics, not statistical significance or clinical confidence.
            guard matched.count >= 3, baseline.count >= 7 else { return nil }
            let mean = matched.compactMap { $0.summary?.meanMGDL }.reduce(0, +) / Double(matched.count)
            let reference = baseline.compactMap { $0.summary?.meanMGDL }.reduce(0, +) / Double(baseline.count)
            let insulin = matched.filter { $0.summary?.insulinIsPartial != true }.compactMap { $0.summary?.insulinUnits }
            let baselineInsulin = baseline.filter { $0.summary?.insulinIsPartial != true }.compactMap { $0.summary?.insulinUnits }
            let carbs = matched.compactMap { $0.summary?.carbGrams }
            let baselineCarbs = baseline.compactMap { $0.summary?.carbGrams }
            func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            return CycleWindowEvidence(cycleStart: cycle.start, days: matched.map(\.day), meanMGDL: mean, baselineMGDL: reference, baselineDays: baseline.map(\.day),
                insulinPerRecordedDay: average(insulin), baselineInsulinPerRecordedDay: average(baselineInsulin), insulinDays: insulin.count, baselineInsulinDays: baselineInsulin.count,
                carbsPerLoggedDay: average(carbs), baselineCarbsPerLoggedDay: average(baselineCarbs), carbDays: carbs.count, baselineCarbDays: baselineCarbs.count)
        }
        // Contradictory eligible cycles suppress a directional claim instead of being cherry-picked.
        for higher in [true, false] {
            guard evidence.count >= 2, evidence.allSatisfy({ higher ? $0.meanMGDL - $0.baselineMGDL >= 10 : $0.baselineMGDL - $0.meanMGDL >= 10 }) else { continue }
            results.insert(CycleInsight(id: current.start + ":glucose", text: "In \(evidence.count) previous cycles, recorded glucose averaged \(higher ? "higher" : "lower") around cycle days \(window.lowerBound)–\(window.upperBound) than on other well-recorded days in those cycles. This is an association, not a forecast or a measure of insulin resistance.",
                noteIDs: previous.flatMap(\.days).filter { window.contains($0.offset) }.flatMap(\.notes).map(\.id),
                supportingDays: evidence.flatMap(\.days), evidence: evidence, basis: "recorded_glucose"), at: 0)
        }
        return results.filter { (journal.hiddenInsights[$0.id] ?? .distantPast) <= now }
    }
}
