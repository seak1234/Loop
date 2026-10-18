import Foundation

enum CompanionCycleIntent {
    static func matches(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["cycle", "cycles", "period", "periods", "menstrual", "menstruation", "pms", "pmdd", "ovulation", "luteal", "follicular", "hormones", "hormonal", "cravings"])
    }
}

enum CompanionReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case providerDefault = "default"
    case none, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .providerDefault: return "Model default"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        default: return rawValue.capitalized
        }
    }
}

struct CompanionModel: Decodable, Identifiable, Equatable {
    struct Reasoning: Decodable, Equatable {
        var supportedEfforts: [String]?
        var exposesEffortSelection: Bool
        var mandatory: Bool
        private enum CodingKeys: String, CodingKey { case supportedEfforts = "supported_efforts", mandatory }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exposesEffortSelection = container.contains(.supportedEfforts)
            supportedEfforts = try container.decodeIfPresent([String].self, forKey: .supportedEfforts)
            mandatory = try container.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
        }
        init(supportedEfforts: [String]?, exposesEffortSelection: Bool, mandatory: Bool) {
            self.supportedEfforts = supportedEfforts
            self.exposesEffortSelection = exposesEffortSelection
            self.mandatory = mandatory
        }
    }
    struct Architecture: Decodable, Equatable {
        var input_modalities: [String]?
        var output_modalities: [String]?
    }
    var id: String
    var name: String
    var supported_parameters: [String]
    var architecture: Architecture?
    var reasoning: Reasoning?

    var isChatToolModel: Bool {
        supported_parameters.contains("tools") && !id.hasSuffix(":batch") &&
            architecture?.input_modalities?.contains("text") == true &&
            architecture?.output_modalities?.contains("text") == true
    }

    var efforts: [CompanionReasoningEffort] {
        guard let reasoning, reasoning.exposesEffortSelection else { return [.providerDefault] }
        let allowed = reasoning.supportedEfforts ?? CompanionReasoningEffort.allCases.map(\.rawValue)
        return [.providerDefault] + CompanionReasoningEffort.allCases.filter {
            $0 != .providerDefault && allowed.contains($0.rawValue) && !(reasoning.mandatory && $0 == .none)
        }
    }

    // Verified fallback for offline setup. A successful catalog refresh replaces it.
    static let gpt61 = CompanionModel(id: "openai/gpt-6.1-sol", name: "OpenAI: GPT-6.1 Sol",
        supported_parameters: ["tools", "reasoning"],
        architecture: Architecture(input_modalities: ["text", "image"], output_modalities: ["text"]),
        reasoning: Reasoning(supportedEfforts: ["low", "medium", "high", "xhigh", "max"], exposesEffortSelection: true, mandatory: true))
}

enum CompanionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct CompanionMessage: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var date = Date()
    var includesHealthData: Bool?
}

/// A read-only snapshot: logged bleeding dates and estimated hormonal phases are
/// deliberately different fields. No symptoms or insulin resistance are inferred.
struct CompanionCycleContext: Encodable {
    enum Phase: String, Encodable { case unknown, period, follicular, ovulation, luteal }
    struct Period: Encodable {
        var startDate: Date
        var endDate: Date?
    }
    struct Education: Encodable {
        var topic: String
        var summary: String
        var sourceTitle: String
        var sourceURL: String
    }

    var asOf: Date
    var timeZone: String
    var hasLoggedPeriods: Bool
    var recordedPeriodCount: Int
    var cycleDay: Int?
    var phase: Phase
    var phaseBasis: String
    var phaseIsEstimate: Bool
    var estimatedCycleLengthDays: Int?
    var cycleLengthBasis: String
    var usableRecordedIntervalDays: [Int]
    var estimatedNextPeriodStart: Date?
    var periodEndNotLogged: Bool
    var recentPeriods: [Period]
    var symptomDataAvailable = false
    var notes: [String]
    let generalEducation = [
        Education(topic: "Cycle, glucose and insulin sensitivity",
            summary: "Hormonal changes can affect insulin sensitivity. Some people see higher glucose before their period, but effects vary between people and cycles. Compare recorded glucose, insulin delivery and meal context before describing a personal association; these data do not measure insulin resistance or prove its cause.",
            sourceTitle: "Diabetes UK — Periods and diabetes",
            sourceURL: "https://www.diabetes.org.uk/living-with-diabetes/life-with-diabetes/periods"),
        Education(topic: "Energy, mood, sleep and cravings",
            summary: "PMS can include fatigue, sleep difficulties, mood changes, bloating, cramps, and appetite changes or cravings. Experiences vary. Ask what the person notices. Offer manageable comfort, rest and routine suggestions based on their preferences, without assuming symptoms or recommending insulin changes.",
            sourceTitle: "NHS — PMS (premenstrual syndrome)",
            sourceURL: "https://www.nhs.uk/conditions/pre-menstrual-syndrome/")
    ]

