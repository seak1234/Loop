import UIKit

/// Observed glucose across a typical local day; deliberately separate from prediction.
final class GlucoseAGPTableViewCell: UITableViewCell {
    struct Summary: Equatable {
        let profile: GlucoseAmbulatoryProfile
        let days: Int
        let coverage: String
        let lowerMGDL: Double
        let upperMGDL: Double
        let showRange: Bool
        let unitMultiplier: Double
        let unitLabel: String
        let isLoading: Bool
    }

    private let card = UIView()
    private let stack = UIStackView()
    private let plot = GlucoseAGPPlotView()
    private let caption = UILabel()
    private let legend = UIStackView()
    private var captionHeight: NSLayoutConstraint!
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
        let title = label(NSLocalizedString("AGP · Typical day", comment: "Title of the observed 24-hour glucose profile"), style: .headline, color: .dashboardInk)
        title.accessibilityTraits = .header
        stack.addArrangedSubview(title)
        plot.accessibilityIdentifier = "glucoseAGPGraph"
        plot.heightAnchor.constraint(equalToConstant: 230).isActive = true
        stack.addArrangedSubview(plot)
        legend.axis = .horizontal
        legend.distribution = .fillEqually
        legend.spacing = 8
        for (text, alpha) in [(NSLocalizedString("Median", comment: "AGP median line"), 1.0), ("25–75%", 0.7), ("5–95%", 0.5)] {
            legend.addArrangedSubview(label(text, style: .caption1, color: UIColor.dashboardGlucoseAccent.withAlphaComponent(CGFloat(alpha))))
        }
        stack.addArrangedSubview(legend)
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .dashboardMutedInk
        caption.numberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.accessibilityIdentifier = "glucoseAGPCoverage"
        captionHeight = caption.heightAnchor.constraint(equalToConstant: 32)
        captionHeight.isActive = true
        stack.addArrangedSubview(caption)
        updateContentSizeLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ summary: Summary) {
        guard summary != lastSummary else { return }
        lastSummary = summary
        plot.summary = summary
        if summary.isLoading {
            caption.text = NSLocalizedString("Updating glucose profile…", comment: "AGP loading caption")
        } else if summary.profile.points.isEmpty {
            caption.text = NSLocalizedString("Needs at least 3 days of readings per time slot.", comment: "AGP unavailable without several observed days")
        } else {
            caption.text = String(format: NSLocalizedString("Last %1$dd · %2$@ CGM coverage\nLocal time · 14+ days recommended", comment: "AGP reporting period, observed days and CGM coverage"), summary.days, summary.coverage)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { updateContentSizeLayout() }
        plot.setNeedsDisplay()
    }

    private func updateContentSizeLayout() {
        legend.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        captionHeight.constant = ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight) * 2 + 4
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }
}

