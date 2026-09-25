//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import SwiftUI
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopTestingKit
import LoopUI
import SwiftCharts
import os.log
import Combine
import WidgetKit
import MockKit

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

private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}

final class StatusTableViewController: LoopChartsTableViewController {

    private let log = OSLog(category: "StatusTableViewController")

    private lazy var dashboardBackgroundImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "DashboardMarbleBackground"))
        imageView.contentMode = .scaleAspectFill
        imageView.transform = CGAffineTransform(scaleX: -1, y: 1)
        imageView.clipsToBounds = true
        imageView.backgroundColor = .dashboardBackground
        imageView.isAccessibilityElement = false
        return imageView
    }()

    lazy var carbFormatter: QuantityFormatter = QuantityFormatter(for: .gram())

    var onboardingManager: OnboardingManager!

    var testingScenariosManager: TestingScenariosManager!

    var automaticDosingStatus: AutomaticDosingStatus!
    
    var alertPermissionsChecker: AlertPermissionsChecker!

    var alertMuter: AlertMuter!

    var supportManager: SupportManager!

    lazy private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {

        super.viewDidLoad()
        
        setupToolbarItems()
        configureDashboardToolbarAppearance()
        
        tableView.register(BolusProgressTableViewCell.nib(), forCellReuseIdentifier: BolusProgressTableViewCell.className)
        tableView.register(AlertPermissionsDisabledWarningCell.self, forCellReuseIdentifier: AlertPermissionsDisabledWarningCell.className)
        tableView.register(MuteAlertsWarningCell.self, forCellReuseIdentifier: MuteAlertsWarningCell.className)
        tableView.register(DashboardGraphicTableViewCell.self, forCellReuseIdentifier: DashboardGraphicTableViewCell.className)
        tableView.register(CycleSummaryTableViewCell.self, forCellReuseIdentifier: CycleSummaryTableViewCell.className)

        if FeatureFlags.predictedGlucoseChartClampEnabled {
            statusCharts.glucose.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBoundClamped
        } else {
            statusCharts.glucose.glucoseDisplayRange = LoopConstants.glucoseChartDefaultDisplayBound
        }

        registerPumpManager()
        registerCGMManager()

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext)
                DispatchQueue.main.async {
                    switch context {
                    case .none, .insulin?:
                        self?.refreshContext.formUnion([.status, .insulin])
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .carbs?:
                        self?.refreshContext.update(with: .carbs)
                    case .glucose?:
                        self?.refreshContext.formUnion([.glucose, .carbs])
                    case .loopFinished?:
                        self?.refreshContext.update(with: .insulin)
                    }

                    self?.hudView?.loopCompletionHUD.loopInProgress = false
                    self?.log.debug("[reloadData] from notification with context %{public}@", String(describing: context))
                    self?.reloadData(animated: true)
                }
                
                WidgetCenter.shared.reloadAllTimelines()
            },
            notificationCenter.addObserver(forName: .LoopRunning, object: deviceManager.loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hudView?.loopCompletionHUD.loopInProgress = true
                }
            },
            notificationCenter.addObserver(forName: .PumpManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerPumpManager()
                    self?.configurePumpManagerHUDViews()
                    self?.updateToolbarItems()
                }
            },
            notificationCenter.addObserver(forName: .CGMManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerCGMManager()
                    self?.configureCGMManagerHUDViews()
                    self?.updateToolbarItems()
                }
            },
            notificationCenter.addObserver(forName: .PumpEventsAdded, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.refreshContext.update(with: .insulin)
                    self?.reloadData(animated: true)
                }
            },
        ]

        automaticDosingStatus.$automaticDosingEnabled
            .receive(on: DispatchQueue.main)
            .sink { self.automaticDosingStatusChanged($0) }
            .store(in: &cancellables)

        alertMuter.$configuration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { _ in
                self.refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
            .store(in: &cancellables)

        if let gestureRecognizer = charts.gestureRecognizer {
            gestureRecognizer.delegate = chartReorderGestureDelegate
            tableView.addGestureRecognizer(gestureRecognizer)
        }

        let chartReorderRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleChartLongPress(_:)))
        chartReorderRecognizer.minimumPressDuration = 0.35
        chartReorderRecognizer.allowableMovement = 18
        chartReorderRecognizer.delegate = chartReorderGestureDelegate
        self.chartReorderRecognizer = chartReorderRecognizer
        tableView.addGestureRecognizer(chartReorderRecognizer)

        tableView.estimatedRowHeight = 74
        tableView.sectionHeaderTopPadding = 0

        // Estimate an initial value
        landscapeMode = UIScreen.main.bounds.size.width > UIScreen.main.bounds.size.height

        addScenarioStepGestureRecognizers()

        tableView.backgroundColor = .dashboardBackground
        tableView.backgroundView = dashboardBackgroundImageView
        updateDashboardBackgroundAppearance()
        tableView.separatorStyle = .none
    
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext.formUnion(RefreshContext.all)
        }
    }

    private var appearedOnce = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        configureDashboardToolbarAppearance()
        installToolbarReordering()
        
        updateToolbarItems()

        alertPermissionsChecker.checkNow()

        updateBolusProgress()

        onboardingManager.$isComplete
            .merge(with: onboardingManager.$isSuspended)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshContext.update(with: .status)
                self?.reloadData(animated: true)
                self?.updateToolbarItems()
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {

        super.viewDidAppear(animated)

        if !appearedOnce {
            appearedOnce = true
            #if targetEnvironment(simulator)
            if self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule == nil {
                let therapySettings = TherapySettings.mockTherapySettings
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.glucoseTargetRangeSchedule = therapySettings.glucoseTargetRangeSchedule
                    settings.preMealTargetRange = therapySettings.correctionRangeOverrides?.preMeal
                    settings.legacyWorkoutTargetRange = therapySettings.correctionRangeOverrides?.workout
                    settings.suspendThreshold = therapySettings.suspendThreshold
                    settings.maximumBolus = therapySettings.maximumBolus
                    settings.maximumBasalRatePerHour = therapySettings.maximumBasalRatePerHour
                    settings.insulinSensitivitySchedule = therapySettings.insulinSensitivitySchedule
                    settings.carbRatioSchedule = therapySettings.carbRatioSchedule
                    settings.basalRateSchedule = therapySettings.basalRateSchedule
                    settings.defaultRapidActingModel = therapySettings.defaultRapidActingModel
                }
            }
            if self.deviceManager.cgmManager == nil {
                _ = self.deviceManager.setupCGMManager(withIdentifier: "MockCGMManager", prefersToSkipUserInteraction: true)
                if let mockCGM = self.deviceManager.cgmManager as? MockCGMManager {
                    mockCGM.dataSource = MockCGMDataSource(model: .sineCurve(parameters: (baseGlucose: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 115), amplitude: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 25), period: TimeInterval(hours: 4), referenceDate: Date())))
                    mockCGM.backfillData(datingBack: .hours(24))
                }
            }
            if self.deviceManager.pumpManager == nil,
               let maximumBasalRate = self.deviceManager.loopManager.settings.maximumBasalRatePerHour,
               let maxBolus = self.deviceManager.loopManager.settings.maximumBolus,
               let basalSchedule = self.deviceManager.loopManager.settings.basalRateSchedule {
                let settings = PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maximumBasalRate, maxBolusUnits: maxBolus, basalSchedule: basalSchedule)
                _ = self.deviceManager.setupPumpManager(withIdentifier: "MockPumpManager", initialSettings: settings, prefersToSkipUserInteraction: true)
            }
            #endif
            DispatchQueue.main.async {
                self.log.debug("[reloadData] after HealthKit authorization")
                self.reloadData()
            }
        }

        onscreen = true

        deviceManager.analyticsServicesManager.didDisplayStatusScreen()

        deviceManager.checkDeliveryUncertaintyState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        onscreen = false

        if presentedViewController == nil {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        maybeOpenDebugMenu()

        super.viewWillTransition(to: size, with: coordinator)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateDashboardBackgroundAppearance()
            for case let cell as ChartTableViewCell in tableView.visibleCells {
                if let indexPath = tableView.indexPath(for: cell) {
                    refreshChartCellPresentation(cell, at: indexPath)
                }
            }
        }
    }

    private func updateDashboardBackgroundAppearance() {
        dashboardBackgroundImageView.alpha = traitCollection.userInterfaceStyle == .dark ? 0.08 : 0.44
    }

    // MARK: - State

    // This reflects whether the application is active 
    override var active: Bool {
        didSet {
            hudView?.loopCompletionHUD.assertTimer(active)
            updateHUDActive()
        }
    }

    // This is similar to the visible property, but is set later, on viewDidAppear, to be
    // suitable for animations that should be seen in their entirety.
    var onscreen: Bool = false {
        didSet {
            updateHUDActive()
        }
    }

    private var bolusState: PumpManagerStatus.BolusState = .noBolus {
        didSet {
            if oldValue != bolusState {
                switch bolusState {
                case .inProgress(let dose):
                    guard case .inProgress = oldValue else {
                        // Bolus starting
                        bolusProgressReporter = deviceManager.pumpManager?.createBolusProgressReporter(reportingOn: DispatchQueue.main)
                        // If there is an existing bolus progressCell, update its dose values now in case the app is currently in the
                        // background as otherwise these values won't get initialized and can contain stale data from some earlier bolus.
                        if let progressCell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
                            progressCell.totalUnits = dose.programmedUnits
                            progressCell.deliveredUnits = 0
                        }
                        break
                    }
                default:
                    break
                }
                refreshContext.update(with: .status)
                reloadData(animated: true)
            }
        }
    }

    private var bolusProgressReporter: DoseProgressReporter?

    private func updateBolusProgress() {
        if let cell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
            cell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
        }
    }

    private func updateHUDActive() {
        deviceManager.pumpManagerHUDProvider?.visible = active && onscreen
    }

    /// Layout of the items in the bottom toolbar.
    fileprivate enum ToolbarLayout {
        static let itemSize = CGSize(width: 64, height: 44)
        static let iconSize = CGSize(width: 24, height: 24)
        static let symbolPointSize: CGFloat = 20
    }

    /// A custom toolbar button with an icon stacked vertically above a text label,
    /// sized to fit the bottom toolbar geometry without text clipping.
    fileprivate final class ToolbarButton: UIButton {
        private let emphasisBackgroundView = UIView()
        private let emphasisGradient = CAGradientLayer()
        private let iconImageView = UIImageView()
        private let titleLabelView = UILabel()
        private let badgeView = UIView()
        private var baseImage: UIImage?
        private var customTintColor: UIColor?
        private var usesDimensionalIcon = false
        var isBadgeVisible: Bool = false {
            didSet {
                badgeView.isHidden = !isBadgeVisible
            }
        }

        init() {
            super.init(frame: CGRect(origin: .zero, size: ToolbarLayout.itemSize))
            setupViews()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupViews()
        }

        private func setupViews() {
            clipsToBounds = false
            isAccessibilityElement = true
            adjustsImageWhenDisabled = false
            tintAdjustmentMode = .normal

            emphasisBackgroundView.translatesAutoresizingMaskIntoConstraints = false
            emphasisBackgroundView.isUserInteractionEnabled = false
            emphasisBackgroundView.isAccessibilityElement = false
            emphasisBackgroundView.layer.cornerRadius = 15
            emphasisBackgroundView.layer.borderWidth = 1
            emphasisBackgroundView.layer.shadowOffset = CGSize(width: 0, height: 2)
            emphasisBackgroundView.layer.shadowRadius = 5
            emphasisBackgroundView.layer.addSublayer(emphasisGradient)
            emphasisBackgroundView.isHidden = true
            addSubview(emphasisBackgroundView)

            iconImageView.translatesAutoresizingMaskIntoConstraints = false
            iconImageView.contentMode = .scaleAspectFit
            iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: ToolbarLayout.symbolPointSize,
                weight: .medium
            )
            iconImageView.clipsToBounds = false
            iconImageView.isUserInteractionEnabled = false
            iconImageView.isAccessibilityElement = false
            iconImageView.tintAdjustmentMode = .normal
            addSubview(iconImageView)

            badgeView.translatesAutoresizingMaskIntoConstraints = false
            badgeView.isUserInteractionEnabled = false
            badgeView.clipsToBounds = true
            badgeView.layer.cornerRadius = 5.5
            badgeView.layer.borderWidth = 1.5
            badgeView.isHidden = true
            badgeView.tintAdjustmentMode = .normal
            addSubview(badgeView)

            titleLabelView.translatesAutoresizingMaskIntoConstraints = false
            titleLabelView.textAlignment = .center
            titleLabelView.font = Self.roundedFont(ofSize: 10, weight: .medium)
            titleLabelView.clipsToBounds = false
            titleLabelView.isUserInteractionEnabled = false
            titleLabelView.isAccessibilityElement = false
            titleLabelView.adjustsFontSizeToFitWidth = true
            titleLabelView.minimumScaleFactor = 0.8
            addSubview(titleLabelView)

            let itemSize = ToolbarLayout.itemSize

            let widthConstraint = widthAnchor.constraint(equalToConstant: itemSize.width)
            widthConstraint.priority = UILayoutPriority(999)

            let heightConstraint = heightAnchor.constraint(equalToConstant: itemSize.height)
            heightConstraint.priority = UILayoutPriority(999)

            NSLayoutConstraint.activate([
                widthConstraint,
                heightConstraint,

                emphasisBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
                emphasisBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
                emphasisBackgroundView.topAnchor.constraint(equalTo: topAnchor),
                emphasisBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

                iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconImageView.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
                iconImageView.widthAnchor.constraint(equalToConstant: ToolbarLayout.iconSize.width),
                iconImageView.heightAnchor.constraint(equalToConstant: ToolbarLayout.iconSize.height),

                badgeView.widthAnchor.constraint(equalToConstant: 11),
                badgeView.heightAnchor.constraint(equalToConstant: 11),
                badgeView.centerXAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 1),
                badgeView.centerYAnchor.constraint(equalTo: iconImageView.topAnchor, constant: 3),

                titleLabelView.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleLabelView.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 1.5),
                titleLabelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                titleLabelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            ])

            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .vertical)
        }

        override var intrinsicContentSize: CGSize {
            return ToolbarLayout.itemSize
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            emphasisGradient.frame = emphasisBackgroundView.bounds
            emphasisGradient.cornerRadius = emphasisBackgroundView.layer.cornerRadius
            emphasisBackgroundView.layer.shadowPath = UIBezierPath(
                roundedRect: emphasisBackgroundView.bounds,
                cornerRadius: emphasisBackgroundView.layer.cornerRadius
            ).cgPath
        }

        private static func roundedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
            return UIFont(descriptor: descriptor, size: size)
        }

        func set(image: UIImage?, title: String, tintColor: UIColor, isBadgeVisible: Bool = false, usesDimensionalIcon: Bool = false, showsEmphasisBackground: Bool = false) {
            self.baseImage = image
            self.customTintColor = tintColor
            self.isBadgeVisible = isBadgeVisible
            self.usesDimensionalIcon = usesDimensionalIcon
            emphasisBackgroundView.isHidden = !showsEmphasisBackground
            titleLabelView.text = title
            self.tintColor = tintColor
            updateColors()
        }

        private func updateColors() {
            let color = customTintColor ?? tintColor ?? .dashboardMutedInk
            if usesDimensionalIcon, let baseImage = baseImage {
                iconImageView.image = Self.dimensionalIcon(from: baseImage, color: color, traits: traitCollection)
            } else {
                iconImageView.image = baseImage?.withTintColor(color, renderingMode: .alwaysOriginal)
            }
            iconImageView.tintColor = color
            titleLabelView.textColor = color
            alpha = 1.0

            let isDark = traitCollection.userInterfaceStyle == .dark
            let coral = UIColor.dashboardCoral.resolvedColor(with: traitCollection)
            emphasisGradient.colors = [
                coral.withAlphaComponent(isDark ? 0.18 : 0.07).cgColor,
                coral.withAlphaComponent(isDark ? 0.30 : 0.18).cgColor
            ]
            emphasisBackgroundView.layer.borderColor = (isDark ? coral.withAlphaComponent(0.30) : UIColor.white.withAlphaComponent(0.75)).cgColor
            emphasisBackgroundView.layer.shadowColor = coral.cgColor
            emphasisBackgroundView.layer.shadowOpacity = isDark ? 0.12 : 0.16

            let borderColor = isDark ? UIColor.dashboardMutedInk : UIColor.dashboardCoral.withAlphaComponent(0.65)
            badgeView.layer.borderColor = borderColor.cgColor
            badgeView.backgroundColor = UIColor.dashboardCoral.withAlphaComponent(isDark ? 0.55 : 0.22)
        }

        private static func dimensionalIcon(from image: UIImage, color: UIColor, traits: UITraitCollection) -> UIImage {
            let canvasSize = ToolbarLayout.iconSize
            let symbol = image.applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: ToolbarLayout.symbolPointSize, weight: .medium)
            ) ?? image
            let scale = min(canvasSize.width / symbol.size.width, canvasSize.height / symbol.size.height)
            let symbolSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let symbolRect = CGRect(
                x: (canvasSize.width - symbolSize.width) / 2,
                y: (canvasSize.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )

            let resolvedColor = color.resolvedColor(with: traits)
            let highlightColor = blend(resolvedColor, with: .white, amount: 0.34)
            let shadowColor = blend(resolvedColor, with: .black, amount: 0.22)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = UIScreen.main.scale

            let gradientSymbol = UIGraphicsImageRenderer(size: canvasSize, format: format).image { rendererContext in
                symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: symbolRect)
                rendererContext.cgContext.setBlendMode(.sourceIn)

                let colors = [highlightColor.cgColor, resolvedColor.cgColor, shadowColor.cgColor] as CFArray
                let locations: [CGFloat] = [0, 0.52, 1]
                guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else {
                    return
                }
                rendererContext.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: canvasSize.width * 0.25, y: 0),
                    end: CGPoint(x: canvasSize.width * 0.75, y: canvasSize.height),
                    options: []
                )
            }

            return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in
                symbol.withTintColor(shadowColor.withAlphaComponent(0.38), renderingMode: .alwaysOriginal)
                    .draw(in: symbolRect.offsetBy(dx: 0.6, dy: 1.0))
                gradientSymbol.draw(at: .zero)
            }.withRenderingMode(.alwaysOriginal)
        }

        private static func blend(_ color: UIColor, with otherColor: UIColor, amount: CGFloat) -> UIColor {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            var otherRed: CGFloat = 0
            var otherGreen: CGFloat = 0
            var otherBlue: CGFloat = 0
            var otherAlpha: CGFloat = 0

            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                  otherColor.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: &otherAlpha)
            else {
                return color
            }

            return UIColor(
                red: red + (otherRed - red) * amount,
                green: green + (otherGreen - green) * amount,
                blue: blue + (otherBlue - blue) * amount,
                alpha: alpha + (otherAlpha - alpha) * amount
            )
        }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            updateColors()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateColors()
        }

        override var tintColor: UIColor! {
            didSet {
                updateColors()
            }
        }

        override var isEnabled: Bool {
            didSet {
                super.isEnabled = isEnabled
                updateColors()
            }
        }

        override var isHighlighted: Bool {
            didSet {
                super.isHighlighted = isHighlighted
                transform = isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
            }
        }
    }

    private lazy var carbEntryButton = makeToolbarButton(
        systemName: "fork.knife",
        title: NSLocalizedString("Add Carbs", comment: "The label of the carb entry button"),
        tintColor: .dashboardMutedInk,
        action: #selector(userTappedAddCarbs)
    )
    private lazy var bolusButton = makeToolbarButton(
        systemName: "drop.fill",
        title: NSLocalizedString("Bolus", comment: "The label of the bolus entry button"),
        tintColor: .dashboardCoral,
        usesDimensionalIcon: true,
        showsEmphasisBackground: true,
        action: #selector(presentBolusScreen)
    )
    private lazy var settingsButton = makeToolbarButton(
        systemName: "slider.horizontal.3",
        title: NSLocalizedString("Settings", comment: "The label of the settings button"),
        tintColor: .dashboardMutedInk,
        action: #selector(onSettingsTapped)
    )

    private lazy var preMealButton: ToolbarButton = {
        let button = ToolbarButton()
        button.addTarget(self, action: #selector(premealButtonTapped(_:)), for: .touchUpInside)
        return button
    }()

    private lazy var workoutButton: ToolbarButton = {
        let button = ToolbarButton()
        button.addTarget(self, action: #selector(toggleWorkoutMode(_:)), for: .touchUpInside)
        return button
    }()

    private func makeToolbarButton(image: UIImage?, title: String, tintColor: UIColor, action: Selector) -> ToolbarButton {
        let button = ToolbarButton()
        button.set(image: image, title: title, tintColor: tintColor)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeToolbarButton(systemName: String, title: String, tintColor: UIColor, usesDimensionalIcon: Bool = false, showsEmphasisBackground: Bool = false, action: Selector) -> ToolbarButton {
        let button = ToolbarButton()
        button.set(
            image: UIImage(systemName: systemName),
            title: title,
            tintColor: tintColor,
            usesDimensionalIcon: usesDimensionalIcon,
            showsEmphasisBackground: showsEmphasisBackground
        )
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// Position of the pre-meal item within `toolbarItems`, recorded at setup
    /// because it differs between the iOS 26 and legacy layouts.
    private var preMealItemIndex: Int = 1

    private enum DashboardAction: String, CaseIterable {
        case carbs, preMeal, bolus, workout, settings
    }

    private static let toolbarOrderKey = "DashboardToolbarOrder"
    private lazy var dashboardToolbarOrder: [DashboardAction] = {
        let saved = UserDefaults.standard.stringArray(forKey: Self.toolbarOrderKey) ?? []
        let ordered = saved.compactMap(DashboardAction.init(rawValue:)).reduce(into: [DashboardAction]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        return ordered + DashboardAction.allCases.filter { !ordered.contains($0) }
    }()
    private weak var draggedToolbarButton: ToolbarButton?
    private var toolbarDragSnapshot: UIView?
    private var toolbarDragOffset = CGPoint.zero
    private var toolbarReorderRecognizers: [UILongPressGestureRecognizer] = []

    private func toolbarButton(for action: DashboardAction) -> ToolbarButton {
        switch action {
        case .carbs: return carbEntryButton
        case .preMeal: return preMealButton
        case .bolus: return bolusButton
        case .workout: return workoutButton
        case .settings: return settingsButton
        }
    }

    private func installToolbarReordering() {
        guard toolbarReorderRecognizers.isEmpty else { return }
        for action in DashboardAction.allCases {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleToolbarLongPress(_:)))
            recognizer.minimumPressDuration = 0.35
            toolbarButton(for: action).addGestureRecognizer(recognizer)
            toolbarReorderRecognizers.append(recognizer)
        }
    }

    @objc private func handleToolbarLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let toolbar = navigationController?.toolbar else { return }
        let location = recognizer.location(in: toolbar)

        switch recognizer.state {
        case .began:
            guard let button = recognizer.view as? ToolbarButton,
                  let action = dashboardToolbarOrder.first(where: { toolbarButton(for: $0) === button }),
                  let snapshot = toolbarButton(for: action).snapshotView(afterScreenUpdates: false)
            else { return }
            snapshot.frame = button.convert(button.bounds, to: toolbar)
            snapshot.layer.shadowColor = UIColor.black.cgColor
            snapshot.layer.shadowOpacity = 0.2
            snapshot.layer.shadowRadius = 8
            toolbar.addSubview(snapshot)
            toolbarDragOffset = CGPoint(x: snapshot.center.x - location.x, y: snapshot.center.y - location.y)
            button.alpha = 0.25
            draggedToolbarButton = button
            toolbarDragSnapshot = snapshot
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            toolbarDragSnapshot?.center = CGPoint(x: location.x + toolbarDragOffset.x, y: location.y + toolbarDragOffset.y)
        case .ended:
            if let source = dashboardToolbarOrder.first(where: { toolbarButton(for: $0) === draggedToolbarButton }),
               let target = dashboardToolbarOrder.min(by: {
                   abs(toolbarButton(for: $0).convert(toolbarButton(for: $0).bounds, to: toolbar).midX - location.x) <
                   abs(toolbarButton(for: $1).convert(toolbarButton(for: $1).bounds, to: toolbar).midX - location.x)
               }),
               let sourceIndex = dashboardToolbarOrder.firstIndex(of: source),
               let targetIndex = dashboardToolbarOrder.firstIndex(of: target),
               sourceIndex != targetIndex
            {
                dashboardToolbarOrder.swapAt(sourceIndex, targetIndex)
                UserDefaults.standard.set(dashboardToolbarOrder.map(\.rawValue), forKey: Self.toolbarOrderKey)
                setupToolbarItems()
                updateToolbarItems()
            }
            fallthrough
        case .cancelled, .failed:
            draggedToolbarButton?.alpha = 1
            toolbarDragSnapshot?.removeFromSuperview()
            draggedToolbarButton = nil
            toolbarDragSnapshot = nil
        default:
            break
        }
    }

    private func setupToolbarItems() {
        let carbs = UIBarButtonItem(customView: carbEntryButton)
        let bolus = UIBarButtonItem(customView: bolusButton)
        let settings = UIBarButtonItem(customView: settingsButton)

        carbs.title = "Add Carbs"

        let preMeal = createPreMealButtonItem(selected: false, isEnabled: true)
        updateWorkoutButton(selected: false, isEnabled: true)
        let workout = UIBarButtonItem(customView: workoutButton)

        func flexibleSpace() -> UIBarButtonItem {
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        }

        let items: [DashboardAction: UIBarButtonItem] = [
            .carbs: carbs, .preMeal: preMeal, .bolus: bolus, .workout: workout, .settings: settings
        ]
        let orderedItems = dashboardToolbarOrder.compactMap { items[$0] }
        if #available(iOS 26, *) {
            toolbarItems = orderedItems
        } else {
            toolbarItems = orderedItems.enumerated().flatMap { index, item in
                index == 0 ? [item] : [flexibleSpace(), item]
            }
        }

        // The two layouts put pre-meal at different indices, so record where it
        // actually landed rather than hardcoding it.
        preMealItemIndex = toolbarItems?.firstIndex { $0 === preMeal } ?? 1
    }

    private func configureDashboardToolbarAppearance() {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .dashboardSurface
        appearance.shadowColor = .dashboardBorder
        navigationController?.toolbar.standardAppearance = appearance
        navigationController?.toolbar.scrollEdgeAppearance = appearance
        navigationController?.toolbar.tintColor = .dashboardCoral
    }

    private func updateToolbarItems() {
        let isPumpOnboarded = onboardingManager.isComplete || deviceManager.pumpManager?.isOnboarded == true

        carbEntryButton.accessibilityLabel = NSLocalizedString("Add Carbs", comment: "The label of the carb entry button")
        carbEntryButton.isEnabled = isPumpOnboarded
        bolusButton.accessibilityLabel = NSLocalizedString("Bolus", comment: "The label of the bolus entry button")
        bolusButton.isEnabled = true
        settingsButton.accessibilityLabel = NSLocalizedString("Settings", comment: "The label of the settings button")

        toolbarItems![preMealItemIndex] = createPreMealButtonItem(selected: preMealMode == true && preMealModeAllowed, isEnabled: preMealModeAllowed)
        updateWorkoutButton(selected: workoutMode == true && workoutModeAllowed, isEnabled: workoutModeAllowed)
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? = nil {
        didSet {
            if oldValue != basalDeliveryState {
                log.debug("New basalDeliveryState: %@", String(describing: basalDeliveryState))
                refreshContext.update(with: .status)
                reloadData(animated: true)
            }
        }
    }

    // Toggles the display mode based on the screen aspect ratio. Should not be updated outside of reloadData().
    private var landscapeMode = false

    private var lastLoopError: Error?

    private var reloading = false

    private var refreshContext = RefreshContext.all

    private var shouldShowHUD: Bool {
        return !landscapeMode
    }

    private var shouldShowStatus: Bool {
        return !landscapeMode && statusRowMode.hasRow
    }

    override func glucoseUnitDidChange() {
        log.debug("[reloadData] for HealthKit unit preference change")
        refreshContext = RefreshContext.all
    }

    // MARK: - Glucose Unit Toggle (US / Europe)

    private var glucoseUnitToastView: UIView?

    private func toggleGlucoseUnit() {
        guard let deviceManager = deviceManager else { return }

        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()

        let newUnit = deviceManager.toggleDisplayGlucoseUnit()

        showGlucoseUnitToast(unit: newUnit)

        unitPreferencesDidChange(to: newUnit)
        tableView.reloadData()
    }

    private func showGlucoseUnitToast(unit: HKUnit) {
        glucoseUnitToastView?.removeFromSuperview()

        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.backgroundColor = UIColor.dashboardInk.withAlphaComponent(0.90)
        toast.layer.cornerRadius = 18
        toast.layer.cornerCurve = .continuous
        toast.clipsToBounds = true

        let iconLabel = UILabel()
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.text = "💧"
        iconLabel.font = .systemFont(ofSize: 15)

        let textLabel = UILabel()
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        let unitText = unit == .millimolesPerLiter ? "mmol/L" : "mg/dL"
        textLabel.text = unitText
        textLabel.font = .dashboardRounded(ofSize: 15, weight: .bold)
        textLabel.textColor = .dashboardSurface

        let stack = UIStackView(arrangedSubviews: [iconLabel, textLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        toast.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toast.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -8)
        ])

        view.addSubview(toast)
        glucoseUnitToastView = toast

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])

        toast.alpha = 0
        toast.transform = CGAffineTransform(scaleX: 0.85, y: 0.85).translatedBy(x: 0, y: -10)

        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.curveEaseOut]) {
            toast.alpha = 1
            toast.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.2, options: [.curveEaseIn]) {
                toast.alpha = 0
                toast.transform = CGAffineTransform(scaleX: 0.9, y: 0.9).translatedBy(x: 0, y: -10)
            } completion: { _ in
                toast.removeFromSuperview()
                if self.glucoseUnitToastView === toast {
                    self.glucoseUnitToastView = nil
                }
            }
        }
    }
    
    private func registerCGMManager() {
        deviceManager.cgmManager?.removeStatusObserver(self)
        deviceManager.cgmManager?.addStatusObserver(self, queue: .main)
    }

    private func registerPumpManager() {
        basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState
        bolusState = deviceManager.pumpManager?.status.bolusState ?? .noBolus
        deviceManager.pumpManager?.removeStatusObserver(self)
        deviceManager.pumpManager?.addStatusObserver(self, queue: .main)
    }
    
    private lazy var statusCharts = StatusChartsManager(colors: .pastelDashboard, settings: .default, traitCollection: traitCollection)

    override func createChartsManager() -> ChartsManager {
        return statusCharts
    }

    private var selectedHistoryHours: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: "StatusChartsSelectedHistoryHours")
            return HistoryDurationSelectorControl.availableHours.contains(saved) ? saved : 3
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "StatusChartsSelectedHistoryHours")
        }
    }

    private func updateHistoryDuration(_ newHours: Int) {
        guard selectedHistoryHours != newHours else { return }
        selectedHistoryHours = newHours
        updateChartDateRange()
        refreshContext.formUnion(RefreshContext.all)
        reloadData()
    }

    private func updateChartDateRange() {
        let historyHours = Double(selectedHistoryHours)

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
        components.second = 0
        let now = calendar.date(from: components) ?? Date()

        let chartStartDate = now.addingTimeInterval(-TimeInterval(hours: historyHours))
        let chartEndDate = statusCharts.showsFutureData
            ? now.addingTimeInterval(TimeInterval(hours: 6))
            // Keep readings later in the current minute visible without
            // shifting the chart's axis on every refresh.
            : now.addingTimeInterval(.minutes(1))

        switch (statusCharts.showsFutureData, selectedHistoryHours) {
        case (false, 1):
            charts.xAxisHourStepOverride = 0.25
        case (false, 3):
            charts.xAxisHourStepOverride = 0.5
        case (false, 6):
            charts.xAxisHourStepOverride = 1
        case (false, 12):
            charts.xAxisHourStepOverride = 2
        case (false, 24):
            charts.xAxisHourStepOverride = 4
        default:
            charts.xAxisHourStepOverride = nil
        }

        if charts.startDate != chartStartDate {
            refreshContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.maxEndDate = chartEndDate
        charts.updateEndDate(chartEndDate)
    }

    private func toggleChartFutureData() {
        statusCharts.showsFutureData.toggle()
        updateChartDateRange()
        redrawCharts()
    }

    override func reloadData(animated: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard view.window != nil else {
            return
        }

        // This should be kept up to date immediately
        hudView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

        guard !reloading && !deviceManager.authorizationRequired else {
            return
        }

        updateChartDateRange()

        if case .bolusing = statusRowMode, bolusProgressReporter?.progress.isComplete == true {
            refreshContext.update(with: .status)
        }

        if visible && active {
            bolusProgressReporter?.addObserver(self)
        } else {
            bolusProgressReporter?.removeObserver(self)
        }

        guard active && visible && !refreshContext.isEmpty else {
            updateBannerRow(animated: animated)
            redrawCharts()
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var glucoseSamples: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var doseEntries: [DoseEntry]?
        var totalDelivery: Double?
        var cobValues: [CarbValue]?
        var carbsOnBoard: HKQuantity?
        let startDate = charts.startDate
        let basalDeliveryState = self.basalDeliveryState
        let automaticDosingEnabled = automaticDosingStatus.automaticDosingEnabled

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucoseIncludingPendingInsulin ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let lastLoopError = state.error

            // Net basal rate HUD
            let netBasal: NetBasal?
            if let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory {
                netBasal = basalDeliveryState?.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            } else {
                netBasal = nil
            }
            self.log.debug("Update net basal to %{public}@", String(describing: netBasal))

            DispatchQueue.main.async {
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.pumpStatusHUD.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)
                }
            }

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                self.deviceManager.carbStore.getCarbsOnBoardValues(start: startDate, end: nil, effectVelocities: state.insulinCounteractionEffects) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("CarbStore failed to get carbs on board values: %{public}@", String(describing: error))
                        retryContext.update(with: .carbs)
                        cobValues = []
                    case .success(let values):
                        cobValues = values
                    }
                    reloadGroup.leave()
                }
            }
            // always check for cob
            carbsOnBoard = state.carbsOnBoard?.quantity

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            deviceManager.glucoseStore.getGlucoseSamples(start: startDate, end: nil) { (result) -> Void in
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

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.doseStore.getInsulinOnBoardValues(start: startDate, end: nil, basalDosingEnd: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get insulin on board values: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                    iobValues = []
                case .success(let values):
                    iobValues = values
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.doseStore.getNormalizedDoseEntries(start: startDate, end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get normalized dose entries: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                    doseEntries = []
                case .success(let doses):
                    doseEntries = doses
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.doseStore.getTotalUnitsDelivered(since: Calendar.current.startOfDay(for: Date())) { (result) in
                switch result {
                case .failure:
                    retryContext.update(with: .insulin)
                    totalDelivery = nil
                case .success(let total):
                    totalDelivery = total.value
                }

                reloadGroup.leave()
            }
        }

        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)

        if deviceManager.loopManager.settings.preMealTargetRange == nil {
            preMealMode = nil
        } else {
            preMealMode = deviceManager.loopManager.settings.preMealTargetEnabled()
        }

        if !FeatureFlags.sensitivityOverridesEnabled, deviceManager.loopManager.settings.legacyWorkoutTargetRange == nil {
            workoutMode = nil
        } else {
            workoutMode = deviceManager.loopManager.settings.nonPreMealOverrideEnabled()
        }

        reloadGroup.notify(queue: .main) {
            /// Update the chart data

            // Glucose
            if let glucoseSamples = glucoseSamples {
                self.statusCharts.setGlucoseValues(glucoseSamples)
            }
            if (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled), let predictedGlucoseValues = predictedGlucoseValues {
                self.statusCharts.setPredictedGlucoseValues(predictedGlucoseValues)
            } else {
                self.statusCharts.setPredictedGlucoseValues([])
            }
            if !FeatureFlags.predictedGlucoseChartClampEnabled,
                let lastPoint = self.statusCharts.glucose.predictedGlucosePoints.last?.y
            {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                // if the predicted glucose values are clamped, the eventually glucose description should not be displayed, since it may not align with what is being charted.
                self.eventualGlucoseDescription = nil
            }
            if currentContext.contains(.targets) {
                self.statusCharts.targetGlucoseSchedule = self.deviceManager.loopManager.settings.glucoseTargetRangeSchedule
                self.statusCharts.preMealOverride = self.deviceManager.loopManager.settings.preMealOverride
                self.statusCharts.scheduleOverride = self.deviceManager.loopManager.settings.scheduleOverride
            }
            if self.statusCharts.scheduleOverride?.hasFinished() == true {
                self.statusCharts.scheduleOverride = nil
            }

            let charts = self.statusCharts

            // Active Insulin
            if let iobValues = iobValues {
                charts.setIOBValues(iobValues)
            }

            // Show the larger of the value either before or after the current date
            if let maxValue = charts.iob.iobPoints.allElementsAdjacent(to: Date()).max(by: {
                return $0.y.scalar < $1.y.scalar
            }) {
                self.currentIOBDescription = String(describing: maxValue.y)
            } else {
                self.currentIOBDescription = nil
            }

            // Insulin Delivery
            if let doseEntries = doseEntries {
                charts.setDoseEntries(doseEntries)
            }
            if let totalDelivery = totalDelivery {
                self.totalDelivery = totalDelivery
            }

            // Active Carbohydrates
            if let cobValues = cobValues {
                charts.setCOBValues(cobValues)
            }
            if let index = charts.cob.cobPoints.closestIndex(priorTo: Date()) {
                self.currentCOBDescription = String(describing: charts.cob.cobPoints[index].y)
            } else if let carbsOnBoard = carbsOnBoard {
                self.currentCOBDescription = self.carbFormatter.string(from: carbsOnBoard)
            } else {
                self.currentCOBDescription = nil
            }

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // CGM Status
                self.updateGlucoseTargetRangeHUD()
                self.updateLoopStatusHUD()
                if let glucose = self.deviceManager.glucoseStore.latestGlucose {
                    let unit = self.statusCharts.glucose.glucoseUnit
                    hudView.cgmStatusHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: unit),
                                                            at: glucose.startDate,
                                                            unit: unit,
                                                            staleGlucoseAge: LoopCoreConstants.inputDataRecencyInterval,
                                                            glucoseDisplay: self.deviceManager.glucoseDisplay(for: glucose),
                                                            wasUserEntered: glucose.wasUserEntered,
                                                            isDisplayOnly: glucose.isDisplayOnly)
                }
                hudView.cgmStatusHUD.presentStatusHighlight(self.deviceManager.cgmStatusHighlight)
                hudView.cgmStatusHUD.presentStatusBadge(self.deviceManager.cgmStatusBadge)
                hudView.cgmStatusHUD.lifecycleProgress = self.deviceManager.cgmLifecycleProgress

                // Pump Status
                hudView.pumpStatusHUD.presentStatusHighlight(self.deviceManager.pumpStatusHighlight)
                hudView.pumpStatusHUD.presentStatusBadge(self.deviceManager.pumpStatusBadge)
                hudView.pumpStatusHUD.lifecycleProgress = self.deviceManager.pumpLifecycleProgress
                hudView.setPumpExpiration(date: self.deviceManager.pumpExpiresAt)
            }

            // Show/hide the table view rows
            let statusRowMode = self.determineStatusRowMode()

            self.updateBannerAndHUDandStatusRows(statusRowMode: statusRowMode, newSize: currentContext.newSize, animated: animated)

            self.redrawCharts()

            self.tableView.endUpdates()

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.log.debug("[reloadData] due to context change during previous reload")
                self.reloadData()
            }
        }
    }

    private enum Section: Int, CaseIterable {
        case alertWarning
        case branding
        case hud
        case status
        case charts
    }

    // MARK: - Chart Section Data

    private enum ChartRow: Int, CaseIterable {
        case glucose
        case iob
        case cob
        case cycle
        case dose

        var accentColor: UIColor {
            switch self {
            case .glucose: return .dashboardGlucoseAccent
            case .iob, .dose: return .dashboardInsulinAccent
            case .cob: return .dashboardCarbAccent
            case .cycle: return .dashboardCycleAccent
            }
        }
    }

    private static let chartOrderKey = "DashboardChartOrder"
    private var chartReorderRecognizer: UILongPressGestureRecognizer?
    private final class ChartReorderGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var owner: StatusTableViewController?

        init(owner: StatusTableViewController) {
            self.owner = owner
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let owner else { return false }
            let location = touch.location(in: owner.tableView)
            if gestureRecognizer === owner.chartReorderRecognizer {
                return owner.canBeginChartReorder(at: location)
            }
            if gestureRecognizer === owner.charts.gestureRecognizer {
                return owner.canBeginChartTouch(at: location)
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
    private lazy var chartReorderGestureDelegate = ChartReorderGestureDelegate(owner: self)
    private var draggedChartIndexPath: IndexPath?
    private weak var draggedChartCell: UITableViewCell?
    private var chartDragSnapshot: UIView?
    private var chartDragOffset = CGPoint.zero
    private var chartWasScrollEnabled = true
    private weak var activeChartReorderRecognizer: UILongPressGestureRecognizer?
    private var chartAutoscrollDisplayLink: CADisplayLink?
    private lazy var chartOrder: [ChartRow] = {
        let saved = UserDefaults.standard.array(forKey: Self.chartOrderKey) as? [Int] ?? []
        let ordered = saved.compactMap(ChartRow.init(rawValue:)).reduce(into: [ChartRow]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        return ordered + ChartRow.allCases.filter { !ordered.contains($0) }
    }()

    private func chartRow(at indexPath: IndexPath) -> ChartRow {
        chartOrder[indexPath.row]
    }

    private func isCollapsedChartRow(_ row: ChartRow) -> Bool {
        collapsedChartRows.contains(row)
    }

    private func canBeginChartReorder(at location: CGPoint) -> Bool {
        guard let indexPath = tableView.indexPathForRow(at: location),
              indexPath.section == Section.charts.rawValue,
              isCollapsedChartRow(chartRow(at: indexPath)),
              tableView.cellForRow(at: indexPath) != nil
        else { return false }

        // A tap keeps its normal action; a hold anywhere on a collapsed card moves it.
        return true
    }

    private func canBeginChartTouch(at location: CGPoint) -> Bool {
        guard let indexPath = tableView.indexPathForRow(at: location),
              indexPath.section == Section.charts.rawValue,
              !isCollapsedChartRow(chartRow(at: indexPath)),
              let cell = tableView.cellForRow(at: indexPath) as? ChartTableViewCell
        else { return false }

        // The chart cursor belongs to the plot, never the card icon or header.
        return cell.convert(location, from: tableView).y > 48
    }

    @objc private func autoscrollChartDuringDrag() {
        guard let recognizer = activeChartReorderRecognizer,
              recognizer.state == .changed || recognizer.state == .began
        else { return }

        let location = recognizer.location(in: tableView)
        let visibleBounds = tableView.bounds
        let edgeHeight: CGFloat = 64
        let distanceFromTop = location.y - visibleBounds.minY
        let distanceFromBottom = visibleBounds.maxY - location.y
        let step: CGFloat
        if distanceFromTop < edgeHeight {
            step = -min(10, (edgeHeight - distanceFromTop) / 6)
        } else if distanceFromBottom < edgeHeight {
            step = min(10, (edgeHeight - distanceFromBottom) / 6)
        } else {
            step = 0
        }

        if step != 0 {
            let minimumOffset = -tableView.adjustedContentInset.top
            let maximumOffset = max(minimumOffset, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            let newOffset = min(max(tableView.contentOffset.y + step, minimumOffset), maximumOffset)
            tableView.contentOffset.y = newOffset
        }

        let updatedLocation = recognizer.location(in: tableView)
        chartDragSnapshot?.center = CGPoint(x: updatedLocation.x + chartDragOffset.x, y: updatedLocation.y + chartDragOffset.y)
    }

    @objc private func handleChartLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: tableView)
        switch recognizer.state {
        case .began:
            guard canBeginChartReorder(at: location),
                  let indexPath = tableView.indexPathForRow(at: location),
                  let cell = tableView.cellForRow(at: indexPath),
                  let snapshot = cell.snapshotView(afterScreenUpdates: false)
            else { return }
            snapshot.frame = cell.frame
            snapshot.layer.shadowColor = UIColor.black.cgColor
            snapshot.layer.shadowOpacity = 0.18
            snapshot.layer.shadowRadius = 12
            tableView.addSubview(snapshot)
            chartDragOffset = CGPoint(x: snapshot.center.x - location.x, y: snapshot.center.y - location.y)
            cell.alpha = 0.25
            draggedChartIndexPath = indexPath
            draggedChartCell = cell
            chartDragSnapshot = snapshot
            chartWasScrollEnabled = tableView.isScrollEnabled
            tableView.isScrollEnabled = false
            activeChartReorderRecognizer = recognizer
            let displayLink = CADisplayLink(target: self, selector: #selector(autoscrollChartDuringDrag))
            displayLink.add(to: .main, forMode: .common)
            chartAutoscrollDisplayLink = displayLink
            charts.gestureRecognizer?.isEnabled = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            chartDragSnapshot?.center = CGPoint(x: location.x + chartDragOffset.x, y: location.y + chartDragOffset.y)
        case .ended:
            if let source = draggedChartIndexPath,
               let target = tableView.indexPathForRow(at: location),
               target.section == Section.charts.rawValue,
               source.row != target.row
            {
                let row = chartOrder.remove(at: source.row)
                chartOrder.insert(row, at: target.row)
                UserDefaults.standard.set(chartOrder.map(\.rawValue), forKey: Self.chartOrderKey)
                draggedChartCell?.alpha = 1
                chartDragSnapshot?.removeFromSuperview()
                tableView.reloadSections(IndexSet(integer: Section.charts.rawValue), with: .automatic)
            }
            fallthrough
        case .cancelled, .failed:
            draggedChartCell?.alpha = 1
            chartDragSnapshot?.removeFromSuperview()
            draggedChartIndexPath = nil
            draggedChartCell = nil
            chartDragSnapshot = nil
            chartAutoscrollDisplayLink?.invalidate()
            chartAutoscrollDisplayLink = nil
            activeChartReorderRecognizer = nil
            tableView.isScrollEnabled = chartWasScrollEnabled
            charts.gestureRecognizer?.isEnabled = true
        default:
            break
        }
    }

    // Keep the primary glucose graph visible and present the supporting metrics as
    // compact summary cards, matching the hierarchy of the redesigned dashboard.
    private var collapsedChartRows: Set<ChartRow> = [.iob, .dose, .cob, .cycle]

    // MARK: Glucose

    private var eventualGlucoseDescription: String?

    // MARK: IOB

    private var currentIOBDescription: String?

    // MARK: Dose

    private var totalDelivery: Double?

    // MARK: COB

    private var currentCOBDescription: String?

    // MARK: - Loop Status Section Data

    private enum StatusRow: Int, CaseIterable {
        case status = 0
    }

    private enum StatusRowMode {
        case hidden
        case scheduleOverrideEnabled(TemporaryScheduleOverride)
        case enactingBolus
        case bolusing(dose: DoseEntry)
        case cancelingBolus
        case pumpSuspended(resuming: Bool)
        case onboardingSuspended
        case recommendManualGlucoseEntry

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden

    private func determineStatusRowMode() -> StatusRowMode {
        let statusRowMode: StatusRowMode

        if case .initiating = bolusState {
            statusRowMode = .enactingBolus
        } else if case .canceling = bolusState {
            statusRowMode = .cancelingBolus
        } else if case .suspended = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: false)
        } else if case .resuming = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: true)
        } else if case .inProgress(let dose) = bolusState, dose.endDate.timeIntervalSinceNow > 0 {
            statusRowMode = .bolusing(dose: dose)
        } else if !onboardingManager.isComplete, deviceManager.pumpManager?.isOnboarded == true {
            statusRowMode = .onboardingSuspended
        } else if onboardingManager.isComplete, deviceManager.isGlucoseValueStale {
            statusRowMode = .recommendManualGlucoseEntry
        } else if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride,
            !scheduleOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(scheduleOverride)
        } else if let premealOverride = deviceManager.loopManager.settings.preMealOverride,
            !premealOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(premealOverride)
        } else {
            statusRowMode = .hidden
        }

        return statusRowMode
    }

    private var shouldShowBannerWarning: Bool {
        alertPermissionsChecker.showWarning || alertMuter.configuration.shouldMute
    }

    private func updateBannerRow(animated: Bool) {
        let warningWasVisible = tableView.numberOfRows(inSection: Section.alertWarning.rawValue) != 0
        if !shouldShowBannerWarning && warningWasVisible {
            tableView.deleteRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else if shouldShowBannerWarning && !warningWasVisible {
            tableView.insertRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else {
            tableView.reloadRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: .none)
        }
    }

    private func updateBannerAndHUDandStatusRows(statusRowMode: StatusRowMode, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD
        let statusWasVisible = self.shouldShowStatus

        let oldStatusRowMode = self.statusRowMode

        self.statusRowMode = statusRowMode

        if let newSize = newSize {
            landscapeMode = newSize.width > newSize.height
        }

        let hudIsVisible = self.shouldShowHUD
        let statusIsVisible = self.shouldShowStatus

        hudView?.cgmStatusHUD?.isVisible = hudIsVisible

        tableView.beginUpdates()
        
        updateBannerRow(animated: animated)

        switch (hudWasVisible, hudIsVisible) {
        case (false, true):
            tableView.insertRows(at: [IndexPath(row: 0, section: Section.branding.rawValue)], with: animated ? .top : .none)
            tableView.insertRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        case (true, false):
            tableView.deleteRows(at: [IndexPath(row: 0, section: Section.branding.rawValue)], with: animated ? .top : .none)
            tableView.deleteRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: animated ? .top : .none)
        default:
            break
        }

        let statusIndexPath = IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)

        switch (statusWasVisible, statusIsVisible) {
        case (true, true):
            switch (oldStatusRowMode, self.statusRowMode) {
            case (.enactingBolus, .enactingBolus):
                break
            case (.bolusing(let oldDose), .bolusing(let newDose)):
                if oldDose.syncIdentifier != newDose.syncIdentifier {
                    tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            case (.pumpSuspended(resuming: let wasResuming), .pumpSuspended(resuming: let isResuming)):
                if isResuming != wasResuming {
                    tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
                }
            default:
                tableView.reloadRows(at: [statusIndexPath], with: animated ? .fade : .none)
            }
        case (false, true):
            tableView.insertRows(at: [statusIndexPath], with: animated ? .bottom : .none)
        case (true, false):
            tableView.deleteRows(at: [statusIndexPath], with: animated ? .top : .none)
        default:
            break
        }

        tableView.endUpdates()
    }

    private func redrawCharts() {
        tableView.beginUpdates()
        charts.prerender()
        for case let cell as ChartTableViewCell in tableView.visibleCells {
            cell.reloadChart()

            if let indexPath = tableView.indexPath(for: cell) {
                refreshChartCellPresentation(cell, at: indexPath)
            }
        }
        tableView.endUpdates()
    }

    // MARK: - Toolbar data

    private var preMealMode: Bool? = nil {
        didSet {
            guard oldValue != preMealMode else {
                return
            }
            updatePresetModeAvailability(automaticDosingEnabled: automaticDosingStatus.automaticDosingEnabled)
        }
    }
    private lazy var preMealModeAllowed: Bool = {
        onboardingManager.isComplete &&
                (automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
    }()

    private func updatePresetModeAvailability(automaticDosingEnabled: Bool) {
        preMealModeAllowed = onboardingManager.isComplete &&
                (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
        workoutModeAllowed = onboardingManager.isComplete && workoutMode != nil
        updateToolbarItems()
    }

    private var workoutMode: Bool? = nil {
        didSet {
            guard oldValue != workoutMode else {
                return
            }
            workoutModeAllowed = workoutMode != nil && onboardingManager.isComplete
            updateToolbarItems()
        }
    }
    private lazy var workoutModeAllowed: Bool = {
        workoutMode != nil && onboardingManager.isComplete
    }()

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .alertWarning:
            return shouldShowBannerWarning ? 1 : 0
        case .branding:
            return shouldShowHUD ? 1 : 0
        case .hud:
            return shouldShowHUD ? 1 : 0
        case .charts:
            return chartOrder.count
        case .status:
            return shouldShowStatus ? StatusRow.allCases.count : 0
        }
    }

    private final class DashboardGraphicTableViewCell: UITableViewCell {
        var onSensorTap: (() -> Void)?

        private let graphicImageView: UIImageView = {
            let imageView = UIImageView(image: UIImage(named: "DashboardHeaderGraphic"))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = false
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = NSLocalizedString("MichiLoop. My pancreas has WiFi.", comment: "Accessibility label for the dashboard header graphic")
            return imageView
        }()

        private lazy var sensorButton: UIButton = {
            let button = UIButton(type: .custom)
            button.backgroundColor = .clear
            button.accessibilityLabel = NSLocalizedString("Toggle glucose unit", comment: "Accessibility label for glucose unit toggle button on header graphic")
            button.accessibilityHint = NSLocalizedString("Switches glucose unit between US (mg/dL) and European (mmol/L) units", comment: "Accessibility hint for glucose unit toggle")
            button.addTarget(self, action: #selector(sensorButtonTapped), for: .touchUpInside)
            return button
        }()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        private func configureView() {
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            selectionStyle = .none
            contentView.addSubview(graphicImageView)
            contentView.addSubview(sensorButton)

            NSLayoutConstraint.activate([
                graphicImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                graphicImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
                graphicImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
                graphicImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let imageFrame = graphicImageView.frame
            // The Dexcom G7 sensor center is located at 66.7% width and 75.7% height
            let centerX = imageFrame.minX + imageFrame.width * 0.667
            let centerY = imageFrame.minY + imageFrame.height * 0.757
            let buttonSize = max(52, imageFrame.height * 0.44)
            sensorButton.frame = CGRect(
                x: centerX - buttonSize / 2,
                y: centerY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )
            sensorButton.layer.cornerRadius = buttonSize / 2
            contentView.bringSubviewToFront(sensorButton)
        }

        @objc private func sensorButtonTapped() {
            UIView.animate(withDuration: 0.08, animations: {
                self.sensorButton.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            }) { _ in
                UIView.animate(withDuration: 0.12) {
                    self.sensorButton.transform = .identity
                }
            }
            onSensorTap?()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            onSensorTap = nil
        }
    }

    private final class CycleProgressBarView: UIView {
        private let barContainer = UIView()
        private let trackGradientLayer = CAGradientLayer()
        private let fillContainer = UIView()
        private let fillGradientLayer = CAGradientLayer()

        private let periodLabel = UILabel()
        private let follicularLabel = UILabel()
        private let ovulationLabel = UILabel()
        private let lutealLabel = UILabel()

        private var progress: Double = 0.0
        private var transitions: [Double] = [5.0 / 28.0, 12.0 / 28.0, 15.0 / 28.0]

        override init(frame: CGRect) {
            super.init(frame: frame)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        private func configureView() {
            backgroundColor = .clear
            isAccessibilityElement = false

            barContainer.layer.cornerRadius = 7
            barContainer.layer.masksToBounds = true
            barContainer.layer.addSublayer(trackGradientLayer)
            barContainer.addSubview(fillContainer)

            fillContainer.layer.masksToBounds = true
            fillContainer.layer.addSublayer(fillGradientLayer)

            addSubview(barContainer)

            let labels = [periodLabel, follicularLabel, ovulationLabel, lutealLabel]
            for label in labels {
                label.font = .dashboardRounded(ofSize: 10, weight: .medium)
                label.textColor = .dashboardMutedInk
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.8
                addSubview(label)
            }

            periodLabel.text = NSLocalizedString("Period", comment: "Cycle phase progress label")
            follicularLabel.text = NSLocalizedString("Follicular", comment: "Cycle phase progress label")
            follicularLabel.textAlignment = .center
            ovulationLabel.text = NSLocalizedString("Ovulation", comment: "Cycle phase progress label")
            ovulationLabel.textAlignment = .center
            lutealLabel.text = NSLocalizedString("Luteal", comment: "Cycle phase progress label")
            lutealLabel.textAlignment = .right

            updateGradientLayers()
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: 34)
        }

        func configure(with summary: CycleTrackingStore.Summary) {
            self.progress = summary.progress
            if let t = summary.phaseTransitions, t.count == 3 {
                self.transitions = t
            } else {
                let length = Double(max(20, summary.cycleLength))
                let periodLength = 5.0
                let ovulationDay = max(10.0, length - 14.0)
                self.transitions = [
                    periodLength / length,
                    (ovulationDay - 2.0) / length,
                    (ovulationDay + 1.0) / length
                ]
            }
            updateGradientLayers()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let barWidth = bounds.width
            guard barWidth > 0 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            barContainer.frame = CGRect(x: 0, y: 0, width: barWidth, height: 14)
            trackGradientLayer.frame = barContainer.bounds

            let clampedProgress = CGFloat(max(0.0, min(1.0, progress)))
            let fillWidth = barWidth * clampedProgress
            fillContainer.frame = CGRect(x: 0, y: 0, width: fillWidth, height: 14)
            fillGradientLayer.frame = CGRect(x: 0, y: 0, width: barWidth, height: 14)

            CATransaction.commit()

            let labelY: CGFloat = 20
            let labelHeight: CGFloat = 14

            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let t0 = transitions.count > 0 ? transitions[0] : (5.0 / 28.0)
            let t1 = transitions.count > 1 ? transitions[1] : (12.0 / 28.0)
            let t2 = transitions.count > 2 ? transitions[2] : (15.0 / 28.0)

            let follicularFraction = (t0 + t1) / 2.0
            let ovulationFraction = (t1 + t2) / 2.0

            let follicularX = isRTL ? barWidth * CGFloat(1.0 - follicularFraction) : barWidth * CGFloat(follicularFraction)
            let ovulationX = isRTL ? barWidth * CGFloat(1.0 - ovulationFraction) : barWidth * CGFloat(ovulationFraction)

            let periodSize = periodLabel.intrinsicContentSize
            let lutealSize = lutealLabel.intrinsicContentSize
            let follicularSize = follicularLabel.intrinsicContentSize
            let ovulationSize = ovulationLabel.intrinsicContentSize

            if isRTL {
                periodLabel.frame = CGRect(x: barWidth - periodSize.width, y: labelY, width: periodSize.width, height: labelHeight)
                lutealLabel.frame = CGRect(x: 0, y: labelY, width: lutealSize.width, height: labelHeight)
            } else {
                periodLabel.frame = CGRect(x: 0, y: labelY, width: periodSize.width, height: labelHeight)
                lutealLabel.frame = CGRect(x: barWidth - lutealSize.width, y: labelY, width: lutealSize.width, height: labelHeight)
            }

            let minFollicularX = periodLabel.frame.maxX + 4
            let maxFollicularX = barWidth - lutealSize.width - follicularSize.width - 4
            let clampedFollicularX = max(minFollicularX, min(maxFollicularX, follicularX - follicularSize.width / 2))
            follicularLabel.frame = CGRect(
                x: clampedFollicularX,
                y: labelY,
                width: follicularSize.width,
                height: labelHeight
            )

            let minOvulationX = follicularLabel.frame.maxX + 4
            let maxOvulationX = barWidth - lutealSize.width - ovulationSize.width - 4
            let clampedOvulationX = max(minOvulationX, min(maxOvulationX, ovulationX - ovulationSize.width / 2))
            ovulationLabel.frame = CGRect(
                x: clampedOvulationX,
                y: labelY,
                width: ovulationSize.width,
                height: labelHeight
            )
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateGradientLayers()
        }

        func updateGradientLayers() {
            let isDark = traitCollection.userInterfaceStyle == .dark
            let trackAlpha: Float = isDark ? 0.20 : 0.13
            let fillAlpha: Float = isDark ? 0.90 : 0.86

            let periodColor = UIColor.dashboardPeriodProgress.resolvedColor(with: traitCollection)
            let follicularColor = UIColor.dashboardFollicularProgress.resolvedColor(with: traitCollection)
            let ovulationColor = UIColor.dashboardOvulationProgress.resolvedColor(with: traitCollection)
            let lutealColor = UIColor.dashboardLutealProgress.resolvedColor(with: traitCollection)

            let colors: [CGColor] = [
                periodColor.cgColor, periodColor.cgColor,
                follicularColor.cgColor, follicularColor.cgColor,
                ovulationColor.cgColor, ovulationColor.cgColor,
                lutealColor.cgColor, lutealColor.cgColor
            ]

            let t0Val = transitions.count > 0 ? transitions[0] : (5.0 / 28.0)
            let t1Val = transitions.count > 1 ? transitions[1] : (12.0 / 28.0)
            let t2Val = transitions.count > 2 ? transitions[2] : (15.0 / 28.0)

            let t0 = NSNumber(value: max(0.01, min(0.97, t0Val)))
            let t1 = NSNumber(value: max(t0.doubleValue + 0.01, min(0.98, t1Val)))
            let t2 = NSNumber(value: max(t1.doubleValue + 0.01, min(0.99, t2Val)))
            let locations: [NSNumber] = [0, t0, t0, t1, t1, t2, t2, 1]

            trackGradientLayer.colors = colors
            trackGradientLayer.locations = locations
            trackGradientLayer.opacity = trackAlpha
            trackGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
            trackGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)

            fillGradientLayer.colors = colors
            fillGradientLayer.locations = locations
            fillGradientLayer.opacity = fillAlpha
            fillGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
            fillGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)

            periodLabel.textColor = .dashboardMutedInk
            follicularLabel.textColor = .dashboardMutedInk
            ovulationLabel.textColor = .dashboardMutedInk
            lutealLabel.textColor = .dashboardMutedInk
        }
    }

    private final class CycleSummaryTableViewCell: UITableViewCell {
        var onHeaderTap: (() -> Void)?
        var onNavigate: (() -> Void)?

        private var isCollapsed: Bool = true

        private let cardView = UIView()
        private let iconBackgroundView = UIView()
        private let iconView = CalendarDropIconView()
        private let titleLabel = UILabel()
        private let detailLabel = UILabel()
        private lazy var textStack: UIStackView = {
            let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            return stack
        }()
        private let valueLabel = UILabel()
        private let chevronView = UIImageView()
        private let progressBarView = CycleProgressBarView()

        private lazy var headerButton: UIButton = {
            let button = UIButton(type: .custom)
            button.backgroundColor = .clear
            button.accessibilityLabel = NSLocalizedString("Expand or collapse cycle summary", comment: "Accessibility label for toggling cycle summary card")
            button.addTarget(self, action: #selector(headerButtonTapped), for: .touchUpInside)
            return button
        }()

        private lazy var navigationButton: UIButton = {
            let button = UIButton(type: .custom)
            button.backgroundColor = .clear
            button.accessibilityLabel = NSLocalizedString("Show Cycle Tracking Details", comment: "Accessibility label for opening cycle details")
            button.addTarget(self, action: #selector(navigationButtonTapped), for: .touchUpInside)
            return button
        }()

        private var collapsedConstraints: [NSLayoutConstraint] = []
        private var expandedConstraints: [NSLayoutConstraint] = []

        private final class CalendarDropIconView: UIView {
            private let calendarView = UIImageView(image: UIImage(systemName: "calendar"))
            private let badgeView = UIView()
            private let dropView = UIImageView(image: UIImage(systemName: "drop.fill"))

            override init(frame: CGRect) {
                super.init(frame: frame)
                configureView()
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                configureView()
            }

            private func configureView() {
                backgroundColor = .clear
                isAccessibilityElement = false

                [calendarView, badgeView, dropView].forEach {
                    $0.translatesAutoresizingMaskIntoConstraints = false
                }

                calendarView.contentMode = .scaleAspectFit
                calendarView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                addSubview(calendarView)

                badgeView.layer.cornerRadius = 8
                addSubview(badgeView)

                dropView.contentMode = .scaleAspectFit
                dropView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                badgeView.addSubview(dropView)

                NSLayoutConstraint.activate([
                    calendarView.topAnchor.constraint(equalTo: topAnchor),
                    calendarView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    calendarView.widthAnchor.constraint(equalToConstant: 24),
                    calendarView.heightAnchor.constraint(equalToConstant: 24),

                    badgeView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    badgeView.bottomAnchor.constraint(equalTo: bottomAnchor),
                    badgeView.widthAnchor.constraint(equalToConstant: 16),
                    badgeView.heightAnchor.constraint(equalTo: badgeView.widthAnchor),

                    dropView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
                    dropView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
                    dropView.widthAnchor.constraint(equalToConstant: 8),
                    dropView.heightAnchor.constraint(equalToConstant: 10)
                ])

                updateColors()
            }

            private func updateColors() {
                calendarView.tintColor = .dashboardCycleAccent
                badgeView.backgroundColor = .dashboardCycleAccent
                dropView.tintColor = .white
            }

            override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
                super.traitCollectionDidChange(previousTraitCollection)
                updateColors()
            }
        }

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            configureView()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureView()
        }

        private func configureView() {
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            selectionStyle = .none
            tintColor = .dashboardCycleAccent

            [cardView, iconBackgroundView, iconView, textStack, valueLabel, chevronView, progressBarView].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
            }

            cardView.backgroundColor = .dashboardSurface
            cardView.layer.cornerRadius = 16
            cardView.layer.cornerCurve = .continuous
            cardView.layer.borderWidth = 1
            contentView.addSubview(cardView)

            contentView.addSubview(headerButton)
            contentView.addSubview(navigationButton)

            iconBackgroundView.backgroundColor = UIColor.dashboardCycleAccent.withAlphaComponent(0.13)
            iconBackgroundView.layer.cornerRadius = 24
            cardView.addSubview(iconBackgroundView)

            iconBackgroundView.addSubview(iconView)

            titleLabel.text = NSLocalizedString("Cycle", comment: "Cycle summary card title").uppercased()
            titleLabel.font = .dashboardRounded(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .dashboardInk
            titleLabel.adjustsFontSizeToFitWidth = true
            titleLabel.minimumScaleFactor = 0.8

            detailLabel.font = .dashboardRounded(ofSize: 12, weight: .regular)
            detailLabel.textColor = .dashboardMutedInk
            detailLabel.adjustsFontSizeToFitWidth = true
            detailLabel.minimumScaleFactor = 0.8

            cardView.addSubview(textStack)

            valueLabel.font = .dashboardRoundedDigits(ofSize: 20, weight: .bold)
            valueLabel.textColor = .dashboardCycleAccent
            valueLabel.textAlignment = .right
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            cardView.addSubview(valueLabel)

            chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            chevronView.tintColor = .dashboardCycleAccent
            chevronView.contentMode = .scaleAspectFit
            cardView.addSubview(chevronView)

            cardView.addSubview(progressBarView)

            NSLayoutConstraint.activate([
                cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
                cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
                cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
                cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

                iconBackgroundView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
                iconBackgroundView.widthAnchor.constraint(equalToConstant: 48),
                iconBackgroundView.heightAnchor.constraint(equalTo: iconBackgroundView.widthAnchor),

                iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28),

                textStack.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 14),
                textStack.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -10),

                chevronView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
                chevronView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
                chevronView.widthAnchor.constraint(equalToConstant: 10),

                valueLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12),
                valueLabel.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor)
            ])

            collapsedConstraints = [
                iconBackgroundView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor)
            ]

            expandedConstraints = [
                iconBackgroundView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
                progressBarView.topAnchor.constraint(equalTo: iconBackgroundView.bottomAnchor, constant: 14),
                progressBarView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
                progressBarView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
                progressBarView.heightAnchor.constraint(equalToConstant: 34),
                progressBarView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14)
            ]

            NSLayoutConstraint.activate(collapsedConstraints)
            progressBarView.isHidden = true

            updateColors()
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let visualFrame = valueLabel.frame.union(chevronView.frame)
                .insetBy(dx: -12, dy: -12)
                .intersection(contentView.bounds)

            let minimumWidth: CGFloat = 132
            let leading = max(contentView.bounds.midX, min(visualFrame.minX, contentView.bounds.maxX - minimumWidth))
            let headerHeight: CGFloat = isCollapsed ? contentView.bounds.height : 68

            navigationButton.frame = CGRect(
                x: leading,
                y: 0,
                width: contentView.bounds.maxX - leading,
                height: headerHeight
            )
            navigationButton.isHidden = navigationButton.frame.isEmpty

            headerButton.frame = CGRect(
                x: 0,
                y: 0,
                width: leading,
                height: headerHeight
            )
            headerButton.isHidden = headerButton.frame.isEmpty

            contentView.bringSubviewToFront(headerButton)
            contentView.bringSubviewToFront(navigationButton)
        }

        @objc private func headerButtonTapped() {
            onHeaderTap?()
        }

        @objc private func navigationButtonTapped() {
            onNavigate?()
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            onHeaderTap = nil
            onNavigate = nil
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateColors()
        }

        private func updateColors() {
            cardView.backgroundColor = .dashboardSurface
            cardView.layer.borderColor = UIColor.dashboardBorder.resolvedColor(with: traitCollection).cgColor
            titleLabel.textColor = .dashboardInk
            detailLabel.textColor = .dashboardMutedInk
            valueLabel.textColor = .dashboardCycleAccent
            chevronView.tintColor = .dashboardCycleAccent
            iconBackgroundView.backgroundColor = UIColor.dashboardCycleAccent.withAlphaComponent(0.13)
            progressBarView.updateGradientLayers()
        }

        func configure(with summary: CycleTrackingStore.Summary, isCollapsed: Bool = true) {
            self.isCollapsed = isCollapsed

            titleLabel.text = summary.detail.uppercased()
            detailLabel.text = summary.nextPhaseDetail
            valueLabel.text = summary.cycleDay.map { day in
                day > summary.cycleLength ? "\(day) days" : "\(day) / \(summary.cycleLength)"
            } ?? "— / \(summary.cycleLength)"
            accessibilityLabel = [titleLabel.text, detailLabel.text, valueLabel.text]
                .compactMap { $0 }
                .joined(separator: ", ")

            if isCollapsed {
                NSLayoutConstraint.deactivate(expandedConstraints)
                NSLayoutConstraint.activate(collapsedConstraints)
                progressBarView.isHidden = true
            } else {
                NSLayoutConstraint.deactivate(collapsedConstraints)
                NSLayoutConstraint.activate(expandedConstraints)
                progressBarView.isHidden = false
                progressBarView.configure(with: summary)
            }

            updateColors()
            setNeedsLayout()
        }
    }

    private final class CycleHostingController: UIHostingController<CycleTrackingView> {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)

            navigationController?.setNavigationBarHidden(false, animated: animated)
            navigationController?.setToolbarHidden(true, animated: animated)
            configureDashboardNavigationAppearance()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)

            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                configureDashboardNavigationAppearance()
            }
        }

        private func configureDashboardNavigationAppearance() {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .dashboardSurface
            appearance.shadowColor = .dashboardBorder
            appearance.titleTextAttributes = [
                .font: UIFont.dashboardRounded(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.dashboardInk
            ]

            navigationController?.navigationBar.standardAppearance = appearance
            navigationController?.navigationBar.scrollEdgeAppearance = appearance
            navigationController?.navigationBar.compactAppearance = appearance
            navigationController?.navigationBar.tintColor = .dashboardCoral
        }
    }

    private class AlertPermissionsDisabledWarningCell: UITableViewCell {
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let titleImageAttachment = NSTextAttachment()
            titleImageAttachment.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.white)
            let title = NSMutableAttributedString(string: NSLocalizedString(" Safety Notifications are OFF", comment: "Warning text for when Notifications or Critical Alerts Permissions is disabled"))
            let titleWithImage = NSMutableAttributedString(attachment: titleImageAttachment)
            titleWithImage.append(title)
            contentConfig.attributedText = titleWithImage
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .bold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = NSLocalizedString("Fix now by turning Notifications, Critical Alerts and Time Sensitive Notifications ON.", comment: "Secondary text for alerts disabled warning, which appears on the main status screen.")
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.backgroundColor = .critical
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 10)
            backgroundConfiguration?.cornerRadius = 10

            let disclosureIndicator = UIImage(systemName: "chevron.right")?.withTintColor(.white)
            let imageView = UIImageView(image: disclosureIndicator)
            imageView.tintColor = .white
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }

    private class MuteAlertsWarningCell: UITableViewCell {
        var formattedAlertMuteEndTime: String = NSLocalizedString("Unknown", comment: "label for when the alert mute end time is unknown")

        fileprivate class GradientView: UIView {
            override static var layerClass: AnyClass { CAGradientLayer.self }
        }
        
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let title = NSMutableAttributedString(string: NSLocalizedString("All Alerts Muted", comment: "Warning text for when alerts are muted"))
            let image = UIImage(systemName: "speaker.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .thin, scale: .large))
            contentConfig.image = image
            contentConfig.imageProperties.tintColor = .white
            contentConfig.attributedText = title
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .semibold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = String(format: NSLocalizedString("Until %1$@", comment: "indication of when alerts will be unmuted (1: time when alerts unmute)"), formattedAlertMuteEndTime)
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            let backgroundGradient = GradientView()
            (backgroundGradient.layer as? CAGradientLayer)?.colors = [UIColor.warning.cgColor, UIColor.warning.withAlphaComponent(0.9).cgColor]
            
            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.customView = backgroundGradient
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 5, trailing: 5)
            backgroundConfiguration?.cornerRadius = 10

            let unmuteIndicator = UIImage(systemName: "stop.circle")?.withTintColor(.white)
            let imageView = UIImageView(image: unmuteIndicator)
            imageView.tintColor = .white
            imageView.frame.size = CGSize(width: 30, height: 30)
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                let cell = tableView.dequeueReusableCell(withIdentifier: AlertPermissionsDisabledWarningCell.className, for: indexPath) as! AlertPermissionsDisabledWarningCell
                return cell
            } else {
                let cell = tableView.dequeueReusableCell(withIdentifier: MuteAlertsWarningCell.className, for: indexPath) as! MuteAlertsWarningCell
                cell.formattedAlertMuteEndTime = alertMuter.formattedEndTime
                cell.selectionStyle = .none
                return cell
            }
        case .branding:
            let cell = tableView.dequeueReusableCell(withIdentifier: DashboardGraphicTableViewCell.className, for: indexPath) as! DashboardGraphicTableViewCell
            cell.onSensorTap = { [weak self] in
                self?.toggleGlucoseUnit()
            }
            return cell
        case .hud:
            let cell = tableView.dequeueReusableCell(withIdentifier: HUDViewTableViewCell.className, for: indexPath) as! HUDViewTableViewCell
            hudView = cell.hudView

            return cell
        case .charts:
            let chartRow = chartRow(at: indexPath)

            if chartRow == .cycle {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: CycleSummaryTableViewCell.className,
                    for: indexPath
                ) as! CycleSummaryTableViewCell
                cell.configure(
                    with: CycleTrackingStore.shared.summary(),
                    isCollapsed: isCollapsedChartRow(.cycle)
                )
                cell.onHeaderTap = { [weak self, weak tableView] in
                    guard let self, let tableView else { return }
                    if self.collapsedChartRows.contains(.cycle) {
                        self.collapsedChartRows.remove(.cycle)
                    } else {
                        self.collapsedChartRows.insert(.cycle)
                    }
                    guard let rowIndex = self.chartOrder.firstIndex(of: .cycle) else { return }
                    tableView.reloadRows(at: [IndexPath(row: rowIndex, section: Section.charts.rawValue)], with: .automatic)
                }
                cell.onNavigate = { [weak self, weak cell] in
                    self?.navigateToDetails(for: .cycle, sender: cell)
                }
                return cell
            }

            let cell = tableView.dequeueReusableCell(withIdentifier: ChartTableViewCell.className, for: indexPath) as! ChartTableViewCell
            cell.dashboardCardAccentColor = chartRow.accentColor

            switch chartRow {
            case .glucose:
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.glucoseChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph"))
                cell.doesNavigate = automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled
                cell.configureHistoryDurationSelector(selectedHours: self.selectedHistoryHours) { [weak self] newHours in
                    self?.updateHistoryDuration(newHours)
                }
            case .iob:
                cell.hideHistoryDurationSelector()
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.iobChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph"))
            case .dose:
                cell.hideHistoryDurationSelector()
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.doseChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Insulin Delivery", comment: "The title of the insulin delivery graph"))
            case .cob:
                cell.hideHistoryDurationSelector()
                cell.setChartGenerator(generator: { [weak self] (frame) in
                    return self?.statusCharts.cobChart(withFrame: frame)?.view
                })
                cell.setTitleLabelText(label: NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board graph"))
            case .cycle:
                assertionFailure("Cycle uses CycleSummaryTableViewCell")
            }

            cell.onNavigate = { [weak self, weak cell] in
                self?.navigateToDetails(for: chartRow, sender: cell)
            }
            cell.onPlotTap = { [weak self] in
                self?.toggleChartFutureData()
            }
            cell.onHeaderTap = { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                if self.collapsedChartRows.contains(chartRow) {
                    self.collapsedChartRows.remove(chartRow)
                } else {
                    self.collapsedChartRows.insert(chartRow)
                }
                guard let rowIndex = self.chartOrder.firstIndex(of: chartRow) else { return }
                tableView.reloadRows(at: [IndexPath(row: rowIndex, section: Section.charts.rawValue)], with: .automatic)
            }

            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)

            if collapsedChartRows.contains(chartRow) {
                configureCollapsedSummary(cell, for: chartRow)
            } else {
                cell.setExpandedAppearance()
            }

            let alpha: CGFloat = charts.gestureRecognizer?.state == .possible ? 1 : 0
            cell.setAlpha(alpha: alpha)

            return cell
        case .status:

            func getTitleSubtitleCell() -> TitleSubtitleTableViewCell {
                let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
                cell.selectionStyle = .none
                cell.backgroundColor = .dashboardSurface
                cell.titleLabel.font = .dashboardRounded(ofSize: 15, weight: .semibold)
                cell.titleLabel.textColor = .dashboardInk
                cell.subtitleLabel.font = .dashboardRounded(ofSize: 13, weight: .regular)
                cell.subtitleLabel.textColor = .dashboardMutedInk
                cell.titleLabel.text = nil
                cell.subtitleLabel.text = nil
                cell.accessoryView = nil
                return cell
            }

            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                switch statusRowMode {
                case .hidden:
                    let cell = getTitleSubtitleCell()
                    return cell
                case .scheduleOverrideEnabled(let override):
                    let cell = getTitleSubtitleCell()
                    switch override.context {
                    case .preMeal:
                        let symbolAttachment = NSTextAttachment()
                        symbolAttachment.image = UIImage(named: "Pre-Meal-symbol")?.withTintColor(.dashboardCoral)

                        let attributedString = NSMutableAttributedString(attachment: symbolAttachment)
                        attributedString.append(NSAttributedString(string: NSLocalizedString(" Pre-meal Preset", comment: "Status row title for premeal override enabled (leading space is to separate from symbol)")))
                        cell.titleLabel.attributedText = attributedString
                    case .legacyWorkout:
                        let symbolAttachment = NSTextAttachment()
                        symbolAttachment.image = UIImage(named: "workout-symbol")?.withTintColor(.dashboardCoral)

                        let attributedString = NSMutableAttributedString(attachment: symbolAttachment)
                        attributedString.append(NSAttributedString(string: NSLocalizedString(" Workout Preset", comment: "Status row title for workout override enabled (leading space is to separate from symbol)")))
                        cell.titleLabel.attributedText = attributedString
                    case .preset(let preset):
                        cell.titleLabel.text = String(format: NSLocalizedString("%@ %@", comment: "The format for an active custom preset. (1: preset symbol)(2: preset name)"), preset.symbol, preset.name)
                    case .custom:
                        cell.titleLabel.text = NSLocalizedString("Custom Preset", comment: "The title of the cell indicating a generic custom preset is enabled")
                    }

                    if override.isActive() {
                        switch override.duration {
                        case .finite:
                            let endTimeText = DateFormatter.localizedString(from: override.activeInterval.end, dateStyle: .none, timeStyle: .short)
                            cell.subtitleLabel.text = String(format: NSLocalizedString("until %@", comment: "The format for the description of a custom preset end date"), endTimeText)
                        case .indefinite:
                            cell.subtitleLabel.text = nil
                        }
                    } else {
                        let startTimeText = DateFormatter.localizedString(from: override.startDate, dateStyle: .none, timeStyle: .short)
                        cell.subtitleLabel.text = String(format: NSLocalizedString("starting at %@", comment: "The format for the description of a custom preset start date"), startTimeText)
                    }

                    return cell
                case .enactingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent")

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .bolusing(let dose):
                    let progressCell = tableView.dequeueReusableCell(withIdentifier: BolusProgressTableViewCell.className, for: indexPath) as! BolusProgressTableViewCell
                    progressCell.selectionStyle = .none
                    progressCell.totalUnits = dose.programmedUnits
                    progressCell.tintColor = .dashboardInsulinAccent
                    progressCell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
                    progressCell.backgroundColor = .dashboardSurface
                    return progressCell
                case .cancelingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Canceling Bolus", comment: "The title of the cell indicating a bolus is being canceled")

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .pumpSuspended(let resuming):
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Insulin Suspended", comment: "The title of the cell indicating the pump is suspended")

                    if resuming {
                        let indicatorView = UIActivityIndicatorView(style: .default)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume insulin delivery")
                    }
                    cell.selectionStyle = .default
                    return cell
                case .onboardingSuspended:
                    let cell = tableView.dequeueReusableCell(withIdentifier: IconTitleSubtitleTableViewCell.className, for: indexPath) as! IconTitleSubtitleTableViewCell
                    cell.selectionStyle = .default
                    cell.backgroundColor = .dashboardSurface
                    cell.iconImageView.image = UIImage(systemName: "exclamationmark.circle.fill")
                    cell.iconImageView.tintColor = .warning
                    cell.iconImageView.contentMode = .scaleAspectFit
                    cell.iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28)
                    cell.titleLabel.text = NSLocalizedString("Setup Incomplete", comment: "The title of the cell indicating that onboarding is suspended")
                    cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume onboarding")
                    cell.accessoryView = nil
                    return cell
                case .recommendManualGlucoseEntry:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("No Recent Glucose", comment: "The title of the cell indicating that there is no recent glucose")
                    cell.subtitleLabel.text = NSLocalizedString("Tap to Add", comment: "The subtitle of the cell displaying an action to add a manually measurement glucose value")
                    cell.selectionStyle = .default
                    let imageView = UIImageView(image: UIImage(named: "drop.circle"))
                    imageView.tintColor = .dashboardGlucoseAccent
                    cell.accessoryView = imageView
                    return cell
                }
            }
        }
    }

    private func navigateToDetails(for row: ChartRow, sender: Any?) {
        switch row {
        case .glucose:
            guard automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled else {
                return
            }
            performSegue(withIdentifier: PredictionTableViewController.className, sender: sender)
        case .iob, .dose:
            performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: sender)
        case .cob:
            performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: sender)
        case .cycle:
            let view = CycleTrackingView { [weak self] in
                guard let self else { return }
                guard let rowIndex = self.chartOrder.firstIndex(of: .cycle) else { return }
                let indexPath = IndexPath(row: rowIndex, section: Section.charts.rawValue)
                if self.tableView.indexPathsForVisibleRows?.contains(indexPath) == true {
                    self.tableView.reloadRows(at: [indexPath], with: .none)
                }
            }
            let controller = CycleHostingController(rootView: view)
            controller.title = NSLocalizedString("Cycle", comment: "Cycle tracker navigation title")
            controller.hidesBottomBarWhenPushed = true
            show(controller, sender: sender)
        }
    }

    private func configureCollapsedSummary(_ cell: ChartTableViewCell, for row: ChartRow) {
        switch row {
        case .glucose:
            cell.setCollapsedAppearance(
                iconSystemName: "drop.fill",
                title: NSLocalizedString("Glucose", comment: "The title of the glucose summary card"),
                detail: NSLocalizedString("Eventually", comment: "The subtitle of the glucose summary card"),
                value: eventualGlucoseDescription,
                tintColor: row.accentColor
            )
        case .iob:
            cell.setCollapsedAppearance(
                iconSystemName: "drop",
                title: NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board summary card"),
                detail: NSLocalizedString("On board (IOB)", comment: "The subtitle of the Insulin On-Board summary card"),
                value: currentIOBDescription,
                tintColor: row.accentColor
            )
        case .dose:
            let value = totalDelivery.map { String(format: NSLocalizedString("%.0f U", comment: "Compact total insulin delivered value"), $0) }
            cell.setCollapsedAppearance(
                iconSystemName: "syringe",
                title: NSLocalizedString("Insulin Delivered", comment: "The title of the insulin delivery summary card"),
                detail: NSLocalizedString("Total today", comment: "The subtitle of the insulin delivery summary card"),
                value: value,
                tintColor: row.accentColor
            )
        case .cob:
            cell.setCollapsedAppearance(
                iconSystemName: "fork.knife",
                title: NSLocalizedString("Active Carbohydrates", comment: "The title of the Carbs On-Board summary card"),
                detail: NSLocalizedString("On board", comment: "The subtitle of the Carbs On-Board summary card"),
                value: currentCOBDescription,
                tintColor: row.accentColor
            )
        case .cycle:
            break
        }
    }

    private func refreshChartCellPresentation(_ cell: ChartTableViewCell, at indexPath: IndexPath) {
        self.tableView(self.tableView, updateSubtitleFor: cell, at: indexPath)

        let row = chartRow(at: indexPath)
        if collapsedChartRows.contains(row) {
            configureCollapsedSummary(cell, for: row)
        } else {
            cell.setExpandedAppearance()
        }
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .charts:
            let chartRow = chartRow(at: indexPath)
            switch chartRow {
            case .glucose:
                if let eventualGlucose = eventualGlucoseDescription {
                    let fullText = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
                    let attrString = NSMutableAttributedString(
                        string: fullText,
                        attributes: [
                            .font: UIFont.dashboardRounded(ofSize: 12, weight: .medium),
                            .foregroundColor: UIColor.dashboardMutedInk
                        ]
                    )
                    if let range = fullText.range(of: eventualGlucose) {
                        let nsRange = NSRange(range, in: fullText)
                        attrString.addAttributes([
                            .font: UIFont.dashboardRoundedDigits(ofSize: 13, weight: .bold),
                            .foregroundColor: chartRow.accentColor
                        ], range: nsRange)
                    }
                    cell.setAttributedSubtitleLabel(attrString)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
                cell.doesNavigate = automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled
            case .iob:
                if let currentIOB = currentIOBDescription {
                    let attrString = NSAttributedString(
                        string: currentIOB,
                        attributes: [
                            .font: UIFont.dashboardRoundedDigits(ofSize: 13, weight: .bold),
                            .foregroundColor: chartRow.accentColor
                        ]
                    )
                    cell.setAttributedSubtitleLabel(attrString)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            case .dose:
                let integerFormatter = NumberFormatter()
                integerFormatter.maximumFractionDigits = 0

                if  let total = totalDelivery,
                    let totalString = integerFormatter.string(from: total) {
                    let valueText = "\(totalString) U"
                    let fullText = String(format: NSLocalizedString("%@ Total", comment: "The subtitle format describing total insulin. (1: localized insulin total)"), valueText)
                    let attrString = NSMutableAttributedString(
                        string: fullText,
                        attributes: [
                            .font: UIFont.dashboardRounded(ofSize: 12, weight: .medium),
                            .foregroundColor: UIColor.dashboardMutedInk
                        ]
                    )
                    if let range = fullText.range(of: valueText) {
                        let nsRange = NSRange(range, in: fullText)
                        attrString.addAttributes([
                            .font: UIFont.dashboardRoundedDigits(ofSize: 13, weight: .bold),
                            .foregroundColor: chartRow.accentColor
                        ], range: nsRange)
                    }
                    cell.setAttributedSubtitleLabel(attrString)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            case .cob:
                if let currentCOB = currentCOBDescription {
                    let attrString = NSAttributedString(
                        string: currentCOB,
                        attributes: [
                            .font: UIFont.dashboardRoundedDigits(ofSize: 13, weight: .bold),
                            .foregroundColor: chartRow.accentColor
                        ]
                    )
                    cell.setAttributedSubtitleLabel(attrString)
                } else {
                    cell.setSubtitleLabel(label: nil)
                }
            case .cycle:
                break
            }
        case .branding, .hud, .status, .alertWarning:
            break
        }
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section)! {
        case .branding:
            let availableWidth = max(0, tableView.bounds.width - 20)
            let graphicAspectRatio: CGFloat = 705 / 1919
            return ceil(availableWidth * graphicAspectRatio)
        case .charts:
            if isCollapsedChartRow(chartRow(at: indexPath)) {
                return 74
            }

            // Compute the height of the HUD, defaulting to 70
            let hudHeight = ceil(hudView?.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height ?? 74)
            var availableSize = max(tableView.bounds.width, tableView.bounds.height)
            availableSize -= (tableView.safeAreaInsets.top + tableView.safeAreaInsets.bottom + hudHeight)

            switch chartRow(at: indexPath) {
            case .glucose:
                return max(150, 0.38 * availableSize)
            case .iob, .dose, .cob:
                return max(115, 0.22 * availableSize)
            case .cycle:
                return 134
            }
        case .hud, .status, .alertWarning:
            return UITableView.automaticDimension
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                tableView.deselectRow(at: indexPath, animated: true)
                AlertPermissionsChecker.gotoSettings()
            } else {
                tableView.deselectRow(at: indexPath, animated: true)
                presentUnmuteAlertConfirmation()
            }
        case .branding, .hud:
            break
        case .status:
            switch StatusRow(rawValue: indexPath.row)! {
            case .status:
                tableView.deselectRow(at: indexPath, animated: true)

                switch statusRowMode {
                case .pumpSuspended(let resuming) where !resuming:
                    updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: true) , newSize: nil, animated: true)
                    deviceManager.pumpManager?.resumeDelivery() { (error) in
                        DispatchQueue.main.async {
                            if let error = error {
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Failed to Resume Insulin Delivery", comment: "The alert title for a resume error"))
                                self.present(alert, animated: true, completion: nil)
                                if case .suspended = self.basalDeliveryState {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: false), newSize: nil, animated: true)
                                }
                            } else {
                                self.updateBannerAndHUDandStatusRows(statusRowMode: self.determineStatusRowMode(), newSize: nil, animated: true)
                                self.refreshContext.update(with: .insulin)
                                self.log.debug("[reloadData] after manually resuming suspend")
                                self.reloadData()
                            }
                        }
                    }
                case .scheduleOverrideEnabled(let override):
                    switch override.context {
                    case .preMeal, .legacyWorkout:
                        break
                    default:
                        let vc = AddEditOverrideTableViewController(glucoseUnit: statusCharts.glucose.glucoseUnit)
                        vc.inputMode = .editOverride(override)
                        vc.delegate = self
                        show(vc, sender: tableView.cellForRow(at: indexPath))
                    }
                case .bolusing:
                    updateBannerAndHUDandStatusRows(statusRowMode: .cancelingBolus, newSize: nil, animated: true)
                    deviceManager.pumpManager?.cancelBolus() { (result) in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                // show user confirmation and actual delivery amount?
                                break
                            case .failure(let error):
                                self.presentErrorCancelingBolus(error)
                                if case .inProgress(let dose) = self.bolusState {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .bolusing(dose: dose), newSize: nil, animated: true)
                                } else {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                                }
                            }
                        }
                    }
                case .onboardingSuspended:
                    onboardingManager.resume()
                case .recommendManualGlucoseEntry:
                    presentBolusEntryView(enableManualGlucoseEntry: true)
                default:
                    break
                }
            }
        case .charts:
            if chartRow(at: indexPath) == .cycle {
                tableView.deselectRow(at: indexPath, animated: true)
                navigateToDetails(for: .cycle, sender: tableView.cellForRow(at: indexPath))
            }
        }
    }

    private func presentUnmuteAlertConfirmation() {
        let title = NSLocalizedString("Unmute Alerts?", comment: "The alert title for unmute alert confirmation")
        let body = NSLocalizedString("Tap Unmute to resume sound for your alerts and alarms.", comment: "The alert body for unmute alert confirmation")
        let action = UIAlertAction(
            title: NSLocalizedString("Unmute", comment: "The title of the action used to unmute alerts"),
            style: .default) { _ in
                self.alertMuter.unmuteAlerts()
            }
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        alert.addCancelAction { _ in }
        present(alert, animated: true, completion: nil)
    }

    private func presentErrorCancelingBolus(_ error: (Error)) {
        log.error("Error Canceling Bolus: %@", error.localizedDescription)
        let title = NSLocalizedString("Error Canceling Bolus", comment: "The alert title for an error while canceling a bolus")
        let body = NSLocalizedString("Unable to stop the bolus in progress. Move your iPhone closer to the pump and try again. Check your insulin delivery history for details, and monitor your glucose closely.", comment: "The alert body for an error while canceling a bolus")
        let action = UIAlertAction(
            title: NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert"), style: .default)
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Actions

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.newCarbEntryActivityType:
            presentCarbEntryScreen(activity)
        default:
            break
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        var targetViewController = segue.destination

        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }

        switch targetViewController {
        case let vc as CarbAbsorptionViewController:
            vc.isOnboardingComplete = onboardingManager.isComplete
            vc.automaticDosingStatus = automaticDosingStatus
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
        case let vc as InsulinDeliveryTableViewController:
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
            vc.enableEntryDeletion = FeatureFlags.entryDeletionEnabled
            vc.headerValueLabelColor = .dashboardInsulinAccent
        case let vc as OverrideSelectionViewController:
            if deviceManager.loopManager.settings.futureOverrideEnabled() {
                vc.scheduledOverride = deviceManager.loopManager.settings.scheduleOverride
            }
            vc.presets = deviceManager.loopManager.settings.overridePresets
            vc.glucoseUnit = statusCharts.glucose.glucoseUnit
            vc.overrideHistory = deviceManager.loopManager.overrideHistory.getEvents()
            vc.delegate = self
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        default:
            break
        }
    }

    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {}

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {}

    @IBAction func userTappedAddCarbs() {
        presentCarbEntryScreen(nil)
    }

    func presentCarbEntryScreen(_ activity: NSUserActivity?) {
        let navigationWrapper: UINavigationController
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            let viewModel = SimpleBolusViewModel(delegate: deviceManager, displayMealEntry: true)
            if let activity = activity {
                viewModel.restoreUserActivityState(activity)
            }
            let bolusEntryView = SimpleBolusView(viewModel: viewModel).environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: bolusEntryView, isModalInPresentation: false)
            navigationWrapper = UINavigationController(rootViewController: hostingController)
            hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Cancel", comment: ""), style: .plain, target: navigationWrapper, action: #selector(dismissWithAnimation))
            present(navigationWrapper, animated: true)
        } else {
            let viewModel = CarbEntryViewModel(delegate: deviceManager)
            if let activity {
                viewModel.restoreUserActivityState(activity)
            }
            let carbEntryView = CarbEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: carbEntryView, isModalInPresentation: false)
            present(hostingController, animated: true)
        }
        deviceManager.analyticsServicesManager.didDisplayCarbEntryScreen()
    }

    @IBAction func presentBolusScreen() {
        presentBolusEntryView()
    }
    
    @ViewBuilder
    func bolusEntryView(enableManualGlucoseEntry: Bool = false) -> some View {
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            SimpleBolusView(
                viewModel: SimpleBolusViewModel(
                    delegate: deviceManager,
                    displayMealEntry: false
                )
            )
            .environmentObject(deviceManager.displayGlucosePreference)
        } else {
            let viewModel: BolusEntryViewModel = {
                let viewModel = BolusEntryViewModel(
                    delegate: deviceManager,
                    screenWidth: UIScreen.main.bounds.width,
                    isManualGlucoseEntryEnabled: enableManualGlucoseEntry
                )
                
                Task { @MainActor in
                    await viewModel.generateRecommendationAndStartObserving()
                }
                
                viewModel.analyticsServicesManager = deviceManager.analyticsServicesManager
                
                return viewModel
            }()
            
            BolusEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
        }
    }

    func presentBolusEntryView(enableManualGlucoseEntry: Bool = false) {
        let hostingController = DismissibleHostingController(
            content: bolusEntryView(
                enableManualGlucoseEntry: enableManualGlucoseEntry
            )
        )
        hostingController.view.backgroundColor = .dashboardBackground
        
        let navigationWrapper = UINavigationController(rootViewController: hostingController)
        navigationWrapper.navigationBar.tintColor = .dashboardInsulinAccent
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithOpaqueBackground()
        navBarAppearance.backgroundColor = .dashboardBackground
        navBarAppearance.shadowColor = .clear
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.dashboardInk,
            .font: UIFont.dashboardRounded(ofSize: 17, weight: .bold)
        ]
        navigationWrapper.navigationBar.standardAppearance = navBarAppearance
        navigationWrapper.navigationBar.scrollEdgeAppearance = navBarAppearance

        let cancelButton = UIBarButtonItem(title: NSLocalizedString("Cancel", comment: ""), style: .plain, target: navigationWrapper, action: #selector(dismissWithAnimation))
        cancelButton.setTitleTextAttributes([
            .font: UIFont.dashboardRounded(ofSize: 17, weight: .medium),
            .foregroundColor: UIColor.dashboardInsulinAccent
        ], for: .normal)
        hostingController.navigationItem.leftBarButtonItem = cancelButton
        present(navigationWrapper, animated: true)
        deviceManager.analyticsServicesManager.didDisplayBolusScreen()
    }

    private func createPreMealButtonItem(selected: Bool, isEnabled: Bool) -> UIBarButtonItem {
        let tintColor = selected ? UIColor.dashboardCoral : UIColor.dashboardMutedInk
        preMealButton.set(
            image: UIImage(systemName: "timer"),
            title: NSLocalizedString("Pre-Meal", comment: "The label of the pre-meal mode toggle button"),
            tintColor: tintColor,
            isBadgeVisible: selected
        )
        preMealButton.accessibilityLabel = NSLocalizedString("Pre-Meal Targets", comment: "The label of the pre-meal mode toggle button")

        if selected {
            preMealButton.accessibilityTraits.insert(.selected)
            preMealButton.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            preMealButton.accessibilityTraits.remove(.selected)
            preMealButton.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        preMealButton.isEnabled = isEnabled

        return UIBarButtonItem(customView: preMealButton)
    }
    
    private func updateWorkoutButton(selected: Bool, isEnabled: Bool) {
        let tintColor = selected ? UIColor.dashboardCoral : UIColor.dashboardMutedInk
        workoutButton.set(
            image: UIImage(systemName: "figure.run"),
            title: NSLocalizedString("Targets", comment: "The label of the workout mode toggle button"),
            tintColor: tintColor,
            isBadgeVisible: selected
        )
        workoutButton.accessibilityLabel = NSLocalizedString("Workout Targets", comment: "The label of the workout mode toggle button")

        if selected {
            workoutButton.accessibilityTraits.insert(.selected)
            workoutButton.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
        } else {
            workoutButton.accessibilityTraits.remove(.selected)
            workoutButton.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
        }

        workoutButton.isEnabled = isEnabled
    }

    @IBAction func premealButtonTapped(_ sender: Any) {
        togglePreMealMode(confirm: false)
    }
    
    func togglePreMealMode(confirm: Bool = true) {
        if preMealMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Pre-Meal Preset?", message: "This will remove any currently applied pre-meal preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride(matching: .preMeal)
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
            }
        } else {
            presentPreMealModeAlertController()
        }
    }
    
    func presentPreMealModeAlertController() {
        let vc = UIAlertController(premealDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.workoutMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enablePreMealOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enablePreMealOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    func presentCustomPresets(confirm: Bool = true) {
        if workoutMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Preset?", message: "This will remove any currently applied preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride()
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
            }
        } else {
            if FeatureFlags.sensitivityOverridesEnabled {
                let workoutItem = toolbarItems?.first { $0.customView === workoutButton }
                performSegue(withIdentifier: OverrideSelectionViewController.className, sender: workoutItem)
            } else {
                presentWorkoutModeAlertController()
            }
        }
    }
    
    func presentWorkoutModeAlertController() {
        let vc = UIAlertController(workoutDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.preMealMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    @IBAction func toggleWorkoutMode(_ sender: Any) {
        presentCustomPresets(confirm: false)
    }
    
    @IBAction func onSettingsTapped(_ sender: Any) {
        presentSettings()
    }

    private func presentSettings() {
        let deletePumpDataFunc: () -> PumpManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.pumpManager is TestingPumpManager) ? {
                [weak self] in self?.deviceManager.deleteTestingPumpData()
                } : nil
        }
        let deleteCGMDataFunc: () -> CGMManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.cgmManager is TestingCGMManager) ? {
                [weak self] in self?.deviceManager.deleteTestingCGMData()
                } : nil
        }
        let pumpViewModel = PumpManagerViewModel(
            image: { [weak self] in self?.deviceManager.pumpManager?.smallImage },
            name: { [weak self] in self?.deviceManager.pumpManager?.localizedTitle ?? "" },
            isSetUp: { [weak self] in self?.deviceManager.pumpManager?.isOnboarded == true },
            availableDevices: deviceManager.availablePumpManagers,
            deleteTestingDataFunc: deletePumpDataFunc,
            onTapped: { [weak self] in
                self?.onPumpTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addPumpManager(withIdentifier: $0.identifier)
        })

        let cgmViewModel = CGMManagerViewModel(
            image: {[weak self] in (self?.deviceManager.cgmManager as? DeviceManagerUI)?.smallImage },
            name: {[weak self] in self?.deviceManager.cgmManager?.localizedTitle ?? "" },
            isSetUp: {[weak self] in self?.deviceManager.cgmManager?.isOnboarded == true },
            availableDevices: deviceManager.availableCGMManagers,
            deleteTestingDataFunc: deleteCGMDataFunc,
            onTapped: { [weak self] in
                self?.onCGMTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addCGMManager(withIdentifier: $0.identifier)
        })
        let servicesViewModel = ServicesViewModel(showServices: FeatureFlags.includeServicesInSettingsEnabled,
                                                  availableServices: { [weak self] in self?.deviceManager.servicesManager.availableServices ?? [] },
                                                  activeServices: { [weak self] in self?.deviceManager.servicesManager.activeServices ?? [] },
                                                  delegate: self)
        let versionUpdateViewModel = VersionUpdateViewModel(supportManager: supportManager, guidanceColors: .default)
        let viewModel = SettingsViewModel(alertPermissionsChecker: alertPermissionsChecker,
                                          alertMuter: alertMuter,
                                          versionUpdateViewModel: versionUpdateViewModel,
                                          pumpManagerSettingsViewModel: pumpViewModel,
                                          cgmManagerSettingsViewModel: cgmViewModel,
                                          servicesViewModel: servicesViewModel,
                                          criticalEventLogExportViewModel: CriticalEventLogExportViewModel(exporterFactory: deviceManager.criticalEventLogExportManager),
                                          therapySettings: { [weak self] in self?.deviceManager.loopManager.therapySettings ?? TherapySettings() },
                                          sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                                          initialDosingEnabled: deviceManager.loopManager.settings.dosingEnabled,
                                          isClosedLoopAllowed: automaticDosingStatus.$isAutomaticDosingAllowed,
                                          automaticDosingStrategy: deviceManager.loopManager.settings.automaticDosingStrategy,
                                          availableSupports: supportManager.availableSupports,
                                          isOnboardingComplete: onboardingManager.isComplete,
                                          therapySettingsViewModelDelegate: deviceManager,
                                          delegate: self)
        let hostingController = DismissibleHostingController(
            rootView: SettingsView(viewModel: viewModel, localizedAppNameAndVersion: supportManager.localizedAppNameAndVersion)
                .environmentObject(deviceManager.displayGlucosePreference)
                .environment(\.appName, Bundle.main.bundleDisplayName),
            isModalInPresentation: false)
        present(hostingController, animated: true)
    }

    private func onPumpTapped() {
        guard var settingsViewController = deviceManager.pumpManager?.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures, allowedInsulinTypes: deviceManager.allowedInsulinTypes) else {
            // assert?
            return
        }
        settingsViewController.pumpManagerOnboardingDelegate = deviceManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }

    private func onCGMTapped() {
        guard let cgmManager = deviceManager.cgmManager as? CGMManagerUI else {
            // assert?
            return
        }

        var settings = cgmManager.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, displayGlucosePreference: deviceManager.displayGlucosePreference, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        settings.cgmManagerOnboardingDelegate = deviceManager
        settings.completionDelegate = self
        show(settings, sender: self)
    }

    private func automaticDosingStatusChanged(_ automaticDosingEnabled: Bool) {
        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)
        hudView?.loopCompletionHUD.loopIconClosed = automaticDosingEnabled
        hudView?.loopCompletionHUD.closedLoopDisallowedLocalizedDescription = deviceManager.closedLoopDisallowedLocalizedDescription
        updateLoopStatusHUD()
    }

    // MARK: - HUDs

    private func updateGlucoseTargetRangeHUD(at date: Date = Date()) {
        let unit = statusCharts.glucose.glucoseUnit
        guard let targetSchedule = deviceManager.loopManager.settings.effectiveGlucoseTargetRangeSchedule() else {
            hudView?.setGlucoseTargetRangeText(nil)
            return
        }

        let targetRange = targetSchedule.quantityRange(at: date)
        let formatter = QuantityFormatter(for: unit).numberFormatter
        guard let lowerBound = formatter.string(from: targetRange.lowerBound.doubleValue(for: unit)),
              let upperBound = formatter.string(from: targetRange.upperBound.doubleValue(for: unit))
        else {
            hudView?.setGlucoseTargetRangeText(nil)
            return
        }

        let targetText = lowerBound == upperBound ? lowerBound : "\(lowerBound)–\(upperBound)"
        hudView?.setGlucoseTargetRangeText(targetText)
    }

    private func updateLoopStatusHUD() {
        hudView?.setLoopStatus(
            isClosedLoop: automaticDosingStatus.automaticDosingEnabled,
            automaticDosingStrategy: deviceManager.loopManager.settings.automaticDosingStrategy
        )
    }

    @IBOutlet var hudView: StatusBarHUDView? {
        didSet {
            guard let hudView = hudView, hudView != oldValue else {
                return
            }

            let statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showLoopCompletionMessage(_:)))
            hudView.loopCompletionHUD.addGestureRecognizer(statusTapGestureRecognizer)
            hudView.loopCompletionHUD.accessibilityHint = NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint")

            let pumpStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(pumpStatusTapped(_:)))
            hudView.pumpStatusHUD.addGestureRecognizer(pumpStatusTapGestureRecognizer)

            let cgmStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(cgmStatusTapped(_:)))
            hudView.cgmStatusHUD.addGestureRecognizer(cgmStatusTapGestureRecognizer)

            configurePumpManagerHUDViews()
            configureCGMManagerHUDViews()

            // when HUD view is initialized, update loop completion HUD (e.g., icon and last loop completed)
            hudView.loopCompletionHUD.stateColors = .dashboardLoopStatus
            hudView.loopCompletionHUD.loopIconClosed = automaticDosingStatus.automaticDosingEnabled
            hudView.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted
            updateLoopStatusHUD()

            hudView.cgmStatusHUD.stateColors = .cgmStatus
            hudView.cgmStatusHUD.tintColor = .dashboardGlucoseAccent
            hudView.pumpStatusHUD.stateColors = .dashboardPumpStatus
            hudView.pumpStatusHUD.tintColor = .dashboardInsulinAccent
            hudView.setPumpExpiration(date: deviceManager.pumpExpiresAt)

            refreshContext.update(with: .status)
            log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }

    private func configurePumpManagerHUDViews() {
        if let hudView = hudView {
            hudView.removePumpManagerProvidedView()
            if let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider {
                if let view = pumpManagerHUDProvider.createHUDView() {
                    addPumpManagerViewToHUD(view)
                }
                pumpManagerHUDProvider.visible = active && onscreen
            }
            hudView.pumpStatusHUD.presentStatusHighlight(deviceManager.pumpStatusHighlight)
            hudView.pumpStatusHUD.lifecycleProgress = deviceManager.pumpLifecycleProgress
            hudView.setPumpExpiration(date: deviceManager.pumpExpiresAt)
        }
    }

    private func configureCGMManagerHUDViews() {
        if let hudView = hudView {
            hudView.cgmStatusHUD.presentStatusHighlight(deviceManager.cgmStatusHighlight)
            hudView.cgmStatusHUD.lifecycleProgress = deviceManager.cgmLifecycleProgress
        }
    }

    private func addPumpManagerViewToHUD(_ view: BaseHUDView) {
        if let hudView = hudView {
            view.stateColors = .dashboardPumpStatus
            view.tintColor = .dashboardCoral
            hudView.addPumpManagerProvidedHUDView(view)
        }
    }

    @objc private func showLoopCompletionMessage(_: Any) {
        guard let loopCompletionMessage = hudView?.loopCompletionHUD.loopCompletionMessage else { return }
        presentLoopCompletionMessage(title: loopCompletionMessage.title, message: loopCompletionMessage.message)
    }

    private func presentLoopCompletionMessage(title: String, message: String) {
        let action = UIAlertAction(title: NSLocalizedString("Dismiss", comment: "The button label of the action used to dismiss an error alert"),
                                   style: .default)
        let alertController = UIAlertController(title: title,
                                                message: message,
                                                preferredStyle: .alert)
        alertController.addAction(action)
        present(alertController, animated: true)
    }

    @objc private func showLastError(_: Any) {
        let error: Error?
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            error = deviceError.error
        } else if let lastLoopError = lastLoopError {
            error = lastLoopError
        } else {
            error = nil
        }
        if let error = error {
            let alertController = UIAlertController(with: error)
            let manualLoopAction = UIAlertAction(title: NSLocalizedString("Retry", comment: "The button text for attempting a manual loop"), style: .default, handler: { _ in
                self.deviceManager.refreshDeviceData()
            })
            alertController.addAction(manualLoopAction)
            present(alertController, animated: true)
        }
    }

    @objc private func pumpStatusTapped(_ sender: UIGestureRecognizer) {
        if let pumpStatusView = sender.view as? PumpStatusHUDView {
            executeHUDTapAction(deviceManager.didTapOnPumpStatus(pumpStatusView.pumpManagerProvidedHUD), from: sender.view)
        }
    }

    @objc private func cgmStatusTapped( _ sender: UIGestureRecognizer) {
        executeHUDTapAction(deviceManager.didTapOnCGMStatus(), from: sender.view)
    }

    private func executeHUDTapAction(_ action: HUDTapAction?, from sourceView: UIView?) {
        guard let action = action else {
            return
        }

        switch action {
        case .presentViewController(let vc):
            var completionNotifyingVC = vc
            completionNotifyingVC.completionDelegate = self
            present(completionNotifyingVC, animated: true, completion: nil)
        case .openAppURL(let url):
            UIApplication.shared.open(url)
        case .setupNewCGM:
            addNewCGMManager(from: sourceView)
        case .setupNewPump:
            addNewPumpManager(from: sourceView)
        default:
            return
        }
    }

    private func addNewPumpManager(from sourceView: UIView?) {
        let availablePumpManagers = deviceManager.availablePumpManagers

        switch availablePumpManagers.count {
        case 1:
            if let availablePumpManager = availablePumpManagers.first {
                addPumpManager(withIdentifier: availablePumpManager.identifier)
            }
        default:
            let alert = UIAlertController(availablePumpManagers: availablePumpManagers) { [weak self] (identifier) in
                self?.addPumpManager(withIdentifier: identifier)
            }
            alert.popoverPresentationController?.sourceView = sourceView ?? view
            alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
            present(alert, animated: true, completion: nil)
        }
    }

    private func addNewCGMManager(from sourceView: UIView?) {
        let availableCGMManagers = deviceManager.availableCGMManagers

        switch availableCGMManagers.count {
        case 1:
            if let availableCGMManager = availableCGMManagers.first {
                addCGMManager(withIdentifier: availableCGMManager.identifier)
            }
        default:
            let alert = UIAlertController(availableCGMManagers: availableCGMManagers) { [weak self] identifier in
                self?.addCGMManager(withIdentifier: identifier)
            }
            alert.popoverPresentationController?.sourceView = sourceView ?? view
            alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
            present(alert, animated: true, completion: nil)
        }
    }


    // MARK: - Debug Scenarios and Simulated Core Data

    var lastOrientation: UIDeviceOrientation?
    var rotateCount = 0
    let maxRotationsToTrigger = 6
    var rotateTimer: Timer?
    let rotateTimerTimeout = TimeInterval.seconds(2)
    private func maybeOpenDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }
        // Opens the debug menu if you rotate the phone 6 times (or back & forth 3 times), each rotation within 2 secs.
        if lastOrientation != UIDevice.current.orientation {
            if UIDevice.current.orientation == .portrait && rotateCount >= maxRotationsToTrigger-1 {
                presentDebugMenu()
                rotateCount = 0
                rotateTimer?.invalidate()
                rotateTimer = nil
            } else {
                rotateTimer?.invalidate()
                rotateTimer = Timer.scheduledTimer(withTimeInterval: rotateTimerTimeout, repeats: false) { [weak self] _ in
                    self?.rotateCount = 0
                    self?.rotateTimer?.invalidate()
                    self?.rotateTimer = nil
                }
                rotateCount += 1
            }
        }
        lastOrientation = UIDevice.current.orientation
    }

    private func presentDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }

        let actionSheet = UIAlertController(title: "Debug", message: nil, preferredStyle: .actionSheet)
        if FeatureFlags.scenariosEnabled {
            actionSheet.addAction(UIAlertAction(title: "Scenarios", style: .default) { _ in
                DispatchQueue.main.async {
                    self.presentScenarioSelector()
                }
            })
        }
        if FeatureFlags.simulatedCoreDataEnabled {
            actionSheet.addAction(UIAlertAction(title: "Simulated Core Data", style: .default) { _ in
                self.presentSimulatedCoreDataMenu()
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Remove Exports Directory", style: .default) { _ in
            if let error = self.deviceManager.removeExportsDirectory() {
                self.presentError(error)
            }
        })
        if FeatureFlags.mockTherapySettingsEnabled {
            actionSheet.addAction(UIAlertAction(title: "Mock Therapy Settings", style: .default) { _ in
                let therapySettings = TherapySettings.mockTherapySettings
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.glucoseTargetRangeSchedule = therapySettings.glucoseTargetRangeSchedule
                    settings.preMealTargetRange = therapySettings.correctionRangeOverrides?.preMeal
                    settings.legacyWorkoutTargetRange = therapySettings.correctionRangeOverrides?.workout
                    settings.suspendThreshold = therapySettings.suspendThreshold
                    settings.maximumBolus = therapySettings.maximumBolus
                    settings.maximumBasalRatePerHour = therapySettings.maximumBasalRatePerHour
                    settings.insulinSensitivitySchedule = therapySettings.insulinSensitivitySchedule
                    settings.carbRatioSchedule = therapySettings.carbRatioSchedule
                    settings.basalRateSchedule = therapySettings.basalRateSchedule
                    settings.defaultRapidActingModel = therapySettings.defaultRapidActingModel
                }
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Crash the App", style: .destructive) { _ in
            fatalError("Test Crash")
        })
        actionSheet.addAction(UIAlertAction(title: "Delete CGM Manager", style: .destructive) { _ in
            self.deviceManager.cgmManager?.delete() { }
        })

        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentScenarioSelector() {
        guard FeatureFlags.scenariosEnabled else {
            fatalError("\(#function) should be invoked only when scenarios are enabled")
        }

        let vc = TestingScenariosTableViewController(scenariosManager: testingScenariosManager)
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func addScenarioStepGestureRecognizers() {
        if FeatureFlags.scenariosEnabled {
            let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioForward))
            leftSwipe.direction = .left
            let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioBackward))
            rightSwipe.direction = .right

            if let toolBar = navigationController?.toolbar {
                toolBar.addGestureRecognizer(leftSwipe)
                toolBar.addGestureRecognizer(rightSwipe)
            }
        }
    }

    private func presentSimulatedCoreDataMenu() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        let actionSheet = UIAlertController(title: "Simulated Core Data", message: nil, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: "Generate Simulated Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged before generating new simulated historical Core Data. Are you sure?", actionTitle: "Generate Simulated Historical") {
                self.generateSimulatedHistoricalCoreData()
            }
        })
        actionSheet.addAction(UIAlertAction(title: "Purge Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged. Are you sure?", actionTitle: "Purge Historical") {
                self.purgeHistoricalCoreData()
            }
        })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func generateSimulatedHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Generating simulated historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    if let error = error {
                        dismissActivityIndicator()
                        self.presentError(error)
                        return
                    }

                    self.deviceManager.generateSimulatedHistoricalCoreData() { error in
                        DispatchQueue.main.async {
                            dismissActivityIndicator()
                            if let error = error {
                                self.presentError(error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func purgeHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Purging historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    dismissActivityIndicator()
                    if let error = error {
                        self.presentError(error)
                    }
                }
            }
        }
    }

    private func presentConfirmation(actionSheetMessage: String, actionTitle: String, handler: @escaping () -> Void) {
        let actionSheet = UIAlertController(title: nil, message: actionSheetMessage, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in handler() })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentError(_ error: Error, handler: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Error", message: "An error occurred: \(String(describing: error))", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in handler?() })
        present(alert, animated: true)
    }

    private func presentActivityIndicator(title: String, message: String, completion: @escaping (@escaping () -> Void) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addActivityIndicator()
        present(alert, animated: true) { completion { alert.dismiss(animated: true) } }
    }

    @objc private func stepActiveScenarioForward() {
        testingScenariosManager.stepActiveScenarioForward { _ in }
    }

    @objc private func stepActiveScenarioBackward() {
        testingScenariosManager.stepActiveScenarioBackward { _ in }
    }
}

