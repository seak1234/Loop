//
//  StatusBarHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit
import LoopKitUI

private extension UIFont {
    static func dashboardRounded(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func dashboardRoundedDigits(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }
}

final class DashboardAccentView: UIView {

    private let gradientLayer = CAGradientLayer()

    init(color: UIColor) {
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        gradientLayer.colors = [
            color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(0.95).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        gradientLayer.locations = [0, 0.5, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateColor(_ color: UIColor) {
        gradientLayer.colors = [
            color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(0.95).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }
}

public class StatusBarHUDView: UIView, NibLoadable {
    
    @IBOutlet public weak var cgmStatusHUD: CGMStatusHUDView!
    
    @IBOutlet public weak var loopCompletionHUD: LoopCompletionHUDView!
    
    @IBOutlet public weak var pumpStatusHUD: PumpStatusHUDView!
        
    public var containerView: UIStackView!

    private var usesDashboardCardStyle = false

    private static let dashboardCardOrderKey = "DashboardStatusCardOrder"
    private let defaultDashboardCardOrder = ["loop", "glucose", "pump"]
    private var dashboardCardOrder: [String] = ["loop", "glucose", "pump"]
    private weak var draggedDashboardCard: UIView?
    private var dashboardCardSnapshot: UIView?
    private var dashboardCardDragOffset = CGPoint.zero

    private weak var glucoseTargetLabel: UILabel?

    private weak var loopTitleLabel: UILabel?

    private weak var loopDosingModeLabel: UILabel?

    private weak var pumpExpiresLabel: UILabel?
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                cgmStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                pumpStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                if usesDashboardCardStyle {
                    containerView.spacing = adjustViewsForNarrowDisplay ? 6.0 : 8.0
                    var margins = containerView.directionalLayoutMargins
                    margins.leading = adjustViewsForNarrowDisplay ? 8.0 : 10.0
                    margins.trailing = adjustViewsForNarrowDisplay ? 8.0 : 10.0
                    containerView.directionalLayoutMargins = margins
                } else {
                    containerView.spacing = adjustViewsForNarrowDisplay ? 8.0 : 16.0
                }
            }
        }
    }

    override public var bounds: CGRect {
        didSet {
            // need to adjust for narrow display. The labels in the status bar need more space when the bounds width is less than 350 points.
            adjustViewsForNarrowDisplay = bounds.width < 350
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
    
    func setup() {
        containerView = (StatusBarHUDView.nib().instantiate(withOwner: self, options: nil)[0] as! UIStackView)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(containerView)

        // Use AutoLayout to have the stack view fill its entire container.
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerView.widthAnchor.constraint(equalTo: widthAnchor),
            containerView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        
        self.backgroundColor = UIColor.secondarySystemBackground
    }

    /// Presents the existing status HUDs as three equal dashboard cards. This is
    /// opt-in because `StatusBarHUDView` is also used by the status extension,
    /// where the original compact layout is still preferable.
    public func configureDashboardCardStyle() {
        guard !usesDashboardCardStyle else {
            return
        }

        usesDashboardCardStyle = true

        backgroundColor = .clear
        containerView.axis = .horizontal
        containerView.alignment = .fill
        containerView.distribution = .fillEqually
        containerView.spacing = adjustViewsForNarrowDisplay ? 6 : 8
        containerView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: adjustViewsForNarrowDisplay ? 8 : 10,
            bottom: 6,
            trailing: adjustViewsForNarrowDisplay ? 8 : 10
        )
        containerView.isLayoutMarginsRelativeArrangement = true

        containerView.insertArrangedSubview(loopCompletionHUD, at: 0)
        containerView.insertArrangedSubview(cgmStatusHUD, at: 1)
        containerView.insertArrangedSubview(pumpStatusHUD, at: 2)

        let cards: [(view: BaseHUDView, title: String, accentColor: UIColor)] = [
            (loopCompletionHUD, LocalizedString("Loop Status", comment: "Dashboard loop status card title"), .dashboardCoral),
            (cgmStatusHUD, LocalizedString("Glucose", comment: "Dashboard glucose card title"), .dashboardGlucoseAccent),
            (pumpStatusHUD, LocalizedString("Pump", comment: "Dashboard pump card title"), .dashboardInsulinAccent),
        ]

        for card in cards {
            removeLegacyWidthConstraints(from: card.view)
            movePrimaryContentDown(in: card.view)
            styleCard(card.view, title: card.title, accentColor: card.accentColor)
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleDashboardCardLongPress(_:)))
            recognizer.minimumPressDuration = 0.5
            card.view.addGestureRecognizer(recognizer)
        }

        let savedOrder = UserDefaults.standard.stringArray(forKey: Self.dashboardCardOrderKey) ?? []
        dashboardCardOrder = savedOrder.filter { defaultDashboardCardOrder.contains($0) }
        dashboardCardOrder.append(contentsOf: defaultDashboardCardOrder.filter { !dashboardCardOrder.contains($0) })
        applyDashboardCardOrder()

        cgmStatusHUD.configureForDashboardCard()
        pumpStatusHUD.configureForDashboardCard(normalColor: .dashboardInsulinAccent)
        pumpStatusHUD.basalRateHUD.configureForDashboardCard()
        configureCompactGlucoseTrend()
        configureGlucoseTargetLabel()
        configureLoopDosingModeLabel()
        updateDashboardCardColors()
    }

