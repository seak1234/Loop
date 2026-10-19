//
//  CarbEntryViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/21/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import HealthKit
import Combine

protocol CarbEntryViewModelDelegate: AnyObject, BolusEntryViewModelDelegate {
    var analyticsServicesManager: AnalyticsServicesManager { get }
    var defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes { get }
}

final class CarbEntryViewModel: ObservableObject {
    enum Alert: Identifiable, Hashable {
        var id: Self {
            return self
        }
        
        case maxQuantityExceded
        case warningQuantityValidation
        case deleteFavoriteFood(id: String, name: String)
    }
    
    enum Warning: Identifiable {
        var id: Self {
            return self
        }
        
        var priority: Int {
            switch self {
            case .entryIsMissedMeal:
                return 1
            case .overrideInProgress:
                return 2
            }
        }
        
        case entryIsMissedMeal
        case overrideInProgress
    }
    
    @Published var alert: CarbEntryViewModel.Alert?
    @Published var warnings: Set<Warning> = []

    @Published var bolusViewModel: BolusEntryViewModel?
    
    let shouldBeginEditingQuantity: Bool
    
    @Published var carbsQuantity: Double? = nil
    var preferredCarbUnit = HKUnit.gram()
    var maxCarbEntryQuantity = LoopConstants.maxCarbEntryQuantity
    var warningCarbEntryQuantity = LoopConstants.warningCarbEntryQuantity
    
    @Published var time = Date()
    private var date = Date()
    var minimumDate: Date {
        get { date.addingTimeInterval(LoopConstants.maxCarbEntryPastTime) }
    }
    var maximumDate: Date {
        get { date.addingTimeInterval(LoopConstants.maxCarbEntryFutureTime) }
    }
    
    @Published var foodType = ""
    @Published var selectedDefaultAbsorptionTimeEmoji: String = "🍗"
    @Published var usesCustomFoodType = false
    @Published var absorptionTimeWasEdited = false // if true, selecting an emoji will not alter the absorption time
    private var absorptionEditIsProgrammatic = false // needed for when absorption time is changed due to favorite food selection, so that absorptionTimeWasEdited does not get set to true

    @Published var absorptionTime: TimeInterval
    let defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes
    let minAbsorptionTime = LoopConstants.minCarbAbsorptionTime
    let maxAbsorptionTime = LoopConstants.maxCarbAbsorptionTime
    var absorptionRimesRange: ClosedRange<TimeInterval> {
        return minAbsorptionTime...maxAbsorptionTime
    }
    
    @Published var favoriteFoods = UserDefaults.standard.favoriteFoods
    @Published var selectedFavoriteFoodIndex = -1
    private var isUpdatingFavoriteSelection = false
    
    weak var delegate: CarbEntryViewModelDelegate?
    
    private lazy var cancellables = Set<AnyCancellable>()
    
    /// Initalizer for when`CarbEntryView` is presented from the home screen
    init(delegate: CarbEntryViewModelDelegate) {
        self.delegate = delegate
        self.absorptionTime = delegate.defaultAbsorptionTimes.slow
        self.defaultAbsorptionTimes = delegate.defaultAbsorptionTimes
        self.shouldBeginEditingQuantity = true
        
        observeAbsorptionTimeChange()
        observeFavoriteFoodChange()
        observeFavoriteFoodIndexChange()
        observeLoopUpdates()
    }
    
    /// Isolated editable draft for photo review. Closing review leaves the original form untouched.
    init(mealReviewDraftFrom source: CarbEntryViewModel) {
        delegate = source.delegate
        defaultAbsorptionTimes = source.defaultAbsorptionTimes
        shouldBeginEditingQuantity = false
        absorptionTime = source.absorptionTime
        carbsQuantity = source.carbsQuantity
        preferredCarbUnit = source.preferredCarbUnit
        maxCarbEntryQuantity = source.maxCarbEntryQuantity
        warningCarbEntryQuantity = source.warningCarbEntryQuantity
        time = source.time
        date = source.date
        selectedDefaultAbsorptionTimeEmoji = source.selectedDefaultAbsorptionTimeEmoji
        usesCustomFoodType = false
        absorptionTimeWasEdited = source.absorptionTimeWasEdited
        observeAbsorptionTimeChange()
        observeLoopUpdates()
    }

    /// Initalizer for when`CarbEntryView` has an entry to edit
    init(delegate: CarbEntryViewModelDelegate, originalCarbEntry: StoredCarbEntry) {
        self.delegate = delegate
        self.originalCarbEntry = originalCarbEntry
        self.defaultAbsorptionTimes = delegate.defaultAbsorptionTimes

        self.carbsQuantity = originalCarbEntry.quantity.doubleValue(for: preferredCarbUnit)
        self.time = originalCarbEntry.startDate
        self.foodType = originalCarbEntry.foodType ?? ""
        self.absorptionTime = originalCarbEntry.absorptionTime ?? .hours(3)
        self.absorptionTimeWasEdited = true
        self.usesCustomFoodType = true
        self.shouldBeginEditingQuantity = false
        
        observeLoopUpdates()
    }
    
