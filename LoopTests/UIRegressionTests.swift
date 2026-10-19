import XCTest
import Combine
#if canImport(Loop)
@testable import Loop
import LoopCore
#endif
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

private final class UIRegressionProvider: CompanionProvider {
    var requestCount = 0
    var delayNanoseconds: UInt64 = 0

    func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion {
        requestCount += 1
        // Deliberately permit a late response after cancellation to exercise the caller's guard.
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        let text = #"{"updateForm":true,"message":"Estimated meal.","estimate":{"food":"🌮","grams":30,"absorptionMinutes":120,"explanation":"One portion.","assumptions":"Portion uncertain."}}"#
        return CompanionCompletion(message: ["role": "assistant", "content": text], text: text, calls: [])
    }
}

@MainActor
final class UIRegressionTests: XCTestCase {
    func testLiveActivityKeepsOtherPendingChangesWhenOneFieldIsReverted() {
        let suite = "UIRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LiveActivityManagementViewModel(defaults: defaults)
        model.enabled.toggle()
        let savedMode = model.mode
        model.mode = savedMode == .large ? .small : .large
        model.mode = savedMode
        XCTAssertTrue(model.isDirty)
        model.enabled.toggle()
        XCTAssertFalse(model.isDirty)
    }

    func testEveryLiveActivityFieldParticipatesInDirtyStateAndSavingUpdatesBaseline() {
        let suite = "UIRegression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LiveActivityManagementViewModel(defaults: defaults)
        for field in [\LiveActivityManagementViewModel.enabled, \.addPredictiveLine, \.useLimits] {
            model[keyPath: field].toggle()
            XCTAssertTrue(model.isDirty)
            model[keyPath: field].toggle()
            XCTAssertFalse(model.isDirty)
        }
        for field in [\LiveActivityManagementViewModel.upperLimitChartMg, \.lowerLimitChartMg, \.upperLimitChartMmol, \.lowerLimitChartMmol] {
            let saved = model[keyPath: field]
            model[keyPath: field] += 1
            XCTAssertTrue(model.isDirty)
            model[keyPath: field] = saved
            XCTAssertFalse(model.isDirty)
        }
        model.isEditingMode = true
        XCTAssertFalse(model.isDirty)
        model.enabled = false
        var saved = LiveActivitySettings()
        saved.enabled = false
        model.markSaved(saved)
        XCTAssertFalse(model.isDirty)
        model.enabled = true
        XCTAssertTrue(model.isDirty)
    }