    private func dashboardCard(for identifier: String) -> UIView? {
        switch identifier {
        case "loop": return loopCompletionHUD
        case "glucose": return cgmStatusHUD
        case "pump": return pumpStatusHUD
        default: return nil
        }
    }

    private func applyDashboardCardOrder() {
        for (index, identifier) in dashboardCardOrder.enumerated() {
            if let card = dashboardCard(for: identifier) {
                containerView.insertArrangedSubview(card, at: index)
            }
        }
    }

    @objc private func handleDashboardCardLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let card = recognizer.view,
              let sourceIdentifier = defaultDashboardCardOrder.first(where: { dashboardCard(for: $0) === card })
        else { return }

        switch recognizer.state {
        case .began:
            guard let snapshot = card.snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = card.convert(card.bounds, to: self)
            snapshot.layer.shadowColor = UIColor.black.cgColor
            snapshot.layer.shadowOpacity = 0.18
            snapshot.layer.shadowRadius = 10
            addSubview(snapshot)
            let touch = recognizer.location(in: self)
            dashboardCardDragOffset = CGPoint(x: snapshot.center.x - touch.x, y: snapshot.center.y - touch.y)
            card.alpha = 0.25
            draggedDashboardCard = card
            dashboardCardSnapshot = snapshot
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            let touch = recognizer.location(in: self)
            dashboardCardSnapshot?.center = CGPoint(x: touch.x + dashboardCardDragOffset.x, y: touch.y + dashboardCardDragOffset.y)
        case .ended:
            if draggedDashboardCard === card,
               let targetIdentifier = dashboardCardOrder.first(where: {
                   guard let target = dashboardCard(for: $0) else { return false }
                   return target.convert(target.bounds, to: self).contains(recognizer.location(in: self))
               }),
               let sourceIndex = dashboardCardOrder.firstIndex(of: sourceIdentifier),
               let targetIndex = dashboardCardOrder.firstIndex(of: targetIdentifier),
               sourceIndex != targetIndex
            {
                dashboardCardOrder.swapAt(sourceIndex, targetIndex)
                applyDashboardCardOrder()
                UserDefaults.standard.set(dashboardCardOrder, forKey: Self.dashboardCardOrderKey)
            }
            fallthrough
        case .cancelled, .failed:
            draggedDashboardCard?.alpha = 1
            dashboardCardSnapshot?.removeFromSuperview()
            draggedDashboardCard = nil
            dashboardCardSnapshot = nil
        default:
            break
        }
    }

