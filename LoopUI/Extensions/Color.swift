//
//  Color.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import SwiftUI

// MARK: - Color palette for common elements
extension Color {
    public static let carbs = Color(UIColor.carbs)
    
    public static let fresh = Color(UIColor.fresh)

    public static let glucose = Color(UIColor.glucose)
    
    public static let insulin = Color(UIColor.insulin)

    // The loopAccent color is intended to be use as the app accent color.
    public static let loopAccent = Color("accent")
    
    public static let warning = Color("warning")
}


// Color version of the UIColor context colors
extension Color {
    public static let agingColor = warning
    
    public static let axisLabelColor = secondary
    
    public static let axisLineColor = clear
    
    public static let cellBackgroundColor = Color(UIColor.cellBackgroundColor)
    
    public static let carbTintColor = carbs
    
    public static let critical = red
    
    public static let destructive = critical
    
    public static let glucoseTintColor = glucose
    
    public static let gridColor = Color(UIColor.gridColor)

    public static let invalid = critical

    public static let insulinTintColor = insulin
    
    public static let pumpStatusNormal = insulin
    
    public static let staleColor = critical
    
    public static let unknownColor = Color(UIColor.unknownColor)
}

// MARK: - Dashboard Palette
extension Color {
    public static let dashboardCoral = Color(UIColor.dashboardCoral)
    public static let dashboardLoopFresh = Color(UIColor.dashboardLoopFresh)
    public static let dashboardInk = Color(UIColor.dashboardInk)
    public static let dashboardMutedInk = Color(UIColor.dashboardMutedInk)
    public static let dashboardSurface = Color(UIColor.dashboardSurface)
    public static let dashboardBackground = Color(UIColor.dashboardBackground)
    public static let dashboardBorder = Color(UIColor.dashboardBorder)
}
