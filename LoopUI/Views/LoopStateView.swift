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

    public let elapsedLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .label
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
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
        shapeLayer.strokeColor = tintColor.cgColor
        elapsedLabel.textColor = tintColor
    }

    var open = false {
        didSet {
            if open != oldValue {
                shapeLayer.path = drawPath()
            }
        }
    }

    override class var layerClass : AnyClass {
        return CAShapeLayer.self
    }

    private var shapeLayer: CAShapeLayer {
        return layer as! CAShapeLayer
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
        shapeLayer.lineWidth = 6.5
        shapeLayer.fillColor = UIColor.clear.cgColor
        addSubview(elapsedLabel)
        updateTintColor()

        shapeLayer.path = drawPath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        shapeLayer.path = drawPath()
        elapsedLabel.frame = bounds.insetBy(dx: 6, dy: 6)
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
                    path.toValue = drawPath(lineWidth: 13)

                    let width = CABasicAnimation(keyPath: "lineWidth")
                    width.fromValue = shapeLayer.lineWidth
                    width.toValue = 8.5

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

