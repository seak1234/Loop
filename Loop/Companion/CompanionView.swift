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

struct MochiAvatar: View {
    var size: CGFloat = 80
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = UIApplication.shared.applicationState == .active
    @State private var floating = false
    @State private var eyeOpenness: CGFloat = 1
    @State private var gaze = CGSize.zero

    private var animated: Bool { !reduceMotion && appActive }

    var body: some View {
        // Keep the eye coordinates in the source image's aspect ratio, inside the square avatar slot.
        let artworkHeight = size * 1083 / 1452
        ZStack {
            Image("MochiAnimatedBase").resizable().scaledToFit()
            eye(x: 0.396, y: 0.400, artworkHeight: artworkHeight)
            eye(x: 0.664, y: 0.373, artworkHeight: artworkHeight)
        }
        .frame(width: size, height: artworkHeight)
        .frame(width: size, height: size)
        .offset(y: animated && floating ? -2 : 0)
        .accessibilityHidden(true)
        .onAppear { appActive = UIApplication.shared.applicationState == .active }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in appActive = false }
        .task(id: animated) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { floating = false; eyeOpenness = 1; gaze = .zero }
            guard animated else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { floating = true }
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

@MainActor
struct CompanionDashboardCard: View {
    @ObservedObject private var controller = CompanionController.shared
    var open: () -> Void
    var onMessageChanged: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var dashboardNow = Date()
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                MochiAvatar(size: 64)
                Text(controller.dashboardText(now: dashboardNow))
                    .font(.subheadline).foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundColor(MochiStyle.blue)
            }
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(MochiStyle.blue.opacity(0.18)))
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Mochi to learn about your diabetes")
        .onAppear { controller.setDashboardVisible(true) }
        .onDisappear { controller.setDashboardVisible(false) }
        .onChange(of: controller.state.dashboardMessage?.generatedAt) { _ in
            dashboardNow = Date()
            onMessageChanged()
        }
        .onReceive(refreshTimer) { now in dashboardNow = now; controller.requestDashboardRefresh(now: now) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { controller.requestDashboardRefresh() }
        }
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
                            }
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
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: controller.state.messages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: controller.state.actions.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
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
            Button("Clear conversation", role: .destructive) { controller.clearConversation() }
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
            if controller.hasKey { controller.send(prompt()) } else { showSettings = true }
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
                Button("Dismiss") { controller.decline(action.id) }.buttonStyle(.bordered)
            }
            .disabled(busyActionIDs.contains(action.id))
        }
        .padding().mochiCard()
    }

    private func send() {
        guard !controller.isThinking, controller.hasKey else { return }
        let text = input
        input = ""
        controller.send(text)
    }
}

@MainActor
private struct CompanionSettingsView: View {
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
    @State private var personality = ""
    @State private var allowHealthData = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
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
                    if controller.hasKey { Button("Remove API key", role: .destructive) { controller.disconnect() } }
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
                Section(header: Text("Data & privacy"), footer: Text("Chat messages, your personality prompt, and approved tool results are sent to OpenRouter and the selected model provider. Enabling health sharing permits glucose, insulin, carb, and menstrual-cycle context to be sent for chat and automatic AI dashboard messages. Dashboard messages refresh every 15 minutes while visible, or after fresh data with at least 5 minutes between requests. Cycle phases are estimates from logged period dates; energy, mood, sleep and cravings are not tracked unless you describe them in chat. Local rules work without sharing health data with AI. Turning sharing off cannot recall data already sent.")) {
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
                        do {
                            if let selectedModel, !selectedModel.efforts.contains(reasoningEffort) {
                                throw CompanionError.invalid("Choose a reasoning effort supported by this model.")
                            }
                            try controller.saveSettings(model: model, reasoningEffort: reasoningEffort, personality: personality, allowHealthData: allowHealthData, key: key)
                            key = ""
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            guard !loadedSettings else { return }
            loadedSettings = true
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
                if let id = deletingRule { controller.deleteRule(id) }
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
