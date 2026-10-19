//
//  CarbEntryView.swift
//  Loop
//
//  Created by Noah Brauner on 7/19/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit
import PhotosUI
import AVFoundation

struct CarbEntryView: View, HorizontalSizeClassOverride {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss

    @ObservedObject var viewModel: CarbEntryViewModel
        
    @State private var expandedRow: Row?
    
    @State private var showMealPhoto = false
    @State private var mealCapture: MealPhotoSource?
    @State private var pendingMealImage: UIImage?
    @State private var acceptedMealValues: CompanionMealFormValues?
    @State private var showHowAbsorptionTimeWorks = false
    @State private var showAddFavoriteFood = false
    
    private let isNewEntry: Bool

    init(viewModel: CarbEntryViewModel) {
        if viewModel.shouldBeginEditingQuantity {
            expandedRow = .amountConsumed
        }
        isNewEntry = viewModel.originalCarbEntry == nil
        self.viewModel = viewModel
    }
    
    var body: some View {
        if isNewEntry {
            NavigationView {
                let title = NSLocalizedString("carb-entry-title-add", value: "Add Carb Entry", comment: "The title of the view controller to create a new carb entry")
                content
                    .navigationBarTitle(title, displayMode: .inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            dismissButton
                        }
                        
                        ToolbarItem(placement: .navigationBarTrailing) {
                            continueButton
                        }
                    }
                
            }
        }
        else {
            content
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        continueButton
                    }
                }
        }
    }
    
    private var content: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                warningsCard

                if isNewEntry {
                    Button {
                        clearExpandedRow()
                        pendingMealImage = nil
                        mealCapture = MealPhotoSource.preferredCapture
                    } label: {
                        HStack(spacing: 12) {
                            MochiAvatar(size: 76)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Scan with Mochi").font(.headline)
                                Text("Estimate a meal from a photo").font(.subheadline).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "camera.fill")
                        }
                        .padding(12)
                        .background(CardBackground())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    Text("Meal photos are sent automatically to OpenRouter and your selected AI provider for an estimate.")
                        .font(.caption).foregroundColor(.secondary).padding(.horizontal)
                }

                mainCard
                    .padding(.top, 8)
                
                continueActionButton
                
                if isNewEntry, FeatureFlags.allowExperimentalFeatures {
                    favoriteFoodsCard
                }
                
                let isBolusViewActive = Binding(get: { viewModel.bolusViewModel != nil }, set: { _, _ in viewModel.bolusViewModel = nil })
                NavigationLink(destination: bolusView, isActive: isBolusViewActive) {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibility(hidden: true)
            }
        }
        .alert(item: $viewModel.alert, content: alert(for:))
        .sheet(isPresented: $showAddFavoriteFood, onDismiss: clearExpandedRow) {
            AddEditFavoriteFoodView(carbsQuantity: $viewModel.carbsQuantity.wrappedValue, foodType: $viewModel.foodType.wrappedValue, absorptionTime: $viewModel.absorptionTime.wrappedValue, onSave: onFavoriteFoodSave(_:))
        }
        .fullScreenCover(item: $mealCapture, onDismiss: {
            if pendingMealImage != nil { showMealPhoto = true }
        }) { source in
            MealPhotoPicker(source: source, onSelect: { pendingMealImage = $0 }, onError: { _ in })
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showMealPhoto, onDismiss: {
            pendingMealImage = nil
            if let values = acceptedMealValues {
                acceptedMealValues = nil
                if viewModel.applyMealFormValues(values) {
                    clearExpandedRow()
                    viewModel.continueToBolus()
                }
            }
        }) {
            if let image = pendingMealImage {
                MochiMealPhotoView(viewModel: viewModel, initialImage: image) { values in
                    acceptedMealValues = values
                }
            }
        }
        .sheet(isPresented: $showHowAbsorptionTimeWorks) {
            HowAbsorptionTimeWorksView()
        }
    }
    
    private var mainCard: some View {
        CarbEntryFormFields(viewModel: viewModel, expandedRow: $expandedRow,
                            showHowAbsorptionTimeWorks: $showHowAbsorptionTimeWorks)
    }

    @ViewBuilder
    private var bolusView: some View {
        if let viewModel = viewModel.bolusViewModel {
            BolusEntryView(viewModel: viewModel)
                .environmentObject(displayGlucosePreference)
                .environment(\.dismissAction, dismiss)
        }
    }
    
    private func clearExpandedRow() {
        self.expandedRow = nil
    }
}

