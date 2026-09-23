//
//  BolusEntryView.swift
//  Loop
//
//  Created by Michael Pangburn on 7/17/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Combine
import HealthKit
import SwiftUI
import LoopKit
import LoopKitUI
import LoopUI


struct BolusEntryView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) var dismiss
    @Environment(\.appName) var appName
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ObservedObject var viewModel: BolusEntryViewModel

    @State private var enteredBolusString = ""
    @State private var isInteractingWithChart = false
    @State private var editedBolusAmount = false

    @FocusState private var bolusFieldFocused: Bool

    private var accessoryClearance: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 72 : 52
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                List {
                    self.chartSection
                        .listRowBackground(Color.dashboardSurface)
                    self.summarySection
                        .listRowBackground(Color.dashboardSurface)
                }
                .insetGroupedListStyle()
                .dashboardScrollBackground()
            }
            .navigationBarTitle(self.title)
            .supportedInterfaceOrientations(.portrait)
            .alert(item: self.$viewModel.activeAlert, content: self.alert(for:))
            .onReceive(self.viewModel.$recommendedBolus) { recommendation in
                // If the recommendation changes, and the user has not edited the bolus amount, update the bolus amount
                let amount = recommendation?.doubleValue(for: .internationalUnit()) ?? 0
                if !editedBolusAmount {
                    var newEnteredBolusString: String
                    if amount == 0 {
                        newEnteredBolusString = ""
                    } else {
                        newEnteredBolusString = viewModel.formatBolusAmount(amount)
                    }
                    enteredBolusStringBinding.wrappedValue = newEnteredBolusString
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bolusFieldFocused {
                    // Reserve space so the toolbar doesn’t overlap the field
                    Color.clear.frame(height: accessoryClearance)
                } else {
                    actionArea
                }
            }
        }
    }
    
    private var title: Text {
        if viewModel.potentialCarbEntry == nil {
            return Text("Bolus", comment: "Title for bolus entry screen")
        }
        return Text("Meal Bolus", comment: "Title for bolus entry screen when also entering carbs")
    }

    private var chartSection: some View {
        Section {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    activeCarbsLabel
                    Spacer(minLength: 8)
                    activeInsulinLabel
                }

                // Use a ZStack to allow horizontally clipping the predicted glucose chart,
                // without clipping the point label on highlight, which draws outside the view's bounds.
                ZStack(alignment: .topLeading) {
                    Text("Glucose", comment: "Title for predicted glucose chart on bolus screen")
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundColor(.dashboardGlucoseAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(isInteractingWithChart ? 0 : 1)

                    predictedGlucoseChart
                        .padding(.horizontal, -4)
                        .padding(.top, UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 8) // Leave space for the 'Glucose' label + spacing
                        .clipped()
                }
                .frame(height: ceil(UIScreen.main.bounds.height / 4))

                if !FeatureFlags.usePositiveMomentumAndRCForManualBoluses {
                    Divider()
                    Button(action: {
                        viewModel.activeAlert = .forecastInfo
                    }) {
                        HStack {
                            Text("Forecasted blood glucose may still be higher than target range.")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundColor(.dashboardMutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "info.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.dashboardInsulinAccent)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }

            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var activeCarbsLabel: some View {
        LabeledQuantity(
            label: Text("Active Carbs", comment: "Title describing quantity of still-absorbing carbohydrates"),
            quantity: viewModel.activeCarbs,
            unit: .gram(),
            accentColor: .dashboardCarbAccent
        )
    }
    
    @ViewBuilder
    private var activeInsulinLabel: some View {
        LabeledQuantity(
            label: Text("Active Insulin", comment: "Title describing quantity of still-absorbing insulin"),
            quantity: viewModel.activeInsulin,
            unit: .internationalUnit(),
            maxFractionDigits: 2,
            accentColor: .dashboardInsulinAccent
        )
    }

    private var predictedGlucoseChart: some View {
        PredictedGlucoseChartView(
            chartManager: viewModel.chartManager,
            glucoseUnit: displayGlucosePreference.unit,
            glucoseValues: viewModel.glucoseValues,
            predictedGlucoseValues: viewModel.predictedGlucoseValues,
            targetGlucoseSchedule: viewModel.targetGlucoseSchedule,
            preMealOverride: viewModel.preMealOverride,
            scheduleOverride: viewModel.scheduleOverride,
            dateInterval: viewModel.chartDateInterval,
            isInteractingWithChart: $isInteractingWithChart
        )
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 16) {
                titleText
                    .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.isManualGlucoseEntryEnabled {
                    ManualGlucoseEntryRow(quantity: $viewModel.manualGlucoseQuantity)
                } else if viewModel.potentialCarbEntry != nil {
                    potentialCarbEntryRow
                } else {
                    recommendedBolusRow
                }
            }
            .padding(.top, 8)
            
            if viewModel.isManualGlucoseEntryEnabled && viewModel.potentialCarbEntry != nil {
                potentialCarbEntryRow
            }

            if viewModel.isManualGlucoseEntryEnabled || viewModel.potentialCarbEntry != nil {
                recommendedBolusRow
            }

            bolusEntryRow
        }
    }
    
    private var titleText: some View {
        Text("Bolus Summary", comment: "Title for card displaying carb entry and bolus recommendation")
            .font(.system(.headline, design: .rounded).bold())
            .foregroundColor(.dashboardInk)
    }

    private var glucoseFormatter: NumberFormatter {
        QuantityFormatter(for: displayGlucosePreference.unit).numberFormatter
    }


    @ViewBuilder
    private var potentialCarbEntryRow: some View {
        if viewModel.carbEntryAmountAndEmojiString != nil && viewModel.carbEntryDateAndAbsorptionTimeString != nil {
            HStack {
                Text("Carb Entry", comment: "Label for carb entry row on bolus screen")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.dashboardInk)

                Text(viewModel.carbEntryAmountAndEmojiString!)
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundColor(.dashboardCarbAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.dashboardCarbAccent.opacity(0.12))
                    )

                Spacer()

                Text(viewModel.carbEntryDateAndAbsorptionTimeString!)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.dashboardMutedInk)
            }
        }
    }

    private var recommendedBolusRow: some View {
        HStack {
            Text("Recommended Bolus", comment: "Label for recommended bolus row on bolus screen")
                .font(.system(.body, design: .rounded))
                .foregroundColor(.dashboardInk)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.recommendedBolusString)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.dashboardInsulinAccent)
                bolusUnitsLabel
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func didBeginEditing() {
        if !editedBolusAmount {
            enteredBolusStringBinding.wrappedValue = ""
            editedBolusAmount = true
        }
    }

    private var bolusEntryRow: some View {
        HStack {
            Text("Bolus", comment: "Label for bolus entry row on bolus screen")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.dashboardInk)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField(viewModel.formatBolusAmount(0.0), text: enteredBolusStringBinding)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.dashboardInsulinAccent)
                    .focused($bolusFieldFocused)
                    .onChange(of: bolusFieldFocused) { focused in
                        if focused {
                            didBeginEditing()
                        }
                    }
                    .onChange(of: enteredBolusString) { newValue in
                        if newValue.count > 5 {
                            enteredBolusString = String(newValue.prefix(5))
                            viewModel.updateEnteredBolus(enteredBolusString)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.dashboardInsulinAccent.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.dashboardInsulinAccent.opacity(bolusFieldFocused ? 0.6 : 0.2), lineWidth: bolusFieldFocused ? 1.5 : 1)
                    )
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { bolusFieldFocused = false }
                                .font(.system(.body, design: .rounded).bold())
                                .foregroundColor(.dashboardInsulinAccent)
                        }
                    }
                bolusUnitsLabel
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var bolusUnitsLabel: some View {
        Text(QuantityFormatter(for: .internationalUnit()).localizedUnitStringWithPlurality())
            .font(.system(.body, design: .rounded))
            .foregroundColor(.dashboardMutedInk)
    }

    private var enteredBolusStringBinding: Binding<String> {
        Binding(
            get: { enteredBolusString },
            set: { newValue in
                viewModel.updateEnteredBolus(newValue)
                enteredBolusString = newValue
            }
        )
    }

    private var actionArea: some View {
        VStack(spacing: 8) {
            if viewModel.isNoticeVisible {
                warning(for: viewModel.activeNotice!)
                    .padding([.top, .horizontal])
                    .transition(AnyTransition.opacity.combined(with: .move(edge: .bottom)))
            }

            if viewModel.isManualGlucosePromptVisible {
                enterManualGlucoseButton
                    .transition(AnyTransition.opacity.combined(with: .move(edge: .bottom)))
            }

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            Color.dashboardSurface
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: -3)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.dashboardBorder),
                    alignment: .top
                )
        )
    }

    private func warning(for notice: BolusEntryViewModel.Notice) -> some View {
        switch notice {
        case .predictedGlucoseBelowSuspendThreshold(suspendThreshold: let suspendThreshold):
            let suspendThresholdString = displayGlucosePreference.format(suspendThreshold)
            return WarningView(
                title: Text("No Bolus Recommended", comment: "Title for bolus screen notice when no bolus is recommended"),
                caption: Text("Your glucose is below or predicted to go below your glucose safety limit, \(suspendThresholdString).", comment: "Caption for bolus screen notice when no bolus is recommended due to prediction dropping below glucose safety limit")
            )
        case .staleGlucoseData:
            return WarningView(
                title: Text("No Recent Glucose Data", comment: "Title for bolus screen notice when glucose data is missing or stale"),
                caption: Text("Enter a blood glucose from a meter for a recommended bolus amount.", comment: "Caption for bolus screen notice when glucose data is missing or stale")
            )
        case .futureGlucoseData:
            return WarningView(
                title: Text("Invalid Future Glucose", comment: "Title for bolus screen notice when glucose data is in the future"),
                caption: Text("Check your device time and/or remove any invalid data from Apple Health.", comment: "Caption for bolus screen notice when glucose data is in the future")
            )
        case .stalePumpData:
            return WarningView(
                title: Text("No Recent Pump Data", comment: "Title for bolus screen notice when pump data is missing or stale"),
                caption: Text(String(format: NSLocalizedString("Your pump data is stale. %1$@ cannot recommend a bolus amount.", comment: "Caption for bolus screen notice when pump data is missing or stale"), appName)),
                severity: .critical
            )
        case .predictedGlucoseInRange, .glucoseBelowTarget:
            return WarningView(
                title: Text("No Bolus Recommended", comment: "Title for bolus screen notice when no bolus is recommended"),
                caption: Text("Based on your predicted glucose, no bolus is recommended.", comment: "Caption for bolus screen notice when no bolus is recommended for the predicted glucose")
            )
        }
    }
            
    private var enterManualGlucoseButton: some View {
        Button(
            action: {
                withAnimation {
                    self.viewModel.isManualGlucoseEntryEnabled = true
                }
            },
            label: { Text("Enter Fingerstick Glucose", comment: "Button text prompting manual glucose entry on bolus screen") }
        )
        .buttonStyle(DashboardActionButtonStyle(isPrimary: viewModel.primaryButton == .manualGlucoseEntry))
        .padding(.top, 4)
    }

    private var actionButton: some View {
        Button<Text>(
            action: {
                if self.viewModel.actionButtonAction == .enterBolus {
                    self.bolusFieldFocused = true
                } else {
                    Task {
                        if await self.viewModel.didPressActionButton() {
                            dismiss()
                        }
                    }
                }
            },
            label: {
                switch viewModel.actionButtonAction {
                case .saveWithoutBolusing:
                    return Text("Save without Bolusing", comment: "Button text to save carbs and/or manual glucose entry without a bolus")
                case .saveAndDeliver:
                    return Text("Save Carbs & Deliver", comment: "Button text to save carbs and/or manual glucose entry and deliver a bolus")
                case .enterBolus:
                    return Text("Enter Bolus", comment: "Button text to begin entering a bolus")
                case .deliver:
                    return Text("Deliver", comment: "Button text to deliver a bolus")
                }
            }
        )
        .buttonStyle(DashboardActionButtonStyle(isPrimary: viewModel.primaryButton == .actionButton))
        .disabled(viewModel.enacting)
        .padding(.bottom, 6)
    }

    private func alert(for alert: BolusEntryViewModel.Alert) -> SwiftUI.Alert {
        switch alert {
        case .recommendationChanged:
            return SwiftUI.Alert(
                title: Text("Bolus Recommendation Updated", comment: "Alert title for an updated bolus recommendation"),
                message: Text("The bolus recommendation has updated. Please reconfirm the bolus amount.", comment: "Alert message for an updated bolus recommendation")
            )
        case .maxBolusExceeded:
            guard let maximumBolusAmountString = viewModel.maximumBolusAmountString else {
                fatalError("Impossible to exceed max bolus without a configured max bolus")
            }
            return SwiftUI.Alert(
                title: Text("Exceeds Maximum Bolus", comment: "Alert title for a maximum bolus validation error"),
                message: Text("The maximum bolus amount is \(maximumBolusAmountString) U.", comment: "Alert message for a maximum bolus validation error (1: max bolus value)")
            )
        case .bolusTooSmall:
            return SwiftUI.Alert(
                title: Text("Bolus Too Small", comment: "Alert title for a bolus too small validation error"),
                message: Text("The bolus amount entered is smaller than the minimum deliverable.", comment: "Alert message for a bolus too small validation error")
            )
        case .noPumpManagerConfigured:
            return SwiftUI.Alert(
                title: Text("No Pump Configured", comment: "Alert title for a missing pump error"),
                message: Text("A pump must be configured before a bolus can be delivered.", comment: "Alert message for a missing pump error")
            )
        case .noMaxBolusConfigured:
            return SwiftUI.Alert(
                title: Text("No Maximum Bolus Configured", comment: "Alert title for a missing maximum bolus setting error"),
                message: Text("The maximum bolus setting must be configured before a bolus can be delivered.", comment: "Alert message for a missing maximum bolus setting error")
            )
        case .carbEntryPersistenceFailure:
            return SwiftUI.Alert(
                title: Text("Unable to Save Carb Entry", comment: "Alert title for a carb entry persistence error"),
                message: Text("An error occurred while trying to save your carb entry.", comment: "Alert message for a carb entry persistence error")
            )
        case .manualGlucoseEntryOutOfAcceptableRange:
            let acceptableLowerBound = displayGlucosePreference.format(LoopConstants.validManualGlucoseEntryRange.lowerBound)
            let acceptableUpperBound = displayGlucosePreference.format(LoopConstants.validManualGlucoseEntryRange.upperBound)
            return SwiftUI.Alert(
                title: Text("Glucose Entry Out of Range", comment: "Alert title for a manual glucose entry out of range error"),
                message: Text("A manual glucose entry must be between \(acceptableLowerBound) and \(acceptableUpperBound)", comment: "Alert message for a manual glucose entry out of range error")
            )
        case .manualGlucoseEntryPersistenceFailure:
            return SwiftUI.Alert(
                title: Text("Unable to Save Manual Glucose Entry", comment: "Alert title for a manual glucose entry persistence error"),
                message: Text("An error occurred while trying to save your manual glucose entry.", comment: "Alert message for a manual glucose entry persistence error")
            )
        case .glucoseNoLongerStale:
            return SwiftUI.Alert(
                title: Text("Glucose Data Now Available", comment: "Alert title when glucose data returns while on bolus screen"),
                message: Text("An updated bolus recommendation is available.", comment: "Alert message when glucose data returns while on bolus screen")
            )
        case .forecastInfo:
            return SwiftUI.Alert(
                title: Text("Forecasted Glucose", comment: "Title for forecast explanation modal on bolus view"),
                message: Text("The bolus dosing algorithm uses a more conservative estimate of forecasted blood glucose than what is used to adjust your basal rate.\n\nAs a result, your forecasted blood glucose after a bolus may still be higher than your target range.", comment: "Forecast explanation modal on bolus view")
            )
        }
    }
}

struct LabeledQuantity: View {
    var label: Text
    var quantity: HKQuantity?
    var unit: HKUnit
    var maxFractionDigits: Int?
    var accentColor: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            label
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(accentColor != nil ? .dashboardInk : Color(.label))
            valueText
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(accentColor ?? Color(.secondaryLabel))
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor?.opacity(0.12) ?? Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor?.opacity(0.22) ?? Color.clear, lineWidth: 1)
        )
    }

    var valueText: Text {
        guard let quantity = quantity else {
            return Text(verbatim: "– –")
        }
        
        let formatter = QuantityFormatter(for: unit)

        if let maxFractionDigits = maxFractionDigits {
            formatter.numberFormatter.maximumFractionDigits = maxFractionDigits
        }

        guard let string = formatter.string(from: quantity) else {
            assertionFailure("Unable to format \(String(describing: quantity)) \(unit)")
            return Text(verbatim: "")
        }

        return Text(string)
    }
}


struct LabelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(.systemGray6))
            )
    }
}
