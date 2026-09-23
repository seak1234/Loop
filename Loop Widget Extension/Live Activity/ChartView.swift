//
//  ChartValues.swift
//  Loop Widget Extension
//
//  Created by Bastiaan Verhaar on 25/06/2024.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI
import Charts
import LoopUI

@available(iOS 16.2, *)
struct ChartView: View {
    private let glucoseSampleData: [ChartValues]
    private let predicatedData: [ChartValues]
    private let glucoseRanges: [GlucoseRangeValue]
    private let preset: Preset?
    private let yAxisMarks: [Double]
    private let colorGradient: LinearGradient
    private let currentTime: Date

    private static let colorInRange = Color.dashboardCoral
    private static let colorBelowRange = Color.red
    private static let colorAboveRange = Color.orange
    private static let colorDefault = Color.dashboardCoral

    // Infer chartable increment from yAxisMarks: mmol/L values are always below 40, mg/dL above 54.
    private var chartableIncrement: Double { (yAxisMarks.max() ?? 100) < 40 ? 1.0/25.0 : 1.0 }

    // When min == max the rectangle has zero height and is invisible. Mirror the main app's
    // doubleRangeWithMinimumIncrement logic by expanding by one chartable increment each side.
    private func adjustedRange(min minValue: Double, max maxValue: Double) -> (min: Double, max: Double) {
        guard (maxValue - minValue) < .ulpOfOne else { return (minValue, maxValue) }
        return (minValue - 3 * chartableIncrement, maxValue + 3 * chartableIncrement)
    }

    init(glucoseSamples: [GlucoseSampleAttributes], predicatedGlucose: [Double], predicatedStartDate: Date?, predicatedInterval: TimeInterval?, useLimits: Bool, lowerLimit: Double, upperLimit: Double, glucoseRanges: [GlucoseRangeValue], preset: Preset?, yAxisMarks: [Double]) {
        let sampleData = ChartValues.convert(data: glucoseSamples, useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit)
        self.glucoseSampleData = sampleData
        let latestSampleDate = sampleData.map(\.x).max()
        let now = Date.now
        let current = max(now, latestSampleDate ?? now)
        self.currentTime = current
        
        self.predicatedData = ChartValues.convert(
            data: predicatedGlucose,
            startDate: predicatedStartDate ?? now,
            interval: predicatedInterval ?? .minutes(5),
            useLimits: useLimits,
            lowerLimit: lowerLimit,
            upperLimit: upperLimit
        ).filter { $0.x >= (latestSampleDate ?? current) }

        self.colorGradient = ChartView.getGradient(useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit, lowestValue: predicatedGlucose.min() ?? 1, highestValue: predicatedGlucose.max() ?? 1)
        self.preset = preset
        self.glucoseRanges = glucoseRanges
        self.yAxisMarks = yAxisMarks
    }
    
    init(glucoseSamples: [GlucoseSampleAttributes], useLimits: Bool, lowerLimit: Double, upperLimit: Double, glucoseRanges: [GlucoseRangeValue], preset: Preset?, yAxisMarks: [Double]) {
        let sampleData = ChartValues.convert(data: glucoseSamples, useLimits: useLimits, lowerLimit: lowerLimit, upperLimit: upperLimit)
        self.glucoseSampleData = sampleData
        let latestSampleDate = sampleData.map(\.x).max()
        let now = Date.now
        self.currentTime = max(now, latestSampleDate ?? now)
        self.predicatedData = []
        self.preset = preset
        self.glucoseRanges = glucoseRanges
        self.yAxisMarks = yAxisMarks
        self.colorGradient = LinearGradient(colors: [], startPoint: .bottom, endPoint: .top)
    }