    var originalCarbEntry: StoredCarbEntry? = nil
    private var favoriteFood: FavoriteFood? = nil
    
    private var updatedCarbEntry: NewCarbEntry? {
        if let quantity = carbsQuantity, quantity != 0 {
            if let o = originalCarbEntry, o.quantity.doubleValue(for: preferredCarbUnit) == quantity && o.startDate == time && o.foodType == foodType && o.absorptionTime == absorptionTime {
                return nil  // No changes were made
            }
            
            return NewCarbEntry(
                date: date,
                quantity: HKQuantity(unit: preferredCarbUnit, doubleValue: quantity),
                startDate: time,
                foodType: usesCustomFoodType ? foodType : selectedDefaultAbsorptionTimeEmoji,
                absorptionTime: absorptionTime
            )
        }
        else {
            return nil
        }
    }
    
    var saveFavoriteFoodButtonDisabled: Bool {
        get {
            if let carbsQuantity, 0...maxCarbEntryQuantity.doubleValue(for: preferredCarbUnit) ~= carbsQuantity, selectedFavoriteFoodIndex == -1 {
                return false
            }
            return true
        }
    }
    
    var continueButtonDisabled: Bool {
        get { updatedCarbEntry == nil }
    }
    
    var mealFormValues: CompanionMealFormValues {
        .init(grams: carbsQuantity, food: selectedDefaultAbsorptionTimeEmoji,
              absorptionMinutes: Int(absorptionTime / 60), time: time)
    }

    var validMealFormValues: CompanionMealFormValues? {
        let values = mealFormValues
        return mealFormValuesAreValid(values) ? values : nil
    }

    private func mealFormValuesAreValid(_ values: CompanionMealFormValues) -> Bool {
        guard let grams = values.grams, grams.isFinite, grams > 0,
              grams <= maxCarbEntryQuantity.doubleValue(for: preferredCarbUnit),
              CompanionMealFoodIcon(food: values.food) != nil,
              absorptionRimesRange.contains(Double(values.absorptionMinutes) * 60),
              (minimumDate...maximumDate).contains(values.time) else { return false }
        return true
    }

    /// Transfer the reviewed fields only; the caller explicitly invokes the normal Continue flow.
    @discardableResult
    func applyMealFormValues(_ values: CompanionMealFormValues) -> Bool {
        guard mealFormValuesAreValid(values), let icon = CompanionMealFoodIcon(food: values.food) else { return false }
        isUpdatingFavoriteSelection = true
        selectedFavoriteFoodIndex = -1
        isUpdatingFavoriteSelection = false
        carbsQuantity = values.grams
        foodType = ""
        selectedDefaultAbsorptionTimeEmoji = icon.rawValue
        usesCustomFoodType = false
        absorptionTime = Double(values.absorptionMinutes) * 60
        absorptionTimeWasEdited = true
        time = values.time
        return true
    }

    /// Populate an unsaved draft. AI food types are limited to the existing shortcut icons.
    func applyMealEstimate(_ estimate: CompanionMealEstimate) {
        guard let icon = CompanionMealFoodIcon(food: estimate.food),
              estimate.grams.isFinite, estimate.grams >= 0,
              estimate.grams <= maxCarbEntryQuantity.doubleValue(for: preferredCarbUnit),
              absorptionRimesRange.contains(Double(estimate.absorptionMinutes) * 60),
              estimate.mealTime.map({ (minimumDate...maximumDate).contains($0) }) ?? true else { return }
        isUpdatingFavoriteSelection = true
        selectedFavoriteFoodIndex = -1
        isUpdatingFavoriteSelection = false
        carbsQuantity = estimate.grams
        foodType = ""
        selectedDefaultAbsorptionTimeEmoji = icon.rawValue
        usesCustomFoodType = false
        absorptionTime = Double(estimate.absorptionMinutes) * 60
        absorptionTimeWasEdited = true
        if let mealTime = estimate.mealTime { time = mealTime }
    }

    // MARK: - Continue to Bolus and Carb Quantity Warnings
    func continueToBolus() {
        guard updatedCarbEntry != nil else {
            return
        }
        
        validateInputAndContinue()
    }
    
    private func validateInputAndContinue() {
        guard absorptionRimesRange.contains(absorptionTime) else {
            return
        }
        
        guard let carbsQuantity, carbsQuantity > 0 else { return }
        let quantity = HKQuantity(unit: preferredCarbUnit, doubleValue: carbsQuantity)
        if quantity.compare(maxCarbEntryQuantity) == .orderedDescending {
            self.alert = .maxQuantityExceded
            return
        }
        else if quantity.compare(warningCarbEntryQuantity) == .orderedDescending, selectedFavoriteFoodIndex == -1 {
            self.alert = .warningQuantityValidation
            return
        }
        
        Task { @MainActor in
            setBolusViewModel()
        }
    }
        
