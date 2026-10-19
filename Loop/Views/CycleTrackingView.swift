//
//  CycleTrackingView.swift
//  Loop
//
//  Stores and presents a lightweight, on-device menstrual cycle tracker.
//

import LoopUI
import SwiftUI
import UIKit

final class CycleTrackingStore: ObservableObject {
    static let shared = CycleTrackingStore()

    struct PeriodEntry: Codable, Identifiable, Equatable {
        var id: UUID
        var startDate: Date
        var endDate: Date?

        init(id: UUID = UUID(), startDate: Date, endDate: Date? = nil) {
            self.id = id
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    struct Summary {
        let cycleDay: Int?
        let cycleLength: Int
        let phaseName: String
        let detail: String
        let nextPhaseDetail: String
        let progress: Double
        let phaseTransitions: [Double]?
    }

    enum Marker: Equatable {
        case period
        case fertile
        case ovulation
    }

    enum Phase: Equatable {
        case period
        case follicular
        case ovulation
        case luteal
    }

    private enum Keys {
        static let lastPeriodStart = "CycleTracking.lastPeriodStart"
        static let periodEntries = "CycleTracking.periodEntries"
    }

    @Published private(set) var periodEntries: [PeriodEntry]

    private let defaults: UserDefaults
    private var calendar: Calendar
    private let maximumUnconfirmedPeriodDays = 10

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        if
            let data = defaults.data(forKey: Keys.periodEntries),
            let entries = try? JSONDecoder().decode([PeriodEntry].self, from: data)
        {
            self.periodEntries = entries
        } else if let legacyStart = defaults.object(forKey: Keys.lastPeriodStart) as? Date {
            let start = calendar.startOfDay(for: legacyStart)
            let projectedEnd = calendar.date(byAdding: .day, value: 4, to: start) ?? start
            let end = min(projectedEnd, calendar.startOfDay(for: Date()))
            self.periodEntries = [PeriodEntry(startDate: start, endDate: max(start, end))]
        } else {
            self.periodEntries = []
        }
        self.periodEntries = normalized(periodEntries)
        persist()
    }

    var isPeriodInProgress: Bool {
        periodEntries.contains { $0.endDate == nil }
    }

    var cycleLength: Int {
        let starts = periodEntries.map(\.startDate).sorted()
        let intervals = zip(starts.dropLast(), starts.dropFirst()).compactMap { previous, next -> Int? in
            guard let days = calendar.dateComponents([.day], from: previous, to: next).day,
                  (15...60).contains(days)
            else {
                return nil
            }
            return days
        }
        guard !intervals.isEmpty else {
            return 28
        }
        return Int((Double(intervals.suffix(6).reduce(0, +)) / Double(min(6, intervals.count))).rounded())
    }

    var periodLength: Int {
        let lengths = periodEntries.compactMap { entry -> Int? in
            guard let endDate = entry.endDate,
                  let days = calendar.dateComponents([.day], from: entry.startDate, to: endDate).day
            else {
                return nil
            }
            let inclusiveLength = days + 1
            return (1...10).contains(inclusiveLength) ? inclusiveLength : nil
        }
        guard !lengths.isEmpty else {
            return 5
        }
        return Int((Double(lengths.suffix(6).reduce(0, +)) / Double(min(6, lengths.count))).rounded())
    }

    func startPeriod(on date: Date = Date()) {
        guard !isPeriodInProgress else {
            return
        }
        periodEntries.append(PeriodEntry(startDate: calendar.startOfDay(for: date)))
        periodEntries = normalized(periodEntries)
        persist()
    }

    func endCurrentPeriod(on date: Date = Date()) {
        guard let index = periodEntries.lastIndex(where: { $0.endDate == nil }) else {
            return
        }
        let end = max(periodEntries[index].startDate, calendar.startOfDay(for: date))
        periodEntries[index].endDate = end
        periodEntries = normalized(periodEntries)
        persist()
    }

    func replacePeriodEntries(with entries: [PeriodEntry]) {
        periodEntries = normalized(entries)
        persist()
    }

    func cycleDay(on date: Date = Date()) -> Int? {
        cycleContext(on: date)?.day
    }

