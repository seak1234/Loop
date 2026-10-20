import SwiftUI

@MainActor
struct CycleJournalSheet: View {
    let date: Date
    @ObservedObject var tracker: CycleTrackingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                CycleJournalDayView(date: date, tracker: tracker)
                    .padding(14)
            }
            .background(Color(uiColor: .dashboardBackground))
            .navigationTitle("Cycle journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

@MainActor
struct CycleJournalDayView: View {
    let date: Date
    @ObservedObject var tracker: CycleTrackingStore
    @ObservedObject private var journal = CycleJournalStore.shared
    @ObservedObject private var controller = CompanionController.shared
    @State private var editor: CycleNoteEditorItem?
    @State private var showsSettings = false
    @State private var insight: CycleInsight?
    @State private var error: String?

    private var observations: [CycleInsight] {
        guard journal.state.showPersonalReminders else { return [] }
        return CyclePatternEngine.insights(starts: tracker.periodEntries.map(\.startDate), estimatedLength: tracker.cycleLength, journal: journal.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Cycle journal", systemImage: "book.closed").font(.headline)
                Spacer()
                Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Cycle journal settings")
            }
            if let failure = journal.failure { Text(failure).font(.footnote).foregroundColor(.red) }
            if let observation = observations.first {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Mochi noticed", systemImage: "sparkles").font(.subheadline.bold())
                    Text(observation.text).font(.callout)
                    HStack {
                        Button("See supporting records") { insight = observation }
                        Spacer()
                        Menu {
                            Button("Snooze for 3 days") { hide(observation, days: 3) }
                            Button("Doesn’t fit this cycle") { hide(observation, days: tracker.cycleLength + 7) }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("Observation feedback")
                    }.font(.footnote)
                }
                .padding(12).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
            Text(date.formatted(date: .complete, time: .omitted)).font(.subheadline.bold())
            Text(tracker.summary(on: date).cycleDay.map { "Cycle day \($0) · \(tracker.summary(on: date).phaseName)" } ?? "Log a period start to place this day in your cycle.")
                .font(.caption).foregroundColor(.secondary)
            if let summary = journal.summary(on: date) {
                CycleDailySummaryView(summary: summary)
            } else {
                Text("No records for this day yet. Available Nightscout history will be included when connected.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            ForEach(journal.notes(on: date)) { note in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(note.occurredAt.formatted(date: .omitted, time: .shortened))
                        if note.source == "mochi" { Text("Saved with Mochi") }
                        if note.source == "nightscout" { Text("From Nightscout") }
                        Spacer()
                        Button("Edit") { editor = CycleNoteEditorItem(note: note, date: note.occurredAt) }
                    }.font(.caption).foregroundColor(.secondary)
                    Text(note.displayText).textSelection(.enabled)
                    if !note.text.isEmpty && !note.tags.isEmpty { Text(note.tags.map(\.title).joined(separator: " · ")).font(.caption).foregroundColor(.secondary) }
                    Text(tracker.noteContext(for: note).summaryText).font(.caption).foregroundColor(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            Button { editor = CycleNoteEditorItem(note: nil, date: date) } label: {
                Label("Add note", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(date > Date() || journal.failure != nil)
            if controller.isCollectingCycleData { ProgressView("Updating records…").font(.caption) }
            if let message = controller.cycleDataError { Text(message).font(.caption).foregroundColor(.secondary) }
            if controller.isSyncingCycleNotes { ProgressView("Syncing cycle notes…").font(.caption) }
            if let message = controller.cycleNoteSyncError { Text(message).font(.caption).foregroundColor(.secondary) }
            if (journal.state.noteSync?.conflictCopies ?? 0) > 0 {
                Text("Some notes changed in both places. Both versions were kept; review your journal.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundColor(.red) }
        }
        .padding(16)
        .background(Color(uiColor: .dashboardSurface), in: RoundedRectangle(cornerRadius: 20))
        .sheet(item: $editor) { item in CycleNoteEditor(item: item, journal: journal) }
        .sheet(isPresented: $showsSettings) { CycleJournalSettings(journal: journal) }
        .sheet(item: $insight) { item in CycleInsightDetail(insight: item, journal: journal) }
        .task(id: CycleDay.key(date)) {
            await controller.refreshCycleSummaries()
            await controller.refreshOlderCycleDay(date)
        }
        .onChange(of: journal.state.retainDailySummaries) { enabled in
            if enabled { Task { await controller.refreshCycleSummaries(force: true) } }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            Task { await controller.syncCycleNotes() }
        }
    }

    private func hide(_ observation: CycleInsight, days: Int) {
        do { try journal.update { $0.hiddenInsights[observation.id] = Calendar.current.date(byAdding: .day, value: days, to: Date()) } }
        catch { self.error = error.localizedDescription }
    }
}

struct CycleNoteEditorItem: Identifiable {
    var id: UUID { note?.id ?? draftID }
    private let draftID = UUID()
    var note: CycleJournalNote?
    var date: Date
    var initialTags: [CycleNoteTag] = []
}

struct CycleNoteEditor: View {
    let item: CycleNoteEditorItem
    @ObservedObject var journal: CycleJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var date: Date
    @State private var tags: Set<CycleNoteTag>
    @State private var error: String?
    @State private var confirmsDelete = false
    private let onSave: () -> Void

    init(item: CycleNoteEditorItem, journal: CycleJournalStore, onSave: @escaping () -> Void = {}) {
        self.item = item; self.journal = journal
        self.onSave = onSave
        _text = State(initialValue: item.note?.text ?? "")
        _date = State(initialValue: min(item.note?.occurredAt ?? item.date, Date()))
        _tags = State(initialValue: Set(item.note?.tags ?? item.initialTags))
    }

    var body: some View {
        NavigationView {
            Form {
                DatePicker("When", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Section(header: Text("Your note (optional)"), footer: Text("Select a tag, write a note, or do both. Notes about insulin sensitivity reflect how you felt, not a measured diagnosis.")) {
                    TextEditor(text: $text).frame(minHeight: 130).accessibilityLabel("Cycle note")
                    Text("\(text.count)/6,000").font(.caption).foregroundColor(text.count > 6000 ? .red : .secondary)
                }
                Section(header: Text("Optional tags")) {
                    ForEach(CycleNoteTag.availableTags) { tag in
                        Toggle(tag.title, isOn: Binding(get: { tags.contains(tag) }, set: { enabled in
                            if enabled { tags.insert(tag) } else { tags.remove(tag) }
                        }))
                    }
                }
                if item.note != nil {
                    Section { Button("Delete note", role: .destructive) { confirmsDelete = true } }
                }
                if let error { Text(error).foregroundColor(.red) }
            }
            .navigationTitle(item.note == nil ? "Add cycle note" : "Edit cycle note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try journal.saveNote(id: item.note?.id, date: date, text: text, tags: Array(tags), cycleContext: automaticCycleContext)
                            onSave()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tags.isEmpty) || text.count > 6000)
                }
            }
            .alert("Delete this note?", isPresented: $confirmsDelete) {
                Button("Delete", role: .destructive) {
                    guard let id = item.note?.id else { return }
                    do { try journal.deleteNote(id); dismiss() } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Cycle comparisons will update without this note.") }
        }.navigationViewStyle(.stack)
    }
    private var automaticCycleContext: CycleNoteContext {
        if let original = item.note, CycleDay.key(date) == CycleDay.key(original.occurredAt) {
            // Preserve synced values on ordinary edits and fill any missing fields.
            let note = journal.state.notes.first(where: { $0.id == original.id }) ?? original
            return CycleTrackingStore.shared.noteContext(for: note)
        }
        // Resolve at save time so new notes and date changes use current history.
        return CycleTrackingStore.shared.noteContext(on: date)
    }
}

struct CycleSavedNoteCards: View {
    let ids: [UUID]
    @ObservedObject var journal: CycleJournalStore
    @ObservedObject private var tracker = CycleTrackingStore.shared
    @State private var editing: CycleNoteEditorItem?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in
                if let note = journal.state.notes.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Saved cycle note · \(note.day)", systemImage: "checkmark.circle")
                            .font(.caption.bold())
                        Text(note.displayText).font(.callout)
                        Text(tracker.noteContext(for: note).summaryText).font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Edit") { editing = CycleNoteEditorItem(note: note, date: note.occurredAt) }
                            Button("Undo save", role: .destructive) {
                                do { try journal.deleteNote(id) } catch { self.error = error.localizedDescription }
                            }
                        }.font(.caption)
                    }.padding(12).background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                } else { Text("Cycle note removed").font(.caption).foregroundColor(.secondary) }
            }
            if let error { Text(error).font(.caption).foregroundColor(.red) }
        }
        .sheet(item: $editing) { item in CycleNoteEditor(item: item, journal: journal) }
    }
}

/// A successful write remains reviewable even if the provider's follow-up fails or is stopped.
struct CycleUnlinkedSavedNotes: View {
    let since: Date?
    let linkedIDs: [UUID]
    @ObservedObject var journal: CycleJournalStore
    private var ids: [UUID] {
        guard let since else { return [] }
        return journal.state.notes.filter { $0.source == "mochi" && $0.createdAt >= since && !linkedIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }.map(\.id)
    }
    var body: some View { CycleSavedNoteCards(ids: ids, journal: journal) }
}

struct CycleDailySummaryView: View {
    @ObservedObject private var graphSettings = GlucoseGraphSettingsStore.shared
    let summary: CycleDailySummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.isPartialDay ? "Recorded so far" : "Recorded that day").font(.subheadline.bold())
            if summary.glucose.count > 1 {
                CycleGlucoseSparkline(readings: summary.glucose).frame(height: 75)
                    .accessibilityLabel("Retained glucose trace in mg/dL. Gaps longer than 20 minutes are not connected.")
            }
            HStack(alignment: .top) {
                metric("Mean glucose", summary.meanMGDL.map { String(format: "%.0f mg/dL", $0) } ?? "—")
                metric("Time in range", summary.timeInRange(using: graphSettings.settings).map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                metric("Day coverage", String(format: "%.0f%%", summary.coverage * 100))
            }
            HStack {
                metric(summary.insulinIsPartial == true ? "Boluses logged" : "Insulin recorded", summary.insulinUnits.map { String(format: "%.1f U", $0) } ?? "—")
                metric("Carbs logged", summary.carbGrams.map { String(format: "%.0f g", $0) } ?? "—")
            }
            DisclosureGroup("About these records") {
                Text(sources)
                Text("Glucose statistics cover observed readings only; coverage is the portion of the full calendar day with readings. Time in range uses the glucose range in Glucose → Settings. Missing means unknown. The trace retains one reading per 15 minutes.")
                if summary.insulinIsPartial == true {
                    Text("Nightscout insulin shows logged boluses only. Basal delivery is not included.")
                } else {
                    Text("Insulin and carb records may be incomplete.")
                }
            }.font(.caption).foregroundColor(.secondary)
        }
    }
    private var sources: String {
        let glucose = summary.meanMGDL == nil ? "Unavailable" : (summary.glucoseSource ?? "Local records")
        let insulin = summary.insulinUnits == nil ? "Unavailable" : (summary.insulinSource ?? "Local records")
        let carbs = summary.carbGrams == nil ? "Unavailable" : (summary.carbSource ?? "Local records")
        return "Sources: glucose — \(glucose); insulin — \(insulin); carbs — \(carbs)."
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption2).foregroundColor(.secondary); Text(value).font(.callout.bold()) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CycleGlucoseSparkline: View {
    let readings: [CycleGlucoseReading]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard let first = readings.first, let last = readings.last else { return }
                let duration = max(1, last.date.timeIntervalSince(first.date))
                let lower = min(60, readings.map(\.mgdl).min() ?? 60)
                let upper = max(180, readings.map(\.mgdl).max() ?? 180)
                for (index, reading) in readings.enumerated() {
                    let point = CGPoint(x: geometry.size.width * reading.date.timeIntervalSince(first.date) / duration,
                                        y: geometry.size.height * (1 - (reading.mgdl - lower) / (upper - lower)))
                    if index == 0 || reading.date.timeIntervalSince(readings[index - 1].date) > 1200 { path.move(to: point) }
                    else { path.addLine(to: point) }
                }
            }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}

