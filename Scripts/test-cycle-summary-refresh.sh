#!/bin/bash
# Exercise the production local journal refresh with controlled store responses.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/cycle-summary-refresh.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
controller = (root / 'Loop/Companion/CompanionController.swift').read_text()
refresh = controller[controller.index('    func refreshCycleSummaries('):controller.index('    func refreshOlderCycleDay(')]
(out / 'Controller.swift').write_text('''
import Foundation
enum CompanionError: Error { case invalid(String) }
enum Unit {
    case milligramsPerDeciliter, grams
    static func gram() -> Self { .grams }
}
struct Quantity { let value: Double; func doubleValue(for: Unit) -> Double { value } }
struct StoredGlucoseSample {
    let startDate: Date; let quantity: Quantity
    let wasUserEntered = false, isDisplayOnly = false
}
struct DoseEntry {
    let startDate: Date, endDate: Date
    let unitsInDeliverableIncrements: Double
    func trimmed(from: Date, to: Date) -> Self { self }
}
struct CarbEntry { let startDate: Date; let quantity: Quantity }
class DoseStore {
    func getNormalizedDoseEntries(start: Date, end: Date, completion: (Result<[DoseEntry], Error>) -> Void) { completion(.success([])) }
}
class CarbStore {
    var entries: [CarbEntry] = []
    var earliestCacheDate = Date.distantPast
    var fails = false
    func getCarbEntries(start: Date, end: Date) async throws -> [CarbEntry] {
        if fails { throw CompanionError.invalid("Synthetic query failure") }
        return entries.filter { $0.startDate >= max(start, earliestCacheDate) && $0.startDate < end }
    }
}
class DeviceDataManager { let doseStore = DoseStore(); let carbStore = CarbStore() }
struct Tracker { func noteContext(for note: CycleJournalNote) -> CycleNoteContext { note.cycleContext ?? .init() } }
@MainActor final class CompanionController {
    let cycleJournal: CycleJournalStore
    let cycleStore = Tracker()
    var deviceManager: DeviceDataManager?
    var cycleDataError: String?
    var isCollectingCycleData = false
    var cycleLastCollection: Date?
    init(journal: CycleJournalStore, manager: DeviceDataManager) { cycleJournal = journal; deviceManager = manager }
    func syncCycleNotes(force: Bool) async {}
    func glucose(start: Date, end: Date) async throws -> [StoredGlucoseSample] { [] }
    func cycleNightscoutConfiguration(manager: DeviceDataManager) -> CycleNightscoutConfiguration? { nil }
    func refreshNightscoutCycleSummaries(manager: DeviceDataManager, now: Date, range: (Date) -> (Double, Double)?) async {}
''' + refresh + '\n}\n')
PY
cat > "$task_temp/Tests.swift" <<'SWIFT'
import Foundation
@main struct SummaryRefreshTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CycleJournalStore(url: directory.appendingPathComponent("journal.json"))
        let manager = DeviceDataManager()
        let controller = CompanionController(journal: journal, manager: manager)
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let first = CarbEntry(startDate: day.addingTimeInterval(3600), quantity: Quantity(value: 30))
        let second = CarbEntry(startDate: day.addingTimeInterval(7200), quantity: Quantity(value: 50))
        manager.carbStore.earliestCacheDate = day
        manager.carbStore.entries = [first, second]
        await controller.refreshCycleSummaries(force: true)
        precondition(journal.summary(on: day)?.carbGrams == 80)

        manager.carbStore.entries = [first]
        await controller.refreshCycleSummaries(force: true)
        precondition(journal.summary(on: day)?.carbGrams == 30)
        precondition(journal.summary(on: day)?.carbEntryCount == 1)
        print("PASS local refresh applies a deleted carb entry")

        manager.carbStore.entries = []
        await controller.refreshCycleSummaries(force: true)
        precondition(journal.summary(on: day)?.carbEntryCount == 0)
        precondition(journal.summary(on: day)?.carbGrams == nil)
        print("PASS deleting the final carb clears an otherwise empty day")

        manager.carbStore.entries = [first, second]
        await controller.refreshCycleSummaries(force: true)
        manager.carbStore.fails = true
        await controller.refreshCycleSummaries(force: true)
        precondition(journal.summary(on: day)?.carbGrams == 80)
        precondition(controller.cycleDataError?.contains("carbs") == true)
        print("PASS failed local query preserves saved totals and reports the failure")

        manager.carbStore.fails = false
        manager.carbStore.earliestCacheDate = second.startDate
        await controller.refreshCycleSummaries(force: true)
        precondition(journal.summary(on: day)?.carbGrams == 80)
        precondition(journal.summary(on: day)?.carbEntryCount == 2)
        print("PASS a partially expired local cache cannot erase retained carbs")

        manager.carbStore.earliestCacheDate = day
        manager.carbStore.entries = [first]
        await controller.refreshCycleSummaries(force: true)
        let reloaded = CycleJournalStore(url: journal.url).summary(on: day)!
        precondition(reloaded.carbGrams == 30 && reloaded.carbEntryCount == 1)
        print("PASS corrected local totals survive reloading the journal")
        print("Passed 5 production cycle summary refresh checks.")
    }
}
SWIFT
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_temp/Controller.swift" "$task_temp/Tests.swift" -o "$task_temp/tests"
"$task_temp/tests"