    func summary(on date: Date = Date()) -> Summary {
        // Continue the calendar's estimates while the next period is awaiting a log.
        guard let context = projectedCycleContext(on: date) ?? cycleContext(on: date) else {
            return Summary(
                cycleDay: nil,
                cycleLength: cycleLength,
                phaseName: NSLocalizedString("Cycle tracking", comment: "Cycle summary phase before a period is logged"),
                detail: NSLocalizedString("Cycle tracking", comment: "Cycle summary phase before a period is logged"),
                nextPhaseDetail: NSLocalizedString("Tap My period started", comment: "Cycle summary prompt before a period is logged"),
                progress: 0,
                phaseTransitions: nil
            )
        }

        let phase = phase(for: context, on: date)
        let phaseName = phase.map { localizedName(for: $0) } ?? NSLocalizedString(
            "Timing uncertain", comment: "Cycle phase when a period has not been confirmed"
        )
        return Summary(
            cycleDay: context.day,
            cycleLength: context.length,
            phaseName: phaseName,
            detail: phaseName,
            nextPhaseDetail: nextPhaseDetail(for: context, phase: phase),
            progress: min(1, Double(context.day) / Double(context.length)),
            phaseTransitions: phaseTransitions(for: context)
        )
    }

    private func nextPhaseDetail(for context: CycleContext, phase: Phase?) -> String {
        if context.isOpen {
            return NSLocalizedString("Confirm period end", comment: "Prompt when a period is still open")
        }
        let isRecordedPeriod = phase == .period
        guard let phase, let ovulationDay = context.ovulationDay else {
            return context.day > context.length && !isRecordedPeriod
                ? NSLocalizedString("Log next period start", comment: "Cycle summary after an estimated period is overdue")
                : NSLocalizedString("Review period dates", comment: "Cycle summary when phase timing cannot be estimated")
        }

        let nextPhaseDay: Int
        let nextPhaseName: String

        switch phase {
        case .period:
            nextPhaseDay = context.periodLength + 1
            nextPhaseName = nextPhaseDay == ovulationDay - 1
                ? NSLocalizedString("Ovulation", comment: "Predicted menstrual cycle ovulation phase")
                : NSLocalizedString("Follicular", comment: "Menstrual cycle follicular phase")
        case .follicular:
            nextPhaseDay = ovulationDay - 1
            nextPhaseName = NSLocalizedString("Ovulation", comment: "Predicted menstrual cycle ovulation phase")
        case .ovulation:
            nextPhaseDay = ovulationDay + 2
            nextPhaseName = NSLocalizedString("Luteal", comment: "Menstrual cycle luteal phase")
        case .luteal:
            nextPhaseDay = context.length + 1
            nextPhaseName = NSLocalizedString("Period", comment: "Predicted next menstrual period")
        }

        let days = nextPhaseDay - context.day
        if days == 1 {
            return String(
                format: NSLocalizedString("1 day until %@", comment: "Countdown until the next menstrual cycle phase"),
                nextPhaseName
            )
        }
        return String(
            format: NSLocalizedString("%d days until %@", comment: "Countdown until the next menstrual cycle phase"),
            days,
            nextPhaseName
        )
    }

    func phase(for date: Date) -> Phase? {
        guard let context = cycleContext(on: date) else { return nil }
        return phase(for: context, on: date)
    }

    private func phase(for context: CycleContext, on date: Date) -> Phase? {
        if context.isOpen,
           calendar.startOfDay(for: date) <= calendar.startOfDay(for: Date()),
           context.day <= maximumUnconfirmedPeriodDays
        {
            return .period
        }
        // Keep forecasting with the usual period length until its end is logged.
        if context.day <= context.periodLength {
            return .period
        }
        guard context.day <= context.length, let ovulationDay = context.ovulationDay else {
            return nil
        }
        if context.day < ovulationDay - 1 {
            return .follicular
        } else if context.day <= ovulationDay + 1 {
            return .ovulation
        } else {
            return .luteal
        }
    }

    private func localizedName(for phase: Phase) -> String {
        switch phase {
        case .period:
            return NSLocalizedString("Period", comment: "Menstrual cycle period phase")
        case .follicular:
            return NSLocalizedString("Follicular", comment: "Menstrual cycle follicular phase")
        case .ovulation:
            return NSLocalizedString("Ovulation", comment: "Predicted menstrual cycle ovulation phase")
        case .luteal:
            return NSLocalizedString("Luteal", comment: "Menstrual cycle luteal phase")
        }
    }

    func marker(for date: Date) -> Marker? {
        if isRecordedPeriodDay(date) {
            return .period
        }

        guard let context = cycleContext(on: date) else { return nil }
        return marker(for: context, on: date)
    }