private extension UIButton {
    func constrainToToolbarIconSize() {
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
}



extension UIAlertController {
    func addActivityIndicator() {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let activityIndicator = UIActivityIndicatorView(frame: frame)
        activityIndicator.style = .default
        activityIndicator.startAnimating()
        let viewController = UIViewController()
        viewController.preferredContentSize = frame.size
        viewController.view.addSubview(activityIndicator)
        setValue(viewController, forKey: "contentViewController")
    }
}

extension StatusTableViewController: CompletionDelegate {
    func completionNotifyingDidComplete(_ object: CompletionNotifying) {
        if let vc = object as? UIViewController {
            if presentedViewController === vc {
                dismiss(animated: true, completion: nil)
            } else {
                vc.dismiss(animated: true, completion: nil)
            }
        }
    }
}

extension StatusTableViewController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        dispatchPrecondition(condition: .onQueue(.main))
        log.default("PumpManager:%{public}@ did update status", String(describing: type(of: pumpManager)))

        basalDeliveryState = status.basalDeliveryState
        bolusState = status.bolusState

        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: CGMManagerStatusObserver {
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {

        updateBolusProgress()

        if doseProgressReporter.progress.isComplete {
            // Bolus ended
            self.bolusProgressReporter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self.bolusState = .noBolus
                self.reloadData(animated: true)
            })
        }
    }
}

