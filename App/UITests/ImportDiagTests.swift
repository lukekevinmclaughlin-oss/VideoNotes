import XCTest

final class ImportDiagTests: XCTestCase {
  func testImportButtonClickDiag() throws {
    let app = XCUIApplication()
    app.launchEnvironment["VIDEONOTES_DEMO"] = "1"
    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()

    for i in 0..<15 {
      try? Thread.sleep(forTimeInterval: 2)
      print("t+\(i * 2)s state=\(app.state) windows=\(app.windows.count)")
      if app.windows.count > 0 { break }
    }

    let chooseMedia = app.buttons["empty-import-button"]
    print("button exists: \(chooseMedia.exists)")
    if app.windows.count > 0 {
      for w in app.windows.allElementsBoundByIndex.prefix(3) {
        print("window: \(w.identifier) [\(w.label)]")
        for b in w.buttons.allElementsBoundByIndex.prefix(8) {
          print("  button: \(b.identifier) [\(b.label)]")
        }
      }
    }
    app.terminate()
  }
}
