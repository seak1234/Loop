#!/bin/bash
# Compile and exercise the production Mochi read bridge. Only device/HealthKit
# interfaces are fixtures; the request validation, serializers and readers are real.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/mochi-data-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root/'Loop/Companion/CompanionController.swift').read_text()
helpers = s[s.index('    private func interval('):s.index('    private func readCompanionData(')]
readers = s[s.index('    private func readCompanionData('):s.index('    private func healthData(')]
cases = s[s.index('        case "get_data_catalog",'):s.index('        case "get_glucose_summary", "get_insulin_summary", "get_carb_entries":')]
shell = '''import Foundation
import CoreFoundation
@MainActor final class CompanionController {
    var state = CompanionState()
    var deviceManager: DeviceDataManager?
    var companionDataReader: ((String, [String: Any]) async throws -> [String: Any])?
    func read(_ tool: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let call = CompanionToolCall(id: UUID().uuidString, name: tool, arguments: try JSONSerialization.data(withJSONObject: args))
        let result = try await execute(call)
        return try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
    }
    private func execute(_ call: CompanionToolCall) async throws -> String {
        guard let args = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else { throw CompanionError.invalid("Invalid arguments") }
        switch call.name {
'''
shell += cases + '\n        default: throw CompanionError.invalid("Unknown tool")\n        }\n    }\n' + helpers + readers + '\n}\n'
(out/'Reader.swift').write_text(shell)
kit = (root.parent/'LoopKit/LoopKit/DeviceManager/CGMManager.swift').read_text()
lifecycle = kit[kit.index('public struct CGMSensorLifecycle'):kit.index('public struct CGMManagerStatus')]
(out/'Lifecycle.swift').write_text('import Foundation\n' + lifecycle)
g7 = (root.parent/'G7SensorKit/G7SensorKit/G7CGMManager/G7CGMManager.swift').read_text()
g7 = g7[g7.index('    public var sensorLifecycle:'):g7.index('    public var sensorFinishesWarmupAt:')]
g6 = (root.parent/'CGMBLEKit/CGMBLEKit/TransmitterManager.swift').read_text()
g6 = g6[g6.index('    public var sensorLifecycle:'):g6.index('    public var cgmManagerStatus:')]
adapters = '''import Foundation
class G7Fixture: CGMSensorLifecycleProviding {
    var sensorActivatedAt: Date? = Date(timeIntervalSince1970: 1800000000)
    var sensorExpiresAt: Date? = Date(timeIntervalSince1970: 1800003600)
    var sensorEndsAt: Date? = Date(timeIntervalSince1970: 1800046800)
    var sensorFinishesWarmupAt: Date? = Date(timeIntervalSince1970: 1800001800)
'''+g7+'''}
class G6Fixture: CGMSensorLifecycleProviding {
    struct Reading { var sessionStartDate: Date? = Date(timeIntervalSince1970: 1800000000) }
    struct State { var sensorLife: Double = 30 * 86400 }
    var latestReading: Reading? = Reading()
    var state = State()
'''+g6+'}\n'
(out/'Adapters.swift').write_text(adapters)
PY
cat > "$task_temp/Interfaces.swift" <<'SWIFT'
import Foundation
struct HKUnit {
    var unitString = "mg/dL"
    static let milligramsPerDeciliter = HKUnit()
    static func minute() -> HKUnit { HKUnit(unitString: "min") }
    func unitDivided(by: HKUnit) -> HKUnit { self }
}
struct HKQuantity: Comparable, Codable {
    let value: Double
    func doubleValue(for: HKUnit) -> Double { value }
    static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}
