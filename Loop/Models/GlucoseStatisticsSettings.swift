import Foundation
import Combine

final class GlucoseStatisticsSettingsStore: ObservableObject {
    static let shared = GlucoseStatisticsSettingsStore()
    static let periods = [3, 7, 14, 30, 90]
    private let defaults: UserDefaults
    @Published var days: Int {
        didSet { defaults.set(days, forKey: "com.loopkit.Loop.GlucoseStatistics.days") }
    }
    @Published var useNightscout: Bool {
        didSet { defaults.set(useNightscout, forKey: "com.loopkit.Loop.GlucoseStatistics.useNightscout") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "com.loopkit.Loop.GlucoseStatistics.days")
        days = Self.periods.contains(saved) ? saved : 14
        useNightscout = defaults.object(forKey: "com.loopkit.Loop.GlucoseStatistics.useNightscout") as? Bool ?? true
    }
}
