#!/bin/bash
# Run real note-sync production code against an in-memory Nightscout HTTP transport.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/cycle-note-sync.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
python3 - "$task_root" "$task_temp" <<'PYTHON'
from pathlib import Path
import re, sys
root, out = map(Path, sys.argv[1:])
tests = (root / 'LoopTests/CycleNightscoutNoteSyncTests.swift').read_text().replace('import XCTest\n@testable import Loop', 'import Foundation')
harness = (root / 'Scripts/test-companion-core.sh').read_text().split("harness = r'''", 1)[1].split("'''", 1)[0]
harness += '''
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { fail(message, file: file, line: line) }
'''
names = re.findall(r'    func (test\w+)\(\)( async)?( throws)?', tests)
runner = '\n@main struct NoteSyncRunner {\n@MainActor static func main() async throws {\nlet suite = CycleNightscoutNoteSyncTests()\n'
for name, asynchronous, throwing in names:
    runner += ('try ' if throwing else '') + ('await ' if asynchronous else '') + 'suite.' + name + '()\nprint("PASS ' + name + '")\n'
runner += f'print("Passed {len(names)} cycle note sync checks.")\n}}\n}}\n'
(out / 'Tests.swift').write_text(harness + tests + runner)
tracker = (root / 'Loop/Views/CycleTrackingView.swift').read_text()
tracker = tracker[tracker.index('final class CycleTrackingStore'):tracker.index('struct CycleTrackingView: View')]
(out / 'Tracker.swift').write_text('import Foundation\nimport Combine\n' + tracker)
controller = (root / 'Loop/Companion/CompanionController.swift').read_text()
methods = controller[controller.index('    var cycleNoteSyncEnabled:'):controller.index('    private func cycleNightscoutConfiguration(')]
# Compile the real controller integration against narrow service/lifecycle stubs.
(out / 'Controller.swift').write_text('''
import Foundation
final class DeviceDataManager { var configuration: CycleNightscoutConfiguration? }
@MainActor final class NoteSyncControllerCheck {
    let cycleJournal: CycleJournalStore
    let cycleStore = CycleTrackingStore()
    var deviceManager: DeviceDataManager?
    var applicationIsActive: () -> Bool = { true }
    var isSyncingCycleNotes = false
    var cycleNoteSyncError: String?
    var cycleNoteSyncTask: Task<Void, Never>?
    var cycleNoteSyncAgain = false
    var cycleNoteSyncLastAttempt: Date?
    init(journal: CycleJournalStore) { cycleJournal = journal }
    private func cycleNightscoutConfiguration(manager: DeviceDataManager) -> CycleNightscoutConfiguration? { manager.configuration }
''' + methods + '\n}\n')
# Only the journal's unrelated local error type is stubbed.
(out / 'Error.swift').write_text('import Foundation\nenum CompanionError: Error { case invalid(String) }\n')
PYTHON
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_root/Loop/Companion/CycleNightscoutNoteSync.swift" \
    "$task_temp/Error.swift" "$task_temp/Tracker.swift" "$task_temp/Controller.swift" "$task_temp/Tests.swift" -o "$task_temp/note-sync-tests"
"$task_temp/note-sync-tests"
