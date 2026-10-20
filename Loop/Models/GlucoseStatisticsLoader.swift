import Foundation
import Combine
import HealthKit
import LoopKit

@MainActor
final class GlucoseStatisticsLoader: ObservableObject {
    /// Keep loaded periods when the page is opened again during this app session.
    static let shared = GlucoseStatisticsLoader()
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var updatedAt: Date?
    private(set) var readings: [GlucoseStatisticsReading] = []
    private(set) var doses: [GlucoseStatisticsInsulin] = []
    private(set) var remoteBoluses: [GlucoseStatisticsInsulin] = []
    private(set) var start = Date()
    private(set) var end = Date()
    private(set) var glucoseSource = "Local CGM"
    private(set) var sourceVersion = UUID()
    private var localReadings: [GlucoseStatisticsReading] = []
    private var remoteReadings: [GlucoseStatisticsReading] = []
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var mergeGeneration = 0
    private var loadedDays: Int?
    private weak var cacheManager: DeviceDataManager?
    private var cacheUsesNightscout: Bool?
    private var cacheConfiguration: CycleNightscoutConfiguration?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private struct History {
        let start: Date
        let end: Date
        let updatedAt: Date
        let localReadings: [GlucoseStatisticsReading]
        let remoteReadings: [GlucoseStatisticsReading]
        let readings: [GlucoseStatisticsReading]
        let doses: [GlucoseStatisticsInsulin]
        let remoteBoluses: [GlucoseStatisticsInsulin]
        let message: String?
        var days: Double { end.timeIntervalSince(start) / 86400 }
    }
    // Refreshing three days must not discard an already downloaded 90-day window.
    private var history: [Int: History] = [:]

    private enum Update {
        case localGlucose([GlucoseStatisticsReading]?)
        case localInsulin([GlucoseStatisticsInsulin]?)
        case remoteGlucoseComplete(Bool)
        case remoteInsulin([GlucoseStatisticsInsulin]?)
    }

