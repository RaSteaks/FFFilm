import XCTest

final class FFFilmUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCalculatorLaunchesWithCoreControls() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["FORMAT & DATA"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reset-action"].firstMatch.exists)
        XCTAssertTrue(app.buttons["pin-action"].firstMatch.exists)
        let result = app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch
        let controls = app.descendants(matching: .any).matching(identifier: "capture-controls").firstMatch
        XCTAssertTrue(result.exists)
        XCTAssertTrue(controls.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "record-time-output").firstMatch.exists)

        #if os(iOS)
        if app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width {
            // The portrait phone layout keeps the live result above the detailed capture controls.
            XCTAssertLessThan(result.frame.minY, controls.frame.minY)
        }
        #endif
    }

    @MainActor
    func testPrimaryActionsExposeImmediateFeedback() throws {
        let app = XCUIApplication()
        app.launch()

        let copyButton = app.buttons["copy-action"].firstMatch
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.tap()
        #if os(macOS)
        XCTAssertEqual(copyButton.label, "Copied")
        #else
        XCTAssertEqual(copyButton.label, "COPIED")
        #endif

        app.buttons["pin-action"].firstMatch.tap()
        let pinnedSetup = app.descendants(matching: .any).matching(identifier: "pinned-setups").firstMatch
        XCTAssertTrue(pinnedSetup.waitForExistence(timeout: 2))
    }

    @MainActor
    private func shutterApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Stable English labels make these interaction tests independent of the host test-plan locale.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        #if os(macOS)
        app.typeKey("2", modifierFlags: .command)
        #else
        app.segmentedControls.buttons["SHUTTER"].tap()
        #endif
        if !app.textFields["shutter-sensorFps"].waitForExistence(timeout: 3) {
            XCTFail("Missing camera FPS field: \(app.debugDescription)")
        }
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 8 {
            if element.isHittable { break }
            if element.exists, element.frame.midY < app.windows.firstMatch.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func enter(_ text: String, field name: String, in app: XCUIApplication) {
        let field = app.textFields["shutter-\(name)"]
        reveal(field, in: app)
        field.tap()
        // Keyboard insets and the app's focus-centering task must settle before selecting text.
        Thread.sleep(forTimeInterval: 0.6)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        #else
        // Select the complete value using the editing menu; a tap does not guarantee an end caret.
        let old = field.value as? String ?? ""
        if !old.isEmpty, old != field.placeholderValue {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(forDuration: 1.2)
            let selectAll = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
                .firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 2), app.debugDescription)
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        if !text.isEmpty { field.typeText(text) }
        if text.isEmpty {
            let value = field.value as? String ?? ""
            XCTAssertTrue(value.isEmpty || value == field.placeholderValue)
        } else {
            XCTAssertEqual(field.value as? String ?? "", text)
        }
        #endif
    }

    @MainActor
    private func finishEditing(_ app: XCUIApplication) {
        #if os(iOS)
        if app.buttons["DONE"].exists { app.buttons["DONE"].tap() }
        #else
        app.typeKey(.tab, modifierFlags: [])
        #endif
    }

    @MainActor
    private func choose(_ label: String, picker: String, in app: XCUIApplication) {
        finishEditing(app)
        let control = app.descendants(matching: .any).matching(identifier: picker).firstMatch
        reveal(control, in: app)
        control.tap()
        #if os(macOS)
        app.menuItems[label].firstMatch.tap()
        #else
        app.buttons[label].firstMatch.tap()
        #endif
    }

    @MainActor
    func testShutterAcceptsCustomFrameRateInput() throws {
        let app = shutterApp()
        enter("23.976", field: "sensorFps", in: app)
        enter("172.8", field: "angle", in: app)
        finishEditing(app)
        XCTAssertTrue(app.staticTexts["shutter-time-output"].label.contains("1/49.95 s"))
        let result = app.descendants(matching: .any).matching(identifier: "shutter-results").firstMatch
        let controls = app.descendants(matching: .any).matching(identifier: "shutter-controls").firstMatch
        #if os(iOS)
        if app.windows.firstMatch.frame.width < 600 { XCTAssertLessThan(result.frame.minY, controls.frame.minY) }
        #endif
        reveal(app.staticTexts["shutter-angle-output"], in: app)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Shutter decimal conversion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testShutterInvalidInputRecoversAndResetClearsDraft() throws {
        let app = shutterApp()
        enter("", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shutter-error-sensorFps").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shutter-angle-output"].exists)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertTrue(app.staticTexts["shutter-time-output"].label.contains("1/120 s"))
        let reset = app.buttons["reset-action"].firstMatch
        reveal(reset, in: app)
        reset.tap()
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        XCTAssertTrue(app.staticTexts["shutter-time-output"].label.contains("1/48 s"))
    }

    @MainActor
    func testShutterFlickerEmptyAndMatchingModes() throws {
        let app = shutterApp()
        // 使用 MODE 当前的中文描述选择模式。
        choose("频闪参考快门", picker: "shutter-mode", in: app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "172.8°")
        enter("120", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shutter-no-candidates").firstMatch.exists)
        choose("升格 / 降格", picker: "shutter-mode", in: app)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "450°")
        choose("Keep angle", picker: "shutter-match", in: app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "180°")
        XCTAssertTrue(app.staticTexts["shutter-time-output"].label.contains("1/120 s"))
        // Supporting readouts are hidden until the single details disclosure is expanded.
        XCTAssertFalse(app.staticTexts["shutter-playback-output"].exists)
        let details = app.staticTexts["DETAILS"].firstMatch
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.staticTexts["shutter-playback-output"].label.contains("0.4×"))
        let check = app.switches["shutter-light-check"]
        reveal(check, in: app)
        check.tap()
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "180°")
        reveal(app.staticTexts["shutter-angle-output"], in: app)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Shutter matching with light check"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testShutterImportDoesNotCreatePersistentLink() throws {
        let app = shutterApp()
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        let importButton = app.buttons["shutter-import"]
        reveal(importButton, in: app)
        importButton.tap()
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        enter("48", field: "sensorFps", in: app)
        finishEditing(app)
        #if os(macOS)
        app.typeKey("1", modifierFlags: .command)
        #else
        reveal(app.segmentedControls.buttons["RATE"], in: app)
        app.segmentedControls.buttons["RATE"].tap()
        #endif
        #if os(macOS)
        app.typeKey("2", modifierFlags: .command)
        #else
        app.segmentedControls.buttons["SHUTTER"].tap()
        #endif
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "48")
        reveal(importButton, in: app)
        importButton.tap()
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
    }

    @MainActor
    private func activateCameraControl(_ element: XCUIElement) {
        // Desktop tests must synthesize a mouse click, while iPhone tests use a touch tap.
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    func testCameraCatalogFavoritesAndDetails() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let library = app.buttons["camera-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        activateCameraControl(library)
        let favorites = app.descendants(matching: .any).matching(identifier: "camera-favorites").firstMatch
        XCTAssertTrue(favorites.waitForExistence(timeout: 3))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.exists)
        activateCameraControl(search)
        search.typeText("MAVO")
        // A specific match proves filtering finished before exercising the row actions.
        let camera = app.descendants(matching: .any).matching(identifier: "catalog-camera-mavo-edge-6k").firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 3))
        let cameraID = camera.identifier.replacingOccurrences(of: "catalog-camera-", with: "")
        let favorite = app.buttons["favorite-toggle-\(cameraID)"]
        let wasFavorite = favorite.value as? String == "Favorite"
        if !wasFavorite { activateCameraControl(favorite) }
        XCTAssertEqual(favorite.value as? String, "Favorite")
        activateCameraControl(camera)
        XCTAssertTrue(app.buttons["favorite-toggle-\(cameraID)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sensor"].exists)
        let earlier = app.buttons["favorite-move-earlier"]
        XCTAssertTrue(earlier.exists)
        if !wasFavorite {
            activateCameraControl(earlier)
            activateCameraControl(app.buttons["favorite-move-later"])
            activateCameraControl(app.buttons["favorite-toggle-\(cameraID)"])
            XCTAssertEqual(app.buttons["favorite-toggle-\(cameraID)"].value as? String, "Not favorite")
            XCTAssertFalse(earlier.exists)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Camera catalog detail"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    #if os(macOS)
    @MainActor
    func testMacWorkbenchToolbarAndKeyboardActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["reset-action"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.toolbars.buttons["copy-action"].exists)
        XCTAssertTrue(app.staticTexts["Recording calculator"].exists)
        let rateScreenshot = XCTAttachment(screenshot: app.screenshot())
        rateScreenshot.name = "Native macOS recording workbench"
        rateScreenshot.lifetime = .keepAlways
        add(rateScreenshot)

        // Commands target the active window; toolbar shortcuts preserve standard text-field Copy.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.textFields["shutter-sensorFps"].waitForExistence(timeout: 2))
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "60")
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Recording calculator"].exists)
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pinned-setups").firstMatch.exists)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.buttons["copy-action"].firstMatch.label, "Copied")
    }
    #endif

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) { XCUIApplication().launch() }
    }
}
