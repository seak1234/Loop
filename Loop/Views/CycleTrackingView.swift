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

    private init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
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
        let day = calendar.startOfDay(for: date)
        guard let anchor = periodEntry(anchoring: day) else {
            return nil
        }

        guard let difference = calendar.dateComponents([.day], from: anchor.startDate, to: day).day else {
            return nil
        }

        return (difference % cycleLength) + 1
    }

    func summary(on date: Date = Date()) -> Summary {
        guard let cycleDay = cycleDay(on: date) else {
            return Summary(
                cycleDay: nil,
                cycleLength: cycleLength,
                phaseName: NSLocalizedString("Cycle tracking", comment: "Cycle summary phase before a period is logged"),
                detail: NSLocalizedString("Cycle tracking", comment: "Cycle summary phase before a period is logged"),
                nextPhaseDetail: NSLocalizedString("Tap My period started", comment: "Cycle summary prompt before a period is logged"),
                progress: 0
            )
        }

        let phase = phaseName(for: cycleDay, on: date)
        return Summary(
            cycleDay: cycleDay,
            cycleLength: cycleLength,
            phaseName: phase,
            detail: phase,
            nextPhaseDetail: nextPhaseDetail(for: cycleDay, on: date),
            progress: Double(cycleDay) / Double(cycleLength)
        )
    }

    private func nextPhaseDetail(for cycleDay: Int, on date: Date) -> String {
        let activePeriodLength = periodLength(forCycleContaining: date)
        let ovulationDay = max(activePeriodLength + 2, cycleLength - 14)
        let nextPhaseDay: Int
        let nextPhaseName: String

        if cycleDay <= activePeriodLength {
            nextPhaseDay = activePeriodLength + 1
            nextPhaseName = NSLocalizedString("Follicular", comment: "Menstrual cycle follicular phase")
        } else if cycleDay < ovulationDay - 1 {
            nextPhaseDay = ovulationDay - 1
            nextPhaseName = NSLocalizedString("Ovulation", comment: "Menstrual cycle ovulation phase")
        } else if cycleDay <= ovulationDay + 1 {
            nextPhaseDay = ovulationDay + 2
            nextPhaseName = NSLocalizedString("Luteal", comment: "Menstrual cycle luteal phase")
        } else {
            nextPhaseDay = cycleLength + 1
            nextPhaseName = NSLocalizedString("Period", comment: "Menstrual cycle period phase")
        }

        let days = max(1, nextPhaseDay - cycleDay)
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

    private func phaseName(for cycleDay: Int, on date: Date) -> String {
        localizedName(for: phase(for: cycleDay, on: date))
    }

    func phase(for date: Date) -> Phase? {
        let day = calendar.startOfDay(for: date)
        guard let cycleDay = cycleDay(on: day) else {
            return nil
        }

        let phase = phase(for: cycleDay, on: day)
        if phase == .period,
           periodEntry(anchoring: day)?.endDate == nil,
           day > calendar.startOfDay(for: Date())
        {
            return nil
        }
        return phase
    }

    private func phase(for cycleDay: Int, on date: Date) -> Phase {
        let activePeriodLength = periodLength(forCycleContaining: date)
        let ovulationDay = max(activePeriodLength + 2, cycleLength - 14)

        if cycleDay <= activePeriodLength {
            return .period
        } else if cycleDay < ovulationDay - 1 {
            return .follicular
        } else if cycleDay <= ovulationDay + 1 {
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
            return NSLocalizedString("Ovulation", comment: "Menstrual cycle ovulation phase")
        case .luteal:
            return NSLocalizedString("Luteal", comment: "Menstrual cycle luteal phase")
        }
    }

    func marker(for date: Date) -> Marker? {
        if isRecordedPeriodDay(date) {
            return .period
        }

        let day = calendar.startOfDay(for: date)
        guard let cycleDay = cycleDay(on: day) else {
            return nil
        }

        let activePeriodLength = periodLength(forCycleContaining: day)
        let ovulationDay = max(activePeriodLength + 2, cycleLength - 14)
        if cycleDay <= activePeriodLength {
            if periodEntry(anchoring: day)?.endDate == nil && day > calendar.startOfDay(for: Date()) {
                return nil
            }
            return .period
        }
        if cycleDay == ovulationDay {
            return .ovulation
        }
        if ((ovulationDay - 3)...(ovulationDay + 2)).contains(cycleDay) {
            return .fertile
        }
        return nil
    }

    func nextPeriodDate(from date: Date = Date()) -> Date? {
        guard let cycleDay = cycleDay(on: date) else {
            return nil
        }

        return calendar.date(
            byAdding: .day,
            value: cycleLength - cycleDay + 1,
            to: calendar.startOfDay(for: date)
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

    private func periodLength(forCycleContaining date: Date) -> Int {
        guard let entry = periodEntry(anchoring: calendar.startOfDay(for: date)) else {
            return periodLength
        }
        if entry.endDate == nil {
            if calendar.startOfDay(for: date) <= calendar.startOfDay(for: Date()) {
                return max(periodLength, cycleDay(on: date) ?? periodLength)
            }
            return periodLength
        }
        guard let endDate = entry.endDate,
              let days = calendar.dateComponents([.day], from: entry.startDate, to: endDate).day
        else {
            return periodLength
        }
        return min(10, max(1, days + 1))
    }

    private func isRecordedPeriodDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        return periodEntries.contains { entry in
            let end = entry.endDate ?? today
            return day >= entry.startDate && day <= end
        }
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

    @ObservedObject private var store = CycleTrackingStore.shared
    @State private var displayedMonth: Date
    @State private var selectedDate: Date
    @State private var showsPeriodConfirmation = false
    @State private var showsPeriodEditor = false
    @State private var confirmationTitle = ""

    init(onDataChanged: @escaping () -> Void = {}) {
        self.onDataChanged = onDataChanged
        let today = Calendar.current.startOfDay(for: Date())
        _displayedMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: today)?.start ?? today)
        _selectedDate = State(initialValue: today)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                phaseCard
                calendarCard
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
    }

    @Environment(\.colorScheme) private var colorScheme

    private var coral: Color { Color(uiColor: .dashboardCoral) }
    private var ink: Color { Color(uiColor: .dashboardInk) }
    private var mutedInk: Color { Color(uiColor: .dashboardMutedInk) }
    private var surface: Color { Color(uiColor: .dashboardSurface) }
    private var border: Color { Color(uiColor: .dashboardBorder) }
    private var gold: Color { Color(red: 0.89, green: 0.61, blue: 0.20) }

    private var summary: CycleTrackingStore.Summary {
        store.summary()
    }

    private var phaseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cycleDay = summary.cycleDay {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(NSLocalizedString("DAY", comment: "Cycle day heading"))
                                .font(.system(size: 25, weight: .medium, design: .serif))
                                .tracking(3)
                            Text("\(cycleDay)")
                                .font(.system(size: 66, weight: .light, design: .serif))
                                .monospacedDigit()
                        }
                        .foregroundStyle(ink)

                        Text(summary.phaseName.uppercased())
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .tracking(3)
                            .foregroundStyle(coral)

                        Text(
                            String(
                                format: NSLocalizedString("Cycle day %d of %d", comment: "Current cycle day and cycle length"),
                                cycleDay,
                                summary.cycleLength
                            )
                        )
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(mutedInk)
                    }
                    .layoutPriority(1)

                    if let phase = store.phase(for: Date()) {
                        insulinSensitivityCallout(for: phase)
                    }
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Start cycle tracking", comment: "Cycle tracker empty state title"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        Text(NSLocalizedString("Tap My period started when your period begins.", comment: "Cycle tracker empty state instructions"))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(mutedInk)
                    }
                } icon: {
                    CycleCalendarDropIcon()
                        .frame(width: 34, height: 34)
                }
            }

            phaseProgressBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(cardBackground)
    }

    private func insulinSensitivityCallout(for phase: CycleTrackingStore.Phase) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .bold))
                Text(NSLocalizedString("INSULIN SENSITIVITY", comment: "Cycle phase insulin sensitivity insight heading"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.7)
            }
            .foregroundStyle(coral)

            Text(insulinSensitivityInsight(for: phase))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            phaseColor(phase).opacity(colorScheme == .dark ? 0.58 : 0.72),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(border.opacity(0.8), lineWidth: 1)
        }
    }

    private func insulinSensitivityInsight(for phase: CycleTrackingStore.Phase) -> String {
        switch phase {
        case .period:
            return NSLocalizedString(
                "You may be more sensitive to insulin as your period begins.",
                comment: "Insulin sensitivity insight for the menstrual period phase"
            )
        case .follicular:
            return NSLocalizedString(
                "Insulin sensitivity is often higher, so insulin may have a stronger effect.",
                comment: "Insulin sensitivity insight for the follicular phase"
            )
        case .ovulation:
            return NSLocalizedString(
                "Hormone shifts may change insulin sensitivity. Some people notice higher glucose.",
                comment: "Insulin sensitivity insight for the ovulation phase"
            )
        case .luteal:
            return NSLocalizedString(
                "Insulin sensitivity may decrease, especially before your period, so glucose may run higher.",
                comment: "Insulin sensitivity insight for the luteal phase"
            )
        }
    }

    private var phaseProgressBar: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let progress = summary.progress
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(phaseBarGradient.opacity(colorScheme == .dark ? 0.26 : 0.18))

                    phaseBarGradient
                        .frame(width: proxy.size.width)
                        .frame(width: proxy.size.width * progress, alignment: .leading)
                        .clipped()
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)

            HStack {
                Text(NSLocalizedString("Period", comment: "Cycle phase progress label"))
                Spacer()
                Text(NSLocalizedString("Follicular", comment: "Cycle phase progress label"))
                Spacer()
                Text(NSLocalizedString("Ovulation", comment: "Cycle phase progress label"))
                Spacer()
                Text(NSLocalizedString("Luteal", comment: "Cycle phase progress label"))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(mutedInk)
        }
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
            }
        }
        .padding(16)
        .background(cardBackground)
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
        let marker = store.marker(for: date)
        let phase = store.phase(for: date)
        let roundsLeadingEdge = phase.map { !phaseContinues(from: date, direction: -1, phase: $0) } ?? false
        let roundsTrailingEdge = phase.map { !phaseContinues(from: date, direction: 1, phase: $0) } ?? false

        return Button {
            selectedDate = date
        } label: {
            ZStack {
                if let phase {
                    CalendarPhaseBandShape(
                        roundsLeadingEdge: roundsLeadingEdge,
                        roundsTrailingEdge: roundsTrailingEdge
                    )
                    .fill(phaseColor(phase))
                }

                VStack(spacing: 3) {
                    ZStack {
                        if isSelected {
                            Circle().fill(coral)
                        }
                        if marker == .ovulation && !isSelected {
                            Circle().stroke(gold, lineWidth: 2)
                        }
                        Text("\(calendar.component(.day, from: date))")
                            .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : (isDisplayedMonth ? ink : mutedInk.opacity(0.45)))
                    }
                    .frame(width: 34, height: 34)

                    Circle()
                        .fill(markerColor(marker) ?? Color.clear)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 43)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                icon: "calendar",
                title: NSLocalizedString("Next period", comment: "Cycle tracker next period title"),
                value: store.daysUntilNextPeriod().map {
                    String(format: NSLocalizedString("%d days", comment: "Days until the next period"), $0)
                } ?? "—"
            )
            statCard(
                icon: "chart.bar.fill",
                title: NSLocalizedString("Cycle length", comment: "Cycle tracker cycle length title"),
                value: String(format: NSLocalizedString("%d days", comment: "Cycle length in days"), store.cycleLength)
            )
        }
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
                    NSLocalizedString("Edit previous period days", comment: "Button to edit saved period history"),
                    systemImage: "pencil"
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.periodEntries.isEmpty ? mutedInk : coral)
            .background(surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(store.periodEntries.isEmpty)
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
            Text(NSLocalizedString("Ovulation day", comment: "Cycle calendar exact ovulation day legend"))
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
                ? Color(red: 0.496, green: 0.483, blue: 0.517)
                : Color(red: 225.0 / 255.0, green: 229.0 / 255.0, blue: 244.0 / 255.0)
        case .ovulation:
            return isDark
                ? Color(red: 0.380, green: 0.263, blue: 0.139)
                : Color(red: 0.974, green: 0.895, blue: 0.789)
        case .luteal:
            return isDark
                ? Color(red: 0.283, green: 0.271, blue: 0.228)
                : Color(red: 0.923, green: 0.925, blue: 0.877)
        }
    }

    private var phaseBarGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: phaseColor(.period), location: 0),
                .init(color: phaseColor(.period), location: 0.18),
                .init(color: phaseColor(.follicular), location: 0.20),
                .init(color: phaseColor(.follicular), location: 0.43),
                .init(color: phaseColor(.ovulation), location: 0.46),
                .init(color: phaseColor(.ovulation), location: 0.56),
                .init(color: phaseColor(.luteal), location: 0.60),
                .init(color: phaseColor(.luteal), location: 1)
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
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
        return store.phase(for: adjacentDate) == phase
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

    private let onSave: ([CycleTrackingStore.PeriodEntry]) -> Void

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
                        "Correct the start and end dates for previously logged periods. Cycle phases and predictions update when you save.",
                        comment: "Instructions for editing cycle period history"
                    ))
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .dashboardMutedInk))
                }

                ForEach($draftEntries) { $entry in
                    Section {
                        DatePicker(
                            NSLocalizedString("Started", comment: "Period history start date label"),
                            selection: startDateBinding(for: $entry),
                            in: ...Date(),
                            displayedComponents: .date
                        )

                        Toggle(
                            NSLocalizedString("Period ended", comment: "Period history ended toggle"),
                            isOn: hasEndDateBinding(for: $entry)
                        )

                        if entry.endDate != nil {
                            DatePicker(
                                NSLocalizedString("Ended", comment: "Period history end date label"),
                                selection: endDateBinding(for: $entry),
                                in: entry.startDate...Date(),
                                displayedComponents: .date
                            )
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
            .navigationTitle(NSLocalizedString("Edit period days", comment: "Period history editor title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel period history edits")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Save", comment: "Save period history edits")) {
                        onSave(draftEntries)
                        dismiss()
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