    init(asOf: Date, cycleDay: Int?, phase: Phase, cycleLength: Int,
         nextPeriodStart: Date?, periods: [Period], calendar: Calendar = .current) {
        self.asOf = asOf
        timeZone = calendar.timeZone.identifier
        let today = calendar.startOfDay(for: asOf)
        let recorded = periods.filter { calendar.startOfDay(for: $0.startDate) <= today }.map { entry -> Period in
            let observedEnd = entry.endDate.flatMap { end -> Date? in
                guard calendar.startOfDay(for: end) <= today, end >= entry.startDate else { return nil }
                return end
            }
            return Period(startDate: entry.startDate, endDate: observedEnd)
        }.sorted { $0.startDate < $1.startDate }
        recordedPeriodCount = recorded.count
        hasLoggedPeriods = !recorded.isEmpty
        recentPeriods = Array(recorded.suffix(6))
        self.cycleDay = hasLoggedPeriods ? cycleDay : nil
        self.phase = hasLoggedPeriods && cycleDay != nil ? phase : .unknown
        let intervals = zip(recorded, recorded.dropFirst()).compactMap { a, b -> Int? in
            guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: a.startDate), to: calendar.startOfDay(for: b.startDate)).day,
                  (15...60).contains(days) else { return nil }
            return days
        }
        usableRecordedIntervalDays = Array(intervals.suffix(6))
        estimatedCycleLengthDays = hasLoggedPeriods ? cycleLength : nil
        cycleLengthBasis = !hasLoggedPeriods ? "unavailable_no_logged_periods" :
            (intervals.isEmpty ? "app_default_not_personal_history" : "calendar_estimate_from_logged_start_intervals")
        let latest = recorded.last
        periodEndNotLogged = latest != nil && latest?.endDate == nil
        let confirmedBleeding = self.phase == .period && recorded.contains { entry in
            guard let end = entry.endDate else { return false }
            return today >= calendar.startOfDay(for: entry.startDate) && today <= calendar.startOfDay(for: end)
        }
        if self.phase == .unknown { phaseBasis = "timing_uncertain_or_no_recorded_anchor" }
        else if confirmedBleeding { phaseBasis = "within_user_logged_period_start_and_end" }
        else if self.phase == .period && periodEndNotLogged { phaseBasis = "period_start_logged_end_unconfirmed" }
        else { phaseBasis = "calendar_estimate_not_confirmed_by_hormone_or_ovulation_measurements" }
        phaseIsEstimate = !confirmedBleeding
        estimatedNextPeriodStart = hasLoggedPeriods && self.phase != .unknown ? nextPeriodStart : nil
        notes = [
            "Source: period dates logged in this app. Phase estimates are not confirmation of ovulation, hormone levels, fertility, or insulin resistance.",
            "Energy, mood, sleep and cravings are not recorded by this tracker. Ask the user about their own experience.",
            "No glucose or insulin comparison has been performed in this snapshot. Use those read tools for matching dates before describing a personal pattern."
        ]
        if !hasLoggedPeriods { notes.append("No periods have been logged. Do not infer a cycle day, phase, or a personal cycle length.") }
        if hasLoggedPeriods && intervals.isEmpty { notes.append("The cycle length uses the app default; there is not enough usable history to establish the person's typical length.") }
        if periodEndNotLogged { notes.append("The latest period has no logged end. This does not establish continued bleeding today.") }
        if self.phase == .unknown && hasLoggedPeriods { notes.append("Timing is uncertain. Ask whether period dates need updating instead of projecting a new cycle.") }
    }
}

