#!/bin/bash
# Exercise and render the production cell with the real Mac Catalyst UIKit runtime.
# This verifies layout stability, not a complete iOS app or Nightscout connection.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/glucose-layout.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_output="${GLUCOSE_LAYOUT_OUTPUT_DIR:-$task_temp/rendered}"
mkdir -p "$task_output"
task_sdk="${MOCHI_TEST_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${MOCHI_TEST_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
cat > "$task_temp/main.swift" <<'SWIFT'
import UIKit
import Foundation
func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
// UIKit may lazily add its own selection image inside a button. Track the button
// itself and every app-owned container/label, without asserting SDK internals.
func persistentViews(_ view: UIView) -> [UIView] { [view] + (view is UIButton ? [] : view.subviews.flatMap(persistentViews)) }
func summary(days: Int, loading: Bool, longest: Bool = false) -> GlucoseStatisticsTableViewCell.Summary {
    .init(days: days, inRange: loading ? "—" : (longest ? "100%" : "72%"),
          belowRange: loading ? "—" : (longest ? "0%" : "6%"), aboveRange: loading ? "—" : (longest ? "0%" : "22%"),
          lowerBoundary: longest ? "4.4" : "80", upperBoundary: longest ? "8.1 mmol/L" : "145 mg/dL",
          glucoseFractions: loading ? nil : (longest ? [0, 1, 0] : [0.06, 0.72, 0.22]),
          averageGlucose: loading ? "—" : (longest ? "7.2 mmol/L" : "132 mg/dL"),
          insulinDailyAverage: loading ? "—" : "36.7 U/day", basal: loading ? "—" : "258.4 U", bolus: loading ? "—" : "255.4 U",
          insulinFractions: loading ? nil : [0.503, 0.497],
          insulinNote: loading ? "Loading insulin history…" : "Partial history · Nightscout boluses only",
          status: loading ? "Updating history… · 0% CGM coverage" : "98% CGM coverage · Local + Nightscout · Incomplete")
}
func fit(_ cell: UITableViewCell, width: CGFloat) -> CGFloat {
    cell.bounds = CGRect(x: 0, y: 0, width: width, height: 1000)
    cell.contentView.bounds = cell.bounds
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
    let height = cell.contentView.systemLayoutSizeFitting(CGSize(width: width, height: 0),
        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    cell.bounds.size.height = height
    cell.contentView.bounds = cell.bounds
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
    return height
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var checkCount = 0
for width: CGFloat in [320, 390, 430] {
    let cell = GlucoseStatisticsTableViewCell(style: .default, reuseIdentifier: "test")
    cell.configure(summary(days: 14, loading: true))
    let initialHeight = fit(cell, width: width)
    precondition(initialHeight > 300, "Card did not size itself")
    let originalViews = persistentViews(cell.contentView)
    let originalIDs = Set(originalViews.map(ObjectIdentifier.init))
    for (index, days) in [3, 7, 14, 30, 90, 14, 3].enumerated() {
        cell.configure(summary(days: days, loading: index.isMultiple(of: 2), longest: index.isMultiple(of: 3)))
        let currentHeight = fit(cell, width: width)
        precondition(abs(currentHeight - initialHeight) < 0.5, "Height changed while loading at width \(width): \(initialHeight) -> \(currentHeight)")
        let currentViews = persistentViews(cell.contentView)
        let currentIDs = Set(currentViews.map(ObjectIdentifier.init))
        if currentIDs != originalIDs {
            print("Added views: " + currentViews.filter { !originalIDs.contains(ObjectIdentifier($0)) }.map { String(describing: type(of: $0)) }.joined(separator: ", "))
            print("Removed views: " + originalViews.filter { !currentIDs.contains(ObjectIdentifier($0)) }.map { String(describing: type(of: $0)) }.joined(separator: ", "))
        }
        fflush(stdout)
        precondition(currentIDs == originalIDs, "Subviews were replaced during an update")
        let bar = descendants(cell).first { $0.accessibilityIdentifier == "glucoseStatisticsRangeDiagram" }!
        let expected = index.isMultiple(of: 2) ? [0.0, 0, 0] : (index.isMultiple(of: 3) ? [0.0, 1, 0] : [0.06, 0.72, 0.22])
        for (segment, fraction) in zip(bar.subviews, expected) {
            precondition(abs(segment.frame.width - bar.bounds.width * CGFloat(fraction)) < 0.5, "Bar fill did not update")
        }
    }
    checkCount += 1
    print("PASS persistent hierarchy and stable \(initialHeight)-point height at width \(width)")
    var selected: Int?
    cell.onSelectDays = { selected = $0 }
    for days in [3, 7, 14, 30, 90] {
        let button = descendants(cell).first { $0.accessibilityIdentifier == "glucoseStatisticsPeriod\(days)" } as! UIButton
        // Exercise the registered UIKit target/actions without an app event loop.
        let actions = button.actions(forTarget: cell, forControlEvent: .touchUpInside) ?? []
        precondition(!actions.isEmpty)
        actions.forEach { _ = cell.perform(NSSelectorFromString($0), with: button) }
        precondition(selected == days && button.isSelected)
    }
    precondition(!descendants(cell).contains { $0.accessibilityIdentifier == "glucoseStatisticsSettings" })
    checkCount += 1
    print("PASS day buttons select periods without opening settings at width \(width)")
    for loading in [true, false] {
        cell.configure(summary(days: 14, loading: loading))
        _ = fit(cell, width: width)
        let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { context in
            cell.layer.render(in: context.cgContext)
        }
        let path = output.appendingPathComponent("statistics-\(Int(width))-\(loading ? "loading" : "loaded").png")
        try image.pngData()!.write(to: path)
    }
}
print("Passed \(checkCount) real UIKit layout/interaction checks; saved loading and loaded renders.")
SWIFT
xcrun swiftc -swift-version 5 -sdk "$task_sdk" -target "$(uname -m)-apple-ios15.1-macabi" \
    -F "$task_sdk/System/iOSSupport/System/Library/Frameworks" \
    -module-cache-path "${MOCHI_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/mochi-swift-module-cache}" \
    "$task_root/Loop/Models/GlucoseStatisticsSettings.swift" \
    "$task_root/LoopUI/Extensions/UIColor.swift" \
    "$task_root/Loop/Views/GlucoseStatisticsTableViewCell.swift" "$task_temp/main.swift" -o "$task_temp/layout-tests"
"$task_temp/layout-tests" "$task_output"