    private static func getGradient(useLimits: Bool, lowerLimit: Double, upperLimit: Double, lowestValue: Double, highestValue: Double) -> LinearGradient {
    
        var stops: [Gradient.Stop] = [Gradient.Stop(color: colorDefault.opacity(0.7), location: 0)]
        if useLimits {
            // For applying a color gradient to line data, the range of the plotted
            // data maps to the space 0 to 1 for setting gradient stops, so normalize:
            // Normalize the transition points to 0-1 space of the plotted range:
            let lowerStop = (lowerLimit - lowestValue) / (highestValue - lowestValue)
            let upperStop = (upperLimit - lowestValue) / (highestValue - lowestValue)
            // Build up a set of stops, only using those in the 0-1 range:
            stops = []
            var stopColor: Color
            // Get the color for glucose at the minimum of the line:
            if lowestValue < lowerLimit {
                stopColor = colorBelowRange.opacity(0.8)
            } else if lowestValue < upperLimit {
                stopColor = colorInRange.opacity(0.7)
            } else {
                stopColor = colorAboveRange.opacity(0.8)
            }
            stops.append(Gradient.Stop(color: stopColor, location: 0))
            // Add the transition stops if they are in the visible range:
            if lowerStop > 0, lowerStop < 1 {
                stops.append(Gradient.Stop(color: colorBelowRange.opacity(0.8), location: lowerStop))
                stops.append(Gradient.Stop(color: colorInRange.opacity(0.7), location: lowerStop + 0.01))
            }
            if upperStop > 0, upperStop < 1 {
                stops.append(Gradient.Stop(color: colorInRange.opacity(0.7), location: upperStop))
                stops.append(Gradient.Stop(color: colorAboveRange.opacity(0.8), location: upperStop + 0.01))
            }
            
        }
        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: .bottom,
            endPoint: .top
        )
    }
    
    var body: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .top)){
            Chart {
                if let preset = self.preset, (preset.minValue > 0 || preset.maxValue > 0), predicatedData.count > 0, preset.endDate > Date.now.addingTimeInterval(.hours(-6)) {
                    let (presetMin, presetMax) = adjustedRange(min: preset.minValue, max: preset.maxValue)
                    RectangleMark(
                        xStart: .value("Start", preset.startDate),
                        xEnd: .value("End", preset.endDate),
                        yStart: .value("Preset override", presetMin),
                        yEnd: .value("Preset override", presetMax)
                    )
                    .foregroundStyle(Color.dashboardCoral)
                    .opacity(0.30)
                }
                
                ForEach(glucoseRanges) { item in
                    let (rangeMin, rangeMax) = adjustedRange(min: item.minValue, max: item.maxValue)
                    RectangleMark(
                        xStart: .value("Start", item.startDate),
                        xEnd: .value("End", item.endDate),
                        yStart: .value("Glucose range", rangeMin),
                        yEnd: .value("Glucose range", rangeMax)
                    )
                    .foregroundStyle(Color.dashboardCoral)
                    .opacity(item.isOverride ? 0.30 : 0.18)
                }

                if !glucoseSampleData.isEmpty || !predicatedData.isEmpty {
                    RuleMark(x: .value("Current Time", currentTime))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color.dashboardMutedInk.opacity(0.65))
                }
                
                ForEach(predicatedData) { item in
                    LineMark (x: .value("Date", item.x),
                              y: .value("Glucose level", item.y)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .foregroundStyle(colorGradient)
                }

                ForEach(glucoseSampleData) { item in
                    PointMark (x: .value("Date", item.x),
                               y: .value("Glucose level", item.y)
                    )
                    .symbolSize(10)
                    .foregroundStyle(by: .value("Color", item.color))
                }

                if let latestSample = glucoseSampleData.last {
                    PointMark (x: .value("Date", latestSample.x),
                               y: .value("Glucose level", latestSample.y)
                    )
                    .symbolSize(18)
                    .foregroundStyle(by: .value("Color", latestSample.color))
                }
            }
            .chartForegroundStyleScale([
                "Good": Self.colorInRange,
                "High": Self.colorAboveRange,
                "Low": Self.colorBelowRange,
                "Default": Self.colorDefault
            ])
            .chartPlotStyle { plotContent in
                plotContent.background(Color.clear)
            }
            .chartLegend(.hidden)
            .chartYScale(domain: [yAxisMarks.first ?? 0, yAxisMarks.last ?? 0])
            .chartYAxis {
                AxisMarks(values: yAxisMarks)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel().foregroundStyle(Color.primary)
                    AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.dashboardBorder.opacity(0.65))
                }
            }
            .chartXAxis {
                AxisMarks(position: .automatic, values: .stride(by: .hour)) { _ in
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .narrow)), anchor: .top)
                        .foregroundStyle(Color.primary)
                    AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.dashboardBorder.opacity(0.65))
                }
            }
            
            if let preset = self.preset, preset.endDate > Date.now {
                Text(preset.title)
                    .font(.footnote)
                    .foregroundStyle(Color.dashboardMutedInk)
                    .padding(.trailing, 5)
                    .padding(.top, 2)
            }
        }
    }
}

struct ChartValues: Identifiable {
    public let id: UUID
    public let x: Date
    public let y: Double
    public let color: String
    
    init(x: Date, y: Double, color: String) {
        self.id = UUID()
        self.x = x
        self.y = y
        self.color = color
    }
    
    static func convert(data: [Double], startDate: Date, interval: TimeInterval, useLimits: Bool, lowerLimit: Double, upperLimit: Double) -> [ChartValues] {
        let cutoff = adjustedChartEnd(startDate.addingTimeInterval(.hours(4)))

        return data.enumerated().filter { (index, item) in
            return startDate.addingTimeInterval(interval * Double(index)) < cutoff
        }.map { (index, item) in
            return ChartValues(
                x: startDate.addingTimeInterval(interval * Double(index)),
                y: item,
                color: "Default" // Color is handled by the gradient
            )
        }
    }

    private static func adjustedChartEnd(_ date: Date) -> Date {
        let minute = Calendar.current.component(.minute, from: date)
        guard minute < 30 else { return date }
        let startOfHour = Calendar.current.dateInterval(of: .hour, for: date)!.start
        return startOfHour.addingTimeInterval(.minutes(30))
    }
    
    static func convert(data: [GlucoseSampleAttributes], useLimits: Bool, lowerLimit: Double, upperLimit: Double) -> [ChartValues] {
        return data.map { item in
            return ChartValues(
                x: item.x,
                y: item.y,
                color: !useLimits ? "Default" : item.y < lowerLimit ? "Low" : item.y > upperLimit ? "High" : "Good"
            )
        }
    }
}
