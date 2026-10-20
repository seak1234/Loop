#!/bin/bash
# Check the real cycle screens against UIKit/SwiftUI using Mac Catalyst. Only
# unrelated app service interfaces are stubbed. This is not a simulator/build test.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$task_root/Scripts/validate-xcode-project.py"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/cycle-ui-typecheck.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
python3 - "$task_root" "$task_temp" <<'PYTHON'
from pathlib import Path
import sys
root=Path(sys.argv[1])
out=Path(sys.argv[2])
s=(root/'Loop/Views/CycleTrackingView.swift').read_text().replace('import LoopUI\n','')
(out/'CycleTrackingView.swift').write_text(s)
s=(root/'Loop/Companion/CompanionView.swift').read_text();a=s.index('private struct MochiCycleSpeechBubble: Shape');b=s.index('struct CompanionDashboardIcon',a)
controller=(root/'Loop/Companion/CompanionController.swift').read_text()
conversation=controller[controller.index('/// Own the request independently'):controller.index('@MainActor\nfinal class CompanionMealConversation')]
(out/'CycleChat.swift').write_text('import SwiftUI\n'+conversation+s[a:b])
(out/'Interfaces.swift').write_text('''
import SwiftUI
import UIKit
@MainActor final class CompanionController: ObservableObject {
    static let shared = CompanionController()
    @Published var state = CompanionState()
    @Published var hasKey = false
    @Published var isCollectingCycleData = false
    @Published var cycleDataError: String?
    @Published var isSyncingCycleNotes = false
    @Published var cycleNoteSyncError: String?
    var cycleNoteSyncEnabled: Bool { false }
    func setCycleNoteSyncEnabled(_ enabled: Bool) {}
    func syncCycleNotes(force: Bool = false) async {}
    func cycleCardPhase(on date: Date) -> CompanionCycleCardPhase { .period }
    func makeCycleCards() async throws -> [CompanionCycleCardPhase: CompanionCycleCardMessage] { [:] }
    let cycleJournal = CycleJournalStore.shared
    func refreshCycleSummaries(force: Bool = false) async {}
    func refreshOlderCycleDay(_ date: Date) async {}
    func replyToCycleConversation(_ turns: [CompanionMessage]) async throws -> CompanionMessage { .init(role: "assistant", text: "") }
}
struct MochiAvatar: View { let size: CGFloat; var body: some View { Color.clear.frame(width: size, height: size) } }
enum MochiStyle { static let blue = Color.blue }
struct CompanionSettingsView: View { let controller: CompanionController; var body: some View { Text("Settings") } }
extension UIColor {
    static var dashboardBackground: UIColor { .systemBackground }
    static var dashboardCoral: UIColor { .systemPink }
    static var dashboardInk: UIColor { .label }
    static var dashboardMutedInk: UIColor { .secondaryLabel }
    static var dashboardSurface: UIColor { .secondarySystemBackground }
    static var dashboardBorder: UIColor { .separator }
}
''')
PYTHON
xcrun swiftc -sdk "$task_sdk" -target "$(uname -m)-apple-ios15.1-macabi" \
    -F "$task_sdk/System/iOSSupport/System/Library/Frameworks" \
    -typecheck -swift-version 5 -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Models/GlucoseStatistics.swift" \
    "$task_root/Loop/Companion/CompanionCore.swift" "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_temp/Interfaces.swift" "$task_temp/CycleTrackingView.swift" "$task_temp/CycleChat.swift" \
    "$task_root/Loop/Views/CycleJournalView.swift"
echo "Cycle journal, period history and cycle chat UIKit/SwiftUI type checks passed."