struct CompanionRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case dailySummary, fallingGlucose, missedCarbs
    }
    var id = UUID()
    var kind: Kind
    var title: String
    var enabled = true
    var hour: Int?
    var minute: Int?
    var timeZone: String?
    var belowMGDL: Double?
    /// Positive magnitude; falling rules compare to the negative of this value.
    var rateMGDLPerMinute: Double?
    var windowMinutes: Double?
    var carbLookbackMinutes: Double?
    var cooldownMinutes: Double?

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120 else {
            throw CompanionError.invalid("Give this rule a title of 1–120 characters.")
        }
        if kind == .dailySummary {
            guard let hour, (0...23).contains(hour), let minute, (0...59).contains(minute),
                  let timeZone, TimeZone(identifier: timeZone) != nil else {
                throw CompanionError.invalid("Choose a time and a valid time zone for the daily review.")
            }
        } else {
            guard let rate = rateMGDLPerMinute, rate.isFinite, (0.1...10).contains(rate),
                  let window = windowMinutes, window.isFinite, (10...30).contains(window),
                  let cooldown = cooldownMinutes, cooldown.isFinite, (15...1440).contains(cooldown) else {
                throw CompanionError.invalid("Specify a rate of 0.1–10 mg/dL/min, a 10–30 minute window, and a 15–1440 minute cooldown.")
            }
            if kind == .fallingGlucose {
                guard let below = belowMGDL, below.isFinite, (40...400).contains(below) else {
                    throw CompanionError.invalid("Specify the glucose threshold in mg/dL (40–400).")
                }
            } else {
                guard let lookback = carbLookbackMinutes, lookback.isFinite, (15...240).contains(lookback) else {
                    throw CompanionError.invalid("Specify how far to look back for carbs (15–240 minutes).")
                }
            }
        }
    }

    var detail: String {
        if kind == .dailySummary {
            return String(format: "Daily at %02d:%02d", hour ?? 0, minute ?? 0) + " · \(timeZone ?? "")\nReminder to open your review; the summary refreshes when opened."
        }
        let rate = String(format: "%.1f", rateMGDLPerMinute ?? 0)
        let window = Int(windowMinutes ?? 0)
        let cooldown = Int(cooldownMinutes ?? 0)
        if kind == .fallingGlucose {
            return "Below \(Int(belowMGDL ?? 0)) mg/dL, falling at least \(rate) mg/dL/min over \(window) minutes. Cooldown: \(cooldown) minutes."
        }
        return "Rising at least \(rate) mg/dL/min over \(window) minutes, with no carbs logged in the past \(Int(carbLookbackMinutes ?? 0)) minutes. Cooldown: \(cooldown) minutes."
    }
}

struct CompanionGlucosePoint: Equatable {
    var date: Date
    var mgdl: Double
}

struct CompanionRuleRuntime: Codable {
    var lastEvaluated: Date?
    var lastFired: Date?
    var latched = false
}

enum CompanionRuleEvaluator {
    /// No interpolation across gaps, future readings, stale data, or duplicate timestamps.
    static func slope(points: [CompanionGlucosePoint], windowMinutes: Double, now: Date) -> Double? {
        let sorted = points.filter { $0.date <= now && $0.mgdl.isFinite && (20...600).contains($0.mgdl) }
            .sorted { $0.date < $1.date }
        guard let last = sorted.last, now.timeIntervalSince(last.date) <= 600 else { return nil }
        let cutoff = last.date.addingTimeInterval(-windowMinutes * 60)
        let values = sorted.filter { $0.date >= cutoff }
        guard values.count >= 3, let first = values.first,
              last.date.timeIntervalSince(first.date) >= windowMinutes * 60 * 0.8 else { return nil }
        for (a, b) in zip(values, values.dropFirst()) {
            let gap = b.date.timeIntervalSince(a.date)
            guard gap > 0, gap <= 420 else { return nil }
        }
        let times = values.map { $0.date.timeIntervalSince(first.date) / 60 }
        let meanTime = times.reduce(0, +) / Double(times.count)
        let meanGlucose = values.map(\.mgdl).reduce(0, +) / Double(values.count)
        let denominator = times.reduce(0) { $0 + pow($1 - meanTime, 2) }
        guard denominator > 0 else { return nil }
        return zip(times, values).reduce(0) { $0 + ($1.0 - meanTime) * ($1.1.mgdl - meanGlucose) } / denominator
    }

    /// A condition fires once per episode; it must clear before it can fire again.
    static func evaluate(_ rule: CompanionRule, points: [CompanionGlucosePoint], carbDates: [Date],
                         now: Date, runtime: inout CompanionRuleRuntime) -> Bool {
        guard rule.enabled, rule.kind != .dailySummary, (try? rule.validate()) != nil,
              let last = points.filter({ $0.date <= now }).max(by: { $0.date < $1.date }),
              last.mgdl.isFinite, (20...600).contains(last.mgdl),
              runtime.lastEvaluated.map({ last.date > $0 }) ?? true,
              let slope = slope(points: points, windowMinutes: rule.windowMinutes!, now: now) else { return false }
        runtime.lastEvaluated = last.date
        let matches: Bool
        if rule.kind == .fallingGlucose {
            matches = last.mgdl < rule.belowMGDL! && slope <= -rule.rateMGDLPerMinute!
        } else {
            let cutoff = now.addingTimeInterval(-rule.carbLookbackMinutes! * 60)
            matches = slope >= rule.rateMGDLPerMinute! && !carbDates.contains { $0 >= cutoff && $0 <= now }
        }
        guard matches else { runtime.latched = false; return false }
        guard !runtime.latched, runtime.lastFired.map({ now.timeIntervalSince($0) >= rule.cooldownMinutes! * 60 }) ?? true else { return false }
        runtime.latched = true
        runtime.lastFired = now
        return true
    }
}

