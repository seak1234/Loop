#!/bin/bash
# Run the Foundation-only rule tests without Xcode or XCTest. Uses the same test
# bodies as the LoopTests target, with a small assertion harness.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/mochi-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
task_cache="${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}"
python3 - "$task_root" "$task_temp" <<'PY'
import pathlib, re, sys
root, out = map(pathlib.Path, sys.argv[1:])
source = (root / 'LoopTests/CompanionCoreTests.swift').read_text()
source = 'final class ' + source.split('final class ', 1)[1]
harness = r'''
import Foundation
class XCTestCase {}
func fail(_ message: String, file: StaticString, line: UInt) -> Never {
    fatalError(message, file: file, line: line)
}
func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value() { fail("Expected true", file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value() { fail("Expected false", file: file, line: line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    if value() != nil { fail("Expected nil", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() != b() { fail("Values are not equal", file: file, line: line) } }
    catch { fail("Unexpected comparison error: \(error)", file: file, line: line) }
}
func XCTAssertNoThrow<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body() } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body() } catch { return }
    fail("Expected an error", file: file, line: line)
}
'''
runner = '\nlet suite = CompanionCoreTests()\n'
tests = re.findall(r'func (test\w+)\(\)( async)?( throws)?', source)
for name, asynchronous, throws in tests:
    runner += ('try ' if throws else '') + ('await ' if asynchronous else '') + 'suite.' + name + '()\nprint("PASS ' + name + '")\n'
runner += f'print("Passed {len(tests)} companion core checks.")\n'
(out / 'main.swift').write_text(harness + source + runner)
PY
xcrun swiftc -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_cache" \
    "$task_root/Loop/Companion/CycleNightscoutHistory.swift" \
    "$task_root/Loop/Models/GlucoseGraphSettings.swift" \
    "$task_root/Loop/Companion/CycleJournal.swift" \
    "$task_root/Loop/Companion/CompanionCore.swift" "$task_temp/main.swift" \
    "$task_root/Loop/Companion/CompanionProvider.swift" \
    -o "$task_temp/companion-tests"
"$task_temp/companion-tests"
