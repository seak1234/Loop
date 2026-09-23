//
//  PredictionInputEffectTableViewCell.swift
//  Loop
//
//  Created by Nate Racklyeft on 9/4/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit

private extension UIFont {
    static func predictionInputRounded(
        ofSize size: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}

class PredictionInputEffectTableViewCell: UITableViewCell {

    @IBOutlet weak var titleLabel: UILabel!

    @IBOutlet weak var subtitleLabel: UILabel!

    override func awakeFromNib() {
        super.awakeFromNib()
        applyDashboardAppearance()
    }

    func applyDashboardAppearance() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        tintColor = .dashboardGlucoseAccent

        let cardView = backgroundView ?? UIView()
        cardView.backgroundColor = .dashboardSurface
        cardView.layer.cornerRadius = 14
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = UIColor.dashboardBorder.resolvedColor(with: traitCollection).cgColor
        backgroundView = cardView

        let selectedCardView = selectedBackgroundView ?? UIView()
        selectedCardView.backgroundColor = UIColor.dashboardGlucoseAccent.withAlphaComponent(0.14)
        selectedCardView.layer.cornerRadius = 14
        selectedCardView.layer.cornerCurve = .continuous
        selectedBackgroundView = selectedCardView

        titleLabel.font = .predictionInputRounded(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .dashboardInk
        subtitleLabel.font = .predictionInputRounded(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .dashboardMutedInk
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        contentView.layoutMargins.left = 30
        contentView.layoutMargins.right = 30
        let cardFrame = bounds.inset(by: UIEdgeInsets(top: 4, left: 14, bottom: 4, right: 14))
        backgroundView?.frame = cardFrame
        selectedBackgroundView?.frame = cardFrame
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else {
            return
        }

        applyDashboardAppearance()
    }

    var enabled: Bool = true {
        didSet {
            if enabled {
                titleLabel.textColor = .dashboardInk
                subtitleLabel.textColor = .dashboardMutedInk
            } else {
                titleLabel.textColor = UIColor.secondaryLabel
                subtitleLabel.textColor = UIColor.secondaryLabel
            }
        }
    }

}