struct CompanionCarbDraft: Codable, Equatable {
    var grams: Double
    var date: Date
    var absorptionHours: Double

    func validate(now: Date = Date()) throws {
        guard grams.isFinite, grams > 0, grams <= 250,
              absorptionHours.isFinite, (0.5...8).contains(absorptionHours),
              date >= now.addingTimeInterval(-12 * 3600), date <= now.addingTimeInterval(3600) else {
            throw CompanionError.invalid("Review the carb amount (1–250 g), time (past 12 hours to next hour), and absorption (0.5–8 hours).")
        }
    }
}

struct CompanionAction: Codable, Identifiable {
    enum Status: String, Codable { case pending, applied, declined, openedForReview }
    var id = UUID()
    var title: String
    var rule: CompanionRule?
    var replacingID: UUID?
    var originalRule: CompanionRule?
    var carb: CompanionCarbDraft?
    var personality: String?
    var status: Status = .pending
    var date = Date()
}

struct CompanionEventRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
}

struct CompanionTopic: Codable, Equatable, Identifiable {
    var title: String
    var prompt: String
    var id: String { title }

    static func decodeSuggestions(_ text: String) throws -> [CompanionTopic] {
        struct Response: Decodable { var topics: [CompanionTopic] }
        guard text.utf8.count <= 4000 else { throw CompanionError.invalid("Topic response is too long.") }
        let topics = try JSONDecoder().decode(Response.self, from: Data(text.utf8)).topics
        let titles = topics.map { $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        guard topics.count == 2, Set(titles).count == 2,
              Set(titles).isDisjoint(with: ["pep talk", "review today", "cycle insights"]),
              topics.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 28 &&
                  $0.title.split(whereSeparator: \.isWhitespace).count <= 4 && !$0.title.contains("\n") &&
                  !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.prompt.count <= 350 }) else {
            throw CompanionError.invalid("Mochi could not create two short topics.")
        }
        return topics
    }
}

struct CompanionDashboardMessage: Codable {
    var text: String
    var generatedAt: Date
    var includesHealthData: Bool
    // Missing on older cached messages, which should be regenerated in the shorter style.
    var styleVersion: Int? = CompanionDashboardRefresh.styleVersion
    var factID: String?
}

/// Conservative permission to celebrate recent readings, not a clinical assessment or alert.
struct CompanionGlucoseEncouragement: Codable {
    let canCelebrateRecentTarget: Bool
    let basis: String

    init(points: [CompanionGlucosePoint], now: Date, lower: Double?, upper: Double?, safetyFloor: Double = 70, sourceIsReliable: Bool = true) {
        guard sourceIsReliable else {
            canCelebrateRecentTarget = false; basis = "Recent manual or display-only readings prevent a reliable CGM-only comparison."; return
        }
        guard let lower, let upper, lower.isFinite, upper.isFinite, safetyFloor.isFinite,
              lower >= max(70, safetyFloor), upper >= lower else {
            canCelebrateRecentTarget = false; basis = "No usable configured target."; return
        }
        let recent = points.filter { $0.date >= now.addingTimeInterval(-1800) && $0.date <= now }.sorted { $0.date < $1.date }
        guard recent.count >= 5, let first = recent.first, let last = recent.last,
              now.timeIntervalSince(last.date) <= 600, last.date.timeIntervalSince(first.date) >= 1440,
              recent.allSatisfy({ $0.mgdl.isFinite && $0.mgdl >= lower && $0.mgdl <= upper }),
              zip(recent, recent.dropFirst()).allSatisfy({
                  let gap = $1.date.timeIntervalSince($0.date)
                  return gap > 0 && gap <= 420
              }) else {
            canCelebrateRecentTarget = false; basis = "Recent data are missing, incomplete, stale, or outside the configured target."; return
        }
        let previous = recent[recent.count - 2]
        let recentRate = (last.mgdl - previous.mgdl) / (last.date.timeIntervalSince(previous.date) / 60)
        guard recentRate > -1 else {
            canCelebrateRecentTarget = false; basis = "Recent readings are falling; do not celebrate them as settled."; return
        }
        canCelebrateRecentTarget = true
        basis = "Available CGM readings span at least 24 of the last 30 minutes, with no gap over 7 minutes, and are all within the current configured target. This does not establish a whole-day result or its cause."
    }
}

