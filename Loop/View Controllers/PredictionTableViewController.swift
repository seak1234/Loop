//
//  PredictionTableViewController.swift
//  Loop
//
//  Created by Nate Racklyeft on 9/3/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Combine
import SwiftUI
import HealthKit
import LoopCore
import LoopKit
import LoopKitUI
import LoopUI
import UIKit
import os.log


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.glucose, .targets]
}

private extension UIFont {
    static func predictionDashboardRounded(
        ofSize size: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func predictionDashboardRoundedDigits(
        ofSize size: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}


class PredictionTableViewController: LoopChartsTableViewController, IdentifiableClass {
    private let log = OSLog(category: "PredictionTableViewController")
    private let statistics = GlucoseStatisticsLoader.shared
    private var statisticsObservers = Set<AnyCancellable>()
    private struct StatisticsValues {
        let sourceVersion: UUID
        let lower: Double
        let upper: Double
        let glucose: GlucoseStatistics
        let insulin: GlucoseInsulinStatistics
    }
    private var statisticsValues: [Int: StatisticsValues] = [:]
    private var statisticsCalculationInProgress = false
    private var statisticsCalculationTask: Task<Void, Never>?
    private lazy var statisticsSizingCell = GlucoseStatisticsTableViewCell(style: .default, reuseIdentifier: nil)
    private var statisticsMeasuredSize: (width: CGFloat, category: UIContentSizeCategory, height: CGFloat)?

    private lazy var dashboardBackgroundImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "DashboardMarbleBackground"))
        imageView.contentMode = .scaleAspectFill
        imageView.transform = CGAffineTransform(scaleX: -1, y: 1)
        imageView.clipsToBounds = true
        imageView.backgroundColor = .dashboardBackground
        imageView.isAccessibilityElement = false
        return imageView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.rowHeight = UITableView.automaticDimension
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.backgroundColor = .dashboardBackground
        tableView.backgroundView = dashboardBackgroundImageView
        tableView.separatorStyle = .none
        tableView.tintColor = .dashboardGlucoseAccent
        tableView.sectionHeaderTopPadding = 4
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 12, right: 0)
        updateDashboardBackgroundAppearance()
        tableView.register(GlucoseStatisticsTableViewCell.self, forCellReuseIdentifier: "GlucoseStatistics")
        title = NSLocalizedString("Glucose", comment: "Title of the glucose page")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("Settings", comment: "Button opening glucose range and data settings"),
            style: .plain,
            target: self,
            action: #selector(showStatisticsSettings)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "glucoseStatisticsSettings"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshStatistics), for: .valueChanged)
        statistics.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.refreshStatisticsDisplay()
                if !self.statistics.isLoading { self.refreshControl?.endRefreshing() }
            }.store(in: &statisticsObservers)
        GlucoseGraphSettingsStore.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.glucoseChart.inRangeDisplayRange = settings.isEnabled ?
                    HKQuantity(unit: .milligramsPerDeciliter, doubleValue: settings.lowerBoundMGDL)...HKQuantity(unit: .milligramsPerDeciliter, doubleValue: settings.upperBoundMGDL) : nil
                self.charts.invalidateChart(atIndex: 0)
                for case let cell as ChartTableViewCell in self.tableView.visibleCells { cell.reloadChart() }
                self.refreshStatisticsDisplay()
            }.store(in: &statisticsObservers)

        glucoseChart.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayRangeWide

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let context = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                DispatchQueue.main.async {
                    switch LoopDataManager.LoopUpdateContext(rawValue: context) {
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .glucose?:
                        self?.refreshContext.update(with: .glucose)
                    default:
                        break
                    }

                    self?.reloadData(animated: true)
                }
            },
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        configureDashboardNavigationAppearance()
        statistics.refresh(manager: deviceManager)
        refreshStatisticsDisplay()
    }

    @objc private func refreshStatistics() {
        statistics.refresh(manager: deviceManager, force: true)
        refreshContext = RefreshContext.all
        reloadData()
    }

    @objc private func showStatisticsSettings() {
        let settings = GlucoseGraphSettingsView().environmentObject(deviceManager.displayGlucosePreference)
        navigationController?.pushViewController(UIHostingController(rootView: settings), animated: true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateDashboardBackgroundAppearance()
            configureDashboardNavigationAppearance()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory, isViewLoaded {
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
    }

    private func configureDashboardNavigationAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .dashboardSurface
        appearance.shadowColor = .dashboardBorder
        appearance.titleTextAttributes = [
            .font: UIFont.predictionDashboardRounded(ofSize: 17, weight: .semibold),
            .foregroundColor: UIColor.dashboardInk
        ]

        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
        navigationController?.navigationBar.tintColor = .dashboardGlucoseAccent
    }

    private func updateDashboardBackgroundAppearance() {
        dashboardBackgroundImageView.alpha = traitCollection.userInterfaceStyle == .dark ? 0.08 : 0.44
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext = RefreshContext.all
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    private var retrospectiveGlucoseDiscrepancies: [GlucoseChange]?

    private var totalRetrospectiveCorrection: HKQuantity?

    private var refreshContext = RefreshContext.all

    private var chartStartDate: Date {
        get {
            return charts.startDate
        }
        set {
            if newValue != chartStartDate {
                refreshContext = RefreshContext.all
            }

            charts.startDate = newValue
        }
    }

    let glucoseChart = PredictedGlucoseChart(yAxisStepSizeMGDLOverride: FeatureFlags.predictedGlucoseChartClampEnabled ? 40 : nil)

    override func createChartsManager() -> ChartsManager {
        glucoseChart.targetGlucoseFillColor = .dashboardGlucoseAccent
        return ChartsManager(colors: .dashboard, settings: .default, charts: [glucoseChart], traitCollection: traitCollection)
    }

    override func glucoseUnitDidChange() {
        self.log.debug("[reloadData] for HealthKit unit preference change")
        refreshContext = RefreshContext.all
        if isViewLoaded { refreshStatisticsDisplay() }
    }

    override func reloadData(animated: Bool = false) {
        if active && visible { statistics.refresh(manager: deviceManager) }
        guard active && visible && !refreshContext.isEmpty else { return }

        refreshContext.remove(.size(.zero))
        let calendar = Calendar.current
        var components = DateComponents()
        components.minute = 0
        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: 1))
        chartStartDate = calendar.nextDate(after: date, matching: components, matchingPolicy: .strict, direction: .backward) ?? date

        let reloadGroup = DispatchGroup()
        var glucoseSamples: [StoredGlucoseSample]?
        var totalRetrospectiveCorrection: HKQuantity?

        if self.refreshContext.remove(.glucose) != nil {
            reloadGroup.enter()
            deviceManager.glucoseStore.getGlucoseSamples(start: self.chartStartDate, end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting glucose samples: %{public}@", String(describing: error))
                    glucoseSamples = nil
                case .success(let samples):
                    glucoseSamples = samples
                }
                reloadGroup.leave()
            }
        }

        // For now, do this every time
        _ = self.refreshContext.remove(.status)
        reloadGroup.enter()
        deviceManager.loopManager.getLoopState { (manager, state) in
            self.retrospectiveGlucoseDiscrepancies = state.retrospectiveGlucoseDiscrepancies
            totalRetrospectiveCorrection = state.totalRetrospectiveCorrection
            self.glucoseChart.setPredictedGlucoseValues(state.predictedGlucoseIncludingPendingInsulin ?? [])

            do {
                let glucose = try state.predictGlucose(using: self.selectedInputs, includingPendingInsulin: true)
                self.glucoseChart.setAlternatePredictedGlucoseValues(glucose)
            } catch {
                self.refreshContext.update(with: .status)
                self.glucoseChart.setAlternatePredictedGlucoseValues([])
            }

            if let lastPoint = self.glucoseChart.alternatePredictedGlucosePoints?.last?.y {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                self.eventualGlucoseDescription = nil
            }

            if self.refreshContext.remove(.targets) != nil {
                self.glucoseChart.targetGlucoseSchedule = manager.settings.glucoseTargetRangeSchedule
            }

            reloadGroup.leave()
        }

        reloadGroup.notify(queue: .main) {
            if let glucoseSamples = glucoseSamples {
                self.glucoseChart.setGlucoseValues(glucoseSamples)
            }
            self.charts.invalidateChart(atIndex: 0)

            if let totalRetrospectiveCorrection = totalRetrospectiveCorrection {
                self.totalRetrospectiveCorrection = totalRetrospectiveCorrection
            }

            self.charts.prerender()

            self.tableView.beginUpdates()
            for cell in self.tableView.visibleCells {
                switch cell {
                case let cell as ChartTableViewCell:
                    cell.reloadChart()

                    if let indexPath = self.tableView.indexPath(for: cell) {
                        self.tableView(self.tableView, updateSubtitleFor: cell, at: indexPath)
                    }
                case let cell as PredictionInputEffectTableViewCell:
                    if let indexPath = self.tableView.indexPath(for: cell) {
                        self.tableView(self.tableView, updateTextFor: cell, at: indexPath)
                    }
                default:
                    break
                }
            }
            self.tableView.endUpdates()
        }
    }

    // MARK: - UITableViewDataSource

    private enum Section: Int, CaseIterable {
        case statistics
        case charts
        case inputs
    }

    private var eventualGlucoseDescription: String?

    private var availableInputs: [PredictionInputEffect] = [.carbs, .insulin, .momentum, .retrospection, .suspend]

    private var selectedInputs = PredictionInputEffect.all

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .statistics:
            return 1
        case .charts:
            return 1
        case .inputs:
            return availableInputs.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .statistics:
            return statisticsCell(at: indexPath)
        case .charts:
            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell
            cell.dashboardCardAccentColor = .dashboardGlucoseAccent
            cell.contentView.layoutMargins.left = tableView.separatorInset.left
            cell.setChartGenerator(generator: { [weak self] (frame) in
                return self?.charts.chart(atIndex: 0, frame: frame)?.view
            })

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)
            cell.selectionStyle = .none
            cell.doesNavigate = false

            for case let label as UILabel in cell.contentView.subviews {
                guard label.text != nil else { continue }
                label.textColor = .dashboardMutedInk
                if label.font.pointSize <= 13 {
                    label.font = .predictionDashboardRounded(ofSize: label.font.pointSize, weight: .regular)
                }
            }

            // Apply this after the supporting copy so the graph heading keeps
            // the stronger dashboard hierarchy.
            cell.setTitleLabelText(label: NSLocalizedString("Predicted Glucose", comment: "The title of the glucose prediction graph"))

            cell.addGestureRecognizer(charts.gestureRecognizer!)

            return cell
        case .inputs:
            let cell = tableView.dequeueReusableCell(withIdentifier: PredictionInputEffectTableViewCell.className, for: indexPath) as! PredictionInputEffectTableViewCell
            cell.applyDashboardAppearance()
            self.tableView(tableView, updateTextFor: cell, at: indexPath)
            return cell
        }
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        guard case .charts? = Section(rawValue: indexPath.section) else {
            return
        }

        if let eventualGlucose = eventualGlucoseDescription {
            let fullText = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
            let attrString = NSMutableAttributedString(
                string: fullText,
                attributes: [
                    .font: UIFont.predictionDashboardRounded(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.dashboardMutedInk
                ]
            )
            if let range = fullText.range(of: eventualGlucose) {
                let nsRange = NSRange(range, in: fullText)
                attrString.addAttributes([
                    .font: UIFont.predictionDashboardRoundedDigits(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor.dashboardGlucoseAccent
                ], range: nsRange)
            }
            cell.setAttributedSubtitleLabel(attrString)
        } else {
            cell.setSubtitleLabel(label: nil)
        }
    }

    private func tableView(_ tableView: UITableView, updateTextFor cell: PredictionInputEffectTableViewCell, at indexPath: IndexPath) {
        guard case .inputs? = Section(rawValue: indexPath.section) else {
            return
        }

        let input = availableInputs[indexPath.row]

        cell.titleLabel?.text = input.localizedTitle
        cell.accessoryType = selectedInputs.contains(input) ? .checkmark : .none
        cell.tintColor = .dashboardGlucoseAccent

        var subtitleText = input.localizedDescription(forGlucoseUnit: glucoseChart.glucoseUnit) ?? ""

        if input == .retrospection,
            let lastDiscrepancy = retrospectiveGlucoseDiscrepancies?.last,
            let currentGlucose = deviceManager.glucoseStore.latestGlucose
        {
            let formatter = QuantityFormatter(for: glucoseChart.glucoseUnit)
            let predicted = HKQuantity(unit: glucoseChart.glucoseUnit, doubleValue: currentGlucose.quantity.doubleValue(for: glucoseChart.glucoseUnit) - lastDiscrepancy.quantity.doubleValue(for: glucoseChart.glucoseUnit))
            var values = [predicted, currentGlucose.quantity].map { formatter.string(from: $0) ?? "?" }
            formatter.numberFormatter.positivePrefix = formatter.numberFormatter.plusSign
            values.append(formatter.string(from: lastDiscrepancy.quantity) ?? "?")

            let retro = String(
                format: NSLocalizedString("Predicted: %1$@\nActual: %2$@ (%3$@)", comment: "Format string describing retrospective glucose prediction comparison. (1: Predicted glucose)(2: Actual glucose)(3: difference)"),
                values[0], values[1], values[2]
            )
            let isIntegralRetrospectiveCorrectionEnabled = UserDefaults.standard.integralRetrospectiveCorrectionEnabled
            
            if isIntegralRetrospectiveCorrectionEnabled {
                var integralEffectDisplay = "?"
                var totalEffectDisplay = "?"
                if let totalEffect = self.totalRetrospectiveCorrection {
                    let integralEffectValue = totalEffect.doubleValue(for: glucoseChart.glucoseUnit) - lastDiscrepancy.quantity.doubleValue(for: glucoseChart.glucoseUnit)
                    let integralEffect = HKQuantity(unit: glucoseChart.glucoseUnit, doubleValue: integralEffectValue)
                    integralEffectDisplay = formatter.string(from: integralEffect) ?? "?"
                    totalEffectDisplay = formatter.string(from: totalEffect) ?? "?"
                }
                let integralRetro = String(
                    format: NSLocalizedString("prediction-description-integral-retrospective-correction", comment: "Format string describing integral retrospective correction. (1: Integral glucose effect)(2: Total glucose effect)"),
                    integralEffectDisplay, totalEffectDisplay
                )
                subtitleText = String(format: "%@\n%@", retro, integralRetro)
            } else {
                subtitleText = String(format: "%@\n%@", subtitleText, retro)
            }
        
        }

        cell.subtitleLabel?.text = subtitleText
    }

    /// Keep the visible cell attached; data updates must not reload or resize its row.
    private func updateVisibleStatisticsCell() {
        let indexPath = IndexPath(row: 0, section: Section.statistics.rawValue)
        if let cell = tableView.cellForRow(at: indexPath) as? GlucoseStatisticsTableViewCell {
            cell.configure(statisticsSummary())
        }
    }

    private func refreshStatisticsDisplay() {
        guard isViewLoaded && visible else { return }
        statisticsCalculationInProgress = true
        updateVisibleStatisticsCell()
        statisticsCalculationTask?.cancel()
        let readings = statistics.readings, doses = statistics.doses, remoteBoluses = statistics.remoteBoluses
        let end = statistics.end
        let range = GlucoseGraphSettingsStore.shared.settings
        let days = GlucoseStatisticsSettingsStore.shared.days
        let sourceVersion = statistics.sourceVersion
        // Precompute the other buttons after a load. Returning to a period then
        // uses its numbers immediately, without a dash/number flash.
        let periods = statistics.isLoading ? [days] : [days] + GlucoseStatisticsSettingsStore.periods.filter { $0 != days }
        let calculation = Task.detached(priority: .userInitiated) { () -> [Int: (GlucoseStatistics, GlucoseInsulinStatistics)] in
            var values: [Int: (GlucoseStatistics, GlucoseInsulinStatistics)] = [:]
            for period in periods {
                guard !Task.isCancelled else { return [:] }
                let start = end.addingTimeInterval(-Double(period) * 86400)
                let glucose = GlucoseStatistics.calculate(readings: readings, start: start, end: end,
                                                          lower: range.lowerBoundMGDL, upper: range.upperBoundMGDL)
                guard !Task.isCancelled else { return [:] }
                let insulin = GlucoseInsulinStatistics.calculate(local: doses, remoteBoluses: remoteBoluses, start: start, end: end)
                values[period] = (glucose, insulin)
            }
            return values
        }
        statisticsCalculationTask = Task { [weak self] in
            let values = await withTaskCancellationHandler(operation: { await calculation.value }, onCancel: { calculation.cancel() })
            guard !Task.isCancelled, let self else { return }
            for (period, value) in values {
                self.statisticsValues[period] = StatisticsValues(sourceVersion: sourceVersion, lower: range.lowerBoundMGDL,
                                                                 upper: range.upperBoundMGDL, glucose: value.0, insulin: value.1)
            }
            self.statisticsCalculationInProgress = false
            self.updateVisibleStatisticsCell()
        }
    }

    private func statisticsCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "GlucoseStatistics", for: indexPath) as! GlucoseStatisticsTableViewCell
        cell.configure(statisticsSummary())
        cell.onSelectDays = { [weak self] days in
            guard let self, days != GlucoseStatisticsSettingsStore.shared.days else { return }
            GlucoseStatisticsSettingsStore.shared.days = days
            self.statistics.refresh(manager: self.deviceManager)
            self.refreshStatisticsDisplay()
        }
        return cell
    }

    private func statisticsSummary() -> GlucoseStatisticsTableViewCell.Summary {
        let settings = GlucoseGraphSettingsStore.shared.settings
        let saved = statisticsValues[GlucoseStatisticsSettingsStore.shared.days]
        let currentValues = saved.flatMap { $0.sourceVersion == statistics.sourceVersion && $0.lower == settings.lowerBoundMGDL && $0.upper == settings.upperBoundMGDL ? $0 : nil }
        let loading = statistics.isLoading || (currentValues == nil && statisticsCalculationInProgress)
        let result = currentValues?.glucose ?? GlucoseStatistics.calculate(readings: [], start: statistics.start, end: statistics.end,
                                                                         lower: settings.lowerBoundMGDL, upper: settings.upperBoundMGDL)
        let insulin = currentValues?.insulin ?? GlucoseInsulinStatistics.calculate(local: [], remoteBoluses: [], start: statistics.start, end: statistics.end)
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        func glucose(_ value: Double?, includeUnit: Bool = true) -> String {
            guard let value else { return "—" }
            return deviceManager.displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value), includeUnit: includeUnit)
        }
        func number(_ value: Double?, suffix: String, multiplier: Double = 1, decimals: Int = 0) -> String {
            guard let value else { return "—" }
            numberFormatter.maximumFractionDigits = decimals
            return (numberFormatter.string(from: NSNumber(value: value * multiplier)) ?? "—") + suffix
        }
        let status: String
        if loading { status = "Updating history… · " + number(result.coverage, suffix: "% CGM coverage", multiplier: 100) }
        else if result.meanMGDL == nil { status = "No glucose history for these days. Pull down to retry." }
        else {
            let coverage = number(result.coverage, suffix: "%", multiplier: 100)
            let source = statistics.glucoseSource.replacingOccurrences(of: " CGM", with: "")
            status = "\(coverage) CGM coverage · \(source)" + (statistics.message == nil ? "" : " · Incomplete")
        }
        // A basal/bolus split is useful only when both are recorded and basal
        // history is sufficiently complete. Otherwise leave the track neutral.
        let insulinFractions: [Double]? = insulin.basalPercentage.map { [$0 / 100, 1 - $0 / 100] }
        let insulinNote: String
        if loading { insulinNote = "Loading insulin history…" }
        else if insulin.total == nil { insulinNote = "No insulin recorded for these days." }
        else if insulin.total == 0 { insulinNote = "0 U recorded for these days." }
        else if insulin.hasRemoteBolusOnlyDays { insulinNote = "Partial history · Nightscout boluses only" }
        else if insulinFractions == nil { insulinNote = "Partial basal history" }
        else { insulinNote = "Recorded totals for the selected days" }
        return .init(
            days: GlucoseStatisticsSettingsStore.shared.days,
            inRange: number(result.inRange, suffix: "%", multiplier: 100),
            belowRange: number(result.belowRange, suffix: "%", multiplier: 100),
            aboveRange: number(result.aboveRange, suffix: "%", multiplier: 100),
            lowerBoundary: glucose(settings.lowerBoundMGDL, includeUnit: false),
            upperBoundary: glucose(settings.upperBoundMGDL),
            glucoseFractions: result.inRange.map { [result.belowRange ?? 0, $0, result.aboveRange ?? 0] },
            averageGlucose: glucose(result.meanMGDL),
            insulinDailyAverage: number(insulin.recordedDailyAverage, suffix: " U/day", decimals: 1),
            basal: number(insulin.basal, suffix: " U", decimals: 1),
            bolus: number(insulin.bolus, suffix: " U", decimals: 1),
            insulinFractions: insulinFractions, insulinNote: insulinNote, status: status)
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if Section(rawValue: section) == .statistics { return nil }
        guard Section(rawValue: section) == .inputs else {
            return nil
        }

        return NSLocalizedString("Prediction Inputs", comment: "Header for the inputs included in glucose prediction")
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else {
            return
        }

        header.contentView.backgroundColor = .clear
        header.textLabel?.font = .predictionDashboardRounded(ofSize: 12, weight: .bold)
        header.textLabel?.textColor = .dashboardInk
    }

    private func statisticsRowHeight() -> CGFloat {
        let width = tableView.bounds.width
        let category = traitCollection.preferredContentSizeCategory
        if let size = statisticsMeasuredSize, size.width == width, size.category == category { return size.height }
        guard width > 0 else { return 570 }
        // All changing copy has reserved line heights. Measure once per width
        // and text size so estimated and final row heights agree from the start.
        statisticsSizingCell.configure(statisticsSummary())
        statisticsSizingCell.bounds = CGRect(x: 0, y: 0, width: width, height: 1000)
        statisticsSizingCell.contentView.bounds = statisticsSizingCell.bounds
        statisticsSizingCell.setNeedsLayout()
        statisticsSizingCell.layoutIfNeeded()
        let height = ceil(statisticsSizingCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height)
        statisticsMeasuredSize = (width, category, height)
        return height
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        Section(rawValue: indexPath.section) == .statistics ? statisticsRowHeight() : UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .statistics:
            return statisticsRowHeight()
        case .charts:
            return 275
        case .inputs:
            return 60
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard Section(rawValue: indexPath.section) == .inputs else { return }

        let input = availableInputs[indexPath.row]
        let isSelected = selectedInputs.contains(input)

        if let cell = tableView.cellForRow(at: indexPath) {
            cell.accessoryType = !isSelected ? .checkmark : .none
        }

        selectedInputs.formSymmetricDifference(input)

        tableView.deselectRow(at: indexPath, animated: true)

        refreshContext.update(with: .status)
        reloadData()
    }
}
