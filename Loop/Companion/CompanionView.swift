import Combine
import SwiftUI
import LoopKitUI

private enum MochiStyle {
    static let blue = Color(red: 0.43, green: 0.51, blue: 0.85)
    static let peach = Color(red: 1, green: 0.93, blue: 0.89)
}

private struct MochiEye: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let baseline = rect.height * (0.5 + 0.28 * openness)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseline))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: baseline),
                          control: CGPoint(x: rect.midX, y: baseline - rect.height * 1.3 * openness))
        return path
    }
}

private struct MochiArmMask: Shape {
    var cuttingOut = false

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        if cuttingOut { path.addRect(rect) }
        // Follow the shoulder seam to animate the existing arm independently of the body.
        path.move(to: point(0.844, 0.29))
        path.addLine(to: point(1, 0.29))
        path.addLine(to: point(1, 0.64))
        path.addLine(to: point(0.844, 0.64))
        path.addCurve(to: point(0.844, 0.29),
                      control1: point(0.86, 0.53), control2: point(0.855, 0.38))
        path.closeSubpath()
        return path
    }
}

struct MochiAvatar: View {
    var size: CGFloat = 80
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = UIApplication.shared.applicationState == .active
    @State private var eyeOpenness: CGFloat = 1
    @State private var gaze = CGSize.zero
    @State private var waveAngle = 0.0

    private var animated: Bool { !reduceMotion && appActive }

    var body: some View {
        // Keep the eye coordinates in the source image's aspect ratio, inside the square avatar slot.
        let artworkHeight = size * 1083 / 1452
        ZStack {
            Image("MochiAnimatedBase").resizable().scaledToFit()
                .mask(MochiArmMask())
                .rotationEffect(.degrees(waveAngle), anchor: UnitPoint(x: 0.848, y: 0.59))
            Image("MochiAnimatedBase").resizable().scaledToFit()
                .mask(MochiArmMask(cuttingOut: true).fill(style: FillStyle(eoFill: true)))
            eye(x: 0.396, y: 0.400, artworkHeight: artworkHeight)
            eye(x: 0.664, y: 0.373, artworkHeight: artworkHeight)
        }
        .frame(width: size, height: artworkHeight)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { appActive = UIApplication.shared.applicationState == .active }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in appActive = false }
        .task(id: animated) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { eyeOpenness = 1; gaze = .zero }
            guard animated else { return }
            do {
                try await pause(0.65)
                try await blink()
                while !Task.isCancelled {
                    try await pause(Double.random(in: 1.0...1.7))
                    withAnimation(.easeInOut(duration: 0.35)) {
                        let direction: CGFloat = Bool.random() ? -1 : 1
                        gaze = CGSize(width: direction * max(1.1, size * 0.025), height: CGFloat.random(in: -0.5...0.5))
                    }
                    try await pause(0.25)
                    try await blink()
                    if Int.random(in: 0..<5) == 0 {
                        try await pause(0.14)
                        try await blink()
                    }
                    try await pause(Double.random(in: 0.3...0.6))
                    withAnimation(.easeInOut(duration: 0.45)) { gaze = .zero }
                }
            } catch { /* SwiftUI cancels the task when hidden, inactive, or Reduce Motion changes. */ }
        }
        .task(id: animated) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { waveAngle = 0 }
            guard animated else { return }
            do {
                try await pause(0.35)
                while !Task.isCancelled {
                    for angle in [-18.0, 24, -18, 24, 0] {
                        withAnimation(.easeInOut(duration: 0.18)) { waveAngle = angle }
                        try await pause(0.20)
                    }
                    try await pause(Double.random(in: 14...20))
                }
            } catch { /* The greeting follows the same visibility and motion settings as the eyes. */ }
        }
    }

    private func eye(x: CGFloat, y: CGFloat, artworkHeight: CGFloat) -> some View {
        MochiEye(openness: eyeOpenness)
            .stroke(LinearGradient(colors: [Color(red: 0.80, green: 1, blue: 1), Color(red: 0.36, green: 0.91, blue: 1)],
                                   startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: size * 0.026 * (0.45 + 0.55 * eyeOpenness), lineCap: .round))
            .frame(width: size * 0.12, height: artworkHeight * 0.08)
            .rotationEffect(.degrees(-6))
            .shadow(color: Color.cyan.opacity(0.85), radius: size * 0.012)
            .offset(x: gaze.width, y: gaze.height)
            .position(x: size * x, y: artworkHeight * y)
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try Task.checkCancellation()
    }

    private func blink() async throws {
        withAnimation(.easeIn(duration: 0.12)) { eyeOpenness = 0 }
        try await pause(0.23)
        withAnimation(.easeOut(duration: 0.18)) { eyeOpenness = 1 }
        try await pause(0.22)
    }
}

