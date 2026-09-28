#if os(iOS)
import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class NegativeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func openNegative(_ app: XCUIApplication) {
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // The visible name is Film Preview; keep the stable workspace identifier.
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "identifier == 'tab-negative' OR label == 'Film Preview'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }

    @MainActor func testEmptyAndCancelledImport() {
        let app = XCUIApplication()
        openNegative(app)
        XCTAssertTrue(app.buttons["negative-import-file"].waitForExistence(timeout: 5))
        app.buttons["negative-import-file"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.buttons["negative-import-file"].waitForExistence(timeout: 5))
        // Dismissing the picker must leave the empty state free of import errors.
        XCTAssertFalse(app.staticTexts["negative-error"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Negative empty"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testCameraFocusSettingsAndRecalibration() {
        let app = XCUIApplication()
        app.launchEnvironment["NEGATIVE_UI_CAMERA"] = "1"
        openNegative(app)
        let image = app.descendants(matching: .any).matching(identifier: "negative-image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["negative-camera-macro-status"].waitForExistence(timeout: 5))
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Ordinary taps focus; only explicit sampling enters the confirmation workflow.
        XCTAssertFalse(app.buttons["negative-confirm-base"].exists)
        // Immersive capture keeps the complete frame visible; one explicit sampling action.
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertLessThanOrEqual(image.frame.maxY, app.frame.maxY)
        XCTAssertGreaterThan(image.frame.height, app.frame.height * 0.4)
        let liveScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        liveScreenshot.name = "Immersive camera portrait"; liveScreenshot.lifetime = .keepAlways; add(liveScreenshot)
        app.buttons["negative-sample"].tap()
        let confirm = app.buttons["negative-confirm-base"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        let sampleScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sampleScreenshot.name = "Immersive camera sampling"; sampleScreenshot.lifetime = .keepAlways; add(sampleScreenshot)
        confirm.tap()
        let export = app.buttons["negative-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10)); XCTAssertTrue(export.isEnabled)
        app.buttons["negative-camera-settings"].tap()
        let resolution = app.descendants(matching: .any).matching(identifier: "negative-camera-resolution").firstMatch
        if !resolution.isHittable { app.swipeUp() }
        resolution.tap(); app.buttons["1080p"].tap()
        let dimensions = app.staticTexts["negative-dimensions"]
        // Dimensions are localized (for example, 1,080 × 1,920 in English).
        expectation(for: NSPredicate { _, _ in dimensions.label.filter(\.isNumber) == "10801920" }, evaluatedWith: dimensions)
        waitForExpectations(timeout: 10)
        // Native menu pickers may be exposed as PopUpButton after a configuration update.
        let lens = app.descendants(matching: .any).matching(identifier: "negative-camera-lens").firstMatch
        XCTAssertTrue(lens.waitForExistence(timeout: 5))
        if !lens.isHittable { dimensions.swipeUp() }
        lens.tap(); app.buttons["Ultra Wide"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Ultra Wide' AND enabled == true"), evaluatedWith: lens)
        waitForExpectations(timeout: 10)
        // Continuous AF no longer requires a separate recovery action.
        XCTAssertFalse(app.buttons["negative-camera-autofocus"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Camera controls"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["negative-settings-done"].tap()
        XCTAssertFalse(export.isEnabled)
        app.buttons["negative-camera-freeze"].tap()
        XCTAssertFalse(app.buttons["negative-camera-settings"].isEnabled)
        app.buttons["negative-camera-freeze"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["negative-sample"].isHittable)
        app.buttons["negative-sample"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        if !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Immersive camera landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["Cancel"].firstMatch.tap()
        XCUIDevice.shared.orientation = .portrait
        expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.buttons["negative-camera-close"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let reopen = app.buttons["negative-camera-fullscreen"]
        if !reopen.isHittable { app.swipeUp() }
        reopen.tap()
        XCTAssertTrue(app.buttons["negative-camera-close"].waitForExistence(timeout: 5))
    }

    @MainActor func testCameraLargeTextAndCancellation() {
        let app = XCUIApplication()
        app.launchEnvironment["NEGATIVE_UI_CAMERA"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        openNegative(app)
        let panel = app.scrollViews["negative-camera-actions"]
        let sample = app.buttons["negative-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        for _ in 0..<8 where !sample.isHittable { panel.swipeUp() }
        XCTAssertTrue(sample.isHittable); sample.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        for _ in 0..<10 where !cancel.isHittable { panel.swipeUp() }
        XCTAssertTrue(cancel.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Camera accessibility text sampling"; screenshot.lifetime = .keepAlways; add(screenshot)
        cancel.tap()
        XCTAssertFalse(app.buttons["negative-confirm-base"].exists)
        XCTAssertTrue(app.buttons["negative-camera-close"].isHittable)
        app.buttons["negative-camera-close"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testTIFFSamplingComparisonAndExport() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("negative-ui-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: source) }
        let context = CIContext()
        let extent = CGRect(x: 0, y: 0, width: 600, height: 800)
        let border = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.4)).cropped(to: extent)
        let content = CIImage(color: CIColor(red: 0.15, green: 0.18, blue: 0.2)).cropped(to: CGRect(x: 80, y: 80, width: 440, height: 500))
        try context.writeTIFFRepresentation(of: content.composited(over: border), to: source, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let app = XCUIApplication(); app.launchEnvironment["NEGATIVE_UI_FIXTURE"] = source.path
        openNegative(app)
        let sample = app.buttons["negative-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons["negative-export"].isEnabled)
        sample.tap()
        let image = app.descendants(matching: .any).matching(identifier: "negative-image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        // The explicit center action is available without a precise image tap.
        let center = app.buttons["negative-center-sample"]
        XCTAssertTrue(center.exists && center.isEnabled)
        center.tap()
        let samplingScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        samplingScreenshot.name = "Film base center target"; samplingScreenshot.lifetime = .keepAlways; add(samplingScreenshot)
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let confirm = app.buttons["negative-confirm-base"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: confirm); waitForExpectations(timeout: 10)
        confirm.tap()
        let export = app.buttons["negative-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10)); XCTAssertTrue(export.isEnabled)
        // File-based previews survive leaving the workspace; camera capture is stopped separately.
        app.tabBars.buttons["Calculate"].tap()
        app.tabBars.buttons["Film Preview"].tap()
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        app.segmentedControls["negative-comparison"].buttons["Original"].tap()
        app.segmentedControls["negative-comparison"].buttons["Positive"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        XCUIDevice.shared.orientation = .portrait
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Negative positive preview"; screenshot.lifetime = .keepAlways; add(screenshot)
        // Every format must finish through the same immutable source snapshot.
        for format in ["tiff", "png", "jpg"] {
            export.tap()
            let option = app.buttons["negative-export-\(format)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            let close = app.buttons.matching(NSPredicate(format: "identifier == 'header.closeButton' OR label IN {'Close', '关闭'}")).firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 25), app.debugDescription)
            close.tap()
            XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        }
        sample.tap()
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(export.isEnabled)
    }
}
#endif
