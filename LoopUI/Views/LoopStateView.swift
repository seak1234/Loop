//
//  LoopStateView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/7/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

final class LoopStateView: UIView {
    var firstDataUpdate = true

    private let trackLayer = CAShapeLayer()
    private let shapeLayer = CAShapeLayer()

    public let elapsedLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .label
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.text = "–"
        return label
    }()

    public var elapsedTime: TimeInterval? {
        didSet {
            updateElapsedDisplay()
        }
    }

    private func updateElapsedDisplay() {
        guard let elapsed = elapsedTime else {
            elapsedLabel.text = "–"
            return
        }
        let totalSeconds = Int(max(0, elapsed))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        elapsedLabel.text = String(format: "%d:%02d", minutes, seconds)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()

        updateTintColor()
    }

    private func updateTintColor() {
        let tint = tintColor ?? .systemGreen
        shapeLayer.strokeColor = tint.cgColor
        elapsedLabel.textColor = tint
        updateTrackColor()
    }

    private func updateTrackColor() {
        let color: UIColor
        if traitCollection.userInterfaceStyle == .dark {
            color = UIColor(red: 38 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1.0)
        } else {
            color = UIColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1.0)
        }
        trackLayer.strokeColor = color.cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTrackColor()
    }

    var open = false {
        didSet {
            if open != oldValue {
                shapeLayer.path = drawPath()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        setupView()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        setupView()
    }

    private func setupView() {
        trackLayer.lineWidth = 3.5
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        shapeLayer.lineWidth = 3.5
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineCap = .round
        layer.addSublayer(shapeLayer)

        addSubview(elapsedLabel)
        updateTintColor()

        trackLayer.path = drawTrackPath()
        shapeLayer.path = drawPath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        trackLayer.frame = bounds
        trackLayer.path = drawTrackPath()

        shapeLayer.frame = bounds
        shapeLayer.path = drawPath()

        elapsedLabel.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    private func drawTrackPath() -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width / 2, bounds.height / 2) - trackLayer.lineWidth / 2

        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 2 * CGFloat.pi,
            clockwise: true
        )

        return path.cgPath
    }

    private func drawPath(lineWidth: CGFloat? = nil) -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let lineWidth = lineWidth ?? shapeLayer.lineWidth
        let radius = min(bounds.width / 2, bounds.height / 2) - lineWidth / 2

        let startAngle = open ? -CGFloat.pi / 4 : 0
        let endAngle = open ? 5 * CGFloat.pi / 4 : 2 * CGFloat.pi

        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )

        return path.cgPath
    }

    private static let AnimationKey = "com.loudnate.Naterade.breatheAnimation"

    var animated: Bool = false {
        didSet {
            if animated != oldValue {
                if animated {
                    let path = CABasicAnimation(keyPath: "path")
                    path.fromValue = shapeLayer.path ?? drawPath()
                    path.toValue = drawPath(lineWidth: 5.5)

                    let width = CABasicAnimation(keyPath: "lineWidth")
                    width.fromValue = shapeLayer.lineWidth
                    width.toValue = 5.0

                    let group = CAAnimationGroup()
                    group.animations = [path, width]
                    group.duration = firstDataUpdate ? 0 : 1
                    group.repeatCount = HUGE
                    group.autoreverses = true
                    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                    shapeLayer.add(group, forKey: type(of: self).AnimationKey)
                } else {
                    shapeLayer.removeAnimation(forKey: type(of: self).AnimationKey)
                }
            }
            firstDataUpdate = false
        }
    }
}