private struct MochiCompactCardLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            MochiAvatar(size: 44)
            Text(text)
                .font(.caption).foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(MochiStyle.blue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(MochiStyle.blue.opacity(0.18)))
    }
}

@MainActor
struct CompanionCycleCard: View {
    @ObservedObject private var controller = CompanionController.shared
    @State private var phaseCards: [CompanionCycleCardPhase: CompanionCycleCardMessage] = [:]
    @State private var now = Date()
    @State private var fallbackIndex = Int.random(in: 0..<8)
    @State private var discussion: CompanionCycleCardMessage?
    private let dayTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var phase: CompanionCycleCardPhase { controller.cycleCardPhase(on: now) }

    private var message: CompanionCycleCardMessage {
        let fallback = CompanionCycleCardMessage.topics(for: phase)
        return phaseCards[phase] ?? fallback[fallbackIndex % fallback.count]
    }

    private var generationIdentity: String {
        "\(controller.hasKey):\(controller.state.model):\(controller.state.reasoningEffort?.rawValue ?? "default"):\(controller.state.personality):\(Int(now.timeIntervalSince1970 / 900))"
    }

    var body: some View {
        Button { discussion = message } label: {
            MochiCompactCardLabel(text: message.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.text)
        .accessibilityHint("Talk with Mochi about your cycle and T1D")
        .task(id: generationIdentity) {
            do { phaseCards = try await controller.makeCycleCards() }
            catch { /* Keep the current phase's invitation when generation is unavailable. */ }
        }
        .onReceive(CycleTrackingStore.shared.$periodEntries) { _ in now = Date() }
        .onReceive(dayTimer) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in now = Date() }
        .sheet(item: $discussion) { topic in
            CompanionCycleChat(openingQuestion: topic.question)
        }
    }
}

