import Foundation

/// Historical statistics only; never used for dosing or alerts.
struct GlucoseStatisticsReading: Equatable {
    let date: Date
    let mgdl: Double
}

struct GlucoseStatisticsInsulin: Equatable {
    enum Kind { case basal, bolus }
    let start: Date
    let end: Date
    let units: Double
    let kind: Kind
}

struct GlucoseStatistics {
    let start: Date
    let end: Date
    let readingCount: Int
    let coveredSeconds: Double
    let meanMGDL: Double?
    let standardDeviationMGDL: Double?
    let belowRange: Double?
    let inRange: Double?
    let aboveRange: Double?
    let below54: Double?
    let above250: Double?

    var coverage: Double { min(1, coveredSeconds / max(1, end.timeIntervalSince(start))) }
    var coefficientOfVariation: Double? {
        guard let mean = meanMGDL, mean > 0, let sd = standardDeviationMGDL else { return nil }
        return sd / mean * 100
    }
    // GMI (%) = 3.31 + 0.02392 × mean sensor glucose (mg/dL).
    // https://doi.org/10.2337/dc18-1581. Require 14 days and 70% coverage.
    var gmi: Double? {
        guard end.timeIntervalSince(start) >= 14 * 86400 - 1, coverage >= 0.7, let mean = meanMGDL else { return nil }
        return 3.31 + 0.02392 * mean
    }

    static func calculate(readings: [GlucoseStatisticsReading], start: Date, end: Date,
                          lower: Double, upper: Double) -> Self {
        // A measurement represents at most five minutes, ending at the next
        // reading. Never bridge a sensor gap or include time outside the window.
        var byDate: [Date: GlucoseStatisticsReading] = [:]
        for reading in readings where reading.mgdl.isFinite && reading.mgdl >= 39 && reading.date < end && reading.date >= start.addingTimeInterval(-300) {
            byDate[reading.date] = reading
        }
        let sorted = byDate.values.sorted { $0.date < $1.date }
        var seconds = 0.0, total = 0.0, below = 0.0, inside = 0.0, above = 0.0, low = 0.0, high = 0.0
        var observed: [(Double, Double)] = []
        for (index, reading) in sorted.enumerated() {
            let next = index + 1 < sorted.count ? sorted[index + 1].date : end
            let duration = max(0, min(end, min(next, reading.date.addingTimeInterval(300))).timeIntervalSince(max(start, reading.date)))
            guard duration > 0 else { continue }
            seconds += duration
            total += reading.mgdl * duration
            observed.append((reading.mgdl, duration))
            if reading.mgdl < lower { below += duration }
            else if reading.mgdl > upper { above += duration }
            else { inside += duration }
            if reading.mgdl < 54 { low += duration }
            if reading.mgdl > 250 { high += duration }
        }
        let mean: Double? = seconds > 0 ? total / seconds : nil
        let sd = mean.map { mean in sqrt(observed.reduce(0) { $0 + pow($1.0 - mean, 2) * $1.1 } / seconds) }
        func fraction(_ value: Double) -> Double? { seconds > 0 ? value / seconds : nil }
        return Self(start: start, end: end, readingCount: sorted.filter { $0.date >= start }.count,
                    coveredSeconds: seconds, meanMGDL: mean, standardDeviationMGDL: sd,
                    belowRange: fraction(below), inRange: fraction(inside), aboveRange: fraction(above),
                    below54: fraction(low), above250: fraction(high))
    }

    /// Prefer local measurements within two minutes of a remote reading to avoid
    /// counting a mirrored Nightscout sample twice. Keep remote data in local gaps.
    static func merge(local: [GlucoseStatisticsReading], remote: [GlucoseStatisticsReading]) -> [GlucoseStatisticsReading] {
        let local = local.filter { $0.mgdl.isFinite && $0.mgdl >= 39 }.sorted { $0.date < $1.date }
        let remote = remote.sorted { $0.date < $1.date }
        var index = 0
        var result = local
        for reading in remote {
            while index < local.count && local[index].date < reading.date.addingTimeInterval(-120) { index += 1 }
            if index == local.count || local[index].date > reading.date.addingTimeInterval(120) { result.append(reading) }
        }
        return result
    }
}

struct GlucoseInsulinStatistics {
    let basal: Double?
    let bolus: Double?
    let coveredSeconds: Double
    let hasRemoteBolusOnlyDays: Bool
    let start: Date
    let end: Date
    var total: Double? {
        guard basal != nil || bolus != nil else { return nil }
        return (basal ?? 0) + (bolus ?? 0)
    }
    var recordedDailyAverage: Double? { total.map { $0 / max(1.0 / 24, end.timeIntervalSince(start) / 86400) } }
    var coverage: Double { min(1, coveredSeconds / max(1, end.timeIntervalSince(start))) }
    var basalPercentage: Double? {
        guard !hasRemoteBolusOnlyDays, coverage >= 0.9, let basal, let total, total > 0 else { return nil }
        return basal / total * 100
    }

    static func calculate(local: [GlucoseStatisticsInsulin], remoteBoluses: [GlucoseStatisticsInsulin],
                          start: Date, end: Date, calendar: Calendar = .current) -> Self {
        let local = local.filter { $0.units.isFinite && $0.units >= 0 && $0.start < end && $0.end >= start }
        // Use remote boluses only on days with no local delivery records. Adding
        // mirrored treatments to pump records would double-count insulin.
        var localDays = Set<Date>()
        for dose in local {
            var day = calendar.startOfDay(for: max(start, dose.start))
            let last = calendar.startOfDay(for: min(end.addingTimeInterval(-0.001), max(dose.start, dose.end.addingTimeInterval(-0.001))))
            while day <= last {
                localDays.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        let remote = remoteBoluses.filter {
            $0.start >= start && $0.start < end && $0.units.isFinite && $0.units >= 0 && !localDays.contains(calendar.startOfDay(for: $0.start))
        }
        var basal = 0.0, bolus = 0.0, hasBasal = false, hasBolus = false
        var intervals: [(Date, Date)] = []
        for dose in local {
            let from = max(start, dose.start), to = min(end, dose.end)
            if dose.kind == .bolus {
                guard dose.start >= start else { continue }
                bolus += dose.units; hasBolus = true
            } else if to > from {
                basal += dose.units * to.timeIntervalSince(from) / max(1, dose.end.timeIntervalSince(dose.start))
                hasBasal = true
                intervals.append((from, to))
            }
        }
        for dose in remote { bolus += dose.units; hasBolus = true }
        // Union basal/suspension intervals so overlapping records cannot inflate coverage.
        var covered = 0.0, previousEnd = start
        for (from, to) in intervals.sorted(by: { $0.0 < $1.0 }) {
            covered += max(0, to.timeIntervalSince(max(from, previousEnd)))
            previousEnd = max(previousEnd, to)
        }
        return Self(basal: hasBasal ? basal : nil, bolus: hasBolus ? bolus : nil, coveredSeconds: covered,
                    hasRemoteBolusOnlyDays: !remote.isEmpty, start: start, end: end)
    }
}