// MARK: - Warnings & Alerts
extension CarbEntryView {
    private var warningsCard: some View {
        ForEach(Array(viewModel.warnings).sorted(by: { $0.priority < $1.priority })) { warning in
            warningView(for: warning)
                .padding(.vertical, 8)
                .padding(.horizontal)
                .background(CardBackground())
                .padding(.horizontal)
                .padding(.top, 8)
        }
    }
    
    private func warningView(for warning: CarbEntryViewModel.Warning) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(triangleColor(for: warning))
            
            Text(warningText(for: warning))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func triangleColor(for warning: CarbEntryViewModel.Warning) -> Color {
        switch warning {
        case .entryIsMissedMeal:
            return .critical
        case .overrideInProgress:
            return .warning
        }
    }
    
    private func warningText(for warning: CarbEntryViewModel.Warning) -> String {
        switch warning {
        case .entryIsMissedMeal:
            return NSLocalizedString("Loop has detected an missed meal and estimated its size. Edit the carb amount to match the amount of any carbs you may have eaten.", comment: "Warning displayed when user is adding a meal from an missed meal notification")
        case .overrideInProgress:
            return NSLocalizedString("An active override is modifying your carb ratio and insulin sensitivity. If you don't want this to affect your bolus calculation and projected glucose, consider turning off the override.", comment: "Warning to ensure the carb entry is accurate during an override")
        }
    }
    
    private func alert(for alert: CarbEntryViewModel.Alert) -> SwiftUI.Alert {
        switch alert {
        case .deleteFavoriteFood(let id, let name):
            return SwiftUI.Alert(
                title: Text("Delete “\(name)”?"),
                message: Text("Are you sure you want to delete this food?"),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("Delete")) {
                    if let food = viewModel.favoriteFoods.first(where: { $0.id == id }) {
                        viewModel.onFavoriteFoodDelete(food)
                    }
                }
            )
        case .maxQuantityExceded:
            let message = String(
                format: NSLocalizedString("The maximum allowed amount is %@ grams.", comment: "Alert body displayed for quantity greater than max (1: maximum quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.maxCarbEntryQuantity.doubleValue(for: viewModel.preferredCarbUnit)), number: .none)
            )
            let okMessage = NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert")
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                dismissButton: .cancel(Text(okMessage), action: viewModel.clearAlert)
            )
        case .warningQuantityValidation:
            let message = String(
                format: NSLocalizedString("Did you intend to enter %1$@ grams as the amount of carbohydrates for this meal?", comment: "Alert body when entered carbohydrates is greater than threshold (1: entered quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.carbsQuantity ?? 0), number: .none)
            )
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                primaryButton: .default(Text("No, edit amount", comment: "The title of the action used when rejecting the the amount of carbohydrates entered."), action: viewModel.clearAlert),
                secondaryButton: .cancel(Text("Yes", comment: "The title of the action used when confirming entered amount of carbohydrates."), action: viewModel.clearAlertAndContinueToBolus)
            )
        }
    }
}

// MARK: - Favorite Foods Card
extension CarbEntryView {
    private var favoriteFoodsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FAVORITE FOODS", comment: "The section title for Carb entry screen where Favorite Foods can be selected")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 26)
            
