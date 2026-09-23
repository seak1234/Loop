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
    public static let dashboardGlucoseAccent = Color(UIColor.dashboardGlucoseAccent)
    public static let dashboardInsulinAccent = Color(UIColor.dashboardInsulinAccent)
    public static let dashboardCarbAccent = Color(UIColor.dashboardCarbAccent)
    public static let dashboardInk = Color(UIColor.dashboardInk)
    public static let dashboardMutedInk = Color(UIColor.dashboardMutedInk)
    public static let dashboardSurface = Color(UIColor.dashboardSurface)
    public static let dashboardBackground = Color(UIColor.dashboardBackground)
    public static let dashboardBorder = Color(UIColor.dashboardBorder)
}

public struct DashboardActionButtonStyle: ButtonStyle {
    public var isPrimary: Bool
    public var tintColor: Color

    @Environment(\.isEnabled) private var isEnabled: Bool

    public init(isPrimary: Bool = true, tintColor: Color = .dashboardInsulinAccent) {
        self.isPrimary = isPrimary
        self.tintColor = tintColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).bold())
            .foregroundColor(isPrimary ? .white : tintColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Group {
                    if !isEnabled {
                        Color(UIColor.systemGray4)
                    } else if isPrimary {
                        tintColor
                    } else {
                        tintColor.opacity(0.12)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isPrimary ? Color.clear : tintColor.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    public func dashboardScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
                .background(Color.dashboardBackground)
        } else {
            self.background(Color.dashboardBackground)
        }
    }
}
