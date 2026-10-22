import UIKit

/// Build the diagram once. Incoming history only changes its values and fills.
final class GlucoseStatisticsTableViewCell: UITableViewCell {
    struct Summary: Equatable {
        let days: Int
        let inRange: String
        let belowRange: String
        let aboveRange: String
        let lowerBoundary: String
        let upperBoundary: String
        let glucoseFractions: [Double]?
        let averageGlucose: String
        let gmi: String
        let estimatedA1c: String
        let estimatesNote: String
        let insulinDailyAverage: String
        let basal: String
        let bolus: String
        let insulinFractions: [Double]?
        let insulinNote: String
        let status: String
    }

    var onSelectDays: ((Int) -> Void)?
    private let stack = UIStackView()
    private let card = UIView()
    private var dayButtons: [UIButton] = []
    private let hero = UIStackView()
    private let percentage = UILabel()
    private let glucoseLegend = UIStackView()
    private let below = StatisticsLegendItem(title: "Below", color: .dashboardGlucoseBelowRange, showsDetail: true)
    private let inside = StatisticsLegendItem(title: "In range", color: .dashboardGlucoseInRange, showsDetail: true)
    private let above = StatisticsLegendItem(title: "Above", color: .dashboardGlucoseAboveRange, showsDetail: true)
    private let basal = StatisticsLegendItem(title: "Basal", color: .systemIndigo)
    private let bolus = StatisticsLegendItem(title: "Bolus", color: .dashboardInsulinAccent)
    private let glucoseBar = GlucoseStatisticsBarView(colors: [.dashboardGlucoseBelowRange, .dashboardGlucoseInRange, .dashboardGlucoseAboveRange])
    private let insulinBar = GlucoseStatisticsBarView(colors: [.systemIndigo, .dashboardInsulinAccent], height: 16)
    private let averageValue = UILabel()
    private let gmiValue = UILabel()
    private let estimatedA1cValue = UILabel()
    private let estimatesNote = UILabel()
    private let insulinValue = UILabel()
    private let status = UILabel()
    private let insulinNote = UILabel()
    private var valueRows: [UIStackView] = []
    private var reservedTextHeights: [NSLayoutConstraint] = []
    private var percentageWidth: NSLayoutConstraint!
    private var lastSummary: Summary?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        card.backgroundColor = .dashboardSurface
        card.layer.cornerRadius = 20
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        buildContent()
        updateContentSizeLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        let picker = UIStackView()
        picker.axis = .horizontal
        picker.spacing = 6
        picker.distribution = .fillEqually
        for days in GlucoseStatisticsSettingsStore.periods {
            let button = UIButton(type: .custom)
            button.setTitle("\(days)d", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.tag = days
            button.layer.cornerRadius = 11
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityLabel = "Last \(days) days"
            button.accessibilityIdentifier = "glucoseStatisticsPeriod\(days)"
            button.addTarget(self, action: #selector(selectDays(_:)), for: .touchUpInside)
            picker.addArrangedSubview(button)
            dayButtons.append(button)
        }
        stack.addArrangedSubview(picker)
        hero.spacing = 8
        styleValue(percentage, style: .largeTitle, color: .dashboardGlucoseInRangeInk)
        percentage.accessibilityIdentifier = "glucoseStatisticsInRangeValue"
        percentageWidth = percentage.widthAnchor.constraint(equalToConstant: 130)
        percentageWidth.isActive = true
        hero.addArrangedSubview(percentage)
        hero.addArrangedSubview(label("in range", style: .headline, color: .dashboardInk))
        hero.addArrangedSubview(UIView())
        hero.isAccessibilityElement = true
        stack.addArrangedSubview(hero)
        stack.setCustomSpacing(10, after: hero)
        glucoseBar.accessibilityIdentifier = "glucoseStatisticsRangeDiagram"
        stack.addArrangedSubview(glucoseBar)
        stack.setCustomSpacing(10, after: glucoseBar)
        glucoseLegend.distribution = .fillEqually
        glucoseLegend.spacing = 10
        [below, inside, above].forEach { glucoseLegend.addArrangedSubview($0) }
        stack.addArrangedSubview(glucoseLegend)
        stack.addArrangedSubview(valueRow("Average glucose", value: averageValue))
        gmiValue.accessibilityIdentifier = "glucoseStatisticsGMI"
        estimatedA1cValue.accessibilityIdentifier = "glucoseStatisticsEstimatedA1c"
        stack.addArrangedSubview(valueRow(NSLocalizedString("GMI", comment: "CGM-derived glucose management indicator"), value: gmiValue))
        stack.addArrangedSubview(valueRow(NSLocalizedString("Est. HbA1c", comment: "ADAG-derived HbA1c estimate, not a lab measurement"), value: estimatedA1cValue))
        reserveTwoLines(estimatesNote)
        stack.addArrangedSubview(estimatesNote)
        reserveTwoLines(status)
        status.accessibilityIdentifier = "glucoseStatisticsStatus"
        stack.addArrangedSubview(status)

        let divider = UIView()
        divider.backgroundColor = .dashboardBorder
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(valueRow("Recorded insulin", value: insulinValue))
        insulinBar.accessibilityIdentifier = "glucoseStatisticsInsulinDiagram"
        stack.addArrangedSubview(insulinBar)
        stack.setCustomSpacing(10, after: insulinBar)
        let insulinLegend = UIStackView(arrangedSubviews: [basal, bolus])
        insulinLegend.axis = .horizontal
        insulinLegend.distribution = .fillEqually
        insulinLegend.spacing = 12
        stack.addArrangedSubview(insulinLegend)
        reserveTwoLines(insulinNote)
        stack.addArrangedSubview(insulinNote)
    }

    func configure(_ summary: Summary) {
        guard summary != lastSummary else { return }
        lastSummary = summary
        UIView.performWithoutAnimation {
            updateSelectedDays(summary.days)
            percentage.text = summary.inRange
            hero.accessibilityLabel = "Time in range, \(summary.inRange), last \(summary.days) days"
            glucoseBar.setFractions(summary.glucoseFractions)
            below.configure(value: summary.belowRange, detail: "< " + summary.lowerBoundary)
            inside.configure(value: summary.inRange, detail: summary.lowerBoundary + "–" + summary.upperBoundary)
            above.configure(value: summary.aboveRange, detail: "> " + summary.upperBoundary)
            averageValue.text = summary.averageGlucose
            gmiValue.text = summary.gmi
            estimatedA1cValue.text = summary.estimatedA1c
            estimatesNote.text = summary.estimatesNote
            status.text = summary.status
            insulinValue.text = summary.insulinDailyAverage
            insulinBar.setFractions(summary.insulinFractions)
            basal.configure(value: summary.basal)
            bolus.configure(value: summary.bolus)
            insulinNote.text = summary.insulinNote
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateContentSizeLayout()
        }
    }

    private func updateContentSizeLayout() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        hero.axis = accessible ? .vertical : .horizontal
        hero.alignment = accessible ? .leading : .firstBaseline
        glucoseLegend.axis = accessible ? .vertical : .horizontal
        for row in valueRows {
            row.axis = accessible ? .vertical : .horizontal
            (row.arrangedSubviews.last as? UILabel)?.textAlignment = accessible ? .left : .right
        }
        let font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .monospacedDigitSystemFont(ofSize: 42, weight: .bold))
        percentage.font = font
        percentageWidth.constant = ceil(("100%" as NSString).size(withAttributes: [.font: font]).width) + 4
        let height = ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight) * 2
        reservedTextHeights.forEach { $0.constant = height }
    }

    @objc private func selectDays(_ sender: UIButton) {
        updateSelectedDays(sender.tag)
        onSelectDays?(sender.tag)
    }

    private func updateSelectedDays(_ days: Int) {
        for button in dayButtons {
            button.isSelected = button.tag == days
            button.backgroundColor = button.isSelected ? .dashboardGlucoseAccent : UIColor.dashboardMutedInk.withAlphaComponent(0.08)
            button.setTitleColor(button.isSelected ? .white : .dashboardInk, for: .normal)
            button.accessibilityTraits = button.isSelected ? [.button, .selected] : [.button]
        }
    }

    private func valueRow(_ title: String, value: UILabel) -> UIStackView {
        let row = UIStackView()
        row.spacing = 8
        row.addArrangedSubview(label(title, style: .subheadline, color: .dashboardMutedInk))
        styleValue(value, style: .headline, color: .dashboardInk)
        row.addArrangedSubview(value)
        valueRows.append(row)
        return row
    }

    private func reserveTwoLines(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .dashboardMutedInk
        label.numberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        let height = label.heightAnchor.constraint(equalToConstant: 30)
        height.isActive = true
        reservedTextHeights.append(height)
    }

    private func styleValue(_ label: UILabel, style: UIFont.TextStyle, color: UIColor) {
        label.text = "—"
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.textColor = color
        label.numberOfLines = 1
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 1
        return label
    }
}

