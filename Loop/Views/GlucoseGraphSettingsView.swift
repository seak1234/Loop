import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct GlucoseGraphSettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @ObservedObject private var store = GlucoseGraphSettingsStore.shared
    @ObservedObject private var statistics = GlucoseStatisticsSettingsStore.shared
    @State private var lowerText = ""
    @State private var upperText = ""
    @State private var lowerEdited = false
    @State private var upperEdited = false
    @State private var hasInvalidBounds = false
    @FocusState private var focusedBoundary: Boundary?

    private enum Boundary: Hashable {
        case lower, upper
    }

    var body: some View {
        List {
            Section(header: Text("History"), footer: Text("Statistics use recorded glucose and insulin over the selected rolling period. Nightscout fills glucose gaps and supplies logged boluses on days without local insulin records.")) {
                Toggle("Include Nightscout history", isOn: $statistics.useNightscout)
            }
            Section(header: Text("Glucose range"), footer: Text("These boundaries determine time below, in and above range, journal statistics, and graph shading. They do not change insulin dosing or alerts.")) {
                boundaryRow(.lower, label: NSLocalizedString("Lower boundary", comment: "Lower glucose graph range boundary"))
                boundaryRow(.upper, label: NSLocalizedString("Upper boundary", comment: "Upper glucose graph range boundary"))
            }
            Section(header: Text("Graph")) {
                Toggle("Show in-range area", isOn: Binding(get: { store.settings.isEnabled }, set: { store.setEnabled($0) }))
            }
            if hasInvalidBounds {
                Section {
                    Text("Enter positive values with the lower boundary below the upper boundary.", comment: "Invalid glucose graph display range")
                        .foregroundColor(.red)
                        .accessibilityIdentifier("glucoseGraphRangeError")
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("Statistics Settings", comment: "Glucose statistics settings title"))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedBoundary = nil }
            }
        }
        .onAppear(perform: loadBoundaryText)
        .onChange(of: displayGlucosePreference.unit) { _ in loadBoundaryText() }
    }

    private func boundaryRow(_ boundary: Boundary, label: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            TextField(label, text: Binding(
                get: { boundary == .lower ? lowerText : upperText },
                set: { text in
                    if boundary == .lower {
                        lowerText = text
                        lowerEdited = true
                    } else {
                        upperText = text
                        upperEdited = true
                    }
                    applyBoundaryText()
                }
            ))
            .multilineTextAlignment(.trailing)
            .keyboardType(displayGlucosePreference.unit == .milligramsPerDeciliter ? .numberPad : .decimalPad)
            .focused($focusedBoundary, equals: boundary)
            .frame(maxWidth: 100)
            .accessibilityIdentifier(boundary == .lower ? "glucoseGraphLowerBoundary" : "glucoseGraphUpperBoundary")
            Text(displayGlucosePreference.formatter.localizedUnitStringWithPlurality())
                .foregroundColor(.secondary)
        }
    }

    private func loadBoundaryText() {
        lowerText = displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: store.settings.lowerBoundMGDL), includeUnit: false)
        upperText = displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: store.settings.upperBoundMGDL), includeUnit: false)
        lowerEdited = false
        upperEdited = false
        hasInvalidBounds = false
    }

    private func parsedBoundary(_ text: String) -> Double? {
        let formatter = displayGlucosePreference.formatter.numberFormatter
        let separator = formatter.decimalSeparator ?? "."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: separator))
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: allowed.inverted) == nil,
              trimmed.components(separatedBy: separator).count <= 2,
              let value = formatter.number(from: trimmed)?.doubleValue, value.isFinite else { return nil }
        return HKQuantity(unit: displayGlucosePreference.unit, doubleValue: value).doubleValue(for: .milligramsPerDeciliter)
    }

    private func applyBoundaryText() {
        // Preserve untouched canonical values: displaying 145 mg/dL as 8.1
        // mmol/L must not round and rewrite it when the other field is edited.
        let lower = lowerEdited ? parsedBoundary(lowerText) : store.settings.lowerBoundMGDL
        let upper = upperEdited ? parsedBoundary(upperText) : store.settings.upperBoundMGDL
        guard let lower, let upper else {
            hasInvalidBounds = true
            return
        }
        hasInvalidBounds = !store.updateBounds(lowerBoundMGDL: lower, upperBoundMGDL: upper)
    }
}
