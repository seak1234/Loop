#!/bin/bash
# Run the production calculations and XCTest test bodies without Xcode.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
# Some Command Line Tools installations select an SDK newer than their compiler.
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/glucose-statistics.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
python3 - "$task_root" "$task_temp" <<'PY'
from pathlib import Path
import re, sys
root, out = map(Path, sys.argv[1:])
harness = (root / 'Scripts/test-companion-core.sh').read_text().split("harness = r'''", 1)[1].split("'''", 1)[0]
s = (root / 'LoopTests/GlucoseStatisticsTests.swift').read_text().replace('import XCTest\n', '').replace('@testable import Loop\n', '')
runner = '\nlet suite = GlucoseStatisticsTests()\n'
methods = re.findall(r'    func (test\w+)\(\)', s)
for name in methods:
    runner += f'suite.{name}()\nprint("PASS {name}")\n'
runner += f'print("Passed {len(methods)} glucose statistics checks.")\n'
(out / 'main.swift').write_text(harness + s + runner)
PY
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseStatistics.swift" \
    "$task_root/Loop/Models/GlucoseStatisticsSettings.swift" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_temp/main.swift" -o "$task_temp/tests"
"$task_temp/tests"
