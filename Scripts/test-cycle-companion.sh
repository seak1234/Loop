#!/bin/bash
# Exercise the cycle-only provider requests with production methods and real tracker data.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/cycle-companion-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
task_cache="${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}"
python3 - "$task_root" "$task_temp" <<'PY'
import pathlib, re, sys
root, out = map(pathlib.Path, sys.argv[1:])
controller = (root / 'Loop/Companion/CompanionController.swift').read_text()
methods = controller[controller.index('    private var cycleConversationInstructions:'):controller.index('    func attach(to manager:')]
cycle_tool = controller[controller.index('        case "get_cycle_context":'):controller.index('        case "get_glucose_summary", "get_insulin_summary", "get_carb_entries":')]
display = controller[controller.index('    func dashboardText('):controller.index('    func dismissDashboard(')]
helpers = controller[controller.index('    private func json('):controller.index('    private func glucose(start:')]
# Omit the iOS lifecycle and unrelated chat/action code; keep the real request
# builders and the real cycle-context tool body unchanged.
shell = '''
import Foundation
import Combine
@MainActor final class CompanionController {
    private let provider: CompanionProvider
    private let cycleStore: CycleTrackingStore
    let state: CompanionState
    let hasKey: Bool
    var isRefreshingDashboard = false
    init(provider: CompanionProvider, stateStore: CompanionStateStore,
         cycleStore: CycleTrackingStore, keyReader: () throws -> String?) {
        self.provider = provider
        self.cycleStore = cycleStore
        state = try! stateStore.load()
        hasKey = (try? keyReader()) != nil
    }
'''
shell += methods + display + helpers + '\nprivate func execute(_ call: CompanionToolCall) async throws -> String {\nswitch call.name {\n'
shell += cycle_tool + '\ndefault: throw CompanionError.invalid("Unexpected test tool")\n}\n}\n}\n'
(out / 'Controller.swift').write_text(shell)
tracker = (root / 'Loop/Views/CycleTrackingView.swift').read_text()
tracker = tracker[tracker.index('final class CycleTrackingStore'):tracker.index('struct CycleTrackingView: View')]
(out / 'Tracker.swift').write_text('import Foundation\nimport Combine\n' + tracker)
source = (root / 'LoopTests/CompanionCycleIntegrationTests.swift').read_text()
probe = source[source.index('private final class CycleProviderProbe'):source.index('@MainActor\nfinal class CompanionCycleIntegrationTests')]
tests = source[source.index('@MainActor\nfinal class CompanionCycleSurfaceTests'):source.index('@MainActor\nfinal class CompanionDashboardIntegrationTests')]
harness = (root / 'Scripts/test-companion-core.sh').read_text().split("harness = r'''", 1)[1].split("'''", 1)[0]
harness += '''
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { fail("Expected a value", file: file, line: line) }
    return value
}
'''
names = re.findall(r'    func (test\w+)\(\)( async)?( throws)?', tests)
runner = '\n@main struct CycleSurfaceRunner {\n@MainActor static func main() async throws {\nlet suite = CompanionCycleSurfaceTests()\n'
for name, asynchronous, throwing in names:
    runner += ('try ' if throwing else '') + ('await ' if asynchronous else '') + 'suite.' + name + '()\nprint("PASS ' + name + '")\n'
runner += f'print("Passed {len(names)} cycle companion checks.")\n}}\n}}\n'
(out / 'Tests.swift').write_text(harness + probe + tests + runner)
PY
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_cache" \
    "$task_root/Loop/Companion/CompanionCore.swift" \
    "$task_root/Loop/Companion/CompanionProvider.swift" \
    "$task_temp/Tracker.swift" "$task_temp/Controller.swift" "$task_temp/Tests.swift" \
    -o "$task_temp/cycle-tests"
"$task_temp/cycle-tests"