    @MainActor private func setBolusViewModel() {
        let viewModel = BolusEntryViewModel(
            delegate: delegate,
            screenWidth: UIScreen.main.bounds.width,
            originalCarbEntry: originalCarbEntry,
            potentialCarbEntry: updatedCarbEntry,
            selectedCarbAbsorptionTimeEmoji: selectedDefaultAbsorptionTimeEmoji
        )
        Task {
            await viewModel.generateRecommendationAndStartObserving()
        }
        
        viewModel.analyticsServicesManager = delegate?.analyticsServicesManager
        bolusViewModel = viewModel
        
        delegate?.analyticsServicesManager.didDisplayBolusScreen()
    }
    
    func clearAlert() {
        self.alert = nil
    }
    
    func clearAlertAndContinueToBolus() {
        self.alert = nil
        Task { @MainActor in
            setBolusViewModel()
        }
    }
    
    // MARK: - Favorite Foods
    func onFavoriteFoodSave(_ food: NewFavoriteFood) {
        let newStoredFood = StoredFavoriteFood(name: food.name, carbsQuantity: food.carbsQuantity, foodType: food.foodType, absorptionTime: food.absorptionTime)
        favoriteFoods.append(newStoredFood)
        selectedFavoriteFoodIndex = favoriteFoods.count - 1
    }

    func onFavoriteFoodDelete(_ food: StoredFavoriteFood) {
        guard let index = favoriteFoods.firstIndex(where: { $0.id == food.id }) else { return }

        // Removing a saved shortcut must not change the carb entry being composed.
        isUpdatingFavoriteSelection = true
        defer { isUpdatingFavoriteSelection = false }
        favoriteFoods.remove(at: index)
        if selectedFavoriteFoodIndex == index {
            selectedFavoriteFoodIndex = -1
        } else if selectedFavoriteFoodIndex > index {
            selectedFavoriteFoodIndex -= 1
        }
    }
    
    private func observeFavoriteFoodIndexChange() {
        $selectedFavoriteFoodIndex
            .dropFirst()
            .sink { [weak self] index in
                guard self?.isUpdatingFavoriteSelection == false else { return }
                self?.favoriteFoodSelected(at: index)
            }
            .store(in: &cancellables)
    }
    
    private func observeFavoriteFoodChange() {
        $favoriteFoods
            .dropFirst()
            .removeDuplicates()
            .sink { newValue in
                UserDefaults.standard.favoriteFoods = newValue
            }
            .store(in: &cancellables)
    }

    private func favoriteFoodSelected(at index: Int) {
        guard index == -1 || favoriteFoods.indices.contains(index) else { return }
        self.absorptionEditIsProgrammatic = true
        if index == -1 {
            self.carbsQuantity = 0
            self.foodType = ""
            self.selectedDefaultAbsorptionTimeEmoji = "🍗"
            self.absorptionTime = defaultAbsorptionTimes.slow
            self.absorptionTimeWasEdited = false
            self.usesCustomFoodType = false
        }
        else {
            let food = favoriteFoods[index]
            self.carbsQuantity = food.carbsQuantity.doubleValue(for: preferredCarbUnit)
            self.foodType = food.foodType
            self.absorptionTime = food.absorptionTime
            self.absorptionTimeWasEdited = true
            self.usesCustomFoodType = true
        }
    }
    
    // MARK: - Utility
    func restoreUserActivityState(_ activity: NSUserActivity) {
        if let entry = activity.newCarbEntry {
            time = entry.date
            carbsQuantity = entry.quantity.doubleValue(for: preferredCarbUnit)

            if let foodType = entry.foodType {
                self.foodType = foodType
                usesCustomFoodType = true
            }

            if let absorptionTime = entry.absorptionTime {
                self.absorptionTime = absorptionTime
                absorptionTimeWasEdited = true
            }
            
            if activity.entryisMissedMeal {
                warnings.insert(.entryIsMissedMeal)
            }
        }
    }
    
    private func observeLoopUpdates() {
        self.checkIfOverrideEnabled()
        NotificationCenter.default
            .publisher(for: .LoopDataUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkIfOverrideEnabled()
            }
            .store(in: &cancellables)
    }
    
    private func checkIfOverrideEnabled() {
        if let managerSettings = delegate?.settings,
           managerSettings.scheduleOverrideEnabled(at: Date()),
           let overrideSettings = managerSettings.scheduleOverride?.settings,
           overrideSettings.effectiveInsulinNeedsScaleFactor != 1.0 {
            self.warnings.insert(.overrideInProgress)
        }
        else {
            self.warnings.remove(.overrideInProgress)
        }
    }
    
    private func observeAbsorptionTimeChange() {
        $absorptionTime
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                if self?.absorptionEditIsProgrammatic == true {
                    self?.absorptionEditIsProgrammatic = false
                }
                else {
                    self?.absorptionTimeWasEdited = true
                }
            }
            .store(in: &cancellables)
    }
}