extension StatusTableViewController: OverrideSelectionViewControllerDelegate {
    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didUpdatePresets presets: [TemporaryScheduleOverridePreset]) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.overridePresets = presets
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmPreset preset: TemporaryScheduleOverridePreset) {
        let intent = EnableOverridePresetIntent()
        intent.overrideName = preset.name

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = preset.id.uuidString
        interaction.groupIdentifier = preset.name
        interaction.donate { (error) in
            if let error = error {
                os_log(.error, "Failed to donate intent: %{public}@", String(describing: error))
            }
        }
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = preset.createOverride(enactTrigger: .local)
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController: AddEditOverrideTableViewControllerDelegate {
    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didSaveOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController {
    fileprivate func addCGMManager(withIdentifier identifier: String) {
        switch deviceManager.setupCGMManager(withIdentifier: identifier) {
        case .failure(let error):
            log.error("Failure to setup CGM manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.cgmManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("CGM manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController {
    fileprivate func addPumpManager(withIdentifier identifier: String) {
        guard let maximumBasalRate = deviceManager.loopManager.settings.maximumBasalRatePerHour,
              let maxBolus = deviceManager.loopManager.settings.maximumBolus,
              let basalSchedule = deviceManager.loopManager.settings.basalRateSchedule else
        {
            log.error("Failure to setup pump manager: incomplete settings")
            return
        }
        
        let settings = PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maximumBasalRate,
                                                maxBolusUnits: maxBolus,
                                                basalSchedule: basalSchedule)
        switch deviceManager.setupPumpManagerUI(withIdentifier: identifier, initialSettings: settings) {
        case .failure(let error):
            log.error("Failure to setup pump manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.pumpManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Pump manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController: BluetoothObserver {
    func bluetoothDidUpdateState(_ state: BluetoothState) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

// MARK: - SettingsViewModel delegation
extension StatusTableViewController: SettingsViewModelDelegate {
    var closedLoopDescriptiveText: String? {
        return deviceManager.closedLoopDisallowedLocalizedDescription
    }

    func dosingEnabledChanged(_ value: Bool) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.dosingEnabled = value
        }
    }
    
    func dosingStrategyChanged(_ strategy: AutomaticDosingStrategy) {
        self.deviceManager.loopManager.mutateSettings { settings in
            settings.automaticDosingStrategy = strategy
        }
        hudView?.setLoopStatus(
            isClosedLoop: automaticDosingStatus.automaticDosingEnabled,
            automaticDosingStrategy: strategy
        )
    }

    func didTapIssueReport() {
        // TODO: this dismiss here is temporary, until we know exactly where
        // we want this screen to belong in the navigation flow
        dismiss(animated: true) {
            let vc = CommandResponseViewController.generateDiagnosticReport(deviceManager: self.deviceManager)
            vc.title = NSLocalizedString("Issue Report", comment: "The view controller title for the issue report screen")
            self.show(vc, sender: nil)
        }
    }
}

// MARK: - Services delegation

extension StatusTableViewController: ServicesViewModelDelegate {
    func addService(withIdentifier identifier: String) {
        switch deviceManager.servicesManager.setupService(withIdentifier: identifier) {
        case .failure(let error):
            log.default("Failure to setup service with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.serviceOnboardingDelegate = deviceManager.servicesManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Service with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }

    func gotoService(withIdentifier identifier: String) {
        guard let serviceUI = deviceManager.servicesManager.activeServices.first(where: { $0.pluginIdentifier == identifier }) as? ServiceUI else {
            return
        }
        showServiceSettings(serviceUI)
    }

    fileprivate func showServiceSettings(_ serviceUI: ServiceUI) {
        var settingsViewController = serviceUI.settingsViewController(colorPalette: .default)
        settingsViewController.serviceOnboardingDelegate = deviceManager.servicesManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }
}