    func refresh(manager: DeviceDataManager, force: Bool = false) {
        let settings = GlucoseStatisticsSettingsStore.shared
        let days = settings.historyDays, useNightscout = settings.useNightscout
        let configuration = useNightscout ? nightscoutConfiguration(manager: manager) : nil
        let sourceChanged = cacheManager !== manager || cacheUsesNightscout != useNightscout || cacheConfiguration != configuration
        if sourceChanged {
            sourceVersion = UUID()
            cancel()
            history = [:]
            loadedDays = nil
            localReadings = []; remoteReadings = []; readings = []; doses = []; remoteBoluses = []
            updatedAt = nil
            cacheManager = manager; cacheUsesNightscout = useNightscout; cacheConfiguration = configuration
        }
        let selectionChanged = loadedDays != days
        if !force && !selectionChanged {
            if isLoading { return }
            if let updatedAt, now().timeIntervalSince(updatedAt) < 300 { return }
        }
        task?.cancel()
        let requestID = UUID()
        revision = requestID
        loadedDays = days
        let covering = history.values.filter { $0.days >= Double(days) - 0.00001 }
            .max { $0.updatedAt < $1.updatedAt }
        // Cached data remains useful after five minutes. Show it immediately,
        // and refresh it in the background rather than blanking the diagram.
        if let cached = covering ?? history.values.max(by: { $0.days < $1.days }) {
            localReadings = cached.localReadings; remoteReadings = cached.remoteReadings
            doses = cached.doses; remoteBoluses = cached.remoteBoluses
            message = cached.message
            updatedAt = cached.updatedAt
            end = cached.end
            start = end.addingTimeInterval(-Double(days) * 86400)
            readings = cached.readings
            updateGlucoseSource()
            objectWillChange.send()
            if !force, covering != nil, now().timeIntervalSince(cached.updatedAt) < 300 {
                isLoading = false
                return
            }
        } else {
            localReadings = []; remoteReadings = []; readings = []; doses = []; remoteBoluses = []
            updatedAt = nil
        }
        end = now()
        start = end.addingTimeInterval(-Double(days) * 86400)
        let from = start, to = end
        message = nil
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            var messages: [String] = []
            if useNightscout && configuration == nil {
                messages.append("Connect Nightscout in Services or CGM settings to include remote history.")
            }
            // Publish each source as soon as it finishes. In particular, glucose
            // must not wait for insulin treatments or a slow local dose query.
            await withTaskGroup(of: Update.self) { group in
                group.addTask { .localGlucose(await Self.localGlucose(manager: manager, start: from.addingTimeInterval(-300), end: to)) }
                group.addTask { .localInsulin(await Self.localInsulin(manager: manager, start: from, end: to)) }
                if let configuration {
                    group.addTask {
                        let complete = await Self.remoteGlucose(configuration: configuration, start: from.addingTimeInterval(-300), end: to) { [weak self] chunk, chunkStart, chunkEnd in
                            guard let self, self.revision == requestID, !Task.isCancelled,
                                  self.nightscoutConfiguration(manager: manager) == configuration else { return }
                            self.remoteReadings.removeAll { $0.date >= chunkStart && $0.date < chunkEnd }
                            self.remoteReadings.append(contentsOf: chunk)
                            await self.publishReadings()
                        }
                        return .remoteGlucoseComplete(complete)
                    }
                    group.addTask { .remoteInsulin(await Self.remoteInsulin(configuration: configuration, start: from, end: to)) }
                }
                for await update in group {
                    guard !Task.isCancelled, self.revision == requestID else { group.cancelAll(); return }
                    switch update {
                    case .localGlucose(let glucose):
                        if let glucose { self.localReadings = glucose }
                        else { messages.append("Local glucose could not be loaded.") }
                    case .localInsulin(let insulin):
                        if let insulin { self.doses = insulin }
                        else { messages.append("Local insulin could not be loaded.") }
                    case .remoteGlucoseComplete(let complete):
                        if !complete { messages.append("Some Nightscout glucose history is unavailable.") }
                    case .remoteInsulin(let insulin):
                        if let configuration, self.nightscoutConfiguration(manager: manager) != configuration {
                            group.cancelAll(); return
                        }
                        if let insulin { self.remoteBoluses = insulin }
                        else { messages.append("Nightscout insulin history is unavailable.") }
                    }
                    await self.publishReadings()
                }
            }
            guard !Task.isCancelled, self.revision == requestID else { return }
            if let configuration, self.nightscoutConfiguration(manager: manager) != configuration {
                self.message = "Nightscout connection changed. Refresh to load current history."
                self.isLoading = false
                return
            }
            let updatedAt = self.now()
            self.message = messages.isEmpty ? nil : messages.joined(separator: " ")
            self.history[days] = History(start: from, end: to, updatedAt: updatedAt,
                                         localReadings: self.localReadings, remoteReadings: self.remoteReadings, readings: self.readings,
                                         doses: self.doses, remoteBoluses: self.remoteBoluses, message: self.message)
            self.updatedAt = updatedAt
            self.isLoading = false
        }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func updateGlucoseSource() {
        glucoseSource = remoteReadings.isEmpty ? "Local CGM" : (localReadings.isEmpty ? "Nightscout CGM" : "Local CGM + Nightscout")
    }

    private func publishReadings() async {
        mergeGeneration += 1
        let generation = mergeGeneration, requestID = revision
        let local = localReadings, remote = remoteReadings
        let merge = Task.detached(priority: .userInitiated) { GlucoseStatistics.merge(local: local, remote: remote) }
        let merged = await withTaskCancellationHandler(operation: { await merge.value }, onCancel: { merge.cancel() })
        guard !Task.isCancelled, revision == requestID, mergeGeneration == generation else { return }
        readings = merged
        updateGlucoseSource()
        objectWillChange.send()
    }