    func calendarPhase(for date: Date) -> Phase? {
        guard let context = projectedCycleContext(on: date) ?? cycleContext(on: date) else { return nil }
        return phase(for: context, on: date)
    }

    func noteContext(on date: Date) -> CycleNoteContext {
        guard let context = projectedCycleContext(on: date) ?? cycleContext(on: date) else { return CycleNoteContext() }
        let phase = phase(for: context, on: date)
        let notePhase: CycleNoteContext.Phase?
        let phaseStart: Int?
        switch phase {
        case .period: notePhase = .period; phaseStart = 1
        case .follicular: notePhase = .follicular; phaseStart = context.periodLength + 1
        case .ovulation: notePhase = .ovulation; phaseStart = context.ovulationDay.map { $0 - 1 }
        case .luteal: notePhase = .luteal; phaseStart = context.ovulationDay.map { $0 + 2 }
        case nil: notePhase = nil; phaseStart = nil
        }
        return CycleNoteContext(cycleDay: context.day, phase: notePhase,
            phaseDay: phaseStart.map { context.day - $0 + 1 },
            isEstimated: phase != .period || !isRecordedPeriodDay(date)
                || (context.isOpen && context.day > 1))
    }

    func noteContext(for note: CycleJournalNote) -> CycleNoteContext {
        // Resolve the note's civil day, rather than the day its timestamp falls
        // on after travel. Use the same projected context as the cycle calendar.
        let date = CycleDay.date(note.day, calendar: calendar) ?? note.occurredAt
        return (note.cycleContext ?? CycleNoteContext()).fillingMissing(from: noteContext(on: date))
    }

    func calendarMarker(for date: Date) -> Marker? {
        if isRecordedPeriodDay(date) { return .period }
        guard let context = projectedCycleContext(on: date) ?? cycleContext(on: date) else { return nil }
        return marker(for: context, on: date)
    }

    private func marker(for context: CycleContext, on date: Date) -> Marker? {
        guard phase(for: context, on: date) != nil else { return nil }

        if context.day <= context.periodLength {
            return .period
        }
        guard let ovulationDay = context.ovulationDay else { return nil }
        if context.day == ovulationDay {
            return .ovulation
        }
        if ((ovulationDay - 5)...(ovulationDay + 1)).contains(context.day) {
            return .fertile
        }
        return nil
    }

    func nextPeriodDate(from date: Date = Date()) -> Date? {
        guard let context = cycleContext(on: date),
              context.day <= context.length
        else { return nil }

        return calendar.date(
            byAdding: .day,
            value: context.length,
            to: context.anchor.startDate
        )
    }

    func daysUntilNextPeriod(from date: Date = Date()) -> Int? {
        guard let nextPeriodDate = nextPeriodDate(from: date) else {
            return nil
        }

        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: nextPeriodDate
        ).day
    }

    private func periodEntry(anchoring date: Date) -> PeriodEntry? {
        periodEntries
            .filter { $0.startDate <= date }
            .max { $0.startDate < $1.startDate }
    }

    private struct CycleContext {
        let anchor: PeriodEntry
        let day: Int
        let length: Int
        let periodLength: Int
        let isOpen: Bool

        var ovulationDay: Int? {
            guard (15...60).contains(length), periodLength < length - 3 else { return nil }
            let day = max(periodLength + 2, length - 14)
            return day + 1 < length ? day : nil
        }
    }

    private func cycleContext(on date: Date) -> CycleContext? {
        let day = calendar.startOfDay(for: date)
        guard let anchor = periodEntry(anchoring: day),
              let elapsed = calendar.dateComponents([.day], from: anchor.startDate, to: day).day
        else { return nil }

        let nextStart = periodEntries.first { $0.startDate > anchor.startDate }?.startDate
        let actualLength = nextStart.flatMap {
            calendar.dateComponents([.day], from: anchor.startDate, to: $0).day
        }
        let length = max(1, actualLength ?? cycleLength)
        let isOpen = anchor.endDate == nil && nextStart == nil
        let recordedEnd = anchor.endDate.map { end -> Date in
            guard let nextStart,
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: nextStart)
            else { return end }
            return min(end, lastDay)
        }
        let recordedLength = recordedEnd.flatMap {
            calendar.dateComponents([.day], from: anchor.startDate, to: $0).day
        }.map { max(1, $0 + 1) }

