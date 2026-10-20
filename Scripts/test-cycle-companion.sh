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
journal_tools = controller[controller.index('        case "get_cycle_journal":'):controller.index('        case "list_automations":')]
journal_helpers = controller[controller.index('    private func cycleJournalInterval('):controller.index('    /// Builds local history')]
parse_date = controller[controller.index('    private func interval('):controller.index('    private func json(')]
display = controller[controller.index('    func dashboardText('):controller.index('    func requestDashboardRefresh(')]
dashboard = controller[controller.index('    func requestDashboardRefresh('):controller.index('    func rateDashboardMessage(')]
topics = controller[controller.index('    private func cancelTopicGeneration('):controller.index('    var dashboardFact:')]
helpers = controller[controller.index('    private func json('):controller.index('    private func glucose(start:')]
# Omit the iOS lifecycle and unrelated chat/action code; keep the real request
# builders and the real cycle-context tool body unchanged.
shell = '''
import Foundation
import CoreFoundation
import Combine
@MainActor final class CompanionController {
    private let provider: CompanionProvider
    private let cycleStore: CycleTrackingStore
    var state: CompanionState
    let store: CompanionStateStore
    var cycleCardRevision = UUID()
    var dashboardVisitIndex = 0
    let cycleJournal: CycleJournalStore
    let hasKey: Bool
    var isRefreshingDashboard = false
    var isThinking = false
    var dashboardVisible = false
    var dashboardDataChanged = false
    var dashboardLastAttempt: Date?
    var dashboardTask: Task<Void, Never>?
    var dashboardRevision = UUID()
    var dashboardRefreshError: String?
    var storageFailure: String?
    var errorMessage: String?
    let applicationIsActive: () -> Bool = { true }
    let dashboardHealthReader: ((String, Date, Date) async throws -> [String: Any])? = nil
    var chatVisible = false
    var suggestedTopics: [CompanionTopic] = []
    var topicRevision = UUID()
    var topicTask: Task<Void, Never>?
    var isGeneratingTopics = false
    var diabetesMindset: String { "Use general educational questions." }
    func beginChatSession() { chatVisible = true; refreshSuggestedTopics() }
    func endChatSession() { chatVisible = false; cancelTopicGeneration() }
    func refreshConnectionStatus() {}
    func healthData(tool: String, start: Date, end: Date) async throws -> [String: Any] { [:] }
    let companionDataReader: ((String, [String: Any]) async throws -> [String: Any])?
    func readCompanionData(tool: String, args: [String: Any]) async throws -> [String: Any] {
        if let reader = companionDataReader { return try await reader(tool, args) }
        return ["status": "unavailable"]
    }
    init(provider: CompanionProvider, stateStore: CompanionStateStore,
         cycleStore: CycleTrackingStore, cycleJournal: CycleJournalStore? = nil, keyReader: () throws -> String?,
         companionDataReader: ((String, [String: Any]) async throws -> [String: Any])? = nil) {
        self.provider = provider
        store = stateStore
        self.cycleStore = cycleStore
        self.cycleJournal = cycleJournal ?? CycleJournalStore(url: stateStore.url.deletingLastPathComponent().appendingPathComponent("journal.json"))
        self.companionDataReader = companionDataReader
        state = try! stateStore.load()
        hasKey = (try? keyReader()) != nil
    }
'''
shell += '''
    func commit(_ edit: (inout CompanionState) throws -> Void) async throws {
        var next = state
        try edit(&next)
        try store.save(next)
        state = next
    }
'''
shell += methods + display + dashboard + topics + helpers + journal_helpers + parse_date + '\nprivate func execute(_ call: CompanionToolCall) async throws -> String {\nguard let args = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else { throw CompanionError.invalid("Invalid arguments") }\nswitch call.name {\n'
shell += cycle_tool + journal_tools + '\ndefault: throw CompanionError.invalid("Unexpected test tool")\n}\n}\n}\n'
shell += controller[controller.index('/// Own the request independently'):controller.index('@MainActor\nfinal class CompanionMealConversation')]
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
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CompanionCore.swift" \
    "$task_root/Loop/Companion/CompanionProvider.swift" \
    "$task_temp/Tracker.swift" "$task_temp/Controller.swift" "$task_temp/Tests.swift" \
    -o "$task_temp/cycle-tests"
"$task_temp/cycle-tests"
