#!/bin/bash
# Run the production async loader with controlled store responses, without UIKit.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/glucose-loader.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root / 'Loop/Models/GlucoseStatisticsLoader.swift').read_text().replace('import HealthKit\n', '').replace('import LoopKit\n', '')
(out / 'Loader.swift').write_text(s)
(out / 'Interfaces.swift').write_text('''
import Foundation
// Only app store/connection interfaces are replaced. The production loader and
// calculation/settings models compile unchanged apart from unavailable imports.
enum HKUnit { case milligramsPerDeciliter }
struct Quantity { func doubleValue(for unit: HKUnit) -> Double { 120 } }
struct Sample { let startDate: Date; let quantity = Quantity(); let wasUserEntered = false; let isDisplayOnly = false }
enum DoseType { case basal, bolus, suspend, resume }
struct Dose { let startDate: Date; let endDate: Date; let unitsInDeliverableIncrements: Double; let type: DoseType; let isMutable = false }
class GlucoseStore {
    var reads = 0
    var hold = false
    var pending: [(Result<[Sample], Error>) -> Void] = []
    func getGlucoseSamples(start: Date, end: Date?, completion: @escaping (Result<[Sample], Error>) -> Void) {
        reads += 1
        if hold { pending.append(completion) }
        else { completion(.success([Sample(startDate: end!.addingTimeInterval(-86400))])) }
    }
    func release() { let callbacks = pending; pending = []; hold = false; callbacks.forEach { $0(.success([])) } }
}
class DoseStore {
    var hold = false
    var pending: [(Result<[Dose], Error>) -> Void] = []
    func getNormalizedDoseEntries(start: Date, end: Date?, completion: @escaping (Result<[Dose], Error>) -> Void) {
        if hold { pending.append(completion) } else { completion(.success([])) }
    }
    func release() { let callbacks = pending; pending = []; hold = false; callbacks.forEach { $0(.success([])) } }
}
struct Service { let pluginIdentifier: String; let isOnboarded: Bool }
struct Services { let activeServices: [Service] = [] }
class DeviceDataManager { let glucoseStore = GlucoseStore(); let doseStore = DoseStore(); let servicesManager = Services(); var cgmManager: Service? }
struct Credentials { let url: URL; let password: String }
enum TestError: Error { case unavailable }
struct KeychainManager {
    static var available = false
    func getInternetCredentials(account: String) throws -> Credentials {
        guard Self.available else { throw TestError.unavailable }
        return Credentials(url: URL(string: "https://example.invalid")!, password: "test-only")
    }
}
struct CycleNightscoutConfiguration: Equatable { let siteURL: URL; let apiSecret: String }
struct RemoteReading { let date: Date; let mgdl: Double }
struct RemoteAmount { let date: Date; let amount: Double }
struct RemoteBatch { let glucose: [RemoteReading]?; let boluses: [RemoteAmount]? }
struct CycleNightscoutHistory {
    let configuration: CycleNightscoutConfiguration
    func fetch(start: Date, end: Date, includeGlucose: Bool = true, includeTreatments: Bool = true) async throws -> RemoteBatch {
        await TestRemoteServer.shared.fetch(start: start, end: end, glucose: includeGlucose)
    }
}
@MainActor final class TestRemoteServer {
    static let shared = TestRemoteServer()
    var holdGlucose = true, holdInsulin = true
    var activeGlucose = 0, maximumActiveGlucose = 0
    var glucoseWindows: [(Date, Date)] = []
    var pendingGlucose: [CheckedContinuation<Void, Never>] = []
    var pendingInsulin: CheckedContinuation<Void, Never>?
    func fetch(start: Date, end: Date, glucose: Bool) async -> RemoteBatch {
        if glucose {
            activeGlucose += 1
            maximumActiveGlucose = max(maximumActiveGlucose, activeGlucose)
            glucoseWindows.append((start, end))
            if holdGlucose { await withCheckedContinuation { pendingGlucose.append($0) } }
            else { try? await Task.sleep(nanoseconds: 1_000_000) }
            activeGlucose -= 1
            return RemoteBatch(glucose: [RemoteReading(date: end.addingTimeInterval(-60), mgdl: 180)], boluses: nil)
        }
        if holdInsulin { await withCheckedContinuation { pendingInsulin = $0 } }
        return RemoteBatch(glucose: nil, boluses: [])
    }
    func releaseGlucose() { holdGlucose = false; let callbacks = pendingGlucose; pendingGlucose = []; callbacks.forEach { $0.resume() } }
    func releaseInsulin() { holdInsulin = false; pendingInsulin?.resume(); pendingInsulin = nil }
}
''')
(out / 'Tests.swift').write_text('''
import Foundation
@main struct LoaderTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Loader did not reach the expected state")
    }
    @MainActor static func main() async throws {
        let settings = GlucoseStatisticsSettingsStore.shared
        let previousDays = settings.days, previousAGPDays = settings.agpDays, previousRemote = settings.useNightscout
        defer { settings.days = previousDays; settings.agpDays = previousAGPDays; settings.useNightscout = previousRemote }
        settings.days = 14; settings.agpDays = 3; settings.useNightscout = false
        let manager = DeviceDataManager(), loader = GlucoseStatisticsLoader()
        loader.refresh(manager: manager)
        try await waitUntil { !loader.isLoading }
        precondition(manager.glucoseStore.reads == 1)
        for days in [3, 7, 14] {
            settings.days = days; loader.refresh(manager: manager)
            precondition(!loader.isLoading && manager.glucoseStore.reads == 1)
            precondition(abs(loader.end.timeIntervalSince(loader.start) - Double(days) * 86400) < 0.01)
        }
        print("PASS smaller day selections reuse wider history immediately")
        settings.days = 30; loader.refresh(manager: manager)
        precondition(loader.isLoading)
        try await waitUntil { !loader.isLoading }
        precondition(manager.glucoseStore.reads == 2)
        precondition(abs(loader.end.timeIntervalSince(loader.start) - 30 * 86400) < 0.01)
        print("PASS larger day selections load the additional history")
        settings.days = 3; settings.agpDays = 30; loader.refresh(manager: manager)
        precondition(!loader.isLoading && manager.glucoseStore.reads == 2)
        precondition(settings.days == 3 && abs(loader.end.timeIntervalSince(loader.start) - 30 * 86400) < 0.01)
        settings.agpDays = 7; loader.refresh(manager: manager)
        precondition(!loader.isLoading && manager.glucoseStore.reads == 2)
        precondition(abs(loader.end.timeIntervalSince(loader.start) - 7 * 86400) < 0.01)
        print("PASS independent AGP selection keeps enough cached history for both cards")
        settings.agpDays = 3; settings.days = 30
        manager.glucoseStore.hold = true
        loader.refresh(manager: manager, force: true)
        try await waitUntil { !manager.glucoseStore.pending.isEmpty }
        loader.refresh(manager: manager) // The page's normal reload must not cancel pull-to-refresh.
        precondition(loader.isLoading)
        manager.glucoseStore.release()
        try await waitUntil { !loader.isLoading }
        print("PASS pull-to-refresh survives the page reload")
        manager.glucoseStore.hold = true
        settings.days = 90; loader.refresh(manager: manager)
        try await waitUntil { !manager.glucoseStore.pending.isEmpty }
        settings.days = 3; loader.refresh(manager: manager)
        precondition(!loader.isLoading)
        let selectedStart = loader.start, selectedEnd = loader.end
        manager.glucoseStore.release()
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(loader.start == selectedStart && loader.end == selectedEnd)
        precondition(abs(loader.end.timeIntervalSince(loader.start) - 3 * 86400) < 0.01)
        print("PASS a stale response cannot overwrite a newer day selection")
        settings.days = 90; loader.refresh(manager: manager)
        try await waitUntil { !loader.isLoading }
        settings.days = 3; loader.refresh(manager: manager, force: true)
        try await waitUntil { !loader.isLoading }
        let readsAfterShortRefresh = manager.glucoseStore.reads
        settings.days = 90; loader.refresh(manager: manager)
        precondition(!loader.isLoading && manager.glucoseStore.reads == readsAfterShortRefresh)
        print("PASS refreshing a short period preserves the cached 90-day history")

        let progressiveManager = DeviceDataManager(), progressiveLoader = GlucoseStatisticsLoader()
        progressiveManager.doseStore.hold = true
        progressiveLoader.refresh(manager: progressiveManager)
        try await waitUntil { !progressiveLoader.readings.isEmpty }
        precondition(progressiveLoader.isLoading && !progressiveManager.doseStore.pending.isEmpty)
        progressiveManager.doseStore.release()
        try await waitUntil { !progressiveLoader.isLoading }
        print("PASS local glucose appears before slow local insulin completes")

        KeychainManager.available = true
        settings.days = 14; settings.useNightscout = true
        let remoteManager = DeviceDataManager(), remoteLoader = GlucoseStatisticsLoader()
        remoteManager.cgmManager = Service(pluginIdentifier: "NightscoutRemoteCGM", isOnboarded: true)
        let server = TestRemoteServer.shared
        remoteLoader.refresh(manager: remoteManager)
        try await waitUntil { server.pendingGlucose.count == 4 && server.pendingInsulin != nil }
        precondition(server.maximumActiveGlucose == 4)
        precondition(server.glucoseWindows.allSatisfy { $0.1.timeIntervalSince($0.0) <= 3 * 86400 })
        print("PASS Nightscout glucose uses bounded parallel three-day queries")
        server.releaseGlucose()
        try await waitUntil { remoteLoader.readings.count > 1 }
        precondition(remoteLoader.isLoading && server.pendingInsulin != nil)
        print("PASS remote glucose updates while Nightscout insulin is still loading")
        server.releaseInsulin()
        try await waitUntil { !remoteLoader.isLoading }
        precondition(server.maximumActiveGlucose <= 4)
        settings.useNightscout = false
        remoteLoader.refresh(manager: remoteManager)
        try await waitUntil { !remoteLoader.isLoading }
        precondition(remoteLoader.readings.count == 1 && remoteLoader.glucoseSource == "Local CGM")
        KeychainManager.available = false
        print("PASS disabling Nightscout invalidates cached remote history")
        settings.days = 14; settings.useNightscout = false
        var testNow = Date()
        let agingManager = DeviceDataManager(), agingLoader = GlucoseStatisticsLoader(now: { testNow })
        agingLoader.refresh(manager: agingManager)
        try await waitUntil { !agingLoader.isLoading }
        testNow = testNow.addingTimeInterval(301)
        agingManager.glucoseStore.hold = true
        settings.days = 7; agingLoader.refresh(manager: agingManager)
        precondition(agingLoader.isLoading && !agingLoader.readings.isEmpty)
        try await waitUntil { !agingManager.glucoseStore.pending.isEmpty }
        agingManager.glucoseStore.release()
        try await waitUntil { !agingLoader.isLoading }
        print("PASS expired cached values stay visible during background refresh")
        let replacementManager = DeviceDataManager()
        agingLoader.refresh(manager: replacementManager)
        precondition(agingLoader.readings.isEmpty)
        try await waitUntil { !agingLoader.isLoading }
        precondition(replacementManager.glucoseStore.reads == 1)
        print("PASS a different device manager cannot reuse the previous source cache")
        print("Passed 12 async statistics loader checks.")
    }
}
''')
PY
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseStatistics.swift" \
    "$task_root/Loop/Models/GlucoseStatisticsSettings.swift" \
    "$task_temp/Interfaces.swift" "$task_temp/Loader.swift" "$task_temp/Tests.swift" -o "$task_temp/loader-tests"
"$task_temp/loader-tests"