private final class GlucoseAGPPlotView: UIView {
    var summary: GlucoseAGPTableViewCell.Summary? {
        didSet {
            setNeedsDisplay()
            guard let summary else { return }
            accessibilityLabel = NSLocalizedString("Ambulatory glucose profile", comment: "Accessibility name of the 24-hour glucose distribution")
            let medians = summary.profile.points.map(\.median)
            if let minimum = medians.min(), let maximum = medians.max() {
                accessibilityValue = String(format: NSLocalizedString("Median glucose %1$@ to %2$@ %3$@. Dark band: 25th to 75th percentiles. Light band: 5th to 95th percentiles. Gaps have insufficient data.", comment: "Accessible AGP description"), number(minimum, summary), number(maximum, summary), summary.unitLabel)
            } else { accessibilityValue = NSLocalizedString("Not enough observed days to draw a profile.", comment: "AGP empty accessibility description") }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let summary, let context = UIGraphicsGetCurrentContext() else { return }
        let plot = CGRect(x: 38, y: 18, width: max(1, bounds.width - 46), height: max(1, bounds.height - 51))
        let low = max(0, floor(min(40, (summary.profile.points.map(\.p05).min() ?? 50) - 10) / 20) * 20)
        let high = ceil(max(200, max(summary.upperMGDL + 20, (summary.profile.points.map(\.p95).max() ?? 180) + 20)) / 50) * 50
        func x(_ minute: Double) -> CGFloat { plot.minX + CGFloat(minute / 1440) * plot.width }
        func y(_ glucose: Double) -> CGFloat { plot.maxY - CGFloat((glucose - low) / (high - low)) * plot.height }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.dashboardMutedInk]
        (summary.unitLabel as NSString).draw(at: CGPoint(x: 0, y: 0), withAttributes: attributes)
        context.setStrokeColor(UIColor.dashboardBorder.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(0.5)
        for tick in 0...4 {
            let value = low + Double(tick) * (high - low) / 4
            let position = y(value)
            context.move(to: CGPoint(x: plot.minX, y: position))
            context.addLine(to: CGPoint(x: plot.maxX, y: position))
            let text = number(value, summary) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: plot.minX - size.width - 5, y: position - size.height / 2), withAttributes: attributes)
        }
        for hour in stride(from: 0, through: 24, by: 6) {
            let position = x(Double(hour * 60))
            context.move(to: CGPoint(x: position, y: plot.minY))
            context.addLine(to: CGPoint(x: position, y: plot.maxY))
            let text = String(format: "%02d", hour) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: position - size.width / 2, y: plot.maxY + 7), withAttributes: attributes)
        }
        context.strokePath()
        context.saveGState()
        context.clip(to: plot)
        if summary.showRange {
            context.setFillColor(UIColor.dashboardGlucoseInRange.withAlphaComponent(0.12).cgColor)
            context.fill(CGRect(x: plot.minX, y: y(summary.upperMGDL), width: plot.width, height: y(summary.lowerMGDL) - y(summary.upperMGDL)))
        }
        for segment in summary.profile.segments {
            func point(_ sample: GlucoseAmbulatoryProfile.Point, _ value: Double) -> CGPoint {
                CGPoint(x: x(Double(sample.minute) + Double(GlucoseAmbulatoryProfile.slotMinutes) / 2), y: y(value))
            }
            func band(lower: KeyPath<GlucoseAmbulatoryProfile.Point, Double>, upper: KeyPath<GlucoseAmbulatoryProfile.Point, Double>, alpha: CGFloat) {
                guard let first = segment.first else { return }
                let path = UIBezierPath()
                path.move(to: point(first, first[keyPath: lower]))
                for sample in segment.dropFirst() { path.addLine(to: point(sample, sample[keyPath: lower])) }
                for sample in segment.reversed() { path.addLine(to: point(sample, sample[keyPath: upper])) }
                path.close()
                UIColor.dashboardGlucoseAccent.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            band(lower: \.p05, upper: \.p95, alpha: 0.12)
            band(lower: \.p25, upper: \.p75, alpha: 0.28)
            let line = UIBezierPath()
            for (index, sample) in segment.enumerated() {
                let position = point(sample, sample.median)
                if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
            }
            UIColor.dashboardGlucoseAccent.setStroke()
            line.lineWidth = 2.5
            line.lineJoinStyle = .round
            line.stroke()
            if segment.count == 1, let sample = segment.first {
                let center = point(sample, sample.median)
                UIColor.dashboardGlucoseAccent.setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            }
        }
        context.restoreGState()
        if summary.profile.points.isEmpty {
            let text = (summary.isLoading ? NSLocalizedString("Loading profile…", comment: "AGP graph loading message") : NSLocalizedString("Not enough data", comment: "AGP graph empty message")) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func number(_ mgdl: Double, _ summary: GlucoseAGPTableViewCell.Summary) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = summary.unitMultiplier < 1 ? 1 : 0
        return formatter.string(from: NSNumber(value: mgdl * summary.unitMultiplier)) ?? "—"
    }
}