            VStack(spacing: 10) {
                Button(action: saveAsFavoriteFood) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Save as favorite food", comment: "Button label for saving current carb entry as a new Favorite Food")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(viewModel.saveFavoriteFoodButtonDisabled)

                ForEach(Array(viewModel.favoriteFoods.enumerated()), id: \.element.id) { favorite in
                    CardSectionDivider()
                    favoriteFoodRow(at: favorite.offset)
                }

                if viewModel.selectedFavoriteFoodIndex != -1 {
                    CardSectionDivider()
                    Button {
                        viewModel.selectedFavoriteFoodIndex = -1
                        clearExpandedRow()
                    } label: {
                        Text("Clear selection", comment: "Button to deselect a favorite food and reset the carb entry")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal)
            .background(CardBackground())
            .padding(.horizontal)
        }
    }
    
    private func favoriteFoodRow(at index: Int) -> some View {
        let food = viewModel.favoriteFoods[index]
        let isSelected = viewModel.selectedFavoriteFoodIndex == index
        let carbFormatter = QuantityFormatter(for: viewModel.preferredCarbUnit)

        return HStack(spacing: 4) {
            Button {
                viewModel.selectedFavoriteFoodIndex = index
                clearExpandedRow()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(food.title)
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                        Text("\(food.carbsString(formatter: carbFormatter)) carbs, \(food.absorptionTimeString(formatter: favoriteAbsorptionTimeFormatter)) absorption")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .accentColor : Color(UIColor.tertiaryLabel))
                        .accessibilityHidden(true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(role: .destructive) {
                viewModel.alert = .deleteFavoriteFood(id: food.id, name: food.name)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Delete “\(food.name)”?"))
        }
    }

    private var favoriteAbsorptionTimeFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    
    private func saveAsFavoriteFood() {
        self.showAddFavoriteFood = true
    }
    
    private func onFavoriteFoodSave(_ food: NewFavoriteFood) {
        clearExpandedRow()
        self.showAddFavoriteFood = false
        viewModel.onFavoriteFoodSave(food)
    }
}

// MARK: - Other UI Elements
extension CarbEntryView {
    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Cancel", comment: "Button label for cancel")
        }
    }
    
    private var continueButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .disabled(viewModel.continueButtonDisabled)
    }
    
    private var continueActionButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .buttonStyle(ActionButtonStyle())
        .padding()
        .disabled(viewModel.continueButtonDisabled)
    }
    
}

extension CarbEntryView {
    enum Row {
        case amountConsumed, time, foodType, absorptionTime
    }
}


/// The same editable carb/time/food/absorption rows in manual entry and photo review.
private struct CarbEntryFormFields: View {
    @ObservedObject var viewModel: CarbEntryViewModel
    @Binding var expandedRow: CarbEntryView.Row?
    @Binding var showHowAbsorptionTimeWorks: Bool
    var iconsOnly = false