@MainActor
struct CompanionCycleChat: View {
    let openingQuestion: String
    @ObservedObject private var controller = CompanionController.shared
    @ObservedObject private var journal = CycleJournalStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [CompanionMessage] = []
    @State private var input = ""
    @State private var requestID: UUID?
    @State private var error: String?
    @State private var showsSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Your cycle, everyday wellbeing and T1D.")
                                .font(.footnote).foregroundColor(.secondary)
                            ForEach(turns) { turn in
                                HStack {
                                    if turn.role == "user" { Spacer(minLength: 28) }
                                    Text(turn.text)
                                        .textSelection(.enabled)
                                        .padding(12)
                                        .foregroundColor(turn.role == "user" ? .white : .primary)
                                        .background(turn.role == "user" ? MochiStyle.blue : Color(UIColor.secondarySystemGroupedBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    if turn.role != "user" { Spacer(minLength: 28) }
                                }
                                if let ids = turn.cycleNoteIDs, !ids.isEmpty {
                                    CycleSavedNoteCards(ids: ids, journal: controller.cycleJournal)
                                }
                            }
                            CycleUnlinkedSavedNotes(since: turns.last(where: { $0.role == "user" })?.date,
                                linkedIDs: turns.flatMap { $0.cycleNoteIDs ?? [] }, journal: controller.cycleJournal)
                            if requestID != nil {
                                HStack {
                                    ProgressView("Mochi is thinking…")
                                    Spacer()
                                    Button("Stop") { requestID = nil }
                                }.font(.footnote)
                            }
                            if let error { Text(error).font(.footnote).foregroundColor(.secondary) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }
                    .onChange(of: turns.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                if !controller.hasKey {
                    Button("Connect OpenRouter to chat") { showsSettings = true }.padding(10)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        cycleShortcut("Cycle phases", question: CompanionCycleCardMessage.topics[0].question)
                        cycleShortcut("Mood & energy", question: CompanionCycleCardMessage.topics[1].question)
                        cycleShortcut("Cycle & T1D", question: CompanionCycleCardMessage.topics[5].question)
                    }.padding(.horizontal)
                }
                HStack(spacing: 8) {
                    TextField("Ask about your cycle…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(sendInput)
                    Button(action: sendInput) { Image(systemName: "paperplane.fill").padding(10) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestID != nil || !controller.hasKey)
                        .accessibilityLabel("Send cycle question")
                }.padding()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Mochi · Cycle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) { MochiAvatar(size: 30); Text("Mochi · Cycle").font(.headline) }
                }
                ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Mochi settings")
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(MochiStyle.blue)
        .task(id: controller.hasKey) {
            if controller.hasKey, turns.isEmpty { _ = send(openingQuestion) }
        }
        .task(id: requestID) {
            guard let pendingID = requestID else { return }
            defer { if requestID == pendingID { requestID = nil } }
            do {
                let reply = try await controller.replyToCycleConversation(turns)
                try Task.checkCancellation()
                guard requestID == pendingID else { return }
                turns.append(reply)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { requestID = nil }
        .onChange(of: controller.state.allowHealthData) { allowed in
            requestID = nil
            if !allowed { turns.removeAll { $0.includesHealthData == true } }
        }
        .onChange(of: journal.state.allowMochiRead) { allowed in
            requestID = nil
            if !allowed { turns.removeAll { $0.includesCycleJournal == true } }
        }
        .onChange(of: journal.state.allowMochiWrite) { _ in requestID = nil }
        .sheet(isPresented: $showsSettings) { CompanionSettingsView(controller: controller) }
    }

    private func cycleShortcut(_ title: String, question: String) -> some View {
        Button(title) { _ = send(question) }
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(MochiStyle.blue.opacity(0.1), in: Capsule())
            .disabled(requestID != nil || !controller.hasKey)
    }

    private func sendInput() {
        if send(input) { input = "" }
    }

    private func send(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestID == nil, controller.hasKey, !text.isEmpty else { return false }
        guard text.count <= 3000, turns.count < 40 else {
            error = "Shorten your message or reopen Mochi to start a new cycle conversation."
            return false
        }
        error = nil
        turns.append(CompanionMessage(role: "user", text: text, includesHealthData: controller.state.allowHealthData))
        requestID = UUID()
        return true
    }
}

struct CompanionDashboardIcon: View {
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            MochiAvatar(size: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mochi")
        .accessibilityHint("Open Mochi to chat")
    }
}

private struct MochiDashboardSpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + 10, width: rect.width, height: max(0, rect.height - 10))
        var path = Path(roundedRect: body, cornerRadius: 18)
        // Keep the pointer inside the hosting view, aligned with Mochi in the banner above.
        path.move(to: CGPoint(x: rect.minX + 42, y: body.minY + 1))
        path.addCurve(to: CGPoint(x: rect.minX + 48, y: rect.minY),
                      control1: CGPoint(x: rect.minX + 44, y: rect.minY + 8),
                      control2: CGPoint(x: rect.minX + 46, y: rect.minY + 3))
        path.addCurve(to: CGPoint(x: rect.minX + 60, y: body.minY + 1),
                      control1: CGPoint(x: rect.minX + 50, y: rect.minY + 3),
                      control2: CGPoint(x: rect.minX + 58, y: rect.minY + 8))
        path.closeSubpath()
        return path
    }
}

@MainActor
struct CompanionDashboardCard: View {
    @ObservedObject private var controller: CompanionController
    var open: () -> Void
    var onMessageChanged: () -> Void = {}

