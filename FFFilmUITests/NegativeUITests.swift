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
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "identifier == 'tab-negative' OR label == 'Negative'")).firstMatch
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
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Negative empty"; screenshot.lifetime = .keepAlways; add(screenshot)
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
        app.tabBars.buttons["Negative"].tap()
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        app.segmentedControls["negative-comparison"].buttons["Original"].tap()
        app.segmentedControls["negative-comparison"].buttons["Positive"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        XCUIDevice.shared.orientation = .portrait
        let screenshot = XCTAttachment(screenshot: app.screenshot())
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
