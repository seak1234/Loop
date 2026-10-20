import Foundation
import Combine

/// Shared historical statistics range and optional graph shading. Never used by the loop algorithm.
struct GlucoseGraphSettings: Equatable {
    static let `default` = GlucoseGraphSettings()

    var isEnabled: Bool
    let lowerBoundMGDL: Double
    let upperBoundMGDL: Double

    private init() {
        isEnabled = true
        lowerBoundMGDL = 80
        upperBoundMGDL = 145
    }

    init?(isEnabled: Bool, lowerBoundMGDL: Double, upperBoundMGDL: Double) {
        guard lowerBoundMGDL.isFinite, upperBoundMGDL.isFinite,
              lowerBoundMGDL > 0, lowerBoundMGDL < upperBoundMGDL else { return nil }
        self.isEnabled = isEnabled
        self.lowerBoundMGDL = lowerBoundMGDL
        self.upperBoundMGDL = upperBoundMGDL
    }

    init?(rawValue: [String: Any]) {
        guard let enabled = rawValue["enabled"] as? Bool,
              let lower = rawValue["lowerBoundMGDL"] as? Double,
              let upper = rawValue["upperBoundMGDL"] as? Double else { return nil }
        self.init(isEnabled: enabled, lowerBoundMGDL: lower, upperBoundMGDL: upper)
    }

    var rawValue: [String: Any] {
        ["enabled": isEnabled, "lowerBoundMGDL": lowerBoundMGDL, "upperBoundMGDL": upperBoundMGDL]
    }
}

final class GlucoseGraphSettingsStore: ObservableObject {
    static let shared = GlucoseGraphSettingsStore()
    static let defaultsKey = "com.loopkit.Loop.GlucoseGraphDisplaySettings"

    private let defaults: UserDefaults

    @Published private(set) var settings: GlucoseGraphSettings {
        didSet { defaults.set(settings.rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.dictionary(forKey: Self.defaultsKey),
           let saved = GlucoseGraphSettings(rawValue: rawValue) {
            settings = saved
        } else {
            settings = .default
        }
    }

    func setEnabled(_ enabled: Bool) {
        var updated = settings
        updated.isEnabled = enabled
        settings = updated
    }

    @discardableResult
    func updateBounds(lowerBoundMGDL: Double, upperBoundMGDL: Double) -> Bool {
        guard let updated = GlucoseGraphSettings(isEnabled: settings.isEnabled,
                                                lowerBoundMGDL: lowerBoundMGDL,
                                                upperBoundMGDL: upperBoundMGDL) else { return false }
        settings = updated
        return true
    }
}