    init(controller: CompanionController? = nil, open: @escaping () -> Void, onMessageChanged: @escaping () -> Void = {}) {
        self.controller = controller ?? .shared
        self.open = open
        self.onMessageChanged = onMessageChanged
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var dashboardNow = Date()
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var bubbleHidden: Bool { controller.state.isDashboardDismissed(at: dashboardNow) }

    var body: some View {
        VStack(spacing: 0) {
            if !bubbleHidden { bubble }
        }
        .onAppear { dashboardNow = Date(); controller.setDashboardVisible(true) }
        .onDisappear { controller.setDashboardVisible(false) }
        .onChange(of: controller.state.dashboardMessage?.generatedAt) { _ in
            dashboardNow = Date()
            onMessageChanged()
        }
        .onChange(of: bubbleHidden) { _ in onMessageChanged() }
        .task(id: controller.state.dashboardHiddenUntil) {
            guard let until = controller.state.dashboardHiddenUntil else { return }
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }
            }
            dashboardNow = Date()
            controller.requestDashboardRefresh(now: dashboardNow)
        }
        .onReceive(refreshTimer) { now in dashboardNow = now; controller.requestDashboardRefresh(now: now) }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                dashboardNow = Date()
                controller.requestDashboardRefresh(now: dashboardNow)
            }
        }
    }

    private var bubble: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                controller.prepareDashboardDiscussion(now: dashboardNow)
                open()
            } label: {
                Text(controller.dashboardText(now: dashboardNow))
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.dashboardText(now: dashboardNow))
            .accessibilityHint("Open Mochi to explore this message")
            Button {
                Task { await controller.dismissDashboard() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Mochi message")
            .accessibilityHint("Hide dashboard messages for \(controller.state.dashboardSnoozeDuration) minutes")
        }
        .padding(.top, 10)
        .background {
            MochiDashboardSpeechBubble()
                .fill(Color(UIColor.secondarySystemGroupedBackground))
                .shadow(color: MochiStyle.blue.opacity(0.08), radius: 5, y: 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

@MainActor
struct CompanionView: View {
    let deviceManager: DeviceDataManager
    @ObservedObject private var controller = CompanionController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var showSettings = false
    @State private var showRules = false
    @State private var confirmClear = false
    @State private var notificationContext: String?
    @State private var carbReview: CarbReview?
    @State private var reviewingActionID: UUID?
    @State private var busyActionIDs = Set<UUID>()

    private struct CarbReview: Identifiable {
        let id: UUID
        let model: CarbEntryViewModel
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Wait for the message list and viewport to lay out before locating the bottom.
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if controller.state.messages.isEmpty { introduction }
                            if let notificationContext {
                                Text(notificationContext).font(.callout).padding().mochiCard()
                            }
                            ForEach(controller.state.messages) { message in
                                HStack {
                                    if message.role == "user" { Spacer(minLength: 32) }
                                    Text(message.text)
                                        .textSelection(.enabled)
                                        .padding(13)
                                        .foregroundColor(message.role == "user" ? .white : .primary)
                                        .background(message.role == "user" ? MochiStyle.blue : Color(UIColor.secondarySystemGroupedBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                        .accessibilityLabel((message.role == "user" ? "You: " : "Mochi: ") + message.text)
                                    if message.role != "user" { Spacer(minLength: 24) }
                                }
                                .id(message.id)
                                if let ids = message.cycleNoteIDs, !ids.isEmpty {
                                    CycleSavedNoteCards(ids: ids, journal: controller.cycleJournal)
                                }
                            }
                            CycleUnlinkedSavedNotes(since: controller.state.messages.last(where: { $0.role == "user" })?.date,
                                linkedIDs: controller.state.messages.flatMap { $0.cycleNoteIDs ?? [] }, journal: controller.cycleJournal)
                            ForEach(controller.state.actions.filter { $0.status == .pending }) { action in
                                actionCard(action)
                            }
                            if controller.isThinking {
                                HStack {
                                    ProgressView()
                                    Text("Mochi is thinking…").font(.subheadline).foregroundColor(.secondary)
                                    Spacer()
                                    Button("Stop") { controller.cancelChat() }
                                }
                            }
                            if let fact = controller.activeDashboardDiscussion?.sourceFact {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text([fact.evidenceStage?.replacingOccurrences(of: "-", with: " "), fact.region].compactMap { $0 }.joined(separator: " · "))
                                        .foregroundColor(.secondary)
                                    Link(fact.publishedAt.map { "Read source · " + $0 } ?? "Read source", destination: fact.source)
                                }
                                .font(.caption)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height) { _ in
                            scrollToLatest(proxy, animated: false)
                        }
                    })
                    .onAppear { scrollToLatest(proxy, animated: false) }
                    .onChange(of: controller.state.messages.count) { _ in scrollToLatest(proxy) }
                    .onChange(of: controller.state.actions.filter { $0.status == .pending }.map(\.id)) { _ in scrollToLatest(proxy) }
                    .onChange(of: controller.isThinking) { _ in scrollToLatest(proxy) }
                }
                if !controller.hasKey {
                    Button("Connect OpenRouter to chat") { showSettings = true }
                        .font(.subheadline.weight(.semibold)).padding(10)
                }
                topicShortcuts
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask Mochi anything…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane.fill").padding(10) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isThinking || !controller.hasKey)
                        .accessibilityLabel("Send message")
                }
                .padding(.horizontal).padding(.vertical, 10)
                Text("You control what Mochi remembers and shares.")
                    .font(.caption2).foregroundColor(.secondary).padding(.bottom, 6)
            }
            .background(LinearGradient(colors: [MochiStyle.peach.opacity(0.25), Color(UIColor.systemGroupedBackground)], startPoint: .top, endPoint: .bottom))
            .navigationTitle("Mochi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        MochiAvatar(size: 30)
                        Text("Mochi").font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let fact = controller.dashboardFact {
                            Link(destination: fact.source) { Label(fact.isNews == true ? "Read source · " + (fact.publishedAt ?? "") : "Read discovery source", systemImage: "book") }
                        }
                        Button { showRules = true } label: { Label("Rules & activity", systemImage: "bell.badge") }
                        Button { showSettings = true } label: { Label("Connection & personality", systemImage: "slider.horizontal.3") }
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear conversation", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Mochi settings and rules")
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(MochiStyle.blue)
        .onAppear {
            controller.refreshConnectionStatus()
            controller.attach(to: deviceManager)
            notificationContext = controller.contextForNotification()
            controller.beginChatSession()
        }
        .onDisappear { controller.endChatSession() }
        .onReceive(NotificationCenter.default.publisher(for: .companionOpenRequested)) { _ in
            notificationContext = controller.contextForNotification()
        }
        .sheet(isPresented: $showSettings) { CompanionSettingsView(controller: controller) }
        .sheet(isPresented: $showRules) { CompanionRulesView(controller: controller) }
        .sheet(item: $carbReview, onDismiss: {
            if let id = reviewingActionID { Task { await controller.finishCarbReview(id) } }
            reviewingActionID = nil
        }) { review in
            CarbEntryView(viewModel: review.model).environmentObject(deviceManager.displayGlucosePreference)
                .environment(\.dismissAction, { carbReview = nil })
        }
        .confirmationDialog("Clear the conversation and its action cards? Saved rules and personality will stay.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { Task { await controller.clearConversation() } }
        }
        .alert("Mochi", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var introduction: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MochiAvatar(size: 54)
                Text("What’s on your mind?").font(.headline)
                Spacer()
            }

        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
    }

    private var topicShortcuts: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                suggestion("Pep talk", icon: "heart") {
                    "I could use a little encouragement today."
                }
                suggestion("Review today", icon: "chart.bar") {
                    "How’s my day looking so far?"
                }
                suggestion("Cycle insights", icon: "moon") {
                    "Could my cycle be affecting my glucose or how I’m feeling?"
                }
            }
            if !controller.suggestedTopics.isEmpty {
                HStack(spacing: 6) {
                    ForEach(controller.suggestedTopics) { topic in
                        suggestion(topic.title, icon: "sparkles") { topic.prompt }
                    }
                }
            } else if controller.isGeneratingTopics {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.7)
                    Text("Finding new topics…").font(.caption2).foregroundColor(.secondary)
                }
                .frame(height: 28)
            }
        }
        .padding(.horizontal).padding(.top, 6)
    }

    private func suggestion(_ title: String, icon: String, prompt: @escaping () -> String) -> some View {
        Button {
            if controller.hasKey { Task { await controller.send(prompt()) } } else { showSettings = true }
        } label: {
            HStack(spacing: 5) { Image(systemName: icon); Text(title).font(.caption).multilineTextAlignment(.center) }
                .frame(maxWidth: .infinity, minHeight: 32).padding(6).mochiCard()
        }
        .buttonStyle(.plain).disabled(controller.isThinking)
    }

    private func actionCard(_ action: CompanionAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review before applying", systemImage: "hand.raised").font(.caption).foregroundColor(.secondary)
            Text(action.title).font(.headline)
            if let rule = action.rule {
                Text(rule.detail).font(.subheadline)
                if !rule.enabled { Text("This will pause the rule.").font(.subheadline.weight(.semibold)) }
            }
            if let carb = action.carb {
                Text("\(carb.grams, specifier: "%.1f") g · \(carb.date.formatted(date: .abbreviated, time: .shortened)) · \(carb.absorptionHours, specifier: "%.1f") h absorption")
                    .font(.subheadline)
                Text("The next screen lets you edit and save. Carb entries affect Loop’s glucose model and subsequent dosing.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let personality = action.personality { Text(personality).font(.subheadline) }
            HStack {
                Button(action.carb == nil ? "Apply" : "Review carb entry") {
                    guard busyActionIDs.insert(action.id).inserted else { return }
                    Task {
                        defer { busyActionIDs.remove(action.id) }
                        if action.carb != nil {
                            do {
                                let model = try await controller.prepareCarbReview(action)
                                reviewingActionID = action.id
                                carbReview = CarbReview(id: action.id, model: model)
                            } catch { controller.errorMessage = error.localizedDescription }
                        } else { await controller.approve(action.id) }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") { Task { await controller.decline(action.id) } }.buttonStyle(.bordered)
            }
            .disabled(busyActionIDs.contains(action.id))
        }
        .padding().mochiCard()
    }

    private func send() {
        guard !controller.isThinking, controller.hasKey else { return }
        let text = input
        Task {
            if await controller.send(text), input == text { input = "" }
        }
    }
}

@MainActor
struct CompanionSettingsView: View {
    @ObservedObject var controller: CompanionController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var model = ""
    @State private var reasoningEffort: CompanionReasoningEffort = .medium
    @State private var models: [CompanionModel] = [.gpt61]
    @State private var showModelPicker = false
    @State private var loadingModels = false
    @State private var catalogError: String?
    @State private var loadedSettings = false
    @State private var saving = false
    @State private var preferredName = "Michelle"
    @State private var useRecentChatsForDashboard = true
    @State private var dashboardSnoozeMinutes = 60
    @State private var personality = ""
    @State private var allowHealthData = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("About you")) {
                    TextField("Your name", text: $preferredName).textContentType(.givenName)
                    Text("Mochi uses your name to make messages personal. Leave it empty to skip names.")
                        .font(.caption).foregroundColor(.secondary)
                    dashboardPausePicker
                    Text("Defaults to one hour. The pause also applies after reopening the app. Changing this updates the pause from the last time you closed the bubble.")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("Revisit recent chat topics", isOn: $useRecentChatsForDashboard)
                    Text("When health-data sharing is on, Mochi can follow up on topics from your recent chats on this device. Clearing the conversation removes those topics.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("OpenRouter connection"), footer: Text("Use your own OpenRouter key and credits. Your key stays in this device’s Keychain. Choose a model that supports tool calling.")) {
                    Label(controller.hasKey ? "Key connected" : "Not connected", systemImage: controller.hasKey ? "checkmark.shield" : "key")
                    SecureField(controller.hasKey ? "Replace key (optional)" : "OpenRouter API key", text: $key)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                    Button { showModelPicker = true } label: {
                        HStack {
                            Text("Model").foregroundColor(.primary)
                            Spacer()
                            Text(selectedModel?.name.replacingOccurrences(of: "OpenAI: ", with: "") ?? model)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Picker("Reasoning effort", selection: $reasoningEffort) {
                        ForEach(availableEfforts) { effort in Text(effort.label).tag(effort) }
                    }
                    .disabled(availableEfforts.count == 1)
                    Text("Higher effort can take longer and cost more. Model default lets the provider choose.")
                        .font(.caption).foregroundColor(.secondary)
                    if loadingModels {
                        HStack { ProgressView(); Text("Refreshing models…").font(.caption) }
                    }
                    if let catalogError { Text(catalogError).font(.caption).foregroundColor(.secondary) }
                    Button("Refresh model list") { Task { await refreshModels() } }.disabled(loadingModels)
                    Link("Manage OpenRouter keys", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    if controller.hasKey { Button("Remove API key", role: .destructive) { Task { await controller.disconnect() } } }
                }
                Section(header: Text("Make Mochi feel like you"), footer: Text("Describe tone, length, humor, and how you like encouragement. This does not grant additional app permissions.")) {
                    HStack {
                        Button("Gentle") { personality = "Talk like a kind friend. Use simple, gentle words and keep it short. Respond to what I say without canned reassurance, advice menus or guilt." }
                        Button("Direct") { personality = "Be warm, clear and straight with me, like a thoughtful friend. Use everyday words, keep it short and skip pep talks unless I ask." }
                        Button("Playful") { personality = "Talk like a warm friend with a light sense of humor. Keep it natural and simple. No forced jokes, jokes about lows, or shame about my readings." }
                    }.buttonStyle(.borderless)
                    TextEditor(text: $personality).frame(minHeight: 130)
                        .accessibilityLabel("Custom personality prompt")
                }
                Section(header: Text("Data & privacy"), footer: Text("Chat messages, your personality prompt, and approved tool results are sent to OpenRouter and the selected model provider. Enabling health sharing permits glucose, insulin, carb, and menstrual-cycle context to be sent for chat and automatic AI dashboard messages. Dashboard messages refresh every 15 minutes while visible, or after fresh data with at least 5 minutes between requests. Cycle phases are estimates from logged period dates; Cycle journal notes and retained daily records require separate journal access, controlled on the cycle page. Notes can be saved only when you ask and enable saving permission. Local rules work without sharing health data with AI. Turning sharing off cannot recall data already sent.")) {
                    Toggle("Allow health data for Mochi", isOn: $allowHealthData)
                    Text("Chat history, rules and preferences are stored on this device and excluded from backups. Notification previews may show glucose information; control previews in iOS Settings.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if let error { Section { Text(error).foregroundColor(.red) } }
            }
            .navigationTitle("Mochi settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !saving else { return }
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                if let selectedModel, !selectedModel.efforts.contains(reasoningEffort) {
                                    throw CompanionError.invalid("Choose a reasoning effort supported by this model.")
                                }
                                try await controller.saveSettings(model: model, reasoningEffort: reasoningEffort, personality: personality, allowHealthData: allowHealthData, key: key, preferredName: preferredName, useRecentChatsForDashboard: useRecentChatsForDashboard, dashboardSnoozeMinutes: dashboardSnoozeMinutes)
                                key = ""
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(saving)
                }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .navigationViewStyle(.stack)
        .onAppear {
            guard !loadedSettings else { return }
            loadedSettings = true
            preferredName = controller.state.displayName
            useRecentChatsForDashboard = controller.state.useRecentChatsForDashboard != false
            dashboardSnoozeMinutes = controller.state.dashboardSnoozeDuration
            model = controller.state.model
            reasoningEffort = controller.state.reasoningEffort ?? .providerDefault
            personality = controller.state.personality
            allowHealthData = controller.state.allowHealthData
        }
        .task { await refreshModels() }
        .sheet(isPresented: $showModelPicker) {
            CompanionModelPicker(models: models, selectedID: model) { selected in
                model = selected.id
                if selected.id == CompanionModel.gpt61.id { reasoningEffort = .medium }
                else if !selected.efforts.contains(reasoningEffort) { reasoningEffort = .providerDefault }
            }
        }
    }

    private var dashboardPausePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pause messages after closing")
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text("Hours").font(.caption).foregroundColor(.secondary)
                    Picker("Hours", selection: Binding(
                        get: { dashboardSnoozeMinutes / 60 },
                        set: { hours in
                            dashboardSnoozeMinutes = max(1, min(1440, hours * 60 + dashboardSnoozeMinutes % 60))
                        }
                    )) {
                        ForEach(0...24, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipped()
                }
                VStack(spacing: 0) {
                    Text("Minutes").font(.caption).foregroundColor(.secondary)
                    Picker("Minutes", selection: Binding(
                        get: { dashboardSnoozeMinutes % 60 },
                        set: { minutes in
                            dashboardSnoozeMinutes = max(1, min(1440, (dashboardSnoozeMinutes / 60) * 60 + minutes))
                        }
                    )) {
                        ForEach(dashboardPauseMinuteRange, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipped()
                    .disabled(dashboardSnoozeMinutes == 1440)
                }
            }
        }
    }

    private var dashboardPauseMinuteRange: ClosedRange<Int> {
        if dashboardSnoozeMinutes == 1440 { return 0...0 }
        return dashboardSnoozeMinutes < 60 ? 1...59 : 0...59
    }

    private var selectedModel: CompanionModel? { models.first { $0.id == model } }
    private var availableEfforts: [CompanionReasoningEffort] {
        selectedModel?.efforts ?? (reasoningEffort == .providerDefault ? [.providerDefault] : [.providerDefault, reasoningEffort])
    }

    private func refreshModels() async {
        guard !loadingModels else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let refreshed = try await OpenRouterModelCatalog.load()
            try Task.checkCancellation()
            models = refreshed
            catalogError = nil
            if let selectedModel, !selectedModel.efforts.contains(reasoningEffort) {
                reasoningEffort = .providerDefault
                catalogError = "The selected model does not support the saved effort. Review the new Model default setting before saving."
            }
        } catch is CancellationError { }
        catch {
            catalogError = "Could not refresh models. Your saved selection is kept, and GPT‑6.1 Sol remains available for setup."
        }
    }
}

private struct CompanionModelPicker: View {
    let models: [CompanionModel]
    let selectedID: String
    let select: (CompanionModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [CompanionModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? models : models.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Only text models with tool calling are listed. Availability and billing depend on your OpenRouter account.")) {
                    ForEach(filtered) { model in
                        Button {
                            select(model)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name).foregroundColor(.primary)
                                    Text(model.id).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if model.id == selectedID { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                            }
                        }
                    }
                    if filtered.isEmpty { Text("No matching models.").foregroundColor(.secondary) }
                }
            }
            .searchable(text: $search, prompt: "Search models, e.g. GPT‑6.1")
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

@MainActor
private struct CompanionRulesView: View {
    @ObservedObject var controller: CompanionController
    @Environment(\.dismiss) private var dismiss
    @State private var busyRules = Set<UUID>()
    @State private var deletingRule: UUID?

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Rules are checked when the app receives fresh CGM data. Missing data or suspended app execution can delay checks. Existing Loop safety alerts remain separate. Daily reviews are scheduled reminders; summaries refresh when opened.")) {
                    if controller.state.rules.isEmpty {
                        Text("Ask Mochi to set up a daily review or a glucose reminder.").foregroundColor(.secondary)
                    }
                    ForEach(controller.state.rules) { rule in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(rule.title, isOn: Binding(get: { rule.enabled }, set: { enabled in
                                guard busyRules.insert(rule.id).inserted else { return }
                                Task {
                                    defer { busyRules.remove(rule.id) }
                                    await controller.setRuleEnabled(rule, enabled: enabled)
                                }
                            }))
                            .disabled(busyRules.contains(rule.id))
                            Text(rule.detail).font(.caption).foregroundColor(.secondary)
                            Button("Delete rule", role: .destructive) { deletingRule = rule.id }.font(.caption)
                        }.padding(.vertical, 4)
                    }
                }
                Section(header: Text("Action history")) {
                    ForEach(controller.state.actions.reversed()) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title)
                            Text(action.status == .openedForReview ? "Carb form opened; verify the entry in carb history." : action.status.rawValue)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section(header: Text("Recent activity")) {
                    ForEach(controller.state.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.headline)
                            Text(event.detail).font(.caption)
                            Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Rules & activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .navigationViewStyle(.stack)
        .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button("Delete rule", role: .destructive) {
                if let id = deletingRule { Task { await controller.deleteRule(id) } }
                deletingRule = nil
            }
        }
    }
}

private extension View {
    func mochiCard() -> some View {
        background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(MochiStyle.blue.opacity(0.16)))
    }
}
