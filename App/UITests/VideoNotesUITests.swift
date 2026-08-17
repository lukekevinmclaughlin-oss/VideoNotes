import XCTest

final class VideoNotesUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    app?.terminate()
    app = nil
    super.tearDown()
  }

  func testEmptyDemoLaunchIsPaywallSafeAndAccessible() {
    app = launch(reset: true)

    XCTAssertTrue(element("workspace").waitForExistence(timeout: 12))
    XCTAssertFalse(element("paywall").exists)
    let chooseMedia = app.buttons["empty-import-button"]
    XCTAssertTrue(chooseMedia.waitForExistence(timeout: 5))
    XCTAssertTrue(chooseMedia.isEnabled)
    XCTAssertTrue(waitUntilHittable(chooseMedia))
    capture("empty-workspace")
  }

  func testCompletedDemoSupportsFormatsNavigationAndExportDiscovery() {
    app = launch(reset: true, fixture: "completed")
    waitForCompletedStudio()

    let pageStatus = element("page-status")
    XCTAssertTrue(pageStatus.label.hasPrefix("Page 1 of "), pageStatus.label)
    let firstPageCount = pageCount(from: pageStatus.label)
    XCTAssertGreaterThan(firstPageCount, 1)
    let illustrationTrust = element("source-illustration-trust")
    XCTAssertTrue(illustrationTrust.waitForExistence(timeout: 8))
    XCTAssertEqual(illustrationTrust.label, "2 source-matched drawings")
    capture("grounded-completed-workspace")

    let next = app.buttons["next-page-button"]
    XCTAssertTrue(waitUntilEnabled(next))
    next.tap()
    XCTAssertTrue(waitForLabel(pageStatus, toHavePrefix: "Page 2 of "))

    let previous = app.buttons["previous-page-button"]
    XCTAssertTrue(waitUntilEnabled(previous))
    previous.tap()
    XCTAssertTrue(waitForLabel(pageStatus, toHavePrefix: "Page 1 of "))

    openFormatPicker()
    let timeline = app.buttons["format-timeline"]
    for _ in 0..<6 where !timeline.exists { app.swipeUp() }
    XCTAssertTrue(timeline.waitForExistence(timeout: 8))
    timeline.tap()
    XCTAssertTrue(waitUntilSelected(timeline))

    let done = app.buttons["format-picker-done-button"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    done.tap()

    let subtitle = element("studio-subtitle")
    XCTAssertTrue(waitForLabel(subtitle, toContain: "Timeline / Chapter Map", timeout: 30))
    XCTAssertTrue(waitUntilEnabled(app.buttons["export-pdf-button"], timeout: 30))
    assertSemanticExportIsDiscoverable()
    capture("timeline-export-ready")
  }

  func testCompletedProjectRestoresAfterRelaunch() {
    app = launch(reset: true, fixture: "completed")
    waitForCompletedStudio()
    XCTAssertTrue(element("note-page-1").exists)

    app.terminate()
    app = launch(reset: false)

    waitForCompletedStudio()
    XCTAssertEqual(app.staticTexts["Grounded AI Lecture"].label, "Grounded AI Lecture")
    XCTAssertTrue(element("note-page-1").exists)
    capture("restored-workspace")
  }

  func testLargeTextAndReduceMotionKeepTheEmptyFlowUsable() {
    app = launch(reset: true, largeText: true, reduceMotion: true)

    let chooseMedia = app.buttons["empty-import-button"]
    XCTAssertTrue(chooseMedia.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilHittable(chooseMedia))
    capture("accessibility-large-text-reduce-motion")
  }

  @discardableResult
  private func launch(
    reset: Bool, fixture: String? = nil, largeText: Bool = false,
    reduceMotion: Bool = true
  ) -> XCUIApplication {
    let application = XCUIApplication()
    application.launchEnvironment["VIDEONOTES_DEMO"] = "1"
    application.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if reset { application.launchEnvironment["VIDEONOTES_UI_TEST_RESET"] = "1" }
    if let fixture { application.launchEnvironment["VIDEONOTES_UI_TEST_FIXTURE"] = fixture }
    if largeText { application.launchEnvironment["VIDEONOTES_UI_TEST_LARGE_TEXT"] = "1" }
    if reduceMotion {
      application.launchArguments += ["-AppleReduceMotionEnabled", "YES"]
    }
    application.launch()
    return application
  }

  private func waitForCompletedStudio(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
      element("studio-subtitle").waitForExistence(timeout: 35),
      "The deterministic fixture did not render",
      file: file, line: line)
    XCTAssertTrue(
      element("note-page-1").waitForExistence(timeout: 8), "The first note page was not exposed",
      file: file, line: line)
    XCTAssertTrue(
      waitUntilEnabled(app.buttons["export-pdf-button"], timeout: 12),
      "Export never became ready", file: file, line: line)
  }

  private func openFormatPicker(file: StaticString = #filePath, line: UInt = #line) {
    let direct = app.buttons["format-picker-button"]
    if !direct.exists {
      let more = app.buttons["more-note-actions-button"]
      XCTAssertTrue(more.waitForExistence(timeout: 5), file: file, line: line)
      more.tap()
    }

    let identified = app.buttons["format-picker-button"]
    let labelled = app.buttons["Note & PDF Formats"]
    let trigger = identified.waitForExistence(timeout: 3) ? identified : labelled
    XCTAssertTrue(trigger.waitForExistence(timeout: 5), file: file, line: line)
    trigger.tap()
    XCTAssertTrue(
      app.buttons["format-evidenceFirst"].waitForExistence(timeout: 8), file: file, line: line)
  }

  private func assertSemanticExportIsDiscoverable(
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let direct = app.buttons["semantic-export-menu"]
    if direct.exists {
      XCTAssertTrue(direct.isEnabled, file: file, line: line)
      direct.tap()
    } else {
      let more = app.buttons["more-note-actions-button"]
      XCTAssertTrue(more.waitForExistence(timeout: 5), file: file, line: line)
      more.tap()
    }

    let markdown =
      app.buttons["semantic-export-markdown"].exists
      ? app.buttons["semantic-export-markdown"] : app.buttons["Markdown"]
    XCTAssertTrue(markdown.waitForExistence(timeout: 6), file: file, line: line)
    XCTAssertTrue(markdown.isEnabled, file: file, line: line)
    XCTAssertTrue(app.buttons["Plain Text"].exists, file: file, line: line)
    XCTAssertTrue(app.buttons["Web Page (HTML)"].exists, file: file, line: line)
    XCTAssertTrue(app.buttons["Structured JSON"].exists, file: file, line: line)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
    let predicate = NSPredicate(format: "exists == true AND enabled == true")
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
      == .completed
  }

  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
    let predicate = NSPredicate(format: "exists == true AND hittable == true")
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
      == .completed
  }

  private func waitUntilSelected(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
    let predicate = NSPredicate(format: "exists == true AND selected == true")
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
      == .completed
  }

  private func waitForLabel(
    _ element: XCUIElement, toHavePrefix prefix: String, timeout: TimeInterval = 8
  ) -> Bool {
    let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
      == .completed
  }

  private func waitForLabel(
    _ element: XCUIElement, toContain value: String, timeout: TimeInterval = 8
  ) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", value)
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
      == .completed
  }

  private func pageCount(from status: String) -> Int {
    Int(status.split(separator: " ").last ?? "0") ?? 0
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
