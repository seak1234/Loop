//
//  LiveActivityConfiguration.swift
//  Loop Widget Extension
//
//  Created by Bastiaan Verhaar on 23/06/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import ActivityKit
import Charts
import HealthKit
import LoopCore
import LoopKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct GlucoseLiveActivityConfiguration: Widget {
    private static let dashboardCoral = Color(
        red: 232 / 255,
        green: 130 / 255,
        blue: 136 / 255
    )

    private static let dashboardLoopFresh = Color(
        red: 116 / 255,
        green: 184 / 255,
        blue: 138 / 255
    )

    var body: some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return ActivityConfiguration(for: GlucoseActivityAttributes.self) {
                context in
                lockScreenView(context: context)
            } dynamicIsland: { context in
                dynamicIslandView(context: context)
            }
            .supplementalActivityFamilies([.small])
        } else {
            return ActivityConfiguration(for: GlucoseActivityAttributes.self) {
                context in
                lockScreenView(context: context)
            } dynamicIsland: { context in
                dynamicIslandView(context: context)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        // Create the presentation that appears on the Lock Screen and as a
        // banner on the Home Screen of devices that don't support the Dynamic Island.
        if #available(iOS 18.0, *) {
            AdaptiveLockScreenView(context: context)
        } else {
            fullLockScreenView(context: context)
        }
    }

    @available(iOS 18.0, *)
    struct AdaptiveLockScreenView: View {
        let context: ActivityViewContext<GlucoseActivityAttributes>
        @Environment(\.activityFamily) private var activityFamily

        var body: some View {
            if activityFamily == .small {
                // WatchOS & CarPlay supplemental view - show only bottom row
                compactLockScreenView(context: context)
            } else {
                // Lock screen - show full view with chart
                fullLockScreenView(context: context)
            }
        }

        @ViewBuilder
        private func fullLockScreenView(
            context: ActivityViewContext<GlucoseActivityAttributes>
        ) -> some View {
            GlucoseLiveActivityConfiguration().fullLockScreenView(
                context: context
            )
        }

        @ViewBuilder
        private func compactLockScreenView(
            context: ActivityViewContext<GlucoseActivityAttributes>
        ) -> some View {
            GlucoseLiveActivityConfiguration().compactLockScreenView(
                context: context
            )
        }
    }

    @ViewBuilder
    private func fullLockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        ZStack {
            VStack {
                if context.attributes.mode == .large {
                    HStack(spacing: 15) {
                        loopIcon(context)
                        if context.attributes.addPredictiveLine {
                            ChartView(
                                glucoseSamples: context.state.glucoseSamples,
                                predicatedGlucose: context.state
                                    .predicatedGlucose,
                                predicatedStartDate: context.state
                                    .predicatedStartDate,
                                predicatedInterval: context.state
                                    .predicatedInterval,
                                useLimits: context.attributes.useLimits,
                                lowerLimit: context.state.isMmol
                                ? context.attributes.lowerLimitChartMmol
                                : context.attributes.lowerLimitChartMg,
                                upperLimit: context.state.isMmol
                                ? context.attributes.upperLimitChartMmol
                                : context.attributes.upperLimitChartMg,
                                glucoseRanges: context.state.glucoseRanges,
                                preset: context.state.preset,
                                yAxisMarks: context.state.yAxisMarks
                            )
                            .frame(height: 85)
                        } else {
                            ChartView(
                                glucoseSamples: context.state.glucoseSamples,
                                useLimits: context.attributes.useLimits,
                                lowerLimit: context.state.isMmol
                                ? context.attributes.lowerLimitChartMmol
                                : context.attributes.lowerLimitChartMg,
                                upperLimit: context.state.isMmol
                                ? context.attributes.upperLimitChartMmol
                                : context.attributes.upperLimitChartMg,
                                glucoseRanges: context.state.glucoseRanges,
                                preset: context.state.preset,
                                yAxisMarks: context.state.yAxisMarks
                            )
                            .frame(height: 85)
                        }
                    }
                }
                
                HStack {
                    bottomSpacer(border: false)
                    
                    let endIndex = context.state.bottomRow.endIndex - 1
                    ForEach(
                        Array(context.state.bottomRow.enumerated()),
                        id: \.element
                    ) { (index, item) in
                        switch item.type {
                        case .generic:
                            bottomItemGeneric(
                                title: item.label,
                                value: item.value,
                                unit: LocalizedString(
                                    item.unit,
                                    comment: "No comment"
                                )
                            )
                            
                        case .basal:
                            BasalViewActivity(
                                percent: item.percentage,
                                rate: item.rate
                            )
                            
                        case .currentBg:
                            bottomItemCurrentBG(
                                value: item.value,
                                trend: item.trend,
                                context: context
                            )
                        }
                        
                        if index != endIndex {
                            bottomSpacer(border: true)
                        }
                    }
                    
                    bottomSpacer(border: false)
                }
            }
            if context.state.ended {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(
                            NSLocalizedString(
                                "Open the app to update the widget",
                                comment: "No comment"
                            )
                        )
                        Spacer()
                    }
                    Spacer()
                }
                .background(.ultraThinMaterial.opacity(0.8))
                .padding(.all, -15)
            }
        }
        .privacySensitive()
        .padding(.all, 15)
        .background(BackgroundStyle.background.opacity(0.4))
        .activityBackgroundTint(Color.clear)
    }

    @ViewBuilder
    private func compactLockScreenView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        let glucoseFormatter = NumberFormatter.glucoseFormatter(
            for: context.state.isMmol
                ? HKUnit.millimolesPerLiter
                : HKUnit.milligramsPerDeciliter
        )
        let unit = context.state.isMmol
            ? HKUnit.millimolesPerLiter.localizedShortUnitString
            : HKUnit.milligramsPerDeciliter.localizedShortUnitString
        
        let glucoseColor = getGlucoseColor(context: context)
        let currentBG = (glucoseFormatter.string(from: context.state.currentGlucose) ?? "??") + getArrowImage(context.state.trendType)
        let eventualBG = formatEventualBG(value: context.state.eventualGlucose, formatter: glucoseFormatter)
        
        HStack(spacing: 10) {
            loopIcon(context, size: 24)
            
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(currentBG)
                        .font(.headline)
                        .foregroundStyle(glucoseColor)
                    Text(context.state.delta + " " + unit)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.7))
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text(eventualBG)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)  // Allow HStack to use full available width
        .privacySensitive()
        .padding(.all, 14)
        .background(Color.clear)
    }
    
    private func formatEventualBG(value: Double?, formatter: NumberFormatter) -> String {
        guard let value = value else {
            return "??"
        }
        
        return formatter.string(from: NSNumber(value: value)) ?? "??"
    }

    // MARK: - Dynamic Island View

    private func dynamicIslandView(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> DynamicIsland {
        let glucoseFormatter = NumberFormatter.glucoseFormatter(
            for: context.state.isMmol
                ? HKUnit.millimolesPerLiter : HKUnit.milligramsPerDeciliter
        )

        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HStack(alignment: .center) {
                    loopIcon(context)
                        .frame(width: 40, height: 40, alignment: .trailing)
                    Spacer()
                    Text(
                        "\(glucoseFormatter.string(from: context.state.currentGlucose) ?? "??")\(getArrowImage(context.state.trendType))"
                    )
                    .foregroundStyle(getGlucoseColor(context: context))
                    .font(.headline)
                    .fontWeight(.heavy)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                HStack {
                    Text(context.state.delta)
                        .foregroundStyle(Color(white: 0.9))
                        .font(.headline)
                    Text(
                        context.state.isMmol
                            ? HKUnit.millimolesPerLiter.localizedShortUnitString
                            : HKUnit.milligramsPerDeciliter
                                .localizedShortUnitString
                    )
                    .foregroundStyle(Color(white: 0.7))
                    .font(.subheadline)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                if context.attributes.addPredictiveLine {
                    ChartView(
                        glucoseSamples: context.state.glucoseSamples,
                        predicatedGlucose: context.state.predicatedGlucose,
                        predicatedStartDate: context.state.predicatedStartDate,
                        predicatedInterval: context.state.predicatedInterval,
                        useLimits: context.attributes.useLimits,
                        lowerLimit: context.state.isMmol
                            ? context.attributes.lowerLimitChartMmol
                            : context.attributes.lowerLimitChartMg,
                        upperLimit: context.state.isMmol
                            ? context.attributes.upperLimitChartMmol
                            : context.attributes.upperLimitChartMg,
                        glucoseRanges: context.state.glucoseRanges,
                        preset: context.state.preset,
                        yAxisMarks: context.state.yAxisMarks
                    )
                    .frame(height: 75)
                } else {
                    ChartView(
                        glucoseSamples: context.state.glucoseSamples,
                        useLimits: context.attributes.useLimits,
                        lowerLimit: context.state.isMmol
                            ? context.attributes.lowerLimitChartMmol
                            : context.attributes.lowerLimitChartMg,
                        upperLimit: context.state.isMmol
                            ? context.attributes.upperLimitChartMmol
                            : context.attributes.upperLimitChartMg,
                        glucoseRanges: context.state.glucoseRanges,
                        preset: context.state.preset,
                        yAxisMarks: context.state.yAxisMarks
                    )
                    .frame(height: 75)
                }
            }
        } compactLeading: {
            Text(
                "\(glucoseFormatter.string(from: context.state.currentGlucose) ?? "??")\(getArrowImage(context.state.trendType))"
            )
            .foregroundStyle(
                getGlucoseColor(context: context)
            )
            .minimumScaleFactor(0.1)
        } compactTrailing: {
            Text(context.state.delta)
                .foregroundStyle(Color(white: 0.9))
                .minimumScaleFactor(0.1)
        } minimal: {
            Text(
                glucoseFormatter.string(from: context.state.currentGlucose)
                    ?? "??"
            )
            .foregroundStyle(
                getGlucoseColor(context: context)
            )
            .minimumScaleFactor(0.1)
        }
    }

    private struct LoopShades {
        let highlight: Color
        let base: Color
        let shadow: Color
        let deepShadow: Color
    }

    private func getLoopShades(_ age: Date?) -> LoopShades {
        var freshness: LoopCompletionFreshness = .stale
        if let age = age {
            freshness = LoopCompletionFreshness(
                age: abs(min(0, age.timeIntervalSinceNow))
            )
        }

        switch freshness {
        case .fresh:
            return LoopShades(
                highlight: Color(red: 178 / 255, green: 236 / 255, blue: 195 / 255),
                base: Self.dashboardLoopFresh,
                shadow: Color(red: 62 / 255, green: 130 / 255, blue: 82 / 255),
                deepShadow: Color(red: 25 / 255, green: 70 / 255, blue: 38 / 255)
            )
        case .aging:
            return LoopShades(
                highlight: Color(red: 255 / 255, green: 220 / 255, blue: 125 / 255),
                base: Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255),
                shadow: Color(red: 180 / 255, green: 95 / 255, blue: 6 / 255),
                deepShadow: Color(red: 115 / 255, green: 50 / 255, blue: 5 / 255)
            )
        case .stale:
            return LoopShades(
                highlight: Color(red: 255 / 255, green: 155 / 255, blue: 155 / 255),
                base: Color(red: 235 / 255, green: 65 / 255, blue: 65 / 255),
                shadow: Color(red: 155 / 255, green: 28 / 255, blue: 28 / 255),
                deepShadow: Color(red: 90 / 255, green: 12 / 255, blue: 12 / 255)
            )
        }
    }

    @ViewBuilder
    private func loopIcon(
        _ context: ActivityViewContext<GlucoseActivityAttributes>,
        size: CGFloat = 36
    ) -> some View {
        let shades = getLoopShades(context.state.lastCompleted)
        let lineWidth = size / 4.5
        let isClosed = context.state.isCloseLoop
        let trimFrom: CGFloat = isClosed ? 0 : 0.2
        let rotation = Angle(degrees: -126)
        let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let spineStyle = StrokeStyle(lineWidth: max(1.0, lineWidth * 0.35), lineCap: .round, lineJoin: .round)

        ZStack {
            // 1. Recessed groove / background track for physical depth
            Circle()
                .trim(from: trimFrom, to: 1)
                .stroke(Color.black.opacity(0.35), style: strokeStyle)
                .rotationEffect(rotation)

            // 2. Volumetric 3D tube with directional lighting gradient (top-left to bottom-right)
            Circle()
                .trim(from: trimFrom, to: 1)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: shades.highlight, location: 0.0),
                            .init(color: shades.base, location: 0.45),
                            .init(color: shades.shadow, location: 1.0)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: strokeStyle
                )
                .rotationEffect(rotation)
                .shadow(color: shades.deepShadow.opacity(0.55), radius: size * 0.06, x: 0, y: size * 0.04)

            // 3. Specular crest highlight along top ridge (gives cylindrical curvature)
            Circle()
                .trim(from: trimFrom, to: 1)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.65), location: 0.0),
                            .init(color: shades.highlight.opacity(0.35), location: 0.35),
                            .init(color: Color.clear, location: 0.75)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: spineStyle
                )
                .rotationEffect(rotation)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func bottomItemGeneric(title: String, value: String, unit: String)
        -> some View
    {
        VStack(alignment: .center) {
            Text("\(value)\(unit)")
                .font(.headline)
                .foregroundStyle(.primary)
                .fontWeight(.heavy)
                .font(Font.body.leading(.tight))
            Text(title)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func bottomItemCurrentBG(
        value: String,
        trend: GlucoseTrend?,
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        VStack(alignment: .center) {
            HStack {
                Text(value + getArrowImage(trend))
                    .font(.title)
                    .foregroundStyle(getGlucoseColor(context: context))
                    .fontWeight(.heavy)
                    .font(Font.body.leading(.tight))
            }
        }
    }

    @ViewBuilder
    private func bottomItemLoopCircle(
        context: ActivityViewContext<GlucoseActivityAttributes>
    ) -> some View {
        VStack(alignment: .center) {
            loopIcon(context)
        }
    }

    @ViewBuilder
    private func bottomSpacer(border: Bool) -> some View {
        Spacer()
        if border {
            Divider()
                .background(.secondary)
            Spacer()
        }

    }

    private func getArrowImage(_ trendType: GlucoseTrend?) -> String {
        switch trendType {
        case .upUpUp:
            return "\u{2191}\u{2191}"  // ↑↑
        case .upUp:
            return "\u{2191}"  // ↑
        case .up:
            return "\u{2197}"  // ↗
        case .flat:
            return "\u{2192}"  // →
        case .down:
            return "\u{2198}"  // ↘
        case .downDown:
            return "\u{2193}"  // ↓
        case .downDownDown:
            return "\u{2193}\u{2193}"  // ↓↓
        case .none:
            return ""
        }
    }

    private func getLoopColor(_ age: Date?) -> Color {
        var freshness: LoopCompletionFreshness = .stale
        if let age = age {
            freshness = LoopCompletionFreshness(
                age: abs(min(0, age.timeIntervalSinceNow))
            )
        }

        switch freshness {
        case .fresh:
            return Self.dashboardLoopFresh
        case .aging:
            return Color("warning")
        case .stale:
            return .red
        }
    }

    private func getGlucoseColor(context: ActivityViewContext<GlucoseActivityAttributes>) -> Color {
        guard context.attributes.useLimits else {
            return .white
        }
        
        let value = context.state.currentGlucose
        if context.state.isMmol
            && value < context.attributes.lowerLimitChartMmol
            || !context.state.isMmol
            && value < context.attributes.lowerLimitChartMg
        {
            return .red
        }

        if context.state.isMmol
            && value > context.attributes.upperLimitChartMmol
            || !context.state.isMmol
            && value > context.attributes.upperLimitChartMg
        {
            return .orange
        }

        return .white
    }

}