    var body: some View {
        VStack(spacing: 10) {
            let amountConsumedFocused: Binding<Bool> = Binding(get: { expandedRow == .amountConsumed }, set: { expandedRow = $0 ? .amountConsumed : nil })
            let timeFocused: Binding<Bool> = Binding(get: { expandedRow == .time }, set: { expandedRow = $0 ? .time : nil })
            let foodTypeFocused: Binding<Bool> = Binding(get: { expandedRow == .foodType }, set: { expandedRow = $0 ? .foodType : nil })
            let absorptionTimeFocused: Binding<Bool> = Binding(get: { expandedRow == .absorptionTime }, set: { expandedRow = $0 ? .absorptionTime : nil })

            CarbQuantityRow(quantity: $viewModel.carbsQuantity, isFocused: amountConsumedFocused, title: NSLocalizedString("Amount Consumed", comment: "Label for carb quantity entry row on carb entry screen"), preferredCarbUnit: viewModel.preferredCarbUnit)

            CardSectionDivider()

            DatePickerRow(date: $viewModel.time, isFocused: timeFocused, minimumDate: viewModel.minimumDate, maximumDate: viewModel.maximumDate)

            CardSectionDivider()

            if iconsOnly {
                iconFoodTypeRow
            } else {
                FoodTypeRow(foodType: $viewModel.foodType, absorptionTime: $viewModel.absorptionTime, selectedDefaultAbsorptionTimeEmoji: $viewModel.selectedDefaultAbsorptionTimeEmoji, usesCustomFoodType: $viewModel.usesCustomFoodType, absorptionTimeWasEdited: $viewModel.absorptionTimeWasEdited, isFocused: foodTypeFocused, defaultAbsorptionTimes: viewModel.defaultAbsorptionTimes)
            }

            CardSectionDivider()

            AbsorptionTimePickerRow(absorptionTime: $viewModel.absorptionTime, isFocused: absorptionTimeFocused, validDurationRange: viewModel.absorptionRimesRange, minuteStride: 15, showHowAbsorptionTimeWorks: $showHowAbsorptionTimeWorks)
                .padding(.bottom, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal, iconsOnly ? 0 : 16)
    }


    private var iconFoodTypeRow: some View {
        HStack {
            Text("Food Type")
            Spacer()
            HStack(spacing: 5) {
                ForEach(CompanionMealFoodIcon.allCases, id: \.self) { icon in
                    Button {
                        expandedRow = nil
                        viewModel.foodType = ""
                        viewModel.usesCustomFoodType = false
                        viewModel.selectedDefaultAbsorptionTimeEmoji = icon.rawValue
                        switch icon {
                        case .fast: viewModel.absorptionTime = viewModel.defaultAbsorptionTimes.fast
                        case .mixed: viewModel.absorptionTime = viewModel.defaultAbsorptionTimes.medium
                        case .slow: viewModel.absorptionTime = viewModel.defaultAbsorptionTimes.slow
                        case .other: break
                        }
                        viewModel.absorptionTimeWasEdited = true
                    } label: {
                        Text(icon.rawValue).font(.title3).frame(width: 40, height: 40)
                            .background(viewModel.selectedDefaultAbsorptionTimeEmoji == icon.rawValue ? Color.gray.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain)
                    .accessibilityLabel(icon.rawValue)
                    .accessibilityAddTraits(viewModel.selectedDefaultAbsorptionTimeEmoji == icon.rawValue ? .isSelected : [])
                }
            }
        }.frame(height: 44).padding(.vertical, -8)
    }
}

/// A meal-specific review/chat, presented immediately after the camera returns a photo.
private struct MochiMealPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: CarbEntryViewModel
    @ObservedObject private var companion = CompanionController.shared
    @StateObject private var conversation: CompanionMealConversation
    let initialImage: UIImage
    let onContinue: (CompanionMealFormValues) -> Void
    @State private var expandedFormRow: CarbEntryView.Row?
    @State private var showAbsorptionInfo = false
    @State private var message = ""
    @State private var picker: MealPhotoSource?
    @State private var pendingImage: UIImage?
    @State private var photoError: String?
    @State private var processingPhoto = false
    @State private var photoTask: Task<Void, Never>?
    @State private var showSettings = false
    @FocusState private var composing: Bool

    init(viewModel: CarbEntryViewModel, initialImage: UIImage, onContinue: @escaping (CompanionMealFormValues) -> Void) {
        let draft = CarbEntryViewModel(mealReviewDraftFrom: viewModel)
        _draft = StateObject(wrappedValue: draft)
        self.initialImage = initialImage
        self.onContinue = onContinue
        _conversation = StateObject(wrappedValue: CompanionMealConversation(controller: .shared,
            maximumGrams: viewModel.maxCarbEntryQuantity.doubleValue(for: .gram()),
            absorptionRange: viewModel.absorptionRimesRange,
            defaults: [viewModel.defaultAbsorptionTimes.fast, viewModel.defaultAbsorptionTimes.medium, viewModel.defaultAbsorptionTimes.slow],
            dateRange: draft.minimumDate...draft.maximumDate,
            currentFormReader: { draft.mealFormValues },
            onFormUpdate: { estimate in
                if let estimate { draft.applyMealEstimate(estimate) }
                else { draft.carbsQuantity = nil }
            }))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                chat
                if let error = photoError ?? conversation.error ?? conversation.submissionError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundColor(.red)
                        HStack {
                            if conversation.needsReply && !conversation.isThinking {
                                Button("Try again") { conversation.retry() }
                                Button("Discard message") { conversation.discardPending() }
                            }
                            if photoError != nil { Button("Dismiss") { photoError = nil } }
                            if !companion.hasKey { Button("Connect Mochi") { showSettings = true } }
                        }.font(.footnote)
                    }.padding(.horizontal).padding(.bottom, 8)
                }
                composer
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Review meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Mochi model and connection settings").disabled(conversation.isThinking || processingPhoto)
                }
            }
            .fullScreenCover(item: $picker, onDismiss: {
                if let image = pendingImage {
                    pendingImage = nil
                    submitPhoto(image, initial: false)
                }
            }) { source in
                MealPhotoPicker(source: source, onSelect: { pendingImage = $0 }, onError: { photoError = $0 })
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                if companion.hasKey && conversation.needsReply { conversation.retry() }
            }) { CompanionSettingsView(controller: companion) }
            .sheet(isPresented: $showAbsorptionInfo) { HowAbsorptionTimeWorksView() }
            .onAppear {
                if conversation.turns.isEmpty { submitPhoto(initialImage, initial: true) }
            }
            .onDisappear { photoTask?.cancel(); conversation.cancel() }
        }
    }

    private var mealForm: some View {
        VStack(spacing: 10) {
            CarbEntryFormFields(viewModel: draft, expandedRow: $expandedFormRow,
                                showHowAbsorptionTimeWorks: $showAbsorptionInfo, iconsOnly: true)
                .disabled(conversation.isThinking || conversation.needsReply || processingPhoto)
            Text("Photo estimates are approximate. You can edit the form or ask Mochi to adjust it.")
                .font(.caption).foregroundColor(.secondary)
            Button {
                guard conversation.canUseForm, let values = draft.validMealFormValues else { return }
                composing = false
                expandedFormRow = nil
                onContinue(values)
                dismiss()
            } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(ActionButtonStyle())
                .disabled(!conversation.canUseForm || draft.validMealFormValues == nil || photoError != nil || processingPhoto)
                .accessibilityHint("Use these form values and open the normal bolus review")
        }.id("meal-form")
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    mealForm
                    ForEach(conversation.turns) { turn in
                        HStack {
                            if turn.reply == nil { Spacer(minLength: 32) }
                            VStack(alignment: .leading, spacing: 8) {
                                if let jpeg = turn.jpeg { MealPhotoThumbnail(jpeg: jpeg) }
                                Text(turn.text).font(.subheadline).textSelection(.enabled)
                            }
                            .padding(12)
                            .background(turn.reply == nil ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            if turn.reply != nil { Spacer(minLength: 24) }
                        }.id(turn.id)
                    }
                    if processingPhoto {
                        ProgressView("Preparing photo…")
                    }
                    if !conversation.canSend && !conversation.isThinking && !conversation.needsReply {
                        Text("This meal chat is full. You can still edit the form and continue.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if conversation.isThinking {
                        HStack { ProgressView(); Text("Mochi is looking…").font(.footnote).foregroundColor(.secondary) }
                        Button("Cancel", role: .cancel) { conversation.cancel() }.font(.footnote)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding()
            }
            .onChange(of: conversation.turns.count) { count in
                if count > 2 { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 12) {
            Menu {
                Button { composing = false; picker = MealPhotoSource.preferredCapture } label: { Label("Take another photo", systemImage: "camera") }
                Button { composing = false; picker = .library } label: { Label("Choose from photos", systemImage: "photo") }
            } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .disabled(!conversation.canAddPhoto || processingPhoto)
                .accessibilityLabel("Add a meal photo")
            TextField("Ask about this meal…", text: $message)
                .focused($composing).submitLabel(.send).onSubmit(sendMessage)
                .disabled(conversation.isThinking || conversation.needsReply || processingPhoto)
            Button(action: sendMessage) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conversation.canSend || processingPhoto)
                .accessibilityLabel("Send meal question")
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func sendMessage() {
        composing = false
        guard !processingPhoto else { return }
        if conversation.send(message) { message = "" }
    }

    private func submitPhoto(_ image: UIImage, initial: Bool) {
        guard !processingPhoto else { return }
        photoError = nil
        processingPhoto = true
        let draftMessage = message
        photoTask = Task { @MainActor in
            defer { processingPhoto = false; photoTask = nil }
            do {
                let jpeg = try await MealPhotoProcessing.jpeg(from: image)
                try Task.checkCancellation()
                let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                let accepted = conversation.send(initial ? "What do you think is in this meal?" : (text.isEmpty ? "Here’s another photo of the same meal." : text), jpeg: jpeg)
                if accepted && message == draftMessage { message = "" }
            } catch is CancellationError { }
            catch { photoError = error.localizedDescription }
        }
    }
}

enum MealPhotoProcessing {
    private static let queue = DispatchQueue(label: "Mochi.MealPhotoProcessing", qos: .userInitiated)

    static func jpeg(from image: UIImage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try autoreleasepool { try normalizedJPEG(from: image) }) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func normalizedJPEG(from image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw CompanionError.invalid("This photo couldn’t be opened. Choose another image.")
        }
        // Normalize orientation and remove source EXIF/location metadata before sending.
        let scale = min(1, 1280 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8), jpeg.count <= 2_000_000 else {
            throw CompanionError.invalid("This photo is too large. Choose another image.")
        }
        return jpeg
    }
}

private struct MealPhotoThumbnail: View {
    let jpeg: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView().frame(height: 90)
            }
        }
        .task {
            guard image == nil else { return }
            let decoded = await Task.detached(priority: .userInitiated) { UIImage(data: jpeg) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

private enum MealPhotoSource: String, Identifiable {
    case camera, library
    var id: String { rawValue }

    static var preferredCapture: Self { .camera }
}

private struct MealPhotoPicker: UIViewControllerRepresentable {
    let source: MealPhotoSource
    let onSelect: (UIImage) -> Void
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIViewController {
        if source == .camera {
            return MochiMealCameraController(onSelect: { image in
                onSelect(image)
                dismiss()
            }, onCancel: { dismiss() })
        }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MealPhotoPicker
        init(parent: MealPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { parent.dismiss(); return }
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onError("This photo couldn’t be opened. Choose another image.")
                parent.dismiss()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [self] object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage { parent.onSelect(image) }
                    else { parent.onError("This photo couldn’t be opened. Choose another image.") }
                    parent.dismiss()
                }
            }
        }
    }
}


/// Shared camera/library surface. Simulator retains the library button without a fake live feed.
private final class MochiMealCameraController: UIViewController, AVCapturePhotoCaptureDelegate, PHPickerViewControllerDelegate {
    private let onSelect: (UIImage) -> Void
    private let onCancel: () -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "Mochi.MealCamera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var frontCamera = false
    private var finished = false
    private var capturing = false
    private var preview: AVCaptureVideoPreviewLayer!
    private let shutter = UIButton(type: .system)
    private let flip = UIButton(type: .system)
    private let status = UILabel()

    init(onSelect: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        status.textColor = .white
        status.numberOfLines = 0
        status.textAlignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .white
        close.accessibilityLabel = "Cancel meal photo"
        close.addAction(UIAction { [weak self] _ in self?.cancelCapture() }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)

        let library = UIButton(type: .system)
        library.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        library.tintColor = .white
        library.accessibilityLabel = "Choose from photos"
        library.addAction(UIAction { [weak self] _ in self?.choosePhoto() }, for: .touchUpInside)
        shutter.setImage(UIImage(systemName: "circle.inset.filled"), for: .normal)
        shutter.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 64), forImageIn: .normal)
        shutter.tintColor = .white
        shutter.accessibilityLabel = "Take meal photo"
        shutter.isEnabled = false
        shutter.addAction(UIAction { [weak self] _ in self?.takePhoto() }, for: .touchUpInside)
        flip.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        flip.tintColor = .white
        flip.accessibilityLabel = "Switch camera"
        flip.isEnabled = false
        flip.addAction(UIAction { [weak self] _ in self?.switchCamera() }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [library, shutter, flip])
        controls.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        controls.layer.cornerRadius = 22
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .equalSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        for button in [library, flip] {
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 26), forImageIn: .normal)
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            close.widthAnchor.constraint(equalToConstant: 44), close.heightAnchor.constraint(equalToConstant: 44),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            controls.heightAnchor.constraint(equalToConstant: 80),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if targetEnvironment(simulator)
        status.text = "Camera preview isn’t available in Simulator.\nChoose a photo using the button below."
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.view.window != nil else { return }
                    if allowed { self.startCamera() }
                    else { self.status.text = "Camera access is off. Choose a photo below, or allow camera access in Settings." }
                }
            }
        default: status.text = "Camera access is off. Choose a photo below, or allow camera access in Settings."
        }
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    private func startCamera() {
        sessionQueue.async { [self] in
            do {
                if !configured {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw CompanionError.invalid("No camera is available. Choose a photo below.")
                    }
                    let cameraInput = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    guard session.canAddInput(cameraInput), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw CompanionError.invalid("The camera couldn’t start. Choose a photo below.")
                    }
                    session.addInput(cameraInput)
                    session.addOutput(output)
                    session.commitConfiguration()
                    input = cameraInput
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
                DispatchQueue.main.async { [self] in shutter.isEnabled = true; flip.isEnabled = true; status.text = nil }
            } catch { DispatchQueue.main.async { [self] in status.text = error.localizedDescription } }
        }
    }

    private func takePhoto() {
        guard session.isRunning, !finished, !capturing else { return }
        capturing = true
        shutter.isEnabled = false
        flip.isEnabled = false
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    private func switchCamera() {
        frontCamera.toggle()
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        shutter.isEnabled = false
        flip.isEnabled = false
        sessionQueue.async { [self] in
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let newInput = try? AVCaptureDeviceInput(device: device), let oldInput = input {
                session.beginConfiguration()
                session.removeInput(oldInput)
                if session.canAddInput(newInput) { session.addInput(newInput); input = newInput }
                else { session.addInput(oldInput) }
                session.commitConfiguration()
            }
            DispatchQueue.main.async { [self] in shutter.isEnabled = true; flip.isEnabled = true }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        DispatchQueue.main.async { [self] in
            guard !finished else { return }
            capturing = false
            if let image { finish(image) }
            else { status.text = "That photo couldn’t be captured. Try again or choose one below."; shutter.isEnabled = true; flip.isEnabled = true }
        }
    }

    private func finish(_ image: UIImage) {
        guard !finished else { return }
        finished = true
        onSelect(image)
    }

    private func cancelCapture() {
        guard !finished else { return }
        finished = true
        onCancel()
    }

    private func choosePhoto() {
        guard !finished, !capturing else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider else { picker.dismiss(animated: true); return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                picker.dismiss(animated: true) {
                    if let image = object as? UIImage { self?.finish(image) }
                    else { self?.status.text = "This photo couldn’t be opened. Choose another image." }
                }
            }
        }
    }
}
