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
        let title = language == "en" ? "Film Simulation" : "胶片模拟"
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "tab-negative", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }

    @MainActor private func selectInputType(_ title: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any).matching(identifier: "negative-input-type").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if !picker.isHittable { app.swipeDown() }
        picker.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
    }

    @MainActor @discardableResult
    private func setLookStrength(_ slider: XCUIElement, in app: XCUIApplication, to target: CGFloat) -> CGFloat {
        if abs(target - slider.normalizedSliderPosition) > 0.02 {
            slider.adjust(toNormalizedSliderPosition: target)
            // A narrow native track can undershoot. Finish on the exact 5% stop with the operator's controls.
            let steps = Int(((target - slider.normalizedSliderPosition) / 0.05).rounded())
            let step = app.buttons[steps > 0 ? "negative-look-strength-increase" : "negative-look-strength-decrease"]
            for _ in 0..<abs(steps) { step.tap() }
        }
        let actual = slider.normalizedSliderPosition
        XCTAssertEqual(actual, target, accuracy: 0.02)
        if target == 0 { XCTAssertFalse(app.buttons["negative-look-strength-decrease"].isEnabled) }
        if target == 1 { XCTAssertFalse(app.buttons["negative-look-strength-increase"].isEnabled) }
        return actual
    }

    /// Drag the document margin to avoid panning the preview while revealing its controls.
    @MainActor private func revealDocumentControl(_ element: XCUIElement, in app: XCUIApplication, towardBottom: Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.frame.minY
        for _ in 0..<4 {
            if element.isHittable, element.frame.midY > top, element.frame.midY < bottom { return }
            let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.24))
            let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.72))
            (towardBottom ? low : high).press(forDuration: 0.05, thenDragTo: towardBottom ? high : low)
        }
        XCTFail("Document control is outside the visible page: \(element)")
    }

    /// Wait for Metal presentation and measure a small interior patch away from the reticle.
    @MainActor @discardableResult
    private func waitForRGB(_ description: String, in image: XCUIElement, context: CIContext,
                            matching matches: @escaping ([Int]) -> Bool) -> [Int] {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgb = [0, 0, 0]
        let condition = NSPredicate { _, _ in
            guard let bitmap = image.screenshot().image.cgImage else { return false }
            let frame = CIImage(cgImage: bitmap)
            let patch = CGRect(x: floor(frame.extent.width * 0.46) - 4, y: floor(frame.extent.height * 0.46) - 4, width: 9, height: 9)
            let mean = frame.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: patch)])
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(mean, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: sRGB)
            rgb = rgba.prefix(3).map(Int.init)
            return matches(rgb)
        }
        let visible = XCTNSPredicateExpectation(predicate: condition, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "\(description), last RGB \(rgb)")
        return rgb
    }

    @MainActor private func verifyFileLookRendering(in app: XCUIApplication, context: CIContext) {
        let image = app.descendants(matching: .any).matching(identifier: "negative-image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let options = app.buttons["negative-look-options"]
        let profiles = app.descendants(matching: .any).matching(identifier: "negative-look-picker").firstMatch
        let strength = app.sliders["negative-look-strength"]
        let done = app.buttons["negative-look-done"]
        // A positive scene can apply a look immediately. Negatives wait for film-base calibration.
        selectInputType("Camera scene", in: app)
        let original = waitForRGB("Original color", in: image, context: context) { $0[0] > $0[1] + 18 && $0[1] > $0[2] + 18 }
        revealDocumentControl(options, in: app, towardBottom: true)
        options.tap(); profiles.tap(); app.buttons["Classic B&W"].tap()
        let previousStrength = strength.normalizedSliderPosition
        setLookStrength(strength, in: app, to: 1)
        done.tap()
        let type = app.descendants(matching: .any).matching(identifier: "negative-input-type").firstMatch
        revealDocumentControl(type, in: app, towardBottom: false)
        let simulated = waitForRGB("Full-strength monochrome", in: image, context: context) { rgb in
            (40...230).contains(rgb[0]) && abs(rgb[0] - rgb[1]) <= 5 && abs(rgb[1] - rgb[2]) <= 5
        }
        let compare = app.buttons["negative-compare-original"]
        revealDocumentControl(compare, in: app, towardBottom: false)
        compare.tap()
        waitForRGB("Compare bypasses the selected look", in: image, context: context) { rgb in
            zip(rgb, original).allSatisfy { abs($0 - $1) <= 5 }
        }
        compare.tap()
        waitForRGB("Same simulation resumes", in: image, context: context) { rgb in
            zip(rgb, simulated).allSatisfy { abs($0 - $1) <= 5 }
        }
        revealDocumentControl(options, in: app, towardBottom: true)
        options.tap(); setLookStrength(strength, in: app, to: previousStrength)
        profiles.tap(); app.buttons["Standard"].tap(); done.tap()
        revealDocumentControl(type, in: app, towardBottom: false)
        waitForRGB("Restored source color", in: image, context: context) { rgb in zip(rgb, original).allSatisfy { abs($0 - $1) <= 5 } }
        XCTAssertFalse(compare.exists)
        selectInputType("Color negative", in: app)
    }

    @MainActor func testExternalDocumentOpensFilmPreview() throws {
        let context = CIContext()
        var files: [URL] = []
        defer { for url in files { try? FileManager.default.removeItem(at: url) } }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-fffilm.film-preview-input-type", "colorNegative"]
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
            if files.count == 1 {
                verifyFileLookRendering(in: app, context: context)
            } else {
                // A transparency already contains a positive image and can be shared immediately.
                selectInputType("Slide / transparency", in: app)
                XCTAssertFalse(app.buttons["negative-sample"].exists)
                XCTAssertFalse(app.buttons["negative-compare-original"].exists)
                let export = app.buttons["negative-export"]
                XCTAssertTrue(export.isEnabled)
                revealDocumentControl(export, in: app, towardBottom: true)
                export.tap()
                let png = app.buttons["negative-export-png"]
                XCTAssertTrue(png.waitForExistence(timeout: 5)); png.tap()
                let close = app.buttons.matching(NSPredicate(format: "identifier == 'header.closeButton' OR label IN {'Close', '关闭'}")).firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 25)); close.tap()
                let type = app.descendants(matching: .any).matching(identifier: "negative-input-type").firstMatch
                revealDocumentControl(type, in: app, towardBottom: false)
                selectInputType("Color negative", in: app)
                XCTAssertFalse(export.isEnabled)
            }
            app.tabBars.buttons["Calculate"].tap()
        }
    }

    @MainActor func testConfigurationLinkOpensRecordingOnColdLaunch() throws {
        let app = XCUIApplication()
        app.terminate()
        let url = try XCTUnwrap(URL(string: "fffilm://configuration?camera=alexa35&mode=open-gate&resolution=a35-open&codec=arriraw&project=24&sensor=24&sensorOverdrive=false&media=1tb&hours=1"))
        app.open(url)
        // Native alert actions can expose localized titles without a SwiftUI identifier.
        let apply = app.alerts.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "handoff-apply", ["Apply", "采用"])).firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 8), app.debugDescription)
        apply.tap()
        let result = app.descendants(matching: .any).matching(identifier: "plan-capacity-output").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "record-time-output").firstMatch.exists)
        XCTAssertFalse(app.buttons["negative-sample"].exists)
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
        let context = CIContext()
        let original = waitForRGB("Warm unprocessed camera frame", in: image, context: context) { rgb in
            rgb[0] > rgb[1] + 18 && rgb[1] > rgb[2] + 15
        }
        let compare = app.buttons["negative-compare-original"]
        XCTAssertFalse(compare.exists)
        XCTAssertTrue(app.staticTexts["negative-camera-macro-status"].waitForExistence(timeout: 5))
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Ordinary taps focus; only explicit sampling enters the confirmation workflow.
        XCTAssertFalse(app.buttons["negative-confirm-base"].exists)
        // The camera surface reaches the window edges while controls stay inside the safe area.
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertEqual(image.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(image.frame.minY, app.frame.minY, accuracy: 1)
        XCTAssertEqual(image.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(image.frame.height, app.frame.height, accuracy: 1)
        let liveScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        liveScreenshot.name = "Immersive camera portrait"; liveScreenshot.lifetime = .keepAlways; add(liveScreenshot)
        app.buttons["negative-sample"].tap()
        let confirm = app.buttons["negative-confirm-base"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        XCTAssertLessThan(image.frame.height, app.frame.height * 0.8)
        let sampleScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sampleScreenshot.name = "Immersive camera sampling"; sampleScreenshot.lifetime = .keepAlways; add(sampleScreenshot)
        confirm.tap()
        let export = app.buttons["negative-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10)); XCTAssertTrue(export.isEnabled)
        // The uniform fixture center matches its sampled base, which converts to black immediately.
        waitForRGB("Automatic calibrated positive", in: image, context: context) { $0.allSatisfy { $0 < 16 } }
        XCTAssertTrue(compare.waitForExistence(timeout: 5))
        compare.tap()
        waitForRGB("Compare bypasses inversion", in: image, context: context) { rgb in
            zip(rgb, original).allSatisfy { abs($0 - $1) <= 5 }
        }
        compare.tap()
        waitForRGB("Calibrated result resumes", in: image, context: context) { $0.allSatisfy { $0 < 16 } }
        app.buttons["negative-camera-settings"].tap()
        // The fixture reports 20 millimeters, which must render as 2 centimeters.
        let distance = app.staticTexts["negative-camera-minimum-distance"]
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        XCTAssertEqual(distance.label, "2")
        let resolution = app.descendants(matching: .any).matching(identifier: "negative-camera-resolution").firstMatch
        if !resolution.isHittable { app.swipeUp() }
        // The default is now Full HD; exercise an actual configuration change.
        resolution.tap(); app.buttons["720p"].tap()
        let dimensions = app.staticTexts["negative-dimensions"]
        // Dimensions are localized (for example, 1,080 × 1,920 in English).
        expectation(for: NSPredicate { _, _ in dimensions.label.filter(\.isNumber) == "7201280" }, evaluatedWith: dimensions)
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
        let wheel = app.descendants(matching: .any).matching(identifier: "negative-film-look").firstMatch
        wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 5.0 / 6)).tap()
        XCTAssertEqual(wheel.value as? String, "Soft color negative")
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
        XCTAssertEqual(app.buttons["negative-look-options"].value as? String, "Soft color negative")
        let reopen = app.buttons["negative-camera-fullscreen"]
        if !reopen.isHittable { app.swipeUp() }
        reopen.tap()
        XCTAssertTrue(app.buttons["negative-camera-close"].waitForExistence(timeout: 5))
        selectInputType("Camera scene", in: app)
        XCTAssertFalse(app.buttons["negative-sample"].exists)
        XCTAssertFalse(app.buttons["negative-compare-original"].exists)
        XCTAssertFalse(export.exists && export.isEnabled)
        XCTAssertTrue(wheel.exists)
        selectInputType("Black & white negative", in: app)
        app.buttons["negative-sample"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10); confirm.tap()
        XCTAssertTrue(export.isEnabled)
        selectInputType("Color negative", in: app)
        XCTAssertFalse(export.isEnabled)
    }

    @MainActor func testLiveCameraZoomComparisonAndFreeze() {
        let app = XCUIApplication()
        app.launchEnvironment["NEGATIVE_UI_CAMERA"] = "1"
        app.launchEnvironment["NEGATIVE_UI_CAMERA_STREAM"] = "1"
        openNegative(app, language: "zh-Hans")
        let image = app.descendants(matching: .any).matching(identifier: "negative-image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let compare = app.buttons["negative-compare-original"]
        let look = app.descendants(matching: .any).matching(identifier: "negative-film-look").firstMatch
        XCTAssertTrue(look.waitForExistence(timeout: 5))
        func expectLook(_ value: String) {
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: look)
            waitForExpectations(timeout: 5)
        }
        func tapNextLook() {
            look.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 5.0 / 6)).tap()
        }
        expectLook("标准")
        tapNextLook(); expectLook("柔和彩负")
        app.buttons["negative-look-options"].tap()
        let strength = app.sliders["negative-look-strength"]
        XCTAssertTrue(strength.waitForExistence(timeout: 5))
        let oldSoftStrength = strength.normalizedSliderPosition
        setLookStrength(strength, in: app, to: 0)
        let softStrength = setLookStrength(strength, in: app, to: 0.25)
        let profiles = app.descendants(matching: .any).matching(identifier: "negative-look-picker").firstMatch
        let portra = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Portra 400")).firstMatch
        profiles.tap(); portra.tap()
        let oldPortraStrength = strength.normalizedSliderPosition
        let portraStrength = setLookStrength(strength, in: app, to: 0.8)
        let options = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        options.name = "PORTRA 400 preview strength"; options.lifetime = .keepAlways; add(options)
        profiles.tap(); app.buttons["柔和彩负"].tap()
        XCTAssertEqual(strength.normalizedSliderPosition, softStrength, accuracy: 0.02)
        setLookStrength(strength, in: app, to: oldSoftStrength)
        profiles.tap(); portra.tap()
        XCTAssertEqual(strength.normalizedSliderPosition, portraStrength, accuracy: 0.02)
        setLookStrength(strength, in: app, to: oldPortraStrength)
        app.buttons["negative-look-done"].tap()
        XCTAssertTrue((look.value as? String)?.localizedCaseInsensitiveContains("Portra 400") == true)
        app.buttons["negative-look-options"].tap()
        profiles.tap(); app.buttons["柔和彩负"].tap()
        app.buttons["negative-look-done"].tap()
        expectLook("柔和彩负")
        tapNextLook(); expectLook("鲜艳反转片")
        XCTAssertFalse(compare.exists)
        let liveDial = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        liveDial.name = "Live film preset thumbwheel"; liveDial.lifetime = .keepAlways; add(liveDial)
        // Inspection gestures must neither sample nor disable the live controls.
        image.doubleTap()
        XCTAssertFalse(app.buttons["negative-confirm-base"].exists)
        XCTAssertTrue(app.buttons["negative-camera-settings"].isEnabled)
        let zoom = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        zoom.name = "Live GPU preview zoomed"; zoom.lifetime = .keepAlways; add(zoom)
        image.doubleTap()
        app.buttons["negative-sample"].tap()
        let confirm = app.buttons["negative-confirm-base"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertFalse(look.exists)
        app.buttons["取消"].firstMatch.tap()
        expectLook("鲜艳反转片")
        app.buttons["negative-sample"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 10)
        confirm.tap()
        XCTAssertTrue(compare.waitForExistence(timeout: 5))
        expectLook("鲜艳反转片")
        XCTAssertTrue(app.buttons["negative-export"].isEnabled)
        let freeze = app.buttons["negative-camera-freeze"]
        freeze.tap()
        XCTAssertFalse(app.buttons["negative-camera-settings"].isEnabled)
        XCTAssertTrue(app.buttons["negative-export"].isEnabled)
        let frozen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        frozen.name = "GPU positive frozen after comparison"; frozen.lifetime = .keepAlways; add(frozen)
        // Classic B&W is followed by manufacturer profiles, so reach it by exact detents.
        tapNextLook(); expectLook("经典黑白")
        let simulated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        simulated.name = "Frozen classic monochrome"; simulated.lifetime = .keepAlways; add(simulated)
        compare.tap(); compare.tap()
        expectLook("经典黑白")
        look.swipeUp()
        expectation(for: NSPredicate(format: "value != %@", "经典黑白"), evaluatedWith: look)
        waitForExpectations(timeout: 5)
        for _ in 0..<8 where look.value as? String != "标准" { look.swipeDown() }
        expectLook("标准")
        freeze.tap()
        XCTAssertTrue(app.buttons["negative-camera-settings"].isEnabled)
        XCTAssertFalse(app.staticTexts["negative-error"].exists)
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
        let wheel = app.descendants(matching: .any).matching(identifier: "negative-film-look").firstMatch
        wheel.swipeUp()
        expectation(for: NSPredicate(format: "value != %@", "Standard"), evaluatedWith: wheel)
        waitForExpectations(timeout: 5)
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
        revealDocumentControl(sample, in: app, towardBottom: true)
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
        app.tabBars.buttons["Film Simulation"].tap()
        XCTAssertTrue(export.waitForExistence(timeout: 5)); XCTAssertTrue(export.isEnabled)
        let compare = app.buttons["negative-compare-original"]
        revealDocumentControl(compare, in: app, towardBottom: false)
        compare.tap(); compare.tap()
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
        // Round-trip the generated photo through the real system share sheet into Film Simulation.
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