    /// Three days of five-minute CGM data fit below Nightscout's 1,000-record
    /// limit. Use at most four requests at once, rather than a large query that
    /// must be recursively split into dozens of sequential requests.
    private static func remoteGlucose(configuration: CycleNightscoutConfiguration, start: Date, end: Date,
                                      onChunk: @escaping @MainActor ([GlucoseStatisticsReading], Date, Date) async -> Void) async -> Bool {
        let client = CycleNightscoutHistory(configuration: configuration)
        var windows: [(Date, Date)] = []
        var upper = end
        while upper > start {
            let lower = max(start, upper.addingTimeInterval(-3 * 86400))
            windows.append((lower, upper))
            upper = lower
        }
        typealias Chunk = (Int, [GlucoseStatisticsReading]?)
        return await withTaskGroup(of: Chunk.self) { group in
            func enqueue(_ index: Int) {
                let (lower, upper) = windows[index]
                group.addTask {
                    do {
                        let batch = try await client.fetch(start: lower, end: upper, includeGlucose: true, includeTreatments: false)
                        return (index, batch.glucose.map { $0.map { .init(date: $0.date, mgdl: $0.mgdl) } })
                    } catch { return (index, nil) }
                }
            }
            var next = min(4, windows.count), complete = true
            for index in 0..<next { enqueue(index) }
            for await (index, chunk) in group {
                guard !Task.isCancelled else { group.cancelAll(); return false }
                if let chunk { await onChunk(chunk, windows[index].0, windows[index].1) }
                else { complete = false }
                if next < windows.count { enqueue(next); next += 1 }
            }
            return complete
        }
    }

    private static func remoteInsulin(configuration: CycleNightscoutConfiguration, start: Date, end: Date) async -> [GlucoseStatisticsInsulin]? {
        do {
            let batch = try await CycleNightscoutHistory(configuration: configuration).fetch(start: start, end: end, includeGlucose: false, includeTreatments: true)
            return batch.boluses.map { $0.map { .init(start: $0.date, end: $0.date, units: $0.amount, kind: .bolus) } }
        } catch { return nil }
    }

    private static func localGlucose(manager: DeviceDataManager, start: Date, end: Date) async -> [GlucoseStatisticsReading]? {
        await withCheckedContinuation { continuation in
            manager.glucoseStore.getGlucoseSamples(start: start, end: end) { result in
                switch result {
                case .success(let samples):
                    continuation.resume(returning: samples.filter { !$0.wasUserEntered && !$0.isDisplayOnly }.map {
                        .init(date: $0.startDate, mgdl: $0.quantity.doubleValue(for: .milligramsPerDeciliter))
                    })
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func localInsulin(manager: DeviceDataManager, start: Date, end: Date) async -> [GlucoseStatisticsInsulin]? {
        await withCheckedContinuation { continuation in
            manager.doseStore.getNormalizedDoseEntries(start: start, end: end) { result in
                switch result {
                case .success(let entries):
                    continuation.resume(returning: entries.filter { !$0.isMutable && $0.type != .resume }.map {
                        .init(start: $0.startDate, end: $0.endDate, units: $0.type == .suspend ? 0 : $0.unitsInDeliverableIncrements,
                              kind: $0.type == .bolus ? .bolus : .basal)
                    })
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }

    private func nightscoutConfiguration(manager: DeviceDataManager) -> CycleNightscoutConfiguration? {
        let keychain = KeychainManager()
        if manager.servicesManager.activeServices.contains(where: { $0.pluginIdentifier == "NightscoutService" && $0.isOnboarded }),
           let credentials = try? keychain.getInternetCredentials(account: "NightscoutAPI") {
            return .init(siteURL: credentials.url, apiSecret: credentials.password)
        }
        if manager.cgmManager?.pluginIdentifier == "NightscoutRemoteCGM", manager.cgmManager?.isOnboarded == true,
           let credentials = try? keychain.getInternetCredentials(account: "NightscoutCGM") {
            return .init(siteURL: credentials.url, apiSecret: credentials.password)
        }
        return nil
    }
}
