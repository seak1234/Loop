//
//  DosingStrategySelectionView.swift
//  Loop
//
//  Created by Pete Schwamb on 1/16/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopCore
import LoopKit
import LoopKitUI

public struct DosingStrategySelectionView: View {
    
    @Binding private var automaticDosingStrategy: AutomaticDosingStrategy
    
    @Binding private var automaticBolusSchedule: AutomaticBolusSchedule

    @State private var internalDosingStrategy: AutomaticDosingStrategy
    
    public init(automaticDosingStrategy: Binding<AutomaticDosingStrategy>, automaticBolusSchedule: Binding<AutomaticBolusSchedule>) {
        self._automaticDosingStrategy = automaticDosingStrategy
        self._automaticBolusSchedule = automaticBolusSchedule
        self._internalDosingStrategy = State(initialValue: automaticDosingStrategy.wrappedValue)
    }
    
    public var body: some View {
        List {
            Section {
                options
            }
            .buttonStyle(PlainButtonStyle()) // Disable row highlighting on selection

            if automaticDosingStrategy == .automaticBolus {
                scheduleOptions
            }
        }
        .insetGroupedListStyle()
    }

    private var scheduleOptions: some View {
        Group {
            Section(footer: Text("When enabled, Automatic Bolus is used only during these daily time ranges. Outside them, Loop uses Temp Basal Only. Times follow your device’s time zone. Closed Loop must be enabled.")) {
                Toggle("Limit Automatic Bolus to Time Ranges", isOn: $automaticBolusSchedule.isEnabled)
            }

            if automaticBolusSchedule.isEnabled {
                ForEach(automaticBolusSchedule.ranges.indices, id: \.self) { index in
                    Section(header: Text("Time Range \(index + 1)")) {
                        DatePicker("Start", selection: timeBinding(index: index, isStart: true), displayedComponents: .hourAndMinute)
                        DatePicker("End", selection: timeBinding(index: index, isStart: false), displayedComponents: .hourAndMinute)
                        if automaticBolusSchedule.ranges[index].startMinute > automaticBolusSchedule.ranges[index].endMinute {
                            Text("Ends the following day")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        if !automaticBolusSchedule.ranges[index].isValid {
                            Text("Choose different start and end times. This range is inactive.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Button(action: { automaticBolusSchedule.ranges.remove(at: index) }) {
                            Text("Remove Time Range").foregroundColor(.red)
                        }
                    }
                }
                Section(footer: Text("Ranges repeat every day and may cross midnight. Overlapping ranges are combined. With no active ranges, Loop uses Temp Basal Only all day.")) {
                    Button("Add Time Range") {
                        automaticBolusSchedule.ranges.append(.init(startMinute: 23 * 60, endMinute: 3 * 60))
                    }
                }
            }
        }
    }

    private func timeBinding(index: Int, isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                guard automaticBolusSchedule.ranges.indices.contains(index) else { return Date() }
                let range = automaticBolusSchedule.ranges[index]
                let minute = isStart ? range.startMinute : range.endMinute
                // Use a fixed winter date so a daylight-saving transition today cannot
                // shift a time being edited. Only hour and minute are persisted.
                return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60))!
            },
            set: { date in
                guard automaticBolusSchedule.ranges.indices.contains(index) else { return }
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if isStart {
                    automaticBolusSchedule.ranges[index].startMinute = minute
                } else {
                    automaticBolusSchedule.ranges[index].endMinute = minute
                }
            }
        )
    }

    public var options: some View {
        ForEach(AutomaticDosingStrategy.allCases, id: \.self) { strategy in
            CheckmarkListItem(
                title: Text(strategy.title),
                description: Text(strategy.informationalText),
                isSelected: Binding(
                    get: { self.automaticDosingStrategy == strategy },
                    set: { isSelected in
                        if isSelected {
                            self.automaticDosingStrategy = strategy
                            self.internalDosingStrategy = strategy // Hack to force update. :(
                        }
                    }
                )
            )
            .padding(.vertical, 4)
        }
    }
}

extension AutomaticDosingStrategy {
    var informationalText: String {
        switch self {
        case .tempBasalOnly:
            return NSLocalizedString("Loop will set temporary basal rates to increase and decrease insulin delivery.", comment: "Description string for temp basal only dosing strategy")
        case .automaticBolus:
            return NSLocalizedString("Loop will automatically bolus when insulin needs are above scheduled basal, and will use temporary basal rates when needed to reduce insulin delivery below scheduled basal.", comment: "Description string for automatic bolus dosing strategy")
        }
    }

}

struct DosingStrategySelectionView_Previews: PreviewProvider {
    static var previews: some View {
        DosingStrategySelectionView(automaticDosingStrategy: .constant(.automaticBolus), automaticBolusSchedule: .constant(AutomaticBolusSchedule(isEnabled: true, ranges: [.init(startMinute: 1380, endMinute: 180), .init(startMinute: 300, endMinute: 420)])))
    }
}
