#!/bin/bash
# Compile the production screen, settings and loader against UIKit/SwiftUI.
# Only unrelated app/chart/service interfaces are stubbed; this is not an iOS build.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/glucose-statistics-ui.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import re, sys
root, out = map(Path, sys.argv[1:])
for name in ['Loop/View Controllers/PredictionTableViewController.swift', 'Loop/Models/GlucoseStatisticsLoader.swift', 'Loop/Views/GlucoseGraphSettingsView.swift']:
    s = (root / name).read_text()
    s = re.sub(r'^import (LoopCore|LoopKit|LoopKitUI|LoopUI)\n', '', s, flags=re.M)
    (out / Path(name).name).write_text(s)
# Use the actual display preference implementation with only its formatter dependency stubbed.
s = (root.parent / 'LoopKit/LoopKitUI/ViewModels/DisplayGlucosePreference.swift').read_text().replace('import LoopKit\n', '')
(out / 'DisplayGlucosePreference.swift').write_text(s)
(out / 'Interfaces.swift').write_text('''
import UIKit
import SwiftUI
import HealthKit
import Combine
import os.log
extension UIColor {
    static var dashboardBackground: UIColor { .systemBackground }
    static var dashboardSurface: UIColor { .secondarySystemBackground }
    static var dashboardBorder: UIColor { .separator }
    static var dashboardGlucoseAccent: UIColor { .systemTeal }
    static var dashboardGlucoseInRange: UIColor { .systemGreen }
    static var dashboardGlucoseInRangeInk: UIColor { .systemGreen }
    static var dashboardGlucoseBelowRange: UIColor { .systemRed }
    static var dashboardGlucoseAboveRange: UIColor { .systemYellow }
    static var dashboardInk: UIColor { .label }
    static var dashboardMutedInk: UIColor { .secondaryLabel }
}
extension HKQuantity: @retroactive Comparable { public static func < (lhs: HKQuantity, rhs: HKQuantity) -> Bool { lhs.compare(rhs) == .orderedAscending } }
extension HKUnit {
    static var milligramsPerDeciliter: HKUnit { .init(from: "mg/dL") }
    var localizedShortUnitString: String { unitString }
}
public protocol DisplayGlucoseUnitObserver { func unitDidChange(to: HKUnit) }
public class QuantityFormatter {
    public let numberFormatter = NumberFormatter()
    public init(for unit: HKUnit) {}
    public func string(from quantity: HKQuantity, includeUnit: Bool = true) -> String? { "0" }
    public func localizedUnitStringWithPlurality() -> String { "mg/dL" }
}
extension View { func insetGroupedListStyle() -> some View { listStyle(.insetGrouped) } }
protocol IdentifiableClass {}
extension IdentifiableClass { static var className: String { String(describing: Self.self) } }
extension UITableViewCell { static var className: String { String(describing: Self.self) } }
extension OSLog {
    convenience init(category: String) { self.init(subsystem: "test", category: category) }
    func debug(_ text: String) {}
    func error(_ text: String, _ value: String) {}
}
extension UserDefaults { var integralRetrospectiveCorrectionEnabled: Bool { false } }
extension TimeInterval { init(hours: Double) { self = hours * 3600 } }
extension Notification.Name { static let LoopDataUpdated = Notification.Name("LoopDataUpdated") }
enum FeatureFlags { static let predictedGlucoseChartClampEnabled = false }
enum LoopConstants { static let glucoseChartDefaultDisplayRangeWide: ClosedRange<Double> = 40...400 }
struct GlucoseChange { let quantity: HKQuantity }
struct StoredGlucoseSample {
    let startDate: Date
    let quantity: HKQuantity
    let wasUserEntered: Bool
    let isDisplayOnly: Bool
}
enum DoseType { case bolus, basal, tempBasal, suspend, resume }
struct DoseEntry {
    let startDate: Date
    let endDate: Date
    let unitsInDeliverableIncrements: Double
    let isMutable: Bool
    let type: DoseType
}
class GlucoseStore {
    var latestGlucose: StoredGlucoseSample? { nil }
    func getGlucoseSamples(start: Date, end: Date?, completion: @escaping (Result<[StoredGlucoseSample], Error>) -> Void) {}
}
class DoseStore {
    func getNormalizedDoseEntries(start: Date, end: Date?, completion: @escaping (Result<[DoseEntry], Error>) -> Void) {}
}
struct Service { let pluginIdentifier: String; let isOnboarded: Bool }
struct ServiceManager { var activeServices: [Service] = [] }
class DeviceDataManager {
    let displayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter)
    let glucoseStore = GlucoseStore()
    let doseStore = DoseStore()
    let loopManager = LoopDataManager()
    let servicesManager = ServiceManager()
    var cgmManager: Service? { nil }
}
struct Credentials { let url: URL; let password: String }
struct KeychainManager { func getInternetCredentials(account: String) throws -> Credentials { fatalError() } }
struct CycleNightscoutConfiguration: Equatable { let siteURL: URL; let apiSecret: String }
struct RemoteReading { let date: Date; let mgdl: Double }
struct RemoteBolus { let date: Date; let amount: Double }
struct RemoteBatch { let glucose: [RemoteReading]?; let boluses: [RemoteBolus]? }
struct CycleNightscoutHistory {
    let configuration: CycleNightscoutConfiguration
    func fetch(start: Date, end: Date, includeGlucose: Bool = true, includeTreatments: Bool = true) async throws -> RemoteBatch { fatalError() }
}
struct LoopState {
    var retrospectiveGlucoseDiscrepancies: [GlucoseChange]? { nil }
    var totalRetrospectiveCorrection: HKQuantity? { nil }
    var predictedGlucoseIncludingPendingInsulin: [HKQuantity]? { nil }
    func predictGlucose(using inputs: PredictionInputEffect, includingPendingInsulin: Bool) throws -> [HKQuantity] { [] }
}
class LoopDataManager {
    static let LoopUpdateContextKey = "context"
    enum LoopUpdateContext: Int { case preferences, glucose }
    struct Settings { var glucoseTargetRangeSchedule: Int? { nil } }
    let settings = Settings()
    func getLoopState(_ completion: @escaping (LoopDataManager, LoopState) -> Void) {}
}
enum ChartColors { case dashboard }
enum ChartSettings { case `default` }
struct ChartPoint { let y: Double }
class PredictedGlucoseChart {
    var glucoseUnit = HKUnit.milligramsPerDeciliter
    var inRangeDisplayRange: ClosedRange<HKQuantity>?
    var glucoseDisplayRange: ClosedRange<Double>?
    var targetGlucoseFillColor = UIColor.clear
    var targetGlucoseSchedule: Int?
    var alternatePredictedGlucosePoints: [ChartPoint]?
    init(yAxisStepSizeMGDLOverride: Double?) {}
    func setPredictedGlucoseValues(_ values: [HKQuantity]) {}
    func setAlternatePredictedGlucoseValues(_ values: [HKQuantity]) {}
    func setGlucoseValues(_ values: [StoredGlucoseSample]) {}
}
struct Chart { var view: UIView { UIView() } }
class ChartsManager {
    var startDate = Date()
    var gestureRecognizer: UIGestureRecognizer? = UIGestureRecognizer()
    init(colors: ChartColors, settings: ChartSettings, charts: [PredictedGlucoseChart], traitCollection: UITraitCollection) {}
    func chart(atIndex: Int, frame: CGRect) -> Chart? { nil }
    func invalidateChart(atIndex: Int) {}
    func prerender() {}
}
class LoopChartsTableViewController: UITableViewController {
    var deviceManager: DeviceDataManager! = DeviceDataManager()
    var active = true
    var visible = true
    var notificationObservers: [NSObjectProtocol] = []
    lazy var charts = createChartsManager()
    func createChartsManager() -> ChartsManager { fatalError() }
    func glucoseUnitDidChange() {}
    func reloadData(animated: Bool = false) {}
}
class ChartTableViewCell: UITableViewCell {
    var dashboardCardAccentColor = UIColor.clear
    var doesNavigate = false
    func setChartGenerator(generator: (CGRect) -> UIView?) {}
    func setTitleLabelText(label: String) {}
    func setAttributedSubtitleLabel(_ text: NSAttributedString) {}
    func setSubtitleLabel(label: String?) {}
    func reloadChart() {}
}
''')
base = (root / 'Loop/View Controllers/LoopChartsTableViewController.swift').read_text()
refresh = base[base.index('enum RefreshContext:'):base.index('/// Abstract class')]
with (out / 'Interfaces.swift').open('a') as f:
    f.write(refresh)
PY
xcrun swiftc -sdk "$task_sdk" -target "$(uname -m)-apple-ios15.1-macabi" \
    -F "$task_sdk/System/iOSSupport/System/Library/Frameworks" \
    -typecheck -swift-version 5 -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Models/GlucoseStatistics.swift" \
    "$task_root/Loop/Models/GlucoseStatisticsSettings.swift" \
    "$task_root/Loop/Models/PredictionInputEffect.swift" \
    "$task_root/Loop/Views/GlucoseStatisticsTableViewCell.swift" \
    "$task_root/Loop/Views/PredictionInputEffectTableViewCell.swift" \
    "$task_temp/Interfaces.swift" "$task_temp/DisplayGlucosePreference.swift" \
    "$task_temp/GlucoseGraphSettingsView.swift" "$task_temp/GlucoseStatisticsLoader.swift" \
    "$task_temp/PredictionTableViewController.swift"
echo "Predicted Glucose statistics screen, settings and loader UIKit/SwiftUI type checks passed."