    func testMealChatLimitPreservesReviewedForm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UIRegressionProvider()
        let controller = CompanionController(provider: provider, stateStore: CompanionStateStore(url: directory.appendingPathComponent("state.json")), keyReader: { "test-key" })
        let chat = CompanionMealConversation(controller: controller, maximumGrams: 250, absorptionRange: 900...28800, defaults: [7200, 10800, 21600])
        for index in 0..<20 {
            XCTAssertTrue(chat.send("Question \(index)", jpeg: index == 0 ? Data([1]) : nil))
            try await waitForMeal(chat)
        }
        XCTAssertEqual(chat.turns.count, 40)
        XCTAssertFalse(chat.canSend)
        XCTAssertFalse(chat.canAddPhoto)
        XCTAssertFalse(chat.send("One more question"))
        XCTAssertNotNil(chat.submissionError)
        XCTAssertNil(chat.error)
        XCTAssertFalse(chat.needsReply)
        XCTAssertTrue(chat.canUseForm)
        XCTAssertEqual(chat.estimate?.grams, 30)
        XCTAssertEqual(provider.requestCount, 20)
    }

    func testRejectedMealMessageDoesNotInvalidateFormAndCanBeCorrected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = UIRegressionProvider()
        let controller = CompanionController(provider: provider, stateStore: CompanionStateStore(url: directory.appendingPathComponent("state.json")), keyReader: { "test-key" })
        let chat = CompanionMealConversation(controller: controller, maximumGrams: 250, absorptionRange: 900...28800, defaults: [7200, 10800, 21600])
        XCTAssertTrue(chat.send("Estimate", jpeg: Data([1])))
        try await waitForMeal(chat)
        XCTAssertFalse(chat.send(String(repeating: "x", count: 3001)))
        XCTAssertTrue(chat.canUseForm)
        XCTAssertEqual(chat.turns.count, 2)
        XCTAssertNotNil(chat.submissionError)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(chat.send("Please explain"))
        try await waitForMeal(chat)
        XCTAssertNil(chat.submissionError)
        XCTAssertTrue(chat.canUseForm)
    }

    func testGeneralChatOnlyAcceptsValidMessagesAndPersistsBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        let provider = UIRegressionProvider()
        let controller = CompanionController(provider: provider, stateStore: store, keyReader: { "test-key" })
        let oversizedAccepted = await controller.send(String(repeating: "x", count: 6001))
        XCTAssertFalse(oversizedAccepted)
        let emptyAccepted = await controller.send("  \n  ")
        XCTAssertFalse(emptyAccepted)
        XCTAssertTrue(controller.state.messages.isEmpty)
        XCTAssertFalse(controller.isThinking)
        XCTAssertEqual(provider.requestCount, 0)
        let accepted = await controller.send("Hello")
        XCTAssertTrue(accepted)
        XCTAssertEqual(try store.load().messages.first?.text, "Hello")
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isThinking)
        XCTAssertEqual(try store.load().messages.count, 2)
    }

    func testCanceledChatCannotPublishALateResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        let provider = UIRegressionProvider()
        provider.delayNanoseconds = 1_000_000_000
        let controller = CompanionController(provider: provider, stateStore: store, keyReader: { "test-key" })
        let accepted = await controller.send("Hello")
        XCTAssertTrue(accepted)
        for _ in 0..<200 where provider.requestCount == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(provider.requestCount, 1)
        controller.cancelChat()
        for _ in 0..<200 where controller.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(controller.isThinking)
        XCTAssertEqual(controller.state.messages.count, 1)
        XCTAssertEqual(try store.load().messages.count, 1)
    }

    func testConcurrentChangesAreAllPublishedAndPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var initial = CompanionState()
        initial.actions = (0..<8).map { CompanionAction(title: "Action \($0)", personality: "Be kind") }
        try store.save(initial)
        let controller = CompanionController(provider: UIRegressionProvider(), stateStore: store, keyReader: { "test-key" })
        await withTaskGroup(of: Void.self) { group in
            for action in initial.actions { group.addTask { await controller.decline(action.id) } }
        }
        XCTAssertTrue(controller.state.actions.allSatisfy { $0.status == .declined })
        let saved = try store.load()
        XCTAssertTrue(saved.actions.allSatisfy { $0.status == .declined })
        XCTAssertEqual(controller.state.actions.count, 8)
        XCTAssertEqual(try store.load().actions.count, 8)
    }

    func testFailedPersistencePreservesPublishedStateAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStateStore(url: directory.appendingPathComponent("state.json"))
        var initial = CompanionState()
        let action = CompanionAction(title: "Action", personality: "Be kind")
        initial.actions = [action]
        try store.save(initial)
        let controller = CompanionController(provider: UIRegressionProvider(), stateStore: store, keyReader: { "test-key" })
        try FileManager.default.removeItem(at: directory)
        try Data([1]).write(to: directory) // A file blocks creation of the state directory.
        await controller.decline(action.id)
        XCTAssertEqual(controller.state.actions.first?.status, .pending)
        XCTAssertNotNil(controller.errorMessage)
        let accepted = await controller.send("Keep this draft")
        XCTAssertFalse(accepted)
        XCTAssertTrue(controller.state.messages.isEmpty)
        XCTAssertFalse(controller.isThinking)
        try FileManager.default.removeItem(at: directory)
        await controller.decline(action.id)
        XCTAssertEqual(controller.state.actions.first?.status, .declined)
        XCTAssertEqual(try store.load().actions.first?.status, .declined)
    }

    private func waitForMeal(_ chat: CompanionMealConversation) async throws {
        for _ in 0..<200 where chat.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(chat.isThinking)
        XCTAssertNil(chat.error)
    }

    #if canImport(UIKit)
    func testDashboardHeaderContainsBubbleBeforeAndAfterRefreshAndReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CompanionController(provider: UIRegressionProvider(),
            stateStore: CompanionStateStore(url: directory.appendingPathComponent("state.json")),
            keyReader: { nil }, applicationIsActive: { false })
        let owner = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = owner
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let cell = StatusTableViewController.DashboardGraphicTableViewCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: 390, height: 160)
        owner.view.addSubview(cell)
        cell.configureMochi(owner: owner, controller: controller, open: {})
        let banner = try XCTUnwrap(cell.contentView.subviews.first { $0.accessibilityIdentifier == "MochiDashboardBanner" })
        let bubble = try XCTUnwrap(cell.contentView.subviews.first { $0.accessibilityIdentifier == "MochiDashboardBubble" })

        func layoutHeader() {
            cell.layoutIfNeeded()
            let size = cell.contentView.systemLayoutSizeFitting(CGSize(width: 390, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            cell.frame.size.height = ceil(size.height)
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
        }

        func layoutAndCheckBubble() {
            layoutHeader()
            XCTAssertGreaterThan(bubble.frame.height, 0)
            XCTAssertGreaterThanOrEqual(bubble.frame.minY, 0)
            XCTAssertLessThanOrEqual(bubble.frame.maxY, cell.contentView.bounds.maxY + 0.5)
            XCTAssertEqual(bubble.frame.minY, banner.frame.maxY - 12, accuracy: 0.5)
            XCTAssertTrue(cell.contentView.subviews.last === bubble)
            XCTAssertGreaterThan(bubble.layer.zPosition, banner.layer.zPosition)
            XCTAssertEqual(owner.children.count, 2)
        }

        // Check the first layout, then the same persistent views across later layout passes.
        layoutAndCheckBubble()
        for _ in 0..<3 {
            await Task.yield()
            XCTAssertFalse(cell.refreshBubbleLayout())
            layoutAndCheckBubble()
        }
        cell.prepareForReuse()
        cell.configureMochi(owner: owner, controller: controller, open: {})
        layoutAndCheckBubble()
        XCTAssertTrue(cell.contentView.subviews.first { $0.accessibilityIdentifier == "MochiDashboardBubble" } === bubble)

        let bannerHeight = banner.frame.height
        await controller.dismissDashboard()
        cell.refreshBubbleLayout()
        layoutHeader()
        XCTAssertFalse(cell.refreshBubbleLayout())
        XCTAssertTrue(bubble.isHidden)
        XCTAssertEqual(bubble.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(banner.frame.maxY, cell.contentView.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(banner.frame.height, bannerHeight, accuracy: 0.5)
        XCTAssertEqual(owner.children.count, 2)
    }

    func testDashboardReloadBeforeSetupDoesNotLoadView() {
        let controller = StatusTableViewController(style: .plain)
        XCTAssertFalse(controller.isViewLoaded)

        controller.reloadData()

        XCTAssertFalse(controller.isViewLoaded)
    }

    func testPhotoProcessingBoundsImageAndRemovesSourceMetadata() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        let taggedData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(taggedData, "public.jpeg" as CFString, 1, nil))
        let metadata = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), metadata)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let taggedSource = try XCTUnwrap(CGImageSourceCreateWithData(taggedData as CFData, nil))
        let taggedProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(taggedSource, 0, nil) as? [String: Any])
        XCTAssertNotNil(taggedProperties[kCGImagePropertyGPSDictionary as String])
        let taggedImage = try XCTUnwrap(UIImage(data: taggedData as Data))
        let jpeg = try await MealPhotoProcessing.jpeg(from: taggedImage)
        let result = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(result.size.width, 1280)
        XCTAssertEqual(result.size.height, 640)
        XCTAssertLessThanOrEqual(jpeg.count, 2_000_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    }

    func testPhotoProcessingRejectsEmptyImage() async {
        do {
            _ = try await MealPhotoProcessing.jpeg(from: UIImage())
            XCTFail("An empty image should be rejected")
        } catch { }
    }
    #endif
}
