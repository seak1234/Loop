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
    @nonobjc static let carbs = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 52/255, green: 220/255, blue: 160/255, alpha: 1.0) // Luminous bright emerald
            : UIColor(red: 16/255, green: 185/255, blue: 129/255, alpha: 1.0) // Vibrant emerald
    }
    
    @nonobjc static let fresh = UIColor(named: "fresh") ?? HIGGreenColor()

    @nonobjc static let glucose = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 56/255, green: 217/255, blue: 245/255, alpha: 1.0) // Luminous radiant cyan
            : UIColor(red: 6/255, green: 182/255, blue: 212/255, alpha: 1.0)  // Vibrant sky cyan
    }
    
    @nonobjc static let insulin = UIColor { traitCollection in
        traitCollection.userInterfaceStyle == .dark
            ? UIColor(red: 251/255, green: 176/255, blue: 30/255, alpha: 1.0) // Luminous golden honey amber
            : UIColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1.0)  // Radiant warm amber
    }

    // The loopAccent color is intended to be use as the app accent color.
    @nonobjc public static let loopAccent = UIColor(named: "accent") ?? systemBlue
    
    @nonobjc public static let warning = UIColor(named: "warning") ?? systemYellow
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
