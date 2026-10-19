//
//  LiveActivityManagementViewModel.swift
//  Loop
//
//  Created by Bastiaan Verhaar on 12/09/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import LoopCore

class LiveActivityManagementViewModel : ObservableObject {
    @Published var enabled: Bool
    @Published var mode: LiveActivityMode
    @Published var isEditingMode: Bool = false
    @Published var addPredictiveLine: Bool
    @Published var useLimits: Bool
    @Published var upperLimitChartMmol: Double
    @Published var lowerLimitChartMmol: Double
    @Published var upperLimitChartMg: Double
    @Published var lowerLimitChartMg: Double
    
    private var savedSettings: LiveActivitySettings

    var isDirty: Bool {
        enabled != savedSettings.enabled || mode != savedSettings.mode ||
        addPredictiveLine != savedSettings.addPredictiveLine || useLimits != savedSettings.useLimits ||
        upperLimitChartMmol != savedSettings.upperLimitChartMmol || lowerLimitChartMmol != savedSettings.lowerLimitChartMmol ||
        upperLimitChartMg != savedSettings.upperLimitChartMg || lowerLimitChartMg != savedSettings.lowerLimitChartMg
    }

    func markSaved(_ settings: LiveActivitySettings) {
        // Notify even when the editable fields have not changed: the baseline has.
        objectWillChange.send()
        savedSettings = settings
    }

    init(defaults: UserDefaults = .standard) {
        let liveActivitySettings = defaults.liveActivity ?? LiveActivitySettings()
        self.savedSettings = liveActivitySettings
        
        self.enabled = liveActivitySettings.enabled
        self.mode = liveActivitySettings.mode
        self.addPredictiveLine = liveActivitySettings.addPredictiveLine
        self.useLimits = liveActivitySettings.useLimits
        self.upperLimitChartMmol = liveActivitySettings.upperLimitChartMmol
        self.lowerLimitChartMmol = liveActivitySettings.lowerLimitChartMmol
        self.upperLimitChartMg = liveActivitySettings.upperLimitChartMg
        self.lowerLimitChartMg = liveActivitySettings.lowerLimitChartMg
    }
}