struct CompanionDashboardFact: Encodable, Identifiable {
    let id: String
    let fact: String
    let source: URL

    static let catalog: [Self] = [
        .init(id: "insulin-nobel-1923", fact: "The discovery of insulin was recognized with the 1923 Nobel Prize in Physiology or Medicine.", source: URL(string: "https://www.nobelprize.org/prizes/medicine/1923/summary/")!),
        .init(id: "insulin-chemistry-1958", fact: "Frederick Sanger received the 1958 Chemistry Nobel Prize for work on protein structure, especially insulin.", source: URL(string: "https://www.nobelprize.org/prizes/chemistry/1958/summary/")!),
        .init(id: "cgm-between-cells", fact: "CGMs estimate glucose in fluid between cells rather than measuring blood directly.", source: URL(string: "https://www.niddk.nih.gov/health-information/diabetes/overview/managing-diabetes/continuous-glucose-monitoring")!),
        .init(id: "pancreatic-islets", fact: "Insulin-producing beta cells live in pancreatic cell clusters called islets.", source: URL(string: "https://www.niddk.nih.gov/health-information/diabetes/overview/what-is-diabetes/type-1-diabetes")!),
        .init(id: "t1d-any-age", fact: "Type 1 diabetes can develop at any age, including adulthood.", source: URL(string: "https://www.niddk.nih.gov/health-information/diabetes/overview/what-is-diabetes/type-1-diabetes")!),
        .init(id: "protein-later-glucose", fact: "Protein can be converted to glucose slowly; low-carb meals are not necessarily glucose-neutral.", source: URL(string: "https://www.diabetesincontrol.com/the-diabetes-diet-chapter-3-part-1/")!)
    ]

    static func next(cursor: Int?) -> Self { catalog[max(0, cursor ?? 0) % catalog.count] }
}

enum CompanionDashboardKind: String {
    case motivation, insight, fact

    static func next(rotation: Int?, allowHealthData: Bool) -> Self {
        if rotation == 3 { return .fact }
        return allowHealthData && rotation == 2 ? .insight : .motivation
    }
}

enum CompanionDashboardRefresh {
    static let styleVersion = 6
    static let maximumCharacters = 90
    static let maximumWords = 12

    static func isConcise(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maximumCharacters && text.split(whereSeparator: \.isWhitespace).count <= maximumWords
    }

    static let regularInterval: TimeInterval = 15 * 60
    static let minimumInterval: TimeInterval = 5 * 60
    static let maximumDisplayAge: TimeInterval = 30 * 60

    static func isDue(message: CompanionDashboardMessage?, lastAttempt: Date?, dataChanged: Bool, now: Date, calendar: Calendar = .current) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        guard let message else { return true }
        if message.styleVersion != styleVersion || !isConcise(message.text) { return true }
        let age = now.timeIntervalSince(message.generatedAt)
        return age < 0 || age >= regularInterval || dataChanged || !calendar.isDate(message.generatedAt, inSameDayAs: now)
    }

    static func isDisplayable(_ message: CompanionDashboardMessage, now: Date) -> Bool {
        let age = now.timeIntervalSince(message.generatedAt)
        return message.styleVersion == styleVersion && isConcise(message.text) && age >= 0 && age < maximumDisplayAge
    }
}

struct CompanionState: Codable {
    var version = 1
    var personality = "Talk like a kind, down-to-earth friend. Use simple words, contractions and a little gentle humor when it fits. Help me make sense of diabetes without lecturing, canned pep talks or guilt."
    var model = "openai/gpt-6.1-sol"
    // Optional so state saved by the first version continues to decode unchanged.
    var reasoningEffort: CompanionReasoningEffort? = .medium
    var allowHealthData = false
    var dashboardMessage: CompanionDashboardMessage?
    var dashboardRotation: Int?
    var dashboardFactCursor: Int?
    var messages: [CompanionMessage] = []
    var rules: [CompanionRule] = []
    var actions: [CompanionAction] = []
    var events: [CompanionEventRecord] = []
    var runtime: [String: CompanionRuleRuntime] = [:]
}

/// Store the whole transaction atomically. Never silently replace unreadable history with empty state.
final class CompanionStateStore {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> CompanionState {
        guard FileManager.default.fileExists(atPath: url.path) else { return CompanionState() }
        let state = try JSONDecoder().decode(CompanionState.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw CompanionError.invalid("This companion data needs a newer app version.") }
        return state
    }

    func save(_ state: CompanionState) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