struct CycleJournalSettings: View {
    @ObservedObject var journal: CycleJournalStore
    @ObservedObject private var controller = CompanionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmsClear = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Nightscout notes"), footer: Text("Share all existing and new cycle notes, including text and tags, with your connected Nightscout site. People who can view its treatments may see them. Edits and deletions sync both ways while this app is active. To add a cycle note in Nightscout, start a Note with [Cycle]. Keep the note footer when editing; its cycle day, phase and phase day can be edited in either place. Turning sync off keeps existing copies in both places. Period history is not uploaded.")) {
                    Toggle("Sync cycle notes with Nightscout", isOn: Binding(
                        get: { controller.cycleNoteSyncEnabled },
                        set: { controller.setCycleNoteSyncEnabled($0) }))
                    if controller.cycleNoteSyncEnabled {
                        Button("Sync now") { Task { await controller.syncCycleNotes(force: true) } }
                            .disabled(controller.isSyncingCycleNotes)
                        if controller.isSyncingCycleNotes { ProgressView("Syncing cycle notes…") }
                        if let source = journal.state.noteSync?.enabledSourceID,
                           let last = journal.state.noteSync?.sites[source]?.lastSyncedAt {
                            Text("Last synced: \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let message = controller.cycleNoteSyncError { Text(message).font(.footnote).foregroundColor(.secondary) }
                    if (journal.state.noteSync?.conflictCopies ?? 0) > 0 {
                        Text("Notes changed in both places. Both versions were kept, including edits that conflicted with a deletion.")
                            .font(.footnote)
                        Button("Dismiss conflict notice") {
                            do { try journal.update { $0.noteSync?.conflictCopies = 0 } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Section(header: Text("On this device"), footer: Text("Keep up to 400 compact daily glucose, insulin and carb summaries for comparisons. Available Nightscout history is imported automatically using your existing connection, with local records as a fallback. Notes remain until you delete them; clearing Mochi chats does not remove this journal.")) {
                    Toggle("Retain daily records", isOn: setting(\.retainDailySummaries))
                    Toggle("Show personal cycle reminders", isOn: setting(\.showPersonalReminders))
                }
                Section(header: Text("Mochi access"), footer: Text("These permissions also require health sharing in Mochi settings. Relevant notes and recorded summaries are sent to OpenRouter and your selected model when requested in chat. Saving permission lets Mochi add notes only when you ask. Existing transmitted content cannot be recalled.")) {
                    Toggle("Let Mochi read my cycle journal", isOn: setting(\.allowMochiRead))
                    Toggle("Let Mochi save notes when I ask", isOn: setting(\.allowMochiWrite))
                }
                Section {
                    Button("Clear retained daily records", role: .destructive) { confirmsClear = true }
                } footer: { Text("Your notes and period dates are kept. Turn off retention first if you do not want available records collected again.") }
                if let failure = journal.failure { Text(failure).foregroundColor(.red) }
                if let error { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Cycle journal settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Clear daily records?", isPresented: $confirmsClear) {
                Button("Clear", role: .destructive) { do { try journal.update { $0.summaries = [] } } catch { self.error = error.localizedDescription } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Retained glucose, insulin and carb summaries will be deleted from this journal.") }
        }.navigationViewStyle(.stack)
    }
    private func setting(_ path: WritableKeyPath<CycleJournalState, Bool>) -> Binding<Bool> {
        Binding(get: { journal.state[keyPath: path] }, set: { value in
            do { try journal.update { $0[keyPath: path] = value } } catch { self.error = error.localizedDescription }
        })
    }
}

struct CycleComparisonView: View {
    @ObservedObject var tracker: CycleTrackingStore
    @ObservedObject var journal: CycleJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var alignment = CycleComparisonAlignment.cycleDay
    @State private var metric = 0
    @State private var selectedDay: String?
    private var cycles: [CycleComparison] {
        CyclePatternEngine.comparisons(starts: tracker.periodEntries.map(\.startDate), summaries: journal.state.summaries, notes: journal.state.notes, alignment: alignment)
    }
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Align by", selection: $alignment) { ForEach(CycleComparisonAlignment.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented)
                    Text(alignment == .cycleDay ? "Aligned to logged period starts. Phase shading on the calendar remains an estimate." : "Negative days count back from the next logged period start. Only completed cycles can be aligned this way.")
                        .font(.footnote).foregroundColor(.secondary)
                    Picker("Compare", selection: $metric) { Text("Glucose").tag(0); Text("Insulin").tag(1); Text("Carbs").tag(2); Text("Notes").tag(3) }.pickerStyle(.segmented)
                    if cycles.isEmpty { Text("Add previous periods to compare your cycles. Daily records will build as you use the app.").foregroundColor(.secondary) }
                    ForEach(cycles.reversed()) { cycle in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(cycle.isCurrent ? "Current cycle" : "Cycle") · \(cycle.start)").font(.subheadline.bold())
                            ScrollView(.horizontal, showsIndicators: true) {
                                HStack(alignment: .bottom, spacing: 5) {
                                    ForEach(cycle.days) { day in
                                        Button { selectedDay = day.day } label: {
                                            VStack(spacing: 4) {
                                                Text(value(day)).font(.system(size: 9)).foregroundColor(.secondary)
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(day.summary?.usableForPatterns == true || metric == 3 ? Color.accentColor : Color.secondary.opacity(0.35))
                                                    .frame(width: 27, height: height(day))
                                                Text("\(day.offset)").font(.caption2)
                                                Circle().fill(day.notes.isEmpty ? Color.clear : Color.accentColor).frame(width: 4, height: 4)
                                            }
                                        }.buttonStyle(.plain).accessibilityLabel("\(day.day): \(value(day)); \(day.notes.count) notes")
                                    }
                                }.frame(minHeight: 120, alignment: .bottom).padding(.bottom, 6)
                            }
                        }
                    }
                    Text("Glucose: daily mean in mg/dL. Insulin: recorded units, potentially incomplete. Carbs: logged grams only. Gray bars indicate insufficient glucose coverage or an unfinished day. Missing days are unknown, not zero. Notes: entry count. Tap a day for its records.")
                        .font(.caption).foregroundColor(.secondary)
                    if let selectedDay, let date = CycleDay.date(selectedDay) {
                        Divider()
                        Text(selectedDay).font(.headline)
                        if let summary = journal.summary(on: date) { CycleDailySummaryView(summary: summary) }
                        ForEach(journal.notes(on: date)) { note in Text(note.displayText).font(.callout) }
                        if journal.summary(on: date) == nil && journal.notes(on: date).isEmpty { Text("No retained records or notes.").foregroundColor(.secondary) }
                    }
                }.padding()
            }
            .navigationTitle("Compare cycles").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }
    private func value(_ day: CycleAlignedDay) -> String {
        if metric == 3 { return "\(day.notes.count)" }
        let value = metric == 0 ? day.summary?.meanMGDL : (metric == 1 ? day.summary?.insulinUnits : day.summary?.carbGrams)
        return value.map { String(format: metric == 0 ? "%.0f" : "%.1f", $0) } ?? "—"
    }
    private func height(_ day: CycleAlignedDay) -> CGFloat {
        let value: Double
        switch metric {
        case 0: value = (day.summary?.meanMGDL ?? 0) / 4
        case 1: value = day.summary?.insulinUnits ?? 0
        case 2: value = (day.summary?.carbGrams ?? 0) / 4
        default: value = Double(day.notes.count) * 20
        }
        return CGFloat(max(3, min(80, value)))
    }
}

struct CycleInsightDetail: View {
    let insight: CycleInsight
    @ObservedObject var journal: CycleJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsChat = false
    var body: some View {
        NavigationView {
            List {
                Section { Text(insight.text) }
                ForEach(insight.evidence, id: \.cycleStart) { evidence in
                    Section(header: Text("Cycle starting \(evidence.cycleStart)")) {
                        Text(String(format: "Matched days: %.0f mg/dL mean\nOther recorded days: %.0f mg/dL mean", evidence.meanMGDL, evidence.baselineMGDL))
                        if let units = evidence.insulinPerRecordedDay, let baseline = evidence.baselineInsulinPerRecordedDay {
                            Text(String(format: "Recorded insulin: %.1f U/day (%d matched days); %.1f U/day (%d other days)", units, evidence.insulinDays, baseline, evidence.baselineInsulinDays)).font(.footnote)
                        }
                        if let grams = evidence.carbsPerLoggedDay, let baseline = evidence.baselineCarbsPerLoggedDay {
                            Text(String(format: "Logged carbs: %.0f g/day (%d matched days); %.0f g/day (%d other days)", grams, evidence.carbDays, baseline, evidence.baselineCarbDays)).font(.footnote)
                        }
                        Text("Matched dates: " + evidence.days.joined(separator: ", ")).font(.caption)
                        Text("Other dates: " + evidence.baselineDays.joined(separator: ", ")).font(.caption)
                    }
                }
                Section(header: Text("Original notes")) {
                    ForEach(journal.state.notes.filter { insight.noteIDs.contains($0.id) }.sorted { $0.day < $1.day }) { note in
                        VStack(alignment: .leading, spacing: 5) { Text(note.day).font(.caption).foregroundColor(.secondary); Text(note.displayText) }
                    }
                }
                Section {
                    Text("Comparisons use completed days with at least 70% glucose coverage. A glucose observation needs at least 3 matched days and 7 other days in each of at least 2 completed cycles, with a consistent difference of at least 10 mg/dL. These are product rules, not clinical confidence. Sleep, meals, illness and other factors can contribute. No dose changes are inferred.").font(.footnote).foregroundColor(.secondary)
                    Button("Talk to Mochi about this") { showsChat = true }
                }
            }
            .navigationTitle("Supporting records").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showsChat) { CompanionCycleChat(openingQuestion: "Explain the current cycle journal observation with ID \(insight.id). Read my journal and its supporting dates; distinguish reports from recorded measurements.") }
        }.navigationViewStyle(.stack)
    }
}

struct CyclePatternsView: View {
    @ObservedObject var tracker: CycleTrackingStore
    @ObservedObject var journal: CycleJournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CycleInsight?
    private var insights: [CycleInsight] {
        CyclePatternEngine.insights(starts: tracker.periodEntries.map(\.startDate), estimatedLength: tracker.cycleLength, journal: journal.state)
    }
    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Observations around your current cycle day, based on previous logged cycles. Missing notes and records mean unknown; a past observation may not repeat.").font(.footnote).foregroundColor(.secondary)
                }
                if insights.isEmpty {
                    Text("No supported observations around now. Add previous periods and notes, and let recorded history build. If period timing is uncertain, update your period dates.").foregroundColor(.secondary)
                }
                ForEach(insights) { insight in
                    Button { selected = insight } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(insight.basis == "user_report" ? "Your reports" : "Recorded glucose").font(.caption.bold()).foregroundColor(.secondary)
                            Text(insight.text).foregroundColor(.primary)
                            Text("View supporting records").font(.caption)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Your cycle patterns").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected) { insight in CycleInsightDetail(insight: insight, journal: journal) }
        }.navigationViewStyle(.stack)
    }
}