    private func removeLegacyWidthConstraints(from view: UIView) {
        let widthConstraints = view.constraints.filter {
            $0.firstAttribute == .width && $0.secondItem == nil
        }
        NSLayoutConstraint.deactivate(widthConstraints)
    }

    private func movePrimaryContentDown(in view: UIView) {
        for constraint in view.constraints where constraint.firstAttribute == .top && constraint.secondItem === view {
            if constraint.constant == 10 {
                constraint.constant = 24
            }
        }
    }

    private func styleCard(_ view: UIView, title: String, accentColor: UIColor) {
        view.backgroundColor = dashboardCardBackgroundColor
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.shadowColor = UIColor.dashboardMutedInk.resolvedColor(with: traitCollection).cgColor
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.layer.shadowRadius = 3
        view.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0 : 0.08
        view.layer.masksToBounds = false

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title.uppercased()
        titleLabel.font = .dashboardRounded(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .dashboardInk
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.isUserInteractionEnabled = false
        titleLabel.accessibilityElementsHidden = true
        view.addSubview(titleLabel)
        let accentView = DashboardAccentView(color: accentColor)
        accentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(accentView)

        if view === loopCompletionHUD {
            loopTitleLabel = titleLabel
        }

        var titleConstraints = [
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
        ]
        if view === cgmStatusHUD {
            let trendLabel = UILabel()
            trendLabel.translatesAutoresizingMaskIntoConstraints = false
            trendLabel.text = "→"
            trendLabel.font = .dashboardRounded(ofSize: 18, weight: .bold)
            trendLabel.textAlignment = .center
            trendLabel.textColor = .dashboardGlucoseAccent
            trendLabel.isUserInteractionEnabled = false
            trendLabel.accessibilityElementsHidden = true
            view.addSubview(trendLabel)
            cgmStatusHUD.configureDashboardTrendLabel(trendLabel)

            titleConstraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trendLabel.leadingAnchor, constant: -4),
                trendLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
                trendLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                trendLabel.widthAnchor.constraint(equalToConstant: 20),
                trendLabel.heightAnchor.constraint(equalToConstant: 20),
            ])
        } else if view === loopCompletionHUD {
            let connectivityPulse = UIView()
            connectivityPulse.translatesAutoresizingMaskIntoConstraints = false
            connectivityPulse.isUserInteractionEnabled = false
            connectivityPulse.accessibilityElementsHidden = true
            connectivityPulse.layer.cornerRadius = 3.5
            connectivityPulse.alpha = 0

            let connectivityDot = UIView()
            connectivityDot.translatesAutoresizingMaskIntoConstraints = false
            connectivityDot.isUserInteractionEnabled = false
            connectivityDot.accessibilityElementsHidden = true
            connectivityDot.layer.cornerRadius = 3.5
            connectivityDot.layer.shadowOpacity = 0.32
            connectivityDot.layer.shadowRadius = 2.5
            connectivityDot.layer.shadowOffset = .zero
            view.addSubview(connectivityPulse)
            view.addSubview(connectivityDot)
            loopCompletionHUD.configureDashboardConnectivityDot(connectivityDot, pulse: connectivityPulse)

            titleConstraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: connectivityDot.leadingAnchor, constant: -4),
                connectivityPulse.centerXAnchor.constraint(equalTo: connectivityDot.centerXAnchor),
                connectivityPulse.centerYAnchor.constraint(equalTo: connectivityDot.centerYAnchor),
                connectivityPulse.widthAnchor.constraint(equalTo: connectivityDot.widthAnchor),
                connectivityPulse.heightAnchor.constraint(equalTo: connectivityDot.heightAnchor),
                connectivityDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                connectivityDot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                connectivityDot.widthAnchor.constraint(equalToConstant: 7),
                connectivityDot.heightAnchor.constraint(equalToConstant: 7),
            ])
        } else if view === pumpStatusHUD {
            let expiresLabel = UILabel()
            expiresLabel.translatesAutoresizingMaskIntoConstraints = false
            expiresLabel.font = .dashboardRoundedDigits(ofSize: 9, weight: .semibold)
            expiresLabel.textColor = .dashboardMutedInk
            expiresLabel.textAlignment = .right
            expiresLabel.adjustsFontSizeToFitWidth = true
            expiresLabel.minimumScaleFactor = 0.75
            expiresLabel.setContentHuggingPriority(.required, for: .horizontal)
            expiresLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.addSubview(expiresLabel)
            pumpExpiresLabel = expiresLabel

            titleConstraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: expiresLabel.leadingAnchor, constant: -4),
                expiresLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                expiresLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            ])
        } else {
            titleConstraints.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -7))
        }
        NSLayoutConstraint.activate(titleConstraints + [
            accentView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            accentView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            accentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            accentView.heightAnchor.constraint(equalToConstant: 2.5),
        ])
    }

    private var dashboardCardBackgroundColor: UIColor {
        return .dashboardSurface
    }

    private func configureCompactGlucoseTrend() {
        guard let glucoseValueHUD = cgmStatusHUD.glucoseValueHUD,
              let glucoseLabel = glucoseValueHUD.glucoseLabel,
              let unitLabel = glucoseValueHUD.unitLabel,
              let trendView = cgmStatusHUD.glucoseTrendHUD
        else {
            return
        }

        glucoseLabel.font = .dashboardRoundedDigits(ofSize: 34, weight: .bold)
        glucoseLabel.textColor = .dashboardInk
        glucoseLabel.textAlignment = .center
        glucoseLabel.adjustsFontSizeToFitWidth = true
        glucoseLabel.minimumScaleFactor = 0.7

        unitLabel.font = .dashboardRounded(ofSize: 11, weight: .semibold)
        unitLabel.textColor = .dashboardMutedInk
        unitLabel.textAlignment = .left
        unitLabel.adjustsFontSizeToFitWidth = true
        unitLabel.minimumScaleFactor = 0.75

        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        glucoseLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let unitConstraints = glucoseValueHUD.constraints.filter {
            $0.firstItem === unitLabel || $0.secondItem === unitLabel
        }
        let glucoseHorizontalConstraints = glucoseValueHUD.constraints.filter {
            guard $0.firstItem === glucoseLabel || $0.secondItem === glucoseLabel else {
                return false
            }
            return [.leading, .trailing, .leadingMargin, .trailingMargin, .left, .right].contains($0.firstAttribute) ||
                   [.leading, .trailing, .leadingMargin, .trailingMargin, .left, .right].contains($0.secondAttribute)
        }
        NSLayoutConstraint.deactivate(unitConstraints + glucoseHorizontalConstraints)

        let stackHorizontalConstraints = cgmStatusHUD.constraints.filter {
            guard $0.firstItem === cgmStatusHUD.statusStackView || $0.secondItem === cgmStatusHUD.statusStackView else {
                return false
            }
            return [.leading, .trailing, .leadingMargin, .trailingMargin, .left, .right].contains($0.firstAttribute) ||
                   [.leading, .trailing, .leadingMargin, .trailingMargin, .left, .right].contains($0.secondAttribute)
        }
        NSLayoutConstraint.deactivate(stackHorizontalConstraints)

        NSLayoutConstraint.activate([
            cgmStatusHUD.statusStackView.centerXAnchor.constraint(equalTo: cgmStatusHUD.centerXAnchor),
            cgmStatusHUD.statusStackView.leadingAnchor.constraint(greaterThanOrEqualTo: cgmStatusHUD.leadingAnchor, constant: 6),
            cgmStatusHUD.statusStackView.trailingAnchor.constraint(lessThanOrEqualTo: cgmStatusHUD.trailingAnchor, constant: -6),

            glucoseValueHUD.leadingAnchor.constraint(equalTo: glucoseLabel.leadingAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: glucoseLabel.trailingAnchor, constant: 3),
            unitLabel.trailingAnchor.constraint(equalTo: glucoseValueHUD.trailingAnchor),
            unitLabel.lastBaselineAnchor.constraint(equalTo: glucoseLabel.lastBaselineAnchor),
        ])

        // Drop the value row slightly below the header, matching the reference card.
        for constraint in glucoseValueHUD.constraints where
            constraint.firstItem === glucoseLabel &&
            constraint.firstAttribute == .top &&
            constraint.secondItem === glucoseValueHUD
        {
            constraint.constant = 0
        }

        for constraint in trendView.constraints {
            if constraint.secondItem == nil,
               constraint.constant == 34,
               constraint.firstAttribute == .width || constraint.firstAttribute == .height
            {
                constraint.constant = 22
            }
        }

        for imageView in trendView.subviews.compactMap({ $0 as? UIImageView }) {
            for constraint in imageView.constraints where constraint.secondItem == nil && constraint.constant == 34 {
                constraint.constant = 22
            }
        }
    }

    private func configureGlucoseTargetLabel() {
        let targetLabel = UILabel()
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.font = .dashboardRoundedDigits(ofSize: 9, weight: .medium)
        targetLabel.textAlignment = .center
        targetLabel.adjustsFontSizeToFitWidth = true
        targetLabel.minimumScaleFactor = 0.7
        targetLabel.isUserInteractionEnabled = false
        targetLabel.accessibilityElementsHidden = true
        cgmStatusHUD.addSubview(targetLabel)
        glucoseTargetLabel = targetLabel
        cgmStatusHUD.configureDashboardTargetLabel(targetLabel)

        for constraint in cgmStatusHUD.constraints {
            if constraint.firstAttribute == .bottom,
               constraint.secondItem === cgmStatusHUD.statusStackView,
               constraint.constant == 20
            {
                constraint.constant = 24
            } else if constraint.firstAttribute == .bottom,
                       constraint.secondItem is UIProgressView,
                       constraint.constant == 8
            {
                constraint.constant = 3
            }
        }

        NSLayoutConstraint.activate([
            targetLabel.topAnchor.constraint(equalTo: cgmStatusHUD.statusStackView.bottomAnchor, constant: 3),
            targetLabel.leadingAnchor.constraint(equalTo: cgmStatusHUD.leadingAnchor, constant: 6),
            targetLabel.trailingAnchor.constraint(equalTo: cgmStatusHUD.trailingAnchor, constant: -6),
            targetLabel.bottomAnchor.constraint(lessThanOrEqualTo: cgmStatusHUD.bottomAnchor, constant: -7),
            targetLabel.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    public func setGlucoseTargetRangeText(_ targetRangeText: String?) {
        guard let targetRangeText = targetRangeText, !targetRangeText.isEmpty else {
            glucoseTargetLabel?.attributedText = nil
            glucoseTargetLabel?.isHidden = true
            return
        }

        let fullText = String(
            format: LocalizedString("Target: %@", comment: "Format for the current glucose target range shown on the dashboard card"),
            targetRangeText
        )
        let attributedText = NSMutableAttributedString(
            string: fullText,
            attributes: [.foregroundColor: UIColor.dashboardMutedInk]
        )
        if let range = fullText.range(of: targetRangeText) {
            attributedText.addAttribute(
                .foregroundColor,
                value: UIColor.dashboardGlucoseAccent,
                range: NSRange(range, in: fullText)
            )
        }
        glucoseTargetLabel?.attributedText = attributedText
        glucoseTargetLabel?.isHidden = cgmStatusHUD.isStatusHighlightActive
    }

    private func configureLoopDosingModeLabel() {
        let dosingModeLabel = UILabel()
        dosingModeLabel.translatesAutoresizingMaskIntoConstraints = false
        dosingModeLabel.font = .dashboardRounded(ofSize: 9, weight: .medium)
        dosingModeLabel.textAlignment = .center
        dosingModeLabel.textColor = .dashboardMutedInk
        dosingModeLabel.adjustsFontSizeToFitWidth = true
        dosingModeLabel.minimumScaleFactor = 0.7
        dosingModeLabel.isUserInteractionEnabled = false
        dosingModeLabel.accessibilityElementsHidden = true
        loopCompletionHUD.addSubview(dosingModeLabel)
        loopDosingModeLabel = dosingModeLabel

        let loopStateView = loopCompletionHUD.subviews.first { $0 is LoopStateView }

        var constraints = [
            dosingModeLabel.leadingAnchor.constraint(equalTo: loopCompletionHUD.leadingAnchor, constant: 6),
            dosingModeLabel.trailingAnchor.constraint(equalTo: loopCompletionHUD.trailingAnchor, constant: -6),
            dosingModeLabel.bottomAnchor.constraint(equalTo: loopCompletionHUD.bottomAnchor, constant: -7),
            dosingModeLabel.heightAnchor.constraint(equalToConstant: 12),
        ]
        if let loopStateView = loopStateView {
            constraints.append(dosingModeLabel.topAnchor.constraint(greaterThanOrEqualTo: loopStateView.bottomAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    public func setLoopStatus(isClosedLoop: Bool, automaticDosingStrategy: AutomaticDosingStrategy) {
        loopTitleLabel?.text = isClosedLoop
            ? LocalizedString("Loop On", comment: "Dashboard title when closed loop is enabled").uppercased()
            : LocalizedString("Loop Off", comment: "Dashboard title when closed loop is disabled").uppercased()

        let dosingMode: String
        if !isClosedLoop {
            dosingMode = LocalizedString("Manual Basal", comment: "Dashboard dosing mode when closed loop is disabled")
        } else {
            switch automaticDosingStrategy {
            case .automaticBolus:
                dosingMode = LocalizedString("Automatic Bolus", comment: "Dashboard automatic bolus dosing mode")
            case .tempBasalOnly:
                dosingMode = LocalizedString("Automatic Basal", comment: "Dashboard automatic basal dosing mode")
            }
        }
        loopDosingModeLabel?.text = dosingMode
    }

    public func setPumpExpiration(remaining: TimeInterval?) {
        guard let remaining = remaining else {
            pumpExpiresLabel?.text = nil
            pumpExpiresLabel?.isHidden = true
            return
        }

        if remaining <= 0 {
            pumpExpiresLabel?.text = LocalizedString("Expired", comment: "Pump expiration badge when expired").uppercased()
            pumpExpiresLabel?.textColor = .systemRed
        } else if remaining < .hours(24) {
            let totalSeconds = Int(remaining)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            pumpExpiresLabel?.text = "\(hours)h \(minutes)m"
            pumpExpiresLabel?.textColor = .systemOrange
        } else {
            let totalSeconds = Int(remaining)
            let days = totalSeconds / 86400
            let hours = (totalSeconds % 86400) / 3600
            pumpExpiresLabel?.text = "\(days)d \(hours)h"
            pumpExpiresLabel?.textColor = .dashboardMutedInk
        }
        pumpExpiresLabel?.isHidden = false
    }

    public func setPumpExpiration(date: Date?) {
        guard let date = date else {
            setPumpExpiration(remaining: nil)
            return
        }
        setPumpExpiration(remaining: date.timeIntervalSinceNow)
    }

    private func updateDashboardCardColors() {
        guard usesDashboardCardStyle else {
            return
        }

        let borderColor = UIColor.dashboardBorder.resolvedColor(with: traitCollection)

        for card in [loopCompletionHUD, cgmStatusHUD, pumpStatusHUD] {
            card?.backgroundColor = dashboardCardBackgroundColor
            card?.layer.borderColor = borderColor.cgColor
            card?.layer.shadowColor = UIColor.dashboardMutedInk.resolvedColor(with: traitCollection).cgColor
            card?.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0 : 0.08
        }
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDashboardCardColors()
    }
        
    public func removePumpManagerProvidedView() {
        pumpStatusHUD.removePumpManagerProvidedHUD()
    }
    
    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        pumpStatusHUD.addPumpManagerProvidedHUDView(pumpManagerProvidedHUD)
    }
}