        return CycleContext(
            anchor: anchor,
            day: elapsed + 1,
            length: length,
            periodLength: recordedLength ?? periodLength,
            isOpen: isOpen
        )
    }

    private func projectedCycleContext(on date: Date) -> CycleContext? {
        guard let context = cycleContext(on: date),
              periodEntries.last?.id == context.anchor.id,
              context.day > context.length
        else { return nil }

        let length = context.length
        return CycleContext(
            anchor: context.anchor,
            day: (context.day - 1) % length + 1,
            length: length,
            periodLength: periodLength,
            isOpen: false
        )
    }

    private func phaseTransitions(for context: CycleContext) -> [Double]? {
        guard context.day <= context.length,
              let ovulationDay = context.ovulationDay
        else { return nil }

        let length = Double(context.length)
        return [
            Double(context.periodLength) / length,
            Double(ovulationDay - 2) / length,
            Double(ovulationDay + 1) / length
        ]
    }

    private func isRecordedPeriodDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        guard let context = cycleContext(on: day) else { return false }
        if context.isOpen {
            return day <= today && context.day <= maximumUnconfirmedPeriodDays
        }
        guard let end = context.anchor.endDate else { return false }
        return day <= end
    }

    static func historyValidationError(_ entries: [PeriodEntry], now: Date = Date(), calendar: Calendar = .current) -> String? {
        let today = calendar.startOfDay(for: now)
        let sorted = entries.sorted { $0.startDate < $1.startDate }
        for (index, entry) in sorted.enumerated() {
            let start = calendar.startOfDay(for: entry.startDate)
            if start > today { return "A period cannot start in the future." }
            if let end = entry.endDate {
                if calendar.startOfDay(for: end) < start || calendar.startOfDay(for: end) > today { return "Choose an end date between the period start and today." }
            } else if index != sorted.count - 1 { return "Only the most recent period can be ongoing. Add an end date to earlier periods." }
            if index + 1 < sorted.count {
                let next = calendar.startOfDay(for: sorted[index + 1].startDate)
                if next <= start { return "Two periods cannot have the same start date." }
                if let end = entry.endDate, calendar.startOfDay(for: end) >= next { return "Period dates overlap. Correct the dates before saving." }
            }
        }
        return nil
    }

    private func normalized(_ entries: [PeriodEntry]) -> [PeriodEntry] {
        var result = entries.map { entry in
            let start = calendar.startOfDay(for: entry.startDate)
            let end = entry.endDate.map { max(start, calendar.startOfDay(for: $0)) }
            return PeriodEntry(id: entry.id, startDate: start, endDate: end)
        }
        result.sort { $0.startDate < $1.startDate }

        if let latestOpenIndex = result.lastIndex(where: { $0.endDate == nil }) {
            for index in result.indices where result[index].endDate == nil && index != latestOpenIndex {
                result[index].endDate = result[index].startDate
            }
        }
        return result
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(periodEntries) else {
            return
        }
        defaults.set(data, forKey: Keys.periodEntries)
        defaults.removeObject(forKey: Keys.lastPeriodStart)
    }
}

struct CycleTrackingView: View {
    private let calendar = Calendar.current
    private let onDataChanged: () -> Void

    @ObservedObject private var journal = CycleJournalStore.shared
    @ObservedObject private var store = CycleTrackingStore.shared
    @State private var displayedMonth: Date
    @State private var selectedDate: Date
    @State private var showsPeriodConfirmation = false
    @State private var showsPeriodEditor = false
    @State private var confirmationTitle = ""
    @State private var journalPresentation: JournalPresentation?
    @State private var quickTags = Set<CycleNoteTag>()
    @State private var quickSaveError: String?
    @State private var quickSavedNoteID: UUID?

    private struct JournalPresentation: Identifiable {
        let id = UUID()
        let date: Date
        var addingNote = false
        var initialTags: [CycleNoteTag] = []
    }

