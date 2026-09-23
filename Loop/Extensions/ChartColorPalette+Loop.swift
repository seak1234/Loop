//
//  ChartColorPalette+Loop.swift
//  Loop
//
//  Created by Bharat Mediratta on 4/1/17.
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import LoopUI
import LoopKitUI


extension ChartColorPalette {
    static var primary: ChartColorPalette {
        return ChartColorPalette(axisLine: .axisLineColor, axisLabel: .axisLabelColor, grid: .gridColor, glucoseTint: .glucoseTintColor, insulinTint: .insulinTintColor, carbTint: .carbTintColor)
    }

    static var dashboard: ChartColorPalette {
        return ChartColorPalette(
            axisLine: .clear,
            axisLabel: .dashboardMutedInk,
            grid: UIColor.dashboardBorder.withAlphaComponent(0.65),
            glucoseTint: .dashboardCoral,
            insulinTint: .dashboardCoral,
            carbTint: .dashboardCoral
        )
    }

    static var pastelDashboard: ChartColorPalette {
        return ChartColorPalette(
            axisLine: .clear,
            axisLabel: .dashboardMutedInk,
            grid: UIColor.dashboardBorder.withAlphaComponent(0.65),
            glucoseTint: .dashboardCoral,
            insulinTint: .dashboardInsulinAccent,
            carbTint: .dashboardCarbAccent
        )
    }

    static var carbDetail: ChartColorPalette {
        return ChartColorPalette(
            axisLine: .axisLineColor,
            axisLabel: .axisLabelColor,
            grid: .gridColor,
            glucoseTint: .glucoseTintColor,
            insulinTint: .insulinTintColor,
            carbTint: .dashboardCarbAccent
        )
    }
}
