#!/bin/bash
# Compile and exercise the production schedule and persistence code without Xcode.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/automatic-bolus-schedule.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'LoopCore/LoopSettings.swift').read_text()
schedule = source[source.index('public struct AutomaticBolusSchedule:'):]
effective = source[source.index('    public func effectiveDosingStrategy('):source.index('    public var defaultRapidActingModel:')]
defaults = (root / 'Loop/Extensions/UserDefaults+Loop.swift').read_text()
property = defaults[defaults.index('    var automaticBolusSchedule:'):defaults.index('    var legacyPumpManagerRawValue:')]
(out / 'Production.swift').write_text('import Foundation\n' + schedule + '''
public enum AutomaticDosingStrategy: CaseIterable { case tempBasalOnly, automaticBolus }
struct LoopSettings {
    var automaticDosingStrategy = AutomaticDosingStrategy.automaticBolus
    var automaticBolusSchedule = AutomaticBolusSchedule()
''' + effective + '''
}
extension UserDefaults {
    private enum Key: String { case automaticBolusSchedule = "com.loopkit.Loop.automaticBolusSchedule" }
''' + property + '\n}\n')
view = (root / 'Loop/Views/DosingStrategySelectionView.swift').read_text()
for module in ['LoopCore', 'LoopKit', 'LoopKitUI']:
    view = view.replace(f'import {module}\n', '')
(out / 'DosingStrategySelectionView.swift').write_text(view)
(out / 'ViewInterfaces.swift').write_text('''import SwiftUI
extension AutomaticDosingStrategy { var title: String { String(describing: self) } }
struct CheckmarkListItem: View {
    let title: Text
    let description: Text
    @Binding var isSelected: Bool
    var body: some View { title }
}
extension View { func insetGroupedListStyle() -> some View { self } }
''')
PY
cat > "$task_temp/Tests.swift" <<'SWIFT'
import Foundation
@main struct Tests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Detroit")!
        func date(_ hour: Int, _ minute: Int = 0, month: Int = 10, day: Int = 20) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        var schedule = AutomaticBolusSchedule(isEnabled: true, ranges: [
            .init(startMinute: 1380, endMinute: 180), .init(startMinute: 300, endMinute: 420)
        ])
        for (hour, minute, expected) in [(22,59,false), (23,0,true), (0,0,true), (2,59,true), (3,0,false), (4,59,false), (5,0,true), (6,59,true), (7,0,false), (12,0,false)] {
            precondition(schedule.allowsAutomaticBolus(at: date(hour, minute), calendar: calendar) == expected)
        }
        print("PASS multiple ranges, midnight, inclusive starts and exclusive ends")
        let restored = AutomaticBolusSchedule(rawValue: schedule.rawValue)!
        precondition(restored == schedule)
        schedule.ranges.append(.init(startMinute: 120, endMinute: 360))
        precondition(schedule.allowsAutomaticBolus(at: date(4), calendar: calendar))
        print("PASS round trip and overlapping ranges")
        schedule.ranges = []
        precondition(!schedule.allowsAutomaticBolus(at: date(1), calendar: calendar))
        schedule.ranges = [.init(startMinute: 100, endMinute: 100), .init(startMinute: -1, endMinute: 200)]
        precondition(!schedule.allowsAutomaticBolus(at: date(1), calendar: calendar))
        precondition(AutomaticBolusSchedule(rawValue: schedule.rawValue) == nil)
        schedule.ranges.removeLast()
        precondition(AutomaticBolusSchedule(rawValue: schedule.rawValue) == schedule)
        schedule.isEnabled = false
        precondition(schedule.allowsAutomaticBolus(at: date(12), calendar: calendar))
        print("PASS empty and invalid ranges, disabled schedule preserves all-day behavior")
        var settings = LoopSettings()
        settings.automaticBolusSchedule = restored
        precondition(settings.effectiveDosingStrategy(at: date(1), calendar: calendar) == .automaticBolus)
        precondition(settings.effectiveDosingStrategy(at: date(12), calendar: calendar) == .tempBasalOnly)
        settings.automaticDosingStrategy = .tempBasalOnly
        precondition(settings.effectiveDosingStrategy(at: date(1), calendar: calendar) == .tempBasalOnly)
        print("PASS selected strategy remains authoritative")
        for (month, day) in [(3, 8), (11, 1)] {
            precondition(restored.allowsAutomaticBolus(at: date(1, month: month, day: day), calendar: calendar))
            precondition(!restored.allowsAutomaticBolus(at: date(3, month: month, day: day), calendar: calendar))
        }
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(!restored.allowsAutomaticBolus(at: date(23), calendar: utc))
        print("PASS DST transition dates and local time zone")
        let suite = "AutomaticBolusScheduleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(!defaults.automaticBolusSchedule.isEnabled)
        defaults.automaticBolusSchedule = restored
        precondition(UserDefaults(suiteName: suite)!.automaticBolusSchedule == restored)
        defaults.set(["isEnabled": true], forKey: "com.loopkit.Loop.automaticBolusSchedule")
        precondition(!defaults.automaticBolusSchedule.allowsAutomaticBolus(at: date(1), calendar: calendar))
        print("PASS persistence reload, legacy default and malformed data fail closed")
    }
}
SWIFT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${TMPDIR:-/tmp}/mochi-swift-module-cache" \
    "$task_temp/Production.swift" "$task_temp/Tests.swift" -o "$task_temp/tests"
"$task_temp/tests"
xcrun swiftc -typecheck -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${TMPDIR:-/tmp}/mochi-swift-module-cache" \
    "$task_temp/Production.swift" "$task_temp/ViewInterfaces.swift" "$task_temp/DosingStrategySelectionView.swift"
printf 'PASS production SwiftUI screen typecheck with dependency interfaces\n'
for task_file in \
    LoopCore/LoopSettings.swift \
    Loop/Extensions/UserDefaults+Loop.swift \
    Loop/Managers/LoopDataManager.swift \
    Loop/Managers/SettingsManager.swift \
    'Loop/View Controllers/StatusTableViewController.swift' \
    'Loop/View Models/SettingsViewModel.swift' \
    Loop/Views/DosingStrategySelectionView.swift \
    Loop/Views/SettingsView.swift; do
    xcrun swiftc -frontend -parse "$task_root/$task_file"
done
printf 'PASS Swift syntax checks for all eight changed production files\n'
