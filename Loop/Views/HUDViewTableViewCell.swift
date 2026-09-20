//
//  HUDViewTableViewCell.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopUI

class HUDViewTableViewCell: UITableViewCell {

    @IBOutlet var hudView: StatusBarHUDView!

    override func awakeFromNib() {
        super.awakeFromNib()

        hudView.configureDashboardCardStyle()
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

}
