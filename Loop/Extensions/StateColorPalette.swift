//
//  StateColorPalette.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import LoopUI
import LoopKitUI

extension StateColorPalette {
    static let loopStatus = StateColorPalette(unknown: .unknownColor, normal: .freshColor, warning: .agingColor, error: .staleColor)

    static let dashboardLoopStatus = StateColorPalette(unknown: .unknownColor, normal: .dashboardLoopFresh, warning: .agingColor, error: .staleColor)

    static let cgmStatus = loopStatus

    static let pumpStatus = StateColorPalette(unknown: .unknownColor, normal: .pumpStatusNormal, warning: .agingColor, error: .staleColor)

    static let dashboardPumpStatus = StateColorPalette(unknown: .unknownColor, normal: .dashboardInsulinAccent, warning: .agingColor, error: .staleColor)
}