    init(onDataChanged: @escaping () -> Void = {}) {
        self.onDataChanged = onDataChanged
        let today = Calendar.current.startOfDay(for: Date())
        _displayedMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: today)?.start ?? today)
        _selectedDate = State(initialValue: today)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.periodEntries.isEmpty { historyWelcome }
                CompanionCycleCard()
                calendarCard
                quickPickTagsCard
                statsRow
                periodActions
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background {
            ZStack {
                Color(uiColor: .dashboardBackground)

                Image("DashboardMarbleBackground")
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(x: -1, y: 1)
                    .opacity(colorScheme == .dark ? 0.08 : 0.44)
            }
            .ignoresSafeArea()
        }
        .navigationTitle(NSLocalizedString("Cycle", comment: "Cycle tracker navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(coral)
        .alert(
            confirmationTitle,
            isPresented: $showsPeriodConfirmation
        ) {
            Button(NSLocalizedString("OK", comment: "Dismiss cycle logging confirmation"), role: .cancel) {}
        } message: {
            Text(Date().formatted(date: .long, time: .omitted))
        }
        .sheet(isPresented: $showsPeriodEditor) {
            CyclePeriodHistoryEditor(entries: store.periodEntries) { entries in
                store.replacePeriodEntries(with: entries)
                onDataChanged()
            }
        }
        .sheet(item: $journalPresentation) { presentation in
            if presentation.addingNote {
                CycleNoteEditor(item: CycleNoteEditorItem(note: nil, date: presentation.date, initialTags: presentation.initialTags), journal: journal) {
                    quickTags.removeAll()
                    quickSavedNoteID = nil
                    onDataChanged()
                }
            } else {
                CycleJournalSheet(date: presentation.date, tracker: store)
            }
        }
        .onChange(of: selectedDate) { _ in
            quickTags.removeAll()
            quickSavedNoteID = nil
            quickSaveError = nil
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var coral: Color { Color(uiColor: .dashboardCoral) }
    private var ink: Color { Color(uiColor: .dashboardInk) }
    private var mutedInk: Color { Color(uiColor: .dashboardMutedInk) }
    private var surface: Color { Color(uiColor: .dashboardSurface) }
    private var border: Color { Color(uiColor: .dashboardBorder) }
    private var gold: Color { Color(red: 0.89, green: 0.61, blue: 0.20) }
    private var noteAccent: Color {
        colorScheme == .dark
            ? Color(red: 0.62, green: 0.23, blue: 0.33)
            : Color(red: 0.70, green: 0.27, blue: 0.38)
    }
    private var noteButtonSurface: Color { coral.opacity(colorScheme == .dark ? 0.10 : 0.06) }
    private var noteIconTint: Color { colorScheme == .dark ? coral : noteAccent }

    private var historyWelcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with your cycle history").font(.headline)
            Text("Add the periods you remember, starting with the most recent. Previous dates help place today in your cycle and make comparisons more useful.")
                .font(.subheadline).foregroundStyle(mutedInk)
            Button { showsPeriodEditor = true } label: {
                Label("Add previous periods", systemImage: "calendar.badge.plus")
                    .font(.subheadline.bold()).padding(.vertical, 8)
            }
            Text("You can add more dates later. No history yet? Use ‘My period started’ when it begins.")
                .font(.caption).foregroundStyle(mutedInk)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
    }

    private var calendarCard: some View {
        VStack(spacing: 14) {
            HStack {
                monthButton(systemName: "chevron.left", offset: -1)
                Spacer()
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Spacer()
                monthButton(systemName: "chevron.right", offset: 1)
            }

            HStack {
                ForEach(weekdaySymbols, id: \.self) { weekday in
                    Text(weekday.prefix(1))
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(mutedInk)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 7) {
                ForEach(monthDates, id: \.self) { date in
                    calendarDay(date)
                }
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    phaseLegendItem(
                        color: phaseColor(.period),
                        label: NSLocalizedString("Period", comment: "Cycle calendar legend")
                    )
                    phaseLegendItem(
                        color: phaseColor(.follicular),
                        label: NSLocalizedString("Follicular", comment: "Cycle calendar legend")
                    )
                    phaseLegendItem(
                        color: phaseColor(.ovulation),
                        label: NSLocalizedString("Ovulation", comment: "Cycle calendar legend")
                    )
                    phaseLegendItem(
                        color: phaseColor(.luteal),
                        label: NSLocalizedString("Luteal", comment: "Cycle calendar legend")
                    )
                }

                HStack(spacing: 18) {
                    legendItem(color: gold, label: NSLocalizedString("Fertile window", comment: "Cycle calendar legend"))
                    ovulationLegend
                }

                Text(NSLocalizedString(
                    "Unlogged cycles repeat as estimates based on logged periods.",
                    comment: "Cycle calendar prediction explanation"
                ))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var addNotesButton: some View {
        Button {
            journalPresentation = JournalPresentation(date: selectedDate, addingNote: true, initialTags: Array(quickTags))
        } label: {
            Label("Add notes", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .background(noteButtonSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(border, lineWidth: 0.75))
        .disabled(selectedDate > Date() || journal.failure != nil)
        .accessibilityHint("Add a cycle note for \(selectedDate.formatted(date: .complete, time: .omitted))")
    }

    private var quickPickTagsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(calendar.isDateInToday(selectedDate) ? "How are you feeling?" : "How did you feel?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
            if !calendar.isDateInToday(selectedDate) {
                Text(selectedDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(mutedInk)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(CycleNoteTag.availableTags) { tag in quickTagButton(tag) }
            }
            HStack(spacing: 8) {
                if !quickTags.isEmpty {
                    Button("Save tags") { saveQuickTags() }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.white)
                        .background(noteAccent, in: Capsule())
                        .buttonStyle(.plain)
                        .disabled(selectedDate > Date() || journal.failure != nil)
                }
                addNotesButton
            }
            if let id = quickSavedNoteID, journal.state.notes.contains(where: { $0.id == id }) {
                HStack {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                    Spacer()
                    Button("View note") { journalPresentation = JournalPresentation(date: selectedDate) }
                }
                .font(.caption).foregroundStyle(.primary)
            }
            if let quickSaveError { Text(quickSaveError).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func quickTagButton(_ tag: CycleNoteTag) -> some View {
        let selected = quickTags.contains(tag)
        return Button {
            if selected { quickTags.remove(tag) } else { quickTags.insert(tag) }
            quickSavedNoteID = nil
            quickSaveError = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark" : tag.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : noteIconTint)
                    .frame(width: 28, height: 28)
                    .background(selected ? noteAccent : coral.opacity(0.14), in: Circle())
                Text(quickTagTitle(tag))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(selected ? coral.opacity(0.22) : noteButtonSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? noteIconTint.opacity(0.5) : border, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(selectedDate > Date() || journal.failure != nil)
        .accessibilityLabel(tag.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func quickTagTitle(_ tag: CycleNoteTag) -> String {
        switch tag {
        case .sensitive: return "Insulin sensitive"
        case .resistant: return "Insulin resistant"
        default: return tag.title
        }
    }

    private func saveQuickTags() {
        guard !quickTags.isEmpty else { return }
        do {
            let date = calendar.isDateInToday(selectedDate) ? Date() : selectedDate
            let note = try journal.saveNote(date: date, text: "", tags: Array(quickTags), cycleContext: store.noteContext(on: date))
            quickSavedNoteID = note.id
            quickTags.removeAll()
            quickSaveError = nil
            onDataChanged()
        } catch { quickSaveError = error.localizedDescription }
    }

    private var monthDates: [Date] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
            let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start),
            let endAnchor = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
            let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: endAnchor)
        else {
            return []
        }

        var dates: [Date] = []
        var date = firstWeek.start
        let end = lastWeek.end
        while date < end {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                break
            }
            date = next
        }
        return dates
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }

    private func calendarDay(_ date: Date) -> some View {
        let isDisplayedMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let marker = store.calendarMarker(for: date)
        let phase = store.calendarPhase(for: date)
        let roundsLeadingEdge = phase.map { !phaseContinues(from: date, direction: -1, phase: $0) } ?? false
        let roundsTrailingEdge = phase.map { !phaseContinues(from: date, direction: 1, phase: $0) } ?? false

        return Button {
            selectedDate = date
            journalPresentation = JournalPresentation(date: date)
        } label: {
            ZStack {
                if let phase {
                    CalendarPhaseBandShape(
                        roundsLeadingEdge: roundsLeadingEdge,
                        roundsTrailingEdge: roundsTrailingEdge
                    )
                    .fill(phaseColor(phase))
                }

                ZStack {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(coral)
                                .frame(width: 30, height: 30)
                        }
                        if marker == .ovulation && !isSelected {
                            Circle()
                                .stroke(gold, lineWidth: 2)
                                .frame(width: 30, height: 30)
                        }
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : (isDisplayedMonth ? ink : mutedInk.opacity(0.45)))
                    }
                    .frame(width: 34, height: 34)

                    HStack(spacing: 3) {
                        if !journal.notes(on: date).isEmpty {
                            Circle().fill(ink).frame(width: 4, height: 4)
                        }
                        if let color = markerColor(marker) {
                            Circle().fill(color).frame(width: 5, height: 5)
                        }
                    }
                    .frame(height: 5)
                    .offset(y: 17)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (journal.notes(on: date).isEmpty ? "" : ", has cycle notes"))
        .accessibilityHint("Open this day's cycle journal")
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                icon: "calendar",
                title: NSLocalizedString("Next period", comment: "Cycle tracker next period title"),
                value: nextPeriodValue
            )
            statCard(
                icon: "chart.bar.fill",
                title: NSLocalizedString("Cycle length", comment: "Cycle tracker cycle length title"),
                value: String(format: NSLocalizedString("%d days", comment: "Cycle length in days"), store.cycleLength)
            )
        }
    }

    private var nextPeriodValue: String {
        if let days = store.daysUntilNextPeriod() {
            return String(format: NSLocalizedString("%d days", comment: "Days until the next period"), days)
        }
        if store.periodEntries.isEmpty { return "—" }
        if store.isPeriodInProgress {
            return NSLocalizedString("Confirm end", comment: "Next period timing while the current period is still open")
        }
        return NSLocalizedString("Estimate passed", comment: "Next period timing after the estimate has passed")
    }

    private func statCard(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(coral)
                .frame(width: 42, height: 42)
                .background(coral.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(mutedInk)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(cardBackground)
    }

    private var periodActions: some View {
        VStack(spacing: 10) {
            Button {
                if store.isPeriodInProgress {
                    store.endCurrentPeriod()
                    confirmationTitle = NSLocalizedString("Period ended", comment: "Confirmation after recording the end of a period")
                } else {
                    store.startPeriod()
                    confirmationTitle = NSLocalizedString("Period started", comment: "Confirmation after recording the start of a period")
                }
                onDataChanged()
                showsPeriodConfirmation = true
            } label: {
                Text(store.isPeriodInProgress
                    ? NSLocalizedString("My period ended", comment: "Button to record the end of a period")
                    : NSLocalizedString("My period started", comment: "Button to record the start of a period"))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(coral)
            .background(surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(coral, lineWidth: 1.5)
            }

            Button {
                showsPeriodEditor = true
            } label: {
                Label(
                    NSLocalizedString("Add or edit previous periods", comment: "Button to add or edit saved period history"),
                    systemImage: "pencil"
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(coral)
            .background(surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(surface.opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .shadow(color: mutedInk.opacity(colorScheme == .dark ? 0 : 0.08), radius: 4, y: 2)
    }

    private func monthButton(systemName: String, offset: Int) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                displayedMonth = month
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(coral)
        .accessibilityLabel(offset < 0
            ? NSLocalizedString("Previous month", comment: "Cycle calendar navigation")
            : NSLocalizedString("Next month", comment: "Cycle calendar navigation"))
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(mutedInk)
    }

    private func phaseLegendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 8)
            Text(label)
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(mutedInk)
    }

    private var ovulationLegend: some View {
        HStack(spacing: 5) {
            Circle().stroke(gold, lineWidth: 2).frame(width: 11, height: 11)
            Text(NSLocalizedString("Ovulation day", comment: "Cycle calendar predicted ovulation day legend"))
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(mutedInk)
    }

    private func markerColor(_ marker: CycleTrackingStore.Marker?) -> Color? {
        switch marker {
        case .period:
            return nil
        case .fertile:
            return gold
        case .ovulation:
            return gold
        case nil:
            return nil
        }
    }

    private func phaseColor(_ phase: CycleTrackingStore.Phase) -> Color {
        let isDark = colorScheme == .dark
        switch phase {
        case .period:
            return isDark
                ? Color(red: 0.402, green: 0.239, blue: 0.254)
                : Color(red: 0.978, green: 0.871, blue: 0.869)
        case .follicular:
            return isDark
                ? Color(red: 0.283, green: 0.271, blue: 0.228)
                : Color(red: 0.923, green: 0.925, blue: 0.877)
        case .ovulation:
            return isDark
                ? Color(red: 0.380, green: 0.263, blue: 0.139)
                : Color(red: 0.974, green: 0.895, blue: 0.789)
        case .luteal:
            return isDark
                ? Color(red: 0.496, green: 0.483, blue: 0.517)
                : Color(red: 225.0 / 255.0, green: 229.0 / 255.0, blue: 244.0 / 255.0)
        }
    }

    private func phaseContinues(
        from date: Date,
        direction: Int,
        phase: CycleTrackingStore.Phase
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let positionInWeek = (weekday - calendar.firstWeekday + 7) % 7
        guard (direction < 0 && positionInWeek > 0) || (direction > 0 && positionInWeek < 6),
              let adjacentDate = calendar.date(byAdding: .day, value: direction, to: date)
        else {
            return false
        }
        return store.calendarPhase(for: adjacentDate) == phase
    }
}

private struct CalendarPhaseBandShape: Shape {
    let roundsLeadingEdge: Bool
    let roundsTrailingEdge: Bool

    func path(in rect: CGRect) -> Path {
        var corners: UIRectCorner = []
        if roundsLeadingEdge {
            corners.formUnion([.topLeft, .bottomLeft])
        }
        if roundsTrailingEdge {
            corners.formUnion([.topRight, .bottomRight])
        }
        return Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: 14, height: 14)
            ).cgPath
        )
    }
}

private struct CyclePeriodHistoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draftEntries: [CycleTrackingStore.PeriodEntry]
    @State private var validationError: String?

    private let onSave: ([CycleTrackingStore.PeriodEntry]) -> Void

    private var latestEntryID: UUID? {
        draftEntries.max { $0.startDate < $1.startDate }?.id
    }

    init(
        entries: [CycleTrackingStore.PeriodEntry],
        onSave: @escaping ([CycleTrackingStore.PeriodEntry]) -> Void
    ) {
        _draftEntries = State(initialValue: entries.sorted { $0.startDate > $1.startDate })
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(NSLocalizedString(
                        "Add the periods you remember or correct existing dates. Choose the actual start and end dates before saving. Cycle estimates and journal comparisons update when you save.",
                        comment: "Instructions for editing cycle period history"
                    ))
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .dashboardMutedInk))
                }

                Section {
                    Button {
                        let calendar = Calendar.current
                        let anchor = draftEntries.map(\.startDate).min() ?? calendar.startOfDay(for: Date())
                        let start = calendar.date(byAdding: .day, value: -28, to: anchor)!
                        let end = calendar.date(byAdding: .day, value: 4, to: start)!
                        draftEntries.insert(.init(startDate: start, endDate: end), at: 0)
                    } label: { Label("Add a previous period", systemImage: "calendar.badge.plus") }
                }
                if let validationError { Section { Text(validationError).foregroundColor(.red) } }
                ForEach($draftEntries) { $entry in
                    Section {
                        DatePicker(
                            NSLocalizedString("Started", comment: "Period history start date label"),
                            selection: startDateBinding(for: $entry),
                            in: ...Date(),
                            displayedComponents: .date
                        )

                        if entry.id == latestEntryID {
                            Toggle(
                                NSLocalizedString("Period ended", comment: "Period history ended toggle"),
                                isOn: hasEndDateBinding(for: $entry)
                            )
                        }

                        if entry.endDate != nil || entry.id != latestEntryID {
                            DatePicker(
                                NSLocalizedString("Ended", comment: "Period history end date label"),
                                selection: endDateBinding(for: $entry),
                                in: entry.startDate...Date(),
                                displayedComponents: .date
                            )
                            if entry.endDate == nil {
                                Text("Choose an end date for this earlier period.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            draftEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Label(
                                NSLocalizedString("Delete period", comment: "Delete a saved period entry"),
                                systemImage: "trash"
                            )
                        }
                    } header: {
                        Text(entry.startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Period history", comment: "Period history editor title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel period history edits")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Save", comment: "Save period history edits")) {
                        if let message = CycleTrackingStore.historyValidationError(draftEntries) {
                            validationError = message
                        } else {
                            onSave(draftEntries)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func startDateBinding(
        for entry: Binding<CycleTrackingStore.PeriodEntry>
    ) -> Binding<Date> {
        Binding(
            get: { entry.wrappedValue.startDate },
            set: { newStart in
                entry.wrappedValue.startDate = newStart
                if let end = entry.wrappedValue.endDate, end < newStart {
                    entry.wrappedValue.endDate = newStart
                }
            }
        )
    }

    private func hasEndDateBinding(
        for entry: Binding<CycleTrackingStore.PeriodEntry>
    ) -> Binding<Bool> {
        Binding(
            get: { entry.wrappedValue.endDate != nil },
            set: { hasEnded in
                let today = Calendar.current.startOfDay(for: Date())
                entry.wrappedValue.endDate = hasEnded ? max(entry.wrappedValue.startDate, today) : nil
            }
        )
    }

    private func endDateBinding(
        for entry: Binding<CycleTrackingStore.PeriodEntry>
    ) -> Binding<Date> {
        Binding(
            get: { entry.wrappedValue.endDate ?? entry.wrappedValue.startDate },
            set: { entry.wrappedValue.endDate = max(entry.wrappedValue.startDate, $0) }
        )
    }
}

private struct CycleCalendarDropIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "calendar")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color(uiColor: .dashboardCoral))
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Circle()
                .fill(Color(uiColor: .dashboardCoral))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .accessibilityHidden(true)
    }
}
