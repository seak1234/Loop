//
//  CGMStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class CGMStatusHUDView: DeviceStatusHUDView, NibLoadable {
    
    private var viewModel: CGMStatusHUDViewModel!
    
    @IBOutlet public weak var glucoseValueHUD: GlucoseValueHUDView!
    
    @IBOutlet public weak var glucoseTrendHUD: GlucoseTrendHUDView!

    private weak var dashboardTrendLabel: UILabel?
    private weak var dashboardTargetLabel: UILabel?
    private(set) var usesDashboardCardStyle = false
    public private(set) var isStatusHighlightActive: Bool = false
    private var statusHighlightConstraints: [NSLayoutConstraint] = []
    
    override public var orderPriority: HUDViewOrderPriority {
        return 1
    }
    
    public var isVisible: Bool {
        get {
            viewModel.isVisible
        }
        set {
            if viewModel.isVisible != newValue {
                viewModel.isVisible = newValue
            }
        }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.right)
        viewModel = CGMStatusHUDViewModel(staleGlucoseValueHandler: { [weak self] in
            self?.updateDisplay()
        })
    }

    override func configureForDashboardCard() {
        super.configureForDashboardCard()
        usesDashboardCardStyle = true
    }
    
    override public func tintColorDidChange() {
        super.tintColorDidChange()
        
        glucoseValueHUD.tintColor = dashboardGlucoseValueTint(for: viewModel.glucoseValueTintColor)
        glucoseTrendHUD.tintColor = dashboardTint(for: viewModel.glucoseTrendTintColor)
    }

    override public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        viewModel.statusHighlight = statusHighlight
        super.presentStatusHighlight(viewModel.statusHighlight)
    }
    
    override func presentStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }

        guard usesDashboardCardStyle else {
            guard statusStackView.arrangedSubviews.contains(glucoseValueHUD),
                statusStackView.arrangedSubviews.contains(glucoseTrendHUD) else
            {
                return
            }
            
            // need to also hide these view, since they will be added back to the stack at some point
            glucoseValueHUD.isHidden = true
            glucoseTrendHUD.isHidden = true
            statusStackView.removeArrangedSubview(glucoseValueHUD)
            statusStackView.removeArrangedSubview(glucoseTrendHUD)
            
            super.presentStatusHighlight()
            return
        }

        if statusStackView.arrangedSubviews.contains(glucoseValueHUD) {
            glucoseValueHUD.isHidden = true
            statusStackView.removeArrangedSubview(glucoseValueHUD)
        }
        if statusStackView.arrangedSubviews.contains(glucoseTrendHUD) {
            glucoseTrendHUD.isHidden = true
            statusStackView.removeArrangedSubview(glucoseTrendHUD)
        }
        statusStackView.isHidden = true
        dashboardTargetLabel?.isHidden = true

        presentCenteredStatusHighlight()
    }
    
    override public func dismissStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }

        guard usesDashboardCardStyle else {
            guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
                return
            }

            super.dismissStatusHighlight()
            
            statusStackView.addArrangedSubview(glucoseValueHUD)
            statusStackView.addArrangedSubview(glucoseTrendHUD)
            glucoseValueHUD.isHidden = false
            glucoseTrendHUD.isHidden = dashboardTrendLabel != nil
            return
        }

        guard isStatusHighlightActive else {
            return
        }

        dismissCenteredStatusHighlight()

        statusStackView.isHidden = false
        if !statusStackView.arrangedSubviews.contains(glucoseValueHUD) {
            statusStackView.addArrangedSubview(glucoseValueHUD)
        }
        if !statusStackView.arrangedSubviews.contains(glucoseTrendHUD) {
            statusStackView.addArrangedSubview(glucoseTrendHUD)
        }
        glucoseValueHUD.isHidden = false
        glucoseTrendHUD.isHidden = dashboardTrendLabel != nil
        dashboardTargetLabel?.isHidden = dashboardTargetLabel?.attributedText == nil
    }

    private func presentCenteredStatusHighlight() {
        isStatusHighlightActive = true

        if statusHighlightView.superview !== self {
            statusHighlightView.removeFromSuperview()
            addSubview(statusHighlightView)
        }
        statusHighlightView.translatesAutoresizingMaskIntoConstraints = false
        statusHighlightView.isHidden = false

        if statusHighlightConstraints.isEmpty {
            statusHighlightConstraints = [
                statusHighlightView.centerXAnchor.constraint(equalTo: centerXAnchor),
                statusHighlightView.centerYAnchor.constraint(equalTo: centerYAnchor),
                statusHighlightView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
                statusHighlightView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                statusHighlightView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
                statusHighlightView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            ]
            NSLayoutConstraint.activate(statusHighlightConstraints)
        }
    }

    private func dismissCenteredStatusHighlight() {
        isStatusHighlightActive = false
        statusHighlightView.isHidden = true
        NSLayoutConstraint.deactivate(statusHighlightConstraints)
        statusHighlightConstraints.removeAll()
        statusHighlightView.removeFromSuperview()
    }
        
    public func setGlucoseQuantity(_ glucoseQuantity: Double,
                                   at glucoseStartDate: Date,
                                   unit: HKUnit,
                                   staleGlucoseAge: TimeInterval,
                                   glucoseDisplay: GlucoseDisplayable?,
                                   wasUserEntered: Bool,
                                   isDisplayOnly: Bool)
    {
        viewModel.setGlucoseQuantity(glucoseQuantity,
                                     at: glucoseStartDate,
                                     unit: unit,
                                     staleGlucoseAge: staleGlucoseAge,
                                     glucoseDisplay: glucoseDisplay,
                                     wasUserEntered: wasUserEntered,
                                     isDisplayOnly: isDisplayOnly)
        
        updateDisplay()
    }

    func updateDisplay() {
        glucoseValueHUD.glucoseLabel.text = viewModel.glucoseValueString
        glucoseValueHUD.unitLabel.text = viewModel.unitsString
        glucoseValueHUD.tintColor = dashboardGlucoseValueTint(for: viewModel.glucoseValueTintColor)
        presentStatusHighlight(viewModel.statusHighlight)
        
        accessibilityValue = viewModel.accessibilityString
    }
    
    func updateTrendIcon() {
        glucoseTrendHUD.setIcon(viewModel.glucoseTrendIcon)
        glucoseTrendHUD.tintColor = dashboardTint(for: viewModel.glucoseTrendTintColor)

        let trend = viewModel.trend
        dashboardTrendLabel?.text = trend?.dashboardArrowText ?? "→"
        dashboardTrendLabel?.textColor = .dashboardCoral
        dashboardTrendLabel?.alpha = trend == nil ? 0.75 : 1
        dashboardTrendLabel?.isHidden = false
    }

    func configureDashboardTrendLabel(_ label: UILabel) {
        dashboardTrendLabel = label
        glucoseTrendHUD.isHidden = true
        updateTrendIcon()
    }

    func configureDashboardTargetLabel(_ label: UILabel) {
        dashboardTargetLabel = label
        if isStatusHighlightActive {
            dashboardTargetLabel?.isHidden = true
        }
    }

    private func dashboardTint(for color: UIColor) -> UIColor {
        let resolvedColor = color.resolvedColor(with: traitCollection)
        let resolvedDefault = UIColor.glucoseTintColor.resolvedColor(with: traitCollection)
        guard usesDashboardCardStyle, resolvedColor.isEqual(resolvedDefault) else {
            return color
        }
        return .dashboardCoral
    }

    private func dashboardGlucoseValueTint(for color: UIColor) -> UIColor {
        guard usesDashboardCardStyle else { return color }

        let resolvedColor = color.resolvedColor(with: traitCollection)
        let normalColor = UIColor.glucoseTintColor.resolvedColor(with: traitCollection)
        let defaultColor = UIColor.label.resolvedColor(with: traitCollection)
        if resolvedColor.isEqual(normalColor) || resolvedColor.isEqual(defaultColor) {
            return .dashboardInk
        }
        return color
    }
}

private extension GlucoseTrend {
    var dashboardArrowText: String {
        switch self {
        case .upUpUp, .upUp:
            return "↑"
        case .up:
            return "↗"
        case .flat:
            return "→"
        case .down:
            return "↘"
        case .downDown, .downDownDown:
            return "↓"
        }
    }
}