private final class StatisticsLegendItem: UIStackView {
    private let title: String
    private let valueLabel = UILabel()
    private let detailLabel = UILabel()
    private var detailHeight: NSLayoutConstraint?

    init(title: String, color: UIColor, showsDetail: Bool = false) {
        self.title = title
        super.init(frame: .zero)
        axis = .vertical
        spacing = 3
        let heading = UILabel()
        let headingText = NSMutableAttributedString(string: "● " + title, attributes: [.foregroundColor: UIColor.dashboardMutedInk])
        headingText.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        heading.attributedText = headingText
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.adjustsFontForContentSizeCategory = true
        addArrangedSubview(heading)
        valueLabel.text = "—"
        valueLabel.font = .preferredFont(forTextStyle: .headline)
        valueLabel.textColor = .dashboardInk
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.65
        addArrangedSubview(valueLabel)
        if showsDetail {
            detailLabel.text = "—"
            detailLabel.font = .preferredFont(forTextStyle: .caption2)
            detailLabel.textColor = .dashboardMutedInk
            detailLabel.adjustsFontForContentSizeCategory = true
            detailLabel.numberOfLines = 2
            detailLabel.lineBreakMode = .byWordWrapping
            detailHeight = detailLabel.heightAnchor.constraint(equalToConstant: ceil(detailLabel.font.lineHeight) * 2)
            detailHeight?.isActive = true
            addArrangedSubview(detailLabel)
        }
        isAccessibilityElement = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(value: String, detail: String? = nil) {
        valueLabel.text = value
        detailLabel.text = detail
        accessibilityLabel = [title, value, detail].compactMap { $0 }.joined(separator: ", ")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        detailHeight?.constant = ceil(UIFont.preferredFont(forTextStyle: .caption2).lineHeight) * 2
    }
}

/// The track and segments stay attached throughout loading and range changes.
private final class GlucoseStatisticsBarView: UIView {
    private var fractions: [Double] = []
    private var segments: [UIView] = []

    init(colors: [UIColor], height: CGFloat = 32) {
        super.init(frame: .zero)
        backgroundColor = UIColor.dashboardMutedInk.withAlphaComponent(0.12)
        layer.cornerRadius = height / 3
        clipsToBounds = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        isAccessibilityElement = false
        for color in colors {
            let segment = UIView()
            segment.backgroundColor = color
            addSubview(segment)
            segments.append(segment)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFractions(_ fractions: [Double]?) {
        let next = fractions ?? []
        guard self.fractions != next else { return }
        self.fractions = next
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let fraction = index < fractions.count && fractions[index].isFinite ? max(0, min(1, fractions[index])) : 0
            let width = bounds.width * CGFloat(fraction)
            segment.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }
}
