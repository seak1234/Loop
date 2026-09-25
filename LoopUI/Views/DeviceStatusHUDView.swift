//
//  DeviceStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

@objc open class DeviceStatusHUDView: BaseHUDView {

    private var dashboardNormalColor: UIColor?
    
    var statusHighlightView: StatusHighlightHUDView! {
        didSet {
            statusHighlightView.isHidden = true
        }
    }
    
    @IBOutlet private var statusBadgeView: StatusBadgeHUDView! {
        didSet {
            statusBadgeView.isHidden = true
        }
    }
    
    @IBOutlet public private(set) weak var progressView: UIProgressView! {
        didSet {
            progressView.isHidden = true
            progressView.tintColor = .systemGray
            // round the edges of the progress view
            progressView.layer.cornerRadius = 2
            progressView.clipsToBounds = true
            progressView.layer.sublayers!.last!.cornerRadius = 2
            progressView.subviews.last!.clipsToBounds = true
        }
    }
    
    @IBOutlet private weak var backgroundView: UIView! {
        didSet {
            backgroundView.backgroundColor = .systemBackground
            backgroundView.layer.cornerRadius = 23
        }
    }
    
    @IBOutlet weak var statusStackView: UIStackView!
    
    public var lifecycleProgress: DeviceLifecycleProgress? {
        didSet {
            guard let lifecycleProgress = lifecycleProgress else {
                resetProgress()
                return
            }
             
            progressView.isHidden = false
            progressView.progress = Float(lifecycleProgress.percentComplete.clamped(to: 0...1))
            progressView.tintColor = color(for: lifecycleProgress.progressState)
        }
    }
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 26),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 26),
                ])
            } else {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 34),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 34),
                ])
            }
        }
    }
    
    private func resetProgress() {
        progressView.isHidden = true
        progressView.progress = 0
    }
    
    func setup() {
        if statusHighlightView == nil {
            statusHighlightView = StatusHighlightHUDView(frame: self.frame)
        }
    }

    func configureForDashboardCard() {
        configureForDashboardCard(normalColor: nil)
    }

    func configureForDashboardCard(normalColor: UIColor?) {
        dashboardNormalColor = normalColor
        backgroundView.backgroundColor = .clear
        backgroundView.layer.cornerRadius = 0

        progressView?.layer.cornerRadius = 1.5
        progressView?.clipsToBounds = true
        progressView?.layer.sublayers?.forEach { $0.cornerRadius = 1.5 }
        progressView?.subviews.forEach { $0.clipsToBounds = true }
        progressView?.trackTintColor = UIColor.dashboardBorder.withAlphaComponent(0.5)

        if let lifecycleProgress = lifecycleProgress {
            progressView.tintColor = color(for: lifecycleProgress.progressState)
        }
    }
    
    public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        guard let statusHighlight = statusHighlight else {
            dismissStatusHighlight()
            return
        }
        
        presentStatusHighlight(withMessage: statusHighlight.localizedMessage,
                               image: statusHighlight.image,
                               color: color(for: statusHighlight.state))
    }
    
    private func presentStatusHighlight(withMessage message: String,
                                       image: UIImage?,
                                       color: UIColor)
    {
        statusHighlightView.messageLabel.text = message
        statusHighlightView.messageLabel.tintColor = .label
        statusHighlightView.icon.image = image
        statusHighlightView.icon.tintColor = color
        presentStatusHighlight()
    }
    
    func presentStatusHighlight() {
        statusStackView?.addArrangedSubview(statusHighlightView)
        statusHighlightView.isHidden = false
    }
    
    func dismissStatusHighlight() {
        // need to also hide this view, since it will be added back to the stack at some point
        statusHighlightView.isHidden = true
        statusStackView?.removeArrangedSubview(statusHighlightView)
    }
    
    public func presentStatusBadge(_ statusBadge: DeviceStatusBadge?) {
        guard let statusBadge = statusBadge else {
            dismissStatusBadge()
            return
        }
        
        presentStatusBadge(withIcon: statusBadge.image,
                           color: color(for: statusBadge.state))
    }
    
    private func presentStatusBadge(withIcon badgeIcon: UIImage?,
                                    color: UIColor) {
        statusBadgeView.setBadgeIcon(badgeIcon)
        statusBadgeView.tintColor = color
        presentStatusBadge()
    }
    
    private func presentStatusBadge() {
        statusBadgeView.isHidden = false
    }
    
    private func dismissStatusBadge() {
        statusBadgeView.isHidden = true
    }

    private func color(for state: DeviceStatusElementState) -> UIColor {
        guard let dashboardNormalColor = dashboardNormalColor else {
            return state.color
        }

        switch state {
        case .normalCGM, .normalPump:
            return dashboardNormalColor
        case .warning, .critical:
            return state.color
        }
    }

    private func color(for state: DeviceLifecycleProgressState) -> UIColor {
        guard let dashboardNormalColor = dashboardNormalColor else {
            return state.color
        }

        switch state {
        case .normalCGM, .normalPump:
            return dashboardNormalColor
        case .critical, .dimmed, .warning:
            return state.color
        }
    }
}