struct Trend { let symbol = "→" }
struct StoredGlucoseSample {
    let startDate: Date
    let quantity: HKQuantity
    var wasUserEntered = false
    var isDisplayOnly = false
    var trend: Trend? = Trend()
    var trendRate: HKQuantity? = nil
}
struct PredictedGlucoseValue { let startDate: Date; let quantity: HKQuantity }
enum DoseType { case bolus, basal, tempBasal, suspend, resume }
struct DoseEntry {
    var type = DoseType.bolus
    var startDate = Date().addingTimeInterval(-300)
    var endDate = Date().addingTimeInterval(-240)
    var programmedUnits = 2.0
    var deliveredUnits: Double? = 1.0
    var unitsInDeliverableIncrements = 1.0
    var isMutable = false
    var automatic: Bool? = false
    var manuallyEntered = false
    func trimmed(from: Date, to: Date) -> Self { self }
}
struct Reservoir { var startDate = Date().addingTimeInterval(-60); var unitVolume = 42.0 }
struct PersistedPumpEvent {
    var date = Date().addingTimeInterval(-120)
    var type: String? = "bolus"
    var title: String? = "Recorded bolus"
    var alarmType: String? = nil
    var dose: DoseEntry? = DoseEntry()
}
enum CgmEventType: String { case sensorStart, sensorEnd, transmitterStart, transmitterEnd }
struct PersistedCgmEvent {
    var date = Date().addingTimeInterval(-3600)
    var type = CgmEventType.sensorStart
    var deviceIdentifier = "private-sensor-id"
    var expectedLifetime: Double? = 7200
    var warmupPeriod: Double? = 1800
    var failureMessage: String? = nil
}
class GlucoseStore {
    var samples: [StoredGlucoseSample] = []
    var latestGlucose: StoredGlucoseSample? { samples.last }
    var reads = 0
    func getGlucoseSamples(start: Date, end: Date, _ completion: (Result<[StoredGlucoseSample], Error>) -> Void) {
        reads += 1; completion(.success(samples.filter { $0.startDate >= start && $0.startDate <= end }))
    }
}
class DoseStore {
    var lastReservoirValue: Reservoir? = Reservoir()
    func getNormalizedDoseEntries(start: Date, end: Date, _ completion: (Result<[DoseEntry], Error>) -> Void) { completion(.success([DoseEntry()])) }
    func getPumpEventValues(since: Date, _ completion: (Result<[PersistedPumpEvent], Error>) -> Void) { completion(.success([PersistedPumpEvent()])) }
}
class CgmEventStore {
    enum QueryResult { case success(Int, [PersistedCgmEvent]); case failure(Error) }
    func executeCgmEventQuery(fromQueryAnchor: Int?, _ completion: (QueryResult) -> Void) { completion(.success(1, [PersistedCgmEvent()])) }
}
struct DeviceIdentity { var name: String? = "private-sensor-id"; var localIdentifier: String? = nil }
struct CGMStatus { var hasValidSensorSession = true; var lastCommunicationDate: Date? = Date(); var device: DeviceIdentity? = DeviceIdentity() }
struct Display { var isStateValid = true; var stateDescription = "OK"; var trendType: Trend? = Trend() }
class CGMManager: CGMSensorLifecycleProviding {
    var sensorLifecycle: CGMSensorLifecycle? = nil
    var cgmManagerStatus = CGMStatus()
    var localizedTitle = "Fixture CGM"
    var glucoseDisplay: Display? = Display()
}
struct PumpManagerStatus {
    enum BasalDeliveryState { case active(Date), suspended(Date), tempBasal(DoseEntry), initiatingTempBasal, cancelingTempBasal, suspending, resuming }
    enum BolusState { case noBolus, initiating, canceling, inProgress(DoseEntry) }
    var pumpBatteryChargeRemaining: Double? = 0.5
    var deliveryIsUncertain = false
    var insulinType: String? = "rapid-acting"
    var basalDeliveryState: BasalDeliveryState? = .active(Date().addingTimeInterval(-60))
    var bolusState = BolusState.noBolus
}
class PumpManager {
    var status = PumpManagerStatus()
    var localizedTitle = "Fixture pump"
    var lastSync: Date? = Date().addingTimeInterval(-60)
    var rawState: [String: Any] = ["sessionToken": "secret-do-not-share", "patchExpiresAt": Date().addingTimeInterval(3600)]
}
enum Severity: String { case normal, warning, critical }
struct Highlight { var localizedMessage = "Device warning"; var state = Severity.warning }
struct Progress { var percentComplete = 0.8; var progressState = Severity.normal }
struct Estimate { var value = 1.5; var startDate = Date().addingTimeInterval(-60) }
struct LoopState {
    var error: NSError? = nil
    var insulinOnBoard: Estimate? = Estimate()
    var carbsOnBoard: Estimate? = nil
    var predictedGlucose: [PredictedGlucoseValue]? = [PredictedGlucoseValue(startDate: Date().addingTimeInterval(300), quantity: HKQuantity(value: 110))]
    var predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]? = nil
}
struct RangeSchedule { func quantityRange(at: Date) -> ClosedRange<HKQuantity> { HKQuantity(value: 80)...HKQuantity(value: 100) } }
struct Override {
    struct Settings { var insulinNeedsScaleFactor: Double? = 1.0; var targetRange: ClosedRange<HKQuantity>? = nil }
    struct Duration { var isFinite = false; var isInfinite = true }
    var settings = Settings()
    var startDate = Date().addingTimeInterval(-300)
    var actualEndDate = Date().addingTimeInterval(3600)
    var duration = Duration()
    func isActive(at: Date) -> Bool { true }
}
struct Settings {
    var dosingEnabled = true
    var scheduleOverride: Override? = Override()
    var preMealOverride: Override? = nil
    func effectiveGlucoseTargetRangeSchedule() -> RangeSchedule? { RangeSchedule() }
}
struct Therapy: Codable { var maximumBolus = 5.0 }
class LoopDataManager {
    var lastLoopCompleted: Date? = Date().addingTimeInterval(-60)
    var settings = Settings()
    var therapySettings = Therapy()
    func getLoopState(_ completion: (LoopDataManager, LoopState) -> Void) { completion(self, LoopState()) }
}
enum HKCategoryTypeIdentifier { case sleepAnalysis }
struct HKCategoryType {}
enum HKObjectType { static func categoryType(forIdentifier: HKCategoryTypeIdentifier) -> HKCategoryType? { HKCategoryType() } }
class HKQuery {
    static func predicateForSamples(withStart: Date, end: Date) -> NSPredicate { NSPredicate(value: true) }
}
let HKObjectQueryNoLimit = 0
let HKSampleSortIdentifierStartDate = "startDate"
struct Source { let name = "Fixture sleep source" }
struct Revision { let source = Source() }
class HKCategorySample {
    let startDate = Date().addingTimeInterval(-3600)
    let endDate = Date().addingTimeInterval(-1200)
    let value = 3
    let sourceRevision = Revision()
}
class HKSampleQuery: HKQuery {
    let completion: (HKSampleQuery, [Any]?, Error?) -> Void
    init(sampleType: HKCategoryType, predicate: NSPredicate, limit: Int, sortDescriptors: [NSSortDescriptor], _ completion: @escaping (HKSampleQuery, [Any]?, Error?) -> Void) { self.completion = completion }
}
class HealthStore { func execute(_ query: HKSampleQuery) { query.completion(query, [HKCategorySample()], nil) } }
struct DisplayPreference { let unit = HKUnit() }
class DeviceDataManager {
    let glucoseStore = GlucoseStore()
    let doseStore = DoseStore()
    let cgmEventStore = CgmEventStore()
    let healthStore = HealthStore()
    let loopManager = LoopDataManager()
    let displayGlucosePreference = DisplayPreference()
    var cgmManager: CGMManager? = CGMManager()
    var pumpManager: PumpManager? = PumpManager()
    var pumpIsAllowingAutomation = true
    var cgmStatusHighlight: Highlight? = nil
    var pumpStatusHighlight: Highlight? = nil
    var cgmLifecycleProgress: Progress? = Progress()
    var pumpLifecycleProgress: Progress? = Progress()
}
@MainActor class GlucoseStatisticsLoader {
    static let shared = GlucoseStatisticsLoader()
    var updatedAt: Date? = nil
    var readings: [GlucoseStatisticsReading] = []
    var doses: [GlucoseStatisticsInsulin] = []
    var remoteBoluses: [GlucoseStatisticsInsulin] = []
    var start = Date().addingTimeInterval(-86400)
    var end = Date()
    var glucoseSource = "Fixture cache"
    var message: String? = nil
    var isLoading = false
}
SWIFT
cat > "$task_temp/Tests.swift" <<'SWIFT'
import Foundation
@main struct ReaderChecks {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let controller = CompanionController()
        var injectedReads = 0
        controller.companionDataReader = { _, _ in injectedReads += 1; return ["private": true] }
        do { _ = try await controller.read("get_device_status"); fatalError("Sharing off must reject device access") } catch {}
        check(injectedReads == 0, "Denied access must not invoke the data reader")
        controller.state.allowHealthData = true
        controller.companionDataReader = { _, _ in controller.state.allowHealthData = false; return ["private": true] }
        do { _ = try await controller.read("get_device_status"); fatalError("Revocation must discard the result") } catch {}
        controller.state.allowHealthData = true; controller.companionDataReader = nil
        let manager = DeviceDataManager(); controller.deviceManager = manager
        let now = Date()
        manager.glucoseStore.samples = (0..<205).map { StoredGlucoseSample(startDate: now.addingTimeInterval(-3600 + Double($0)), quantity: HKQuantity(value: 110)) }
        let devices = try await controller.read("get_device_status")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: devices), as: UTF8.self)
        check(!encoded.contains("secret-do-not-share") && !encoded.contains("private-sensor-id"), "Device payload must omit credentials and hardware identifiers")
        let cgm = devices["cgm"] as! [String: Any]
        check((cgm["lifecycle"] as! [String: Any])["expected_session_end"] != nil, "Recorded sensor start/lifetime must be available")
        check((devices["pump"] as! [String: Any])["reservoir"] != nil, "Pump reservoir must be available")
        let g7 = G7Fixture()
        manager.cgmManager?.sensorLifecycle = g7.sensorLifecycle
        let currentDevice = try await controller.read("get_device_status")
        let currentLifecycle = (currentDevice["cgm"] as! [String: Any])["lifecycle"] as! [String: Any]
        check(currentLifecycle["nominal_expiration"] as? String == CompanionDataContext.stamp(g7.sensorExpiresAt!), "Current nominal expiration must come from the CGM provider")
        check(currentLifecycle["expected_session_end"] as? String == CompanionDataContext.stamp(g7.sensorEndsAt!), "Grace-period end must stay distinct from nominal expiration")
        let g6 = G6Fixture()
        check(g6.sensorLifecycle?.sessionEndDate == g6.latestReading!.sessionStartDate!.addingTimeInterval(30 * 86400), "G6 lifecycle must respect the actual configured sensor life")
        g6.latestReading = nil
        check(g6.sensorLifecycle == nil, "G6 must not invent a start without a sensor reading")
        let loop = try await controller.read("get_loop_status")
        check(loop["carbs_on_board"] is NSNull, "Missing COB must remain unknown")
        check((loop["insulin_on_board"] as! [String: Any])["units"] as? Double == 1.5, "IOB must come from Loop's model")
        let settings = try await controller.read("get_therapy_settings")
        check((settings["active_overrides"] as! [[String: Any]]).first?["indefinite"] as? Bool == true, "Indefinite overrides must serialize without infinity")
        var interval: [String: Any] = ["kind": "glucose", "start": CompanionDataContext.stamp(now.addingTimeInterval(-7200)), "end": CompanionDataContext.stamp(now)]
        let first = try await controller.read("get_health_records", interval)
        check((first["records"] as! [[String: Any]]).count == 200 && first["has_more"] as? Bool == true, "Detailed history must expose pagination")
        interval["offset"] = first["next_offset"]
        let second = try await controller.read("get_health_records", interval)
        check((second["records"] as! [[String: Any]]).count == 5 && second["has_more"] as? Bool == false, "Pagination must recover the remaining history")
        interval["offset"] = true
        do { _ = try await controller.read("get_health_records", interval); fatalError("Boolean offset must be rejected") } catch {}
        interval["offset"] = 0
        for kind in ["insulin", "pump_events", "cgm_events", "sleep"] {
            interval["kind"] = kind
            let result = try await controller.read("get_health_records", interval)
            check(!(result["records"] as! [[String: Any]]).isEmpty, "Reader must expose \(kind) records")
        }
        interval["start"] = CompanionDataContext.stamp(now.addingTimeInterval(-8 * 86400))
        do { _ = try await controller.read("get_health_records", interval); fatalError("Unbounded date interval must be rejected") } catch {}
        let catalog = try await controller.read("get_data_catalog")
        check(catalog["sources"] != nil, "Catalog must identify actual data sources")
        let missingStatistics = try await controller.read("get_glucose_statistics")
        check(missingStatistics["status"] as? String == "not_loaded", "Missing long-term cache must stay unknown")
        GlucoseStatisticsLoader.shared.updatedAt = now
        let statistics = try await controller.read("get_glucose_statistics")
        check((statistics["glucose"] as! [String: Any])["gmi_percent"] is NSNull, "Unavailable GMI must not become zero")
        print("PASS device access and in-flight consent revocation")
        print("PASS current CGM/pump lifecycle, reservoir and secret filtering")
        print("PASS production G6/G7 lifecycle adapters and grace-period distinction")
        print("PASS dated Loop IOB/COB and predictions")
        print("PASS read-only therapy settings and indefinite overrides")
        print("PASS all five history readers, pagination and argument validation")
        print("PASS source catalog")
        print("PASS cached long-term statistics and missing-cache handling")
    }
}
SWIFT
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Models/GlucoseStatistics.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CompanionCore.swift" \
    "$task_root/Loop/Companion/CompanionProvider.swift" \
    "$task_temp/Lifecycle.swift" "$task_temp/Adapters.swift" "$task_temp/Interfaces.swift" "$task_temp/Reader.swift" "$task_temp/Tests.swift" \
    -o "$task_temp/data-tests"
"$task_temp/data-tests"
