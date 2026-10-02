import XCTest

#if os(iOS)
import UIKit
#endif

final class FFFilmUITests: XCTestCase {
    // Mirrors the app's 900pt usable-width threshold plus two 12pt page gutters.
    private let splitWindowWidth: CGFloat = 924

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCalculatorLaunchesWithCoreControls() throws {
        let app = XCUIApplication()
        app.launch()
        // Identifiers only: the simulator language may differ from English.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "app-title").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["more-action"].firstMatch.exists)
        XCTAssertTrue(app.buttons["pin-action"].firstMatch.exists)
        let result = app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch
        let controls = app.descendants(matching: .any).matching(identifier: "capture-controls").firstMatch
        XCTAssertTrue(result.exists)
        XCTAssertTrue(controls.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "record-time-output").firstMatch.exists)

        #if os(iOS)
        let windowWidth = app.windows.firstMatch.frame.width
        if windowWidth < splitWindowWidth, app.windows.firstMatch.frame.height > windowWidth {
            // Narrow iPad windows and portrait phones keep the live result first.
            XCTAssertLessThan(result.frame.minY, controls.frame.minY)
        } else if windowWidth >= splitWindowWidth {
            // Wide iPad windows show parameters beside the live result.
            XCTAssertLessThan(controls.frame.maxX, result.frame.minX)
        }
        #endif
    }

    @MainActor
    func testRecordingTasksSeparateInputsAndPreserveDuration() throws {
        verifyRecordingTasks(chinese: false)
    }

    @MainActor
    func testRecordingTasksInChinese() throws {
        verifyRecordingTasks(chinese: true)
    }

    @MainActor
    private func verifyRecordingTasks(chinese: Bool) {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", chinese ? "(zh-Hans)" : "(en)", "-AppleLocale", chinese ? "zh_CN" : "en_US"]
        app.launch()
        let picker = app.segmentedControls["recording-task-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let capacity = picker.buttons[chinese ? "拍摄容量" : "Storage needed"]
        let runtime = picker.buttons[chinese ? "可录制时长" : "Recording time"]
        let duration = app.textFields["capture-duration"].firstMatch
        let preset = app.buttons["duration-quick-4"].firstMatch
        reveal(preset, in: app)
        preset.tap()
        XCTAssertEqual(duration.value as? String, "4.00")
        reveal(picker, in: app)
        let capacityScreenshot = XCTAttachment(screenshot: app.screenshot())
        capacityScreenshot.name = chinese ? "拍摄容量" : "Storage needed"
        capacityScreenshot.lifetime = .keepAlways
        add(capacityScreenshot)
        runtime.tap()
        XCTAssertFalse(duration.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan-capacity-output").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "card-runtime-output").firstMatch.exists)
        let media = app.descendants(matching: .any).matching(identifier: "capture-media").firstMatch
        reveal(media, in: app)
        media.tap()
        app.buttons["1 TB"].firstMatch.tap()
        reveal(picker, in: app)
        let runtimeScreenshot = XCTAttachment(screenshot: app.screenshot())
        runtimeScreenshot.name = chinese ? "可录制时长" : "Recording time"
        runtimeScreenshot.lifetime = .keepAlways
        add(runtimeScreenshot)
        capacity.tap()
        XCTAssertFalse(media.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "plan-capacity-output").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "card-runtime-output").firstMatch.exists)
        XCTAssertEqual(duration.value as? String, "4.00")
        // An invalid draft must survive hiding its field and returning to capacity planning.
        enterText("30", into: duration, in: app)
        finishDurationEditing(app)
        reveal(picker, in: app)
        runtime.tap()
        capacity.tap()
        XCTAssertEqual(duration.value as? String, "30")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "duration-error").firstMatch.exists)
    }

    #if os(iOS)
    /// Native tab buttons can expose their localized label instead of the Tab
    /// identifier on older SDKs; both selectors remain scoped to the tab bar.
    @MainActor
    private func tabButton(_ destination: String, in app: XCUIApplication) -> XCUIElement {
        let labels: [String]
        switch destination {
        case "rate": labels = ["Calculate", "计算"]
        case "shutter": labels = ["Shutter", "快门"]
        default: labels = ["Settings", "设置"]
        }
        return app.tabBars.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label IN %@", "tab-\(destination)", labels
        )).firstMatch
    }

    @MainActor
    private func selectTab(_ destination: String, in app: XCUIApplication) {
        let button = tabButton(destination, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 3), app.debugDescription)
        button.tap()
    }

    @MainActor
    func testAppLanguageSwitchesImmediatelyAndPersists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FFFILM_UI_RESET_LANGUAGE"] = "1"
        app.launch()
        // Clear only this test's preference when finished so system-language tests stay isolated.
        defer {
            app.terminate()
            app.launchEnvironment["FFFILM_UI_RESET_LANGUAGE"] = "1"
            app.launch()
            app.terminate()
        }
        let duration = app.textFields["capture-duration"].firstMatch
        let preset = app.buttons["duration-quick-4"].firstMatch
        reveal(preset, in: app)
        preset.tap()
        selectTab("shutter", in: app)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        selectTab("settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        choose("简体中文", picker: "app-language-picker", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["计算"].exists)
        XCTAssertTrue(app.tabBars.buttons["胶片预览"].exists)
        let unit = app.descendants(matching: .any).matching(identifier: "storage-unit-picker").firstMatch
        XCTAssertTrue((unit.label + " " + (unit.value as? String ?? "")).contains("进制"))
        let chinese = XCTAttachment(screenshot: app.screenshot())
        chinese.name = "Settings - Simplified Chinese"
        chinese.lifetime = .keepAlways
        add(chinese)
        selectTab("shutter", in: app)
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "60")
        selectTab("rate", in: app)
        XCTAssertEqual(duration.value as? String, "4.00")
        enterText("30", into: duration, in: app)
        finishDurationEditing(app)
        XCTAssertTrue(app.staticTexts["请输入 0.25–24 小时范围内的数值。"].exists)
        selectTab("settings", in: app)
        choose("English", picker: "app-language-picker", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        selectTab("rate", in: app)
        XCTAssertEqual(duration.value as? String, "30")
        XCTAssertTrue(app.staticTexts["Enter a value from 0.25 to 24 hours."].exists)
        selectTab("settings", in: app)
        let english = XCTAttachment(screenshot: app.screenshot())
        english.name = "Settings - English"
        english.lifetime = .keepAlways
        add(english)

        // Relaunch under the opposite system language to prove the explicit choice wins.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "FFFILM_UI_RESET_LANGUAGE")
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        selectTab("settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        choose("简体中文", picker: "app-language-picker", in: app)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        selectTab("settings", in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testBottomTabsKeepSettingsAndCalculatorStateIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        // Negative preview adds a fourth workspace without changing calculator state.
        XCTAssertEqual(tabBar.buttons.count, 4)
        XCTAssertFalse(app.segmentedControls["calculator-view-picker"].exists)
        XCTAssertFalse(app.buttons["settings-action"].exists)
        for destination in ["rate", "shutter", "settings"] {
            let button = tabButton(destination, in: app)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThan(button.frame.midY, app.windows.firstMatch.frame.maxY * 0.75)
        }
        // Keep every tab's actual native chrome available for visual review.
        let calculateScreenshot = XCTAttachment(screenshot: app.screenshot())
        calculateScreenshot.name = "Bottom navigation - Calculate"
        calculateScreenshot.lifetime = .keepAlways
        add(calculateScreenshot)

        let duration = app.textFields["capture-duration"].firstMatch
        let quick12 = app.buttons["duration-quick-12"].firstMatch
        reveal(quick12, in: app)
        quick12.tap()
        XCTAssertEqual(duration.value as? String, "12.00")
        selectTab("shutter", in: app)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        let shutterScreenshot = XCTAttachment(screenshot: app.screenshot())
        shutterScreenshot.name = "Bottom navigation - Shutter at 60 FPS"
        shutterScreenshot.lifetime = .keepAlways
        add(shutterScreenshot)

        selectTab("settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
        settingsScreenshot.name = "Bottom navigation - Settings navigation bar"
        settingsScreenshot.lifetime = .keepAlways
        add(settingsScreenshot)
        XCTAssertFalse(app.buttons["settings-done"].exists)
        let picker = app.descendants(matching: .any).matching(identifier: "storage-unit-picker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let selectedUnit = (picker.value as? String ?? "") + " " + picker.label
        XCTAssertTrue(selectedUnit.contains("GB") || selectedUnit.contains("GiB"), selectedUnit)
        let wasBinary = selectedUnit.contains("GiB")
        let decimal = "Decimal · 1 GB = 1000 MB"
        let binary = "Binary · 1 GiB = 1024 MiB"
        // Restore the app-wide preference so later tests keep their original units.
        defer {
            selectTab("settings", in: app)
            choose(wasBinary ? binary : decimal, picker: "storage-unit-picker", in: app)
        }
        choose(wasBinary ? decimal : binary, picker: "storage-unit-picker", in: app)

        selectTab("rate", in: app)
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        XCTAssertEqual(duration.value as? String, "12.00")
        let expectedUnit = wasBinary ? "GB per hour" : "GiB per hour"
        let result = app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch
        XCTAssertTrue(result.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", expectedUnit)).firstMatch.waitForExistence(timeout: 3))
        // An empty duration is still an editor draft, not a request to reload the model.
        enterText("", into: duration, in: app)
        finishDurationEditing(app)
        selectTab("settings", in: app)
        selectTab("rate", in: app)
        let durationDraft = duration.value as? String ?? ""
        XCTAssertTrue(durationDraft.isEmpty || durationDraft == duration.placeholderValue)
        selectTab("shutter", in: app)
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "60")

        // A tab switch must also retain invalid editor text instead of rebuilding
        // the field from its last committed numeric value.
        enter("", field: "sensorFps", in: app)
        finishEditing(app)
        selectTab("settings", in: app)
        selectTab("shutter", in: app)
        let field = app.textFields["shutter-sensorFps"]
        let draft = field.value as? String ?? ""
        XCTAssertTrue(draft.isEmpty || draft == field.placeholderValue)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "shutter-error-sensorFps").firstMatch.exists)
    }

    @MainActor
    func testIPadWorkbenchAndCatalogKeepVisibleContext() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<30 where app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)

        let rateControls = app.descendants(matching: .any).matching(identifier: "capture-controls").firstMatch
        let rateResult = app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch
        XCTAssertTrue(rateControls.waitForExistence(timeout: 5))
        if app.windows.firstMatch.frame.width >= splitWindowWidth {
            XCTAssertLessThan(rateControls.frame.maxX, rateResult.frame.minX)
        } else {
            XCTAssertLessThan(rateResult.frame.minY, rateControls.frame.minY)
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        // Rotation is asynchronous in XCTest; wait for the app window's
        // geometry before checking the responsive two-column placement.
        for _ in 0..<30 where app.windows.firstMatch.frame.width <= app.windows.firstMatch.frame.height {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        XCTAssertLessThan(rateControls.frame.maxX, rateResult.frame.minX)

        selectTab("shutter", in: app)
        let shutterControls = app.descendants(matching: .any).matching(identifier: "shutter-controls").firstMatch
        let shutterResult = app.descendants(matching: .any).matching(identifier: "shutter-results").firstMatch
        XCTAssertTrue(shutterControls.waitForExistence(timeout: 3))
        if app.windows.firstMatch.frame.width >= splitWindowWidth {
            XCTAssertLessThan(shutterControls.frame.maxX, shutterResult.frame.minX)
        }

        selectTab("settings", in: app)
        let storagePicker = app.descendants(matching: .any).matching(identifier: "storage-unit-picker").firstMatch
        XCTAssertTrue(storagePicker.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(storagePicker.frame.width, 680)
        selectTab("rate", in: app)

        app.buttons["camera-library"].firstMatch.tap()
        let camera = app.descendants(matching: .any).matching(identifier: "catalog-camera-alexa35").firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "camera-detail").firstMatch.waitForExistence(timeout: 3))
        if app.windows.firstMatch.frame.width >= splitWindowWidth {
            XCTAssertTrue(camera.isHittable)
        }
    }

    @MainActor
    func testWidePhoneLandscapeKeepsShutterControlsFirst() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        for _ in 0..<30 where app.windows.firstMatch.frame.width <= app.windows.firstMatch.frame.height {
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Only wide phones exercise the former regular-width stack order.
        guard app.windows.firstMatch.frame.width >= splitWindowWidth else { return }

        selectTab("shutter", in: app)
        let controls = app.descendants(matching: .any).matching(identifier: "shutter-controls").firstMatch
        let result = app.descendants(matching: .any).matching(identifier: "shutter-results").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 3))
        XCTAssertTrue(result.exists)
        XCTAssertLessThan(controls.frame.minY, result.frame.minY)
    }
    #endif

    @MainActor
    func testPrimaryActionsExposeImmediateFeedback() throws {
        let app = XCUIApplication()
        app.launch()

        let copyButton = app.buttons["copy-action"].firstMatch
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        // The label changes to the localized "copied" state; the exact wording
        // depends on the simulator language, so compare against the rest state.
        let restLabel = copyButton.label
        copyButton.tap()
        XCTAssertNotEqual(copyButton.label, restLabel)

        app.buttons["pin-action"].firstMatch.tap()
        let pinnedSetup = app.descendants(matching: .any).matching(identifier: "pinned-setups").firstMatch
        XCTAssertTrue(pinnedSetup.waitForExistence(timeout: 2))
    }

    @MainActor
    func testDurationDirectInputCommitsOnlyOnSubmit() throws {
        let app = XCUIApplication()
        // Number formatting is locale-dependent; pin the language for value checks.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let field = app.textFields["capture-duration"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String ?? "", "8.00")

        // Decimal typing must survive intermediate states ("2" alone is valid).
        enterText("2.5", into: field, in: app)
        finishDurationEditing(app)
        XCTAssertEqual(field.value as? String ?? "", "2.50")

        // Out-of-range input keeps the last valid plan and surfaces an inline error.
        enterText("30", into: field, in: app)
        finishDurationEditing(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "duration-error").firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(field.value as? String ?? "", "30")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch.exists)

        // Quick presets share the store path and clear the error.
        let quick = app.buttons["duration-quick-4"].firstMatch
        reveal(quick, in: app)
        quick.tap()
        XCTAssertEqual(field.value as? String ?? "", "4.00")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "duration-error").firstMatch.exists)
    }

    #if os(iOS)
    /// XCTest sheet hit-testing is unreliable on the available macOS host, so
    /// the comparison sheet flow runs on iOS only (AGENT.md, camera catalog).
    @MainActor
    func testComparisonSheetAddsViewsAndRemovesSnapshots() throws {
        let app = XCUIApplication()
        app.launch()
        let view = app.buttons["comparison-view"].firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        XCTAssertFalse(view.isEnabled)

        let add = app.buttons["comparison-add"].firstMatch
        reveal(add, in: app)
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "feedback-banner").firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(view.isEnabled)

        view.tap()
        let snapshot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'comparison-snapshot-'")).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 3))
        let remove = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'comparison-remove-'")).firstMatch
        XCTAssertTrue(remove.exists)
        remove.tap()

        let done = app.buttons["comparison-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        done.tap()
        let disabled = NSPredicate(format: "isEnabled == false")
        let expectation = XCTNSPredicateExpectation(predicate: disabled, object: view)
        XCTWaiter().wait(for: [expectation], timeout: 4)
        XCTAssertFalse(view.isEnabled)
    }

    @MainActor
    func testStandaloneProResComparisonNamesProjectFPS() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // The ProRes quick-start bypasses the camera picker's virtualized list.
        let proRes = app.buttons["PRORES"].firstMatch
        XCTAssertTrue(proRes.waitForExistence(timeout: 3))
        proRes.tap()
        let add = app.buttons["comparison-add"].firstMatch
        reveal(add, in: app)
        add.tap()
        app.buttons["comparison-view"].firstMatch.tap()
        let snapshot = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'comparison-snapshot-'")).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: 3))
        // The stored cadence is project FPS for standalone ProRes, including in comparisons.
        XCTAssertTrue(snapshot.staticTexts["Project FPS"].exists)
        XCTAssertFalse(snapshot.staticTexts["Sensor FPS"].exists)
    }
    #endif

    @MainActor
    func testRateResetFromMoreMenuOfferedOneStepUndo() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let field = app.textFields["capture-duration"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let quick12 = app.buttons["duration-quick-12"].firstMatch
        reveal(quick12, in: app)
        quick12.tap()
        XCTAssertEqual(field.value as? String ?? "", "12.00")

        #if os(macOS)
        app.typeKey("r", modifierFlags: [.command, .shift])
        #else
        openMore(in: app)
        let reset = app.buttons["reset-action"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()
        #endif

        let undo = app.buttons["reset-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        // Reset restored the default plan; undo brings the edited plan back.
        XCTAssertEqual(field.value as? String ?? "", "8.00")
        undo.tap()
        XCTAssertEqual(field.value as? String ?? "", "12.00")
        XCTAssertFalse(app.buttons["reset-undo"].firstMatch.exists)
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
        selectTab("shutter", in: app)
        #endif
        if !app.textFields["shutter-sensorFps"].waitForExistence(timeout: 3) {
            XCTFail("Missing camera FPS field: \(app.debugDescription)")
        }
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0 ..< 10 {
            if element.isHittable { break }
            guard element.exists else { break }
            // Short center drags avoid the momentum oscillation full swipes
            // cause around partially clipped fields.
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            if element.frame.midY < window.midY {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        XCTAssertTrue(element.isHittable, "never became hittable: \(element)")
    }

    @MainActor
    private func enter(_ text: String, field name: String, in app: XCUIApplication) {
        enterText(text, into: app.textFields["shutter-\(name)"], in: app)
    }

    @MainActor
    private func enterText(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        dismissKeyboardFocus(in: app)
        reveal(field, in: app)
        field.tap()
        // Keyboard insets and the app's focus-centering task must settle before selecting text.
        Thread.sleep(forTimeInterval: 0.6)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        #else
        replaceFieldText(text, field: field, app: app)
        if text.isEmpty {
            let value = field.value as? String ?? ""
            XCTAssertTrue(value.isEmpty || value == field.placeholderValue)
        } else {
            XCTAssertEqual(field.value as? String ?? "", text)
        }
        #endif
    }

    /// A focused field keeps its keyboard toolbar over the lower form; dismiss
    /// it so the next reveal works on a calm layout.
    @MainActor
    private func dismissKeyboardFocus(in app: XCUIApplication) {
        #if os(iOS)
        for identifier in ["shutter-done", "duration-done", "DONE"] where app.buttons[identifier].exists {
            app.buttons[identifier].tap()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        #endif
    }

    /// Replaces the whole field content on iOS. The automation host keeps a
    /// hardware keyboard attached, so the software keyboard never shows, the
    /// long-press edit menu never appears, and delete-key events are dropped
    /// for some fields (verified against screen recordings). A two-finger tap
    /// selects the whole single-paragraph content; typing then replaces the
    /// selection outright. Verified per-key deletes and the edit menu remain
    /// as fallbacks.
    @MainActor
    private func replaceFieldText(_ text: String, field: XCUIElement, app: XCUIApplication) {
        func settled() -> Bool {
            let value = field.value as? String ?? ""
            return text.isEmpty ? (value.isEmpty || value == field.placeholderValue) : value == text
        }
        for _ in 0 ..< 2 {
            if settled() { return }
            #if os(iOS)
            field.twoFingerTap()
            Thread.sleep(forTimeInterval: 0.3)
            #endif
            field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
            Thread.sleep(forTimeInterval: 0.3)
            if settled() { return }
            deleteBackward(field)
            clearThroughMenu(field, app: app)
            if !text.isEmpty { field.typeText(text) }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    @MainActor
    private func clearThroughMenu(_ field: XCUIElement, app: XCUIApplication) {
        let value = field.value as? String ?? ""
        guard !value.isEmpty, value != field.placeholderValue else { return }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Select All' OR label == '全选'"))
            .firstMatch
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
            Thread.sleep(forTimeInterval: 0.2)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    @MainActor
    private func deleteBackward(_ field: XCUIElement) {
        for _ in 0 ..< 24 {
            let value = field.value as? String ?? ""
            if value.isEmpty || value == field.placeholderValue { return }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            Thread.sleep(forTimeInterval: 0.1)
            if (field.value as? String ?? "") == value {
                // The key did not land; reposition the cursor and keep going.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
    }

    @MainActor
    private func finishEditing(_ app: XCUIApplication) {
        #if os(iOS)
        dismissKeyboardFocus(in: app)
        #else
        app.typeKey(.tab, modifierFlags: [])
        #endif
    }

    @MainActor
    private func finishDurationEditing(_ app: XCUIApplication) {
        // The duration draft commits through the keyboard toolbar on iOS.
        #if os(iOS)
        let done = app.buttons["duration-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 2), app.debugDescription)
        done.tap()
        #else
        app.typeKey(.tab, modifierFlags: [])
        #endif
    }

    @MainActor
    private func openMore(in app: XCUIApplication) {
        let more = app.buttons["more-action"].firstMatch
        if more.exists { reveal(more, in: app); more.tap() }
    }

    @MainActor
    private func choose(_ label: String, picker: String, in app: XCUIApplication) {
        finishEditing(app)
        let control = app.descendants(matching: .any).matching(identifier: picker).firstMatch
        reveal(control, in: app)
        control.tap()
        #if os(macOS)
        // macOS exposes SwiftUI menu actions with a shared identifier; the visible
        // localized title is the stable selector for the menu item itself.
        let byIdentifier = app.menuItems[label].firstMatch
        let item = byIdentifier.exists
            ? byIdentifier
            : app.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", label, label)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 2), app.debugDescription)
        item.tap()
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
        // Conversion angle→time shows the time as the primary readout.
        XCTAssertTrue(app.staticTexts["shutter-time-primary"].label.contains("1/49.95 s"))
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

        // Preset selection replaces the decimal draft and retains the unrounded 100/3 cadence.
        let presets = app.buttons["shutter-presets-sensorFps"].firstMatch
        reveal(presets, in: app)
        presets.tap()
        let fractionalPreset = app.buttons["33.333 (100/3)"].firstMatch
        XCTAssertTrue(fractionalPreset.waitForExistence(timeout: 3))
        let presetAttachment = XCTAttachment(screenshot: app.screenshot())
        presetAttachment.name = "Camera FPS 100 over 3 preset"
        presetAttachment.lifetime = .keepAlways
        add(presetAttachment)
        fractionalPreset.tap()
        enter("120", field: "angle", in: app)
        finishEditing(app)
        XCTAssertTrue(app.staticTexts["shutter-time-primary"].label.contains("1/100 s"))

        // The new capture preset must not leak into the delivery/project-rate menu.
        choose("Over / undercrank", picker: "shutter-mode", in: app)
        let projectPresets = app.buttons["shutter-presets-projectFps"].firstMatch
        reveal(projectPresets, in: app)
        projectPresets.tap()
        XCTAssertTrue(app.buttons["25 fps"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["33.333 (100/3)"].firstMatch.exists)
        app.buttons["25 fps"].firstMatch.tap()
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
        XCTAssertTrue(app.staticTexts["shutter-time-primary"].label.contains("1/120 s"))
        openMore(in: app)
        let reset = app.buttons["reset-action"].firstMatch
        reveal(reset, in: app)
        reset.tap()
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        XCTAssertTrue(app.staticTexts["shutter-time-primary"].label.contains("1/48 s"))
    }

    @MainActor
    func testShutterFlickerEmptyAndMatchingModes() throws {
        let app = shutterApp()
        choose("Flicker reference", picker: "shutter-mode", in: app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "172.8°")
        enter("120", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shutter-no-candidates").firstMatch.exists)
        choose("Over / undercrank", picker: "shutter-mode", in: app)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "450°")
        choose("Keep angle", picker: "shutter-match", in: app)
        XCTAssertEqual(app.staticTexts["shutter-angle-output"].label, "180°")
        XCTAssertTrue(app.staticTexts["shutter-time-output"].label.contains("1/120 s"))
        // Supporting readouts are hidden until the single details disclosure is expanded.
        XCTAssertFalse(app.staticTexts["shutter-playback-output"].exists)
        let details = app.staticTexts["Technical details"].firstMatch
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
    func testMultipleDisplayShutterInputAndRecovery() throws {
        let app = shutterApp()
        // macOS selectable Text combines descendants; read both accessibility labels and values.
        func resultText() -> String {
            let result = app.descendants(matching: .any).matching(identifier: "shutter-results").firstMatch
            return result.descendants(matching: .staticText).allElementsBoundByIndex.map {
                $0.label + " " + ($0.value as? String ?? "")
            }.joined(separator: " ")
        }
        choose("Flicker reference", picker: "shutter-mode", in: app)
        choose("Multiple displays", picker: "shutter-light-source", in: app)
        XCTAssertTrue(resultText().contains("144°"), resultText())
        // A missing exact solution now produces a qualified compromise; invalid text still clears it.
        enter("50, 60", field: "display-rates", in: app)
        finishEditing(app)
        XCTAssertFalse(resultText().contains("144°"))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "shutter-compromise-notice").firstMatch.exists)
        XCTAssertTrue(resultText().contains("157.090909°"), resultText())
        enter("60,", field: "display-rates", in: app)
        finishEditing(app)
        XCTAssertFalse(resultText().contains("144°"))
        XCTAssertFalse(resultText().contains("157.090909°"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "shutter-compromise-notice").firstMatch.exists)
        enter("60, 120", field: "display-rates", in: app)
        finishEditing(app)
        XCTAssertTrue(resultText().contains("144°"), resultText())
        #if os(macOS)
        let details = app.disclosureTriangles.matching(NSPredicate(format: "label == %@", "Technical details")).firstMatch
        #else
        let details = app.staticTexts["Technical details"].firstMatch
        #endif
        reveal(details, in: app)
        #if os(macOS)
        // Use the native desktop mouse action for the disclosure control.
        details.click()
        #else
        details.tap()
        #endif
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            resultText().contains("60 Hz × 1 cycles · 120 Hz × 2 cycles")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed, resultText())
        // Let the native disclosure animation finish before recording visual evidence.
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Multiple display shutter candidates"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Replacing the list passes through an invalid draft, which recreates collapsed details.
        enter("50, 60", field: "display-rates", in: app)
        finishEditing(app)
        reveal(details, in: app)
        #if os(macOS)
        details.click()
        #else
        details.tap()
        #endif
        let compromiseExpanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            resultText().contains("Worst cycle deviation: 0.090909 cycles")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compromiseExpanded], timeout: 3), .completed, resultText())
        XCTAssertTrue(resultText().contains("Worst cycle deviation: 0.090909 cycles"), resultText())
        XCTAssertTrue(resultText().contains("50 Hz · 0.909091 cycles · nearest 1"), resultText())
        let compromiseOutput = app.descendants(matching: .any).matching(identifier: "shutter-compromise-output").firstMatch
        reveal(compromiseOutput, in: app)
        let compromiseImage = XCTAttachment(screenshot: app.screenshot())
        compromiseImage.name = "Multi-display compromise reference"
        compromiseImage.lifetime = .keepAlways
        add(compromiseImage)
        openMore(in: app)
        let reset = app.buttons["reset-action"].firstMatch
        reveal(reset, in: app)
        reset.tap()
        XCTAssertTrue(resultText().contains("180°"), resultText())
    }

    @MainActor
    func testShutterImportDoesNotCreatePersistentLink() throws {
        let app = shutterApp()
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        let importButton = app.buttons["shutter-import"]
        reveal(importButton, in: app)
        // Import belongs to the camera FPS row and must remain a named, usable target.
        XCTAssertEqual(importButton.frame.midY, app.textFields["shutter-sensorFps"].frame.midY, accuracy: 2)
        XCTAssertEqual(importButton.label, "Import FPS from recording calculator")
        #if os(iOS)
        // Accessibility frame subtraction can return 43.99999999999994 for 44pt.
        XCTAssertGreaterThanOrEqual(importButton.frame.height + 1e-6, 44)
        #endif
        let placement = XCTAttachment(screenshot: app.screenshot())
        placement.name = "Shutter camera FPS inline import"
        placement.lifetime = .keepAlways
        add(placement)
        importButton.tap()
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        enter("48", field: "sensorFps", in: app)
        finishEditing(app)
        #if os(macOS)
        app.typeKey("1", modifierFlags: .command)
        #else
        selectTab("rate", in: app)
        #endif
        #if os(macOS)
        app.typeKey("2", modifierFlags: .command)
        #else
        selectTab("shutter", in: app)
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
        // Each standalone favorite button must name its camera for VoiceOver.
        XCTAssertTrue(favorite.label.contains("MAVO Edge 6K"))
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
        XCTAssertTrue(app.buttons["more-action"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.toolbars.buttons["copy-action"].exists)
        // The titlebar is the only macOS workbench navigation; the old content header is gone.
        XCTAssertEqual(app.segmentedControls.matching(identifier: "calculator-view-picker").count, 1)
        XCTAssertFalse(app.staticTexts["Recording calculator"].exists)
        let rateScreenshot = XCTAttachment(screenshot: app.screenshot())
        rateScreenshot.name = "Native macOS recording workbench"
        rateScreenshot.lifetime = .keepAlways
        add(rateScreenshot)

        // Commands target the active window; toolbar shortcuts preserve standard text-field Copy.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.textFields["shutter-sensorFps"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.toolbars.buttons["copy-action"].exists)
        enter("60", field: "sensorFps", in: app)
        finishEditing(app)
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "60")
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.textFields["shutter-sensorFps"].value as? String, "24")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "rate-results").firstMatch.exists)
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
