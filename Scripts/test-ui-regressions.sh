#!/bin/bash
# Exercise portable UI state with the same test bodies used by the iOS target.
# UIKit rendering and device lifecycle checks still require Xcode.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/loop-ui-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
task_cache="${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}"
python3 - "$task_root" "$task_temp" <<'PY'
import pathlib, re, sys
root, out = map(pathlib.Path, sys.argv[1:])
controller = (root / 'Loop/Companion/CompanionController.swift').read_text()

def method(name):
    match = re.search(r'^    (?:private )?func ' + name + r'\(.*?^    }\n', controller, re.M | re.S)
    assert match, name
    header = match.group().splitlines()[0]
    return header + '\n' if header.rstrip().endswith('}') else match.group()

# Only replace the iOS-specific controller shell. Transactions, chat submission,
# meal review and meal conversation methods below are copied directly from source.
shell = '''
import Foundation
import Combine
@MainActor final class CompanionController: ObservableObject {
    @Published private(set) var state: CompanionState
    @Published private(set) var isThinking = false
    var errorMessage: String?
    let store: CompanionStateStore
    let provider: CompanionProvider
    let cycleJournal: CycleJournalStore
    let hasKey: Bool
    var storageFailure: String?
    var chatTask: Task<Void, Never>?
    var chatRevision = UUID()
    var commitInProgress = false
    var commitWaiters: [CheckedContinuation<Void, Never>] = []
    var busyActions = Set<UUID>()
    var instructions: String { "Test conversation" }
    init(provider: CompanionProvider, stateStore: CompanionStateStore, keyReader: () throws -> String?) {
        self.provider = provider
        store = stateStore
        cycleJournal = CycleJournalStore(url: stateStore.url.deletingLastPathComponent().appendingPathComponent("journal.json"))
        state = try! store.load()
        hasKey = (try? keyReader()) != nil
    }
    func dashboardDataDidChange() {}
    func continueDashboardDiscussion() {}
    func execute(_ call: CompanionToolCall) async throws -> String { throw CompanionError.invalid("No device attached") }
    func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
'''
shell += '\n'.join(method(name) for name in ['commit', 'send', 'reviewMeal', 'decline', 'cancelChat']) + '\n}\n'
shell += controller[controller.index('@MainActor\nfinal class CompanionMealConversation'):]
(out / 'Controller.swift').write_text(shell)
model = (root / 'Loop/View Models/LiveActivityManagementViewModel.swift').read_text().replace('import LoopCore', 'import Combine')
# Use the actual UserDefaults property while omitting unrelated LoopCore services.
defaults = (root / 'LoopCore/NSUserDefaults.swift').read_text()
prop = defaults[defaults.index('    public var liveActivity:'):defaults.index('    public func removeLegacyLoopSettings')]
prop = prop.replace('Key.liveActivity.rawValue', '"com.loopkit.Loop.liveActivity"')
(out / 'LiveActivityModel.swift').write_text(model + '\nextension UserDefaults {\n' + prop + '\n}\n')
# Reuse the lightweight XCTest assertions from the existing portable core runner.
core_runner = (root / 'Scripts/test-companion-core.sh').read_text()
harness = core_runner.split("harness = r'''", 1)[1].split("'''", 1)[0]
harness += '''
func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() == nil { fail("Expected a value", file: file, line: line) }
}
'''
tests = (root / 'LoopTests/UIRegressionTests.swift').read_text().replace('import XCTest', '')
# UIKit image tests compile and run only in the iOS target.
portable = re.sub(r'    #if canImport\(UIKit\).*?    #endif', '', tests, flags=re.S)
names = re.findall(r'    func (test\w+)\(\)( async)?( throws)?', portable)
runner = '\n@main struct UIRegressionRunner {\n@MainActor static func main() async throws {\nlet suite = UIRegressionTests()\n'
for name, asynchronous, throwing in names:
    runner += ('try ' if throwing else '') + ('await ' if asynchronous else '') + 'suite.' + name + '()\nprint("PASS ' + name + '")\n'
runner += f'print("Passed {len(names)} UI regression checks.")\n}}\n}}\n'
(out / 'Tests.swift').write_text(harness + tests + runner)
PY
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_cache" \
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CompanionCore.swift" \
    "$task_root/Loop/Companion/CompanionProvider.swift" \
    "$task_root/LoopCore/LiveActivitySettings.swift" \
    "$task_temp/Controller.swift" "$task_temp/LiveActivityModel.swift" "$task_temp/Tests.swift" \
    -o "$task_temp/ui-tests"
"$task_temp/ui-tests"
