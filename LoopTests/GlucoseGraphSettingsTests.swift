import XCTest
@testable import Loop

class GlucoseGraphSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GlucoseGraphSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsEnableEightyToOneFortyFive() {
        let settings = GlucoseGraphSettingsStore(defaults: defaults).settings
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.lowerBoundMGDL, 80)
        XCTAssertEqual(settings.upperBoundMGDL, 145)
    }

    func testBoundariesAndToggleSurviveRelaunch() {
        let store = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertTrue(store.updateBounds(lowerBoundMGDL: 75, upperBoundMGDL: 160))
        store.setEnabled(false)

        let restored = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertFalse(restored.settings.isEnabled)
        XCTAssertEqual(restored.settings.lowerBoundMGDL, 75)
        XCTAssertEqual(restored.settings.upperBoundMGDL, 160)
        restored.setEnabled(true)
        XCTAssertEqual(restored.settings.lowerBoundMGDL, 75)
        XCTAssertEqual(restored.settings.upperBoundMGDL, 160)
    }

    func testInvalidBoundariesLeaveLastValidSettingsIntact() {
        let store = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertTrue(store.updateBounds(lowerBoundMGDL: 90, upperBoundMGDL: 150))
        for (lower, upper) in [(150.0, 90.0), (90, 90), (0, 150), (-10, 150), (.nan, 150), (90, .infinity)] {
            XCTAssertFalse(store.updateBounds(lowerBoundMGDL: lower, upperBoundMGDL: upper))
            XCTAssertEqual(store.settings.lowerBoundMGDL, 90)
            XCTAssertEqual(store.settings.upperBoundMGDL, 150)
        }
        XCTAssertEqual(GlucoseGraphSettingsStore(defaults: defaults).settings, store.settings)
    }

    func testCorruptStoredRangeFallsBackToDefaults() {
        defaults.set(["enabled": true, "lowerBoundMGDL": 160, "upperBoundMGDL": 70],
                     forKey: GlucoseGraphSettingsStore.defaultsKey)
        XCTAssertEqual(GlucoseGraphSettingsStore(defaults: defaults).settings, .default)
        defaults.set(["enabled": false], forKey: GlucoseGraphSettingsStore.defaultsKey)
        XCTAssertEqual(GlucoseGraphSettingsStore(defaults: defaults).settings, .default)
    }

    func testCanonicalValuesKeepTheirPrecision() {
        let store = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertTrue(store.updateBounds(lowerBoundMGDL: 79.27, upperBoundMGDL: 145.94))
        store.setEnabled(false)
        store.setEnabled(true)
        let restored = GlucoseGraphSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.lowerBoundMGDL, 79.27)
        XCTAssertEqual(restored.settings.upperBoundMGDL, 145.94)
    }
}
