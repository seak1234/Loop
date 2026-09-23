//
//  UIColor.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 1/23/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

// MARK: - Color palette for common elements
extension UIColor {
    @nonobjc public static let carbs = UIColor { _ in
        UIColor(red: 241/255, green: 115/255, blue: 110/255, alpha: 1.0) // Reference coral red (#f1736e)
    }
    
    @nonobjc public static let fresh = UIColor { _ in
        UIColor(red: 16/255, green: 185/255, blue: 129/255, alpha: 1.0) // Emerald status green (#10b981)
    }

    @nonobjc public static let glucose = UIColor { _ in
        UIColor(red: 54/255, green: 175/255, blue: 209/255, alpha: 1.0) // Balanced Ocean glucose blue (#36afd1)
    }
    
    @nonobjc public static let insulin = UIColor { _ in
        UIColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1.0) // Reference amber/orange from HTML (#f59e0b)
    }

    // The loopAccent color is intended to be use as the app accent color.
    @nonobjc public static let loopAccent = UIColor(named: "accent") ?? glucose
    
    @nonobjc public static let warning = UIColor(named: "warning") ?? systemYellow

    // Warm dashboard-only palette inspired by the reference design. These are
    // intentionally separate from the clinical state colors used by Loop.
    @nonobjc public static let dashboardCoral = UIColor { _ in
        UIColor(red: 232 / 255, green: 130 / 255, blue: 136 / 255, alpha: 1.0) // #E88288
    }

    @nonobjc public static let dashboardLoopFresh = UIColor { _ in
        UIColor(red: 116 / 255, green: 184 / 255, blue: 138 / 255, alpha: 1.0) // #74B88A
    }

    @nonobjc public static let dashboardGlucoseAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.72, green: 0.79, blue: 0.96, alpha: 1.0)
            : UIColor(red: 0.46, green: 0.54, blue: 0.78, alpha: 1.0)
    }

    @nonobjc public static let dashboardInsulinAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.70, green: 0.83, blue: 0.72, alpha: 1.0)
            : UIColor(red: 0.43, green: 0.59, blue: 0.48, alpha: 1.0)
    }

    @nonobjc public static let dashboardCarbAccent = dashboardCoral

    @nonobjc public static let dashboardCycleAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.84, green: 0.74, blue: 0.91, alpha: 1.0)
            : UIColor(red: 0.63, green: 0.49, blue: 0.72, alpha: 1.0)
    }

    @nonobjc public static let dashboardPeriodProgress = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.59, green: 0.33, blue: 0.37, alpha: 1.0)
            : UIColor(red: 0.96, green: 0.73, blue: 0.76, alpha: 1.0)
    }

    @nonobjc public static let dashboardFollicularProgress = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.34, green: 0.48, blue: 0.37, alpha: 1.0)
            : UIColor(red: 0.73, green: 0.86, blue: 0.76, alpha: 1.0)
    }

    @nonobjc public static let dashboardOvulationProgress = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.47, blue: 0.26, alpha: 1.0)
            : UIColor(red: 0.95, green: 0.81, blue: 0.56, alpha: 1.0)
    }

    @nonobjc public static let dashboardLutealProgress = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.40, green: 0.46, blue: 0.64, alpha: 1.0)
            : UIColor(red: 0.75, green: 0.79, blue: 0.93, alpha: 1.0)
    }

    @nonobjc public static let dashboardInk = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.94, blue: 0.92, alpha: 1.0)
            : UIColor(red: 0.25, green: 0.14, blue: 0.15, alpha: 1.0)
    }

    @nonobjc public static let dashboardMutedInk = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.82, green: 0.68, blue: 0.66, alpha: 1.0)
            : UIColor(red: 0.52, green: 0.36, blue: 0.37, alpha: 1.0)
    }

    @nonobjc public static let dashboardSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.10, blue: 0.11, alpha: 1.0)
            : UIColor(red: 1.00, green: 0.985, blue: 0.975, alpha: 1.0)
    }

    @nonobjc public static let dashboardBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.055, blue: 0.06, alpha: 1.0)
            : UIColor(red: 0.985, green: 0.93, blue: 0.90, alpha: 1.0)
    }

    @nonobjc public static let dashboardBorder = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor(red: 0.95, green: 0.84, blue: 0.81, alpha: 1.0)
    }
}

// MARK: - Context for colors
extension UIColor {
    @nonobjc public static let agingColor = warning
    
    @nonobjc public static let axisLabelColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 148/255, green: 163/255, blue: 184/255, alpha: 0.85)
            : UIColor(red: 100/255, green: 116/255, blue: 139/255, alpha: 0.85)
    }
    
    @nonobjc public static let axisLineColor = clear
    
    @nonobjc public static let cellBackgroundColor = secondarySystemBackground
    
    @nonobjc public static let carbTintColor = carbs
    
    @nonobjc public static let critical = systemRed
    
    @nonobjc public static let destructive = critical
    
    @nonobjc public static let freshColor = fresh

    @nonobjc public static let glucoseTintColor = glucose
    
    @nonobjc public static let gridColor = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.14)
            : UIColor.black.withAlphaComponent(0.09)
    }
    
    @nonobjc public static let invalid = critical

    @nonobjc public static let insulinTintColor = insulin
    
    @nonobjc public static let pumpStatusNormal = insulin
    
    @nonobjc public static let staleColor = critical
    
    @nonobjc public static let unknownColor = systemGray4
}
