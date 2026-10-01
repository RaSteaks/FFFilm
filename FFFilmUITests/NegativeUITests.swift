#if os(iOS)
import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class NegativeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func openNegative(_ app: XCUIApplication, language: String = "en") {
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        // The visible name is Film Preview; keep the stable workspace identifier.
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "identifier == 'tab-negative' OR label == 'Film Preview'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }

    @MainActor func testExternalDocumentOpensFilmPreview() throws {
        let context = CIContext()
        var files: [URL] = []
        defer { for url in files { try? FileManager.default.removeItem(at: url) } }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.terminate()
        // Deliver real system document-open events, including a cold launch without visiting the tab.
        for (width, height) in [(120, 80), (90, 130)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("external-ui-\(UUID()).tiff")
            files.append(url)
            try context.writeTIFFRepresentation(of: CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.3))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: url,
                format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            app.open(url)
            let dims = app.staticTexts["negative-dimensions"]
            XCTAssertTrue(dims.waitForExistence(timeout: 15), app.debugDescription)
            expectation(for: NSPredicate { _, _ in dims.label.filter(\.isNumber) == "\(width)\(height)" }, evaluatedWith: dims)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(app.buttons["negative-sample"].isEnabled)
            XCTAssertFalse(app.buttons["negative-export"].isEnabled)
            app.tabBars.buttons["Calculate"].tap()
        }
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
        // The fixture reports 20 millimeters, which must render as 2 centimeters.
        let distance = app.staticTexts["negative-camera-minimum-distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        XCTAssertEqual(distance.label, "2")
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

    @MainActor func testCameraPermissionSettingsInBothWorkspaces() {
        for (scenario, language) in [("1", "en"), ("restart", "zh-Hans")] {
            let app = XCUIApplication()
            app.launchEnvironment["NEGATIVE_UI_CAMERA"] = "1"
            app.launchEnvironment["NEGATIVE_UI_CAMERA_DENIED"] = scenario
            openNegative(app, language: language)
            if scenario == "restart" {
                // A previously authorized camera remains immersive when a later start is denied.
                let image = app.descendants(matching: .any).matching(identifier: "negative-image").firstMatch
                XCTAssertTrue(image.waitForExistence(timeout: 10))
                app.buttons["negative-camera-close"].tap()
                let reopen = app.buttons["negative-camera-fullscreen"]
                XCTAssertTrue(reopen.waitForExistence(timeout: 5))
                if !reopen.isHittable { app.swipeUp() }
                reopen.tap()
                XCTAssertTrue(app.buttons["negative-camera-close"].waitForExistence(timeout: 5))
            } else {
                XCTAssertFalse(app.buttons["negative-camera-close"].exists)
            }
            XCTAssertTrue(app.staticTexts["negative-error"].waitForExistence(timeout: 5))
            let settings = app.buttons["negative-open-camera-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            if !settings.isHittable { app.scrollViews["negative-camera-actions"].swipeUp() }
            XCTAssertTrue(settings.isHittable)
            XCTAssertEqual(settings.label, language == "en" ? "Open Settings" : "打开设置")
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Camera permission \(scenario) \(language)"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
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
        // Real PhotoKit integration handles first-run add-only authorization as well as prior grants.
        export.tap()
        app.buttons["negative-save-photos"].tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let allow = permission.buttons.matching(NSPredicate(format:
                "(label CONTAINS[c] 'Allow' OR label CONTAINS '允许') AND NOT label CONTAINS[c] 'Don' AND NOT label CONTAINS '不'")).firstMatch
            if allow.exists { allow.tap() }
        }
        let saved = app.alerts["Save to Photos"]
        XCTAssertTrue(saved.waitForExistence(timeout: 25))
        XCTAssertTrue(saved.staticTexts["Positive saved to Photos."].exists)
        saved.buttons["Done"].tap()
        XCTAssertTrue(export.isEnabled)
        sample.tap()
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(export.isEnabled)
        // Round-trip the generated photo through the real system share sheet into Film Preview.
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let welcome = photos.buttons.matching(NSPredicate(format: "label IN {'Continue', '继续'}")).firstMatch
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        let back = photos.buttons["PUOneUpBarButtonItemIdentifierDone"]
        if back.exists { back.tap() }
        let libraryTab = photos.buttons["LibraryTab"]
        if libraryTab.exists { libraryTab.tap() }
        let thumbnails = photos.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 10))
        // Photos' tiled image elements may report no hit point despite a visible frame.
        // Scroll the newest test image into view, then tap its actual center.
        let newest = thumbnails.element(boundBy: thumbnails.count - 1)
        for _ in 0..<8 where newest.frame.midY >= photos.frame.height - 100 {
            photos.scrollViews["content_scroll_view"].swipeUp()
        }
        newest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let sharePhoto = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
        XCTAssertTrue(sharePhoto.waitForExistence(timeout: 5), photos.debugDescription)
        sharePhoto.tap()
        let target = photos.cells.matching(NSPredicate(format:
            "label == 'FFFilm' OR label == 'Copy to FFFilm' OR label == '拷贝到FFFilm' OR label == '拷贝到 FFFilm'")).firstMatch
        if !target.isHittable {
            let more = photos.cells.matching(NSPredicate(format: "label IN {'More', '更多'}")).firstMatch
            if more.exists { more.tap() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), photos.debugDescription)
        target.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let imported = app.staticTexts["negative-dimensions"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        XCTAssertEqual(imported.label.filter(\.isNumber), "600800")
        XCTAssertFalse(app.buttons["negative-export"].isEnabled)
    }
}
#endif
