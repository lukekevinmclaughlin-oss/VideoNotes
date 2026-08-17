import SketchnoteEngine
import SwiftUI

@main
struct VideoNotesApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model: StudioModel
  @StateObject private var purchase: PurchaseManager

  init() {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["VIDEONOTES_UI_TEST_RESET"] == "1" {
        try? ProjectSnapshotStore.applicationSupport().remove()
        let defaults = UserDefaults.standard
        for key in ["vn.paletteIndex", "vn.compact", "vn.presentationFormat", "vn.pdfPageFormat"] {
          defaults.removeObject(forKey: key)
        }
      }
    #endif
    _model = StateObject(wrappedValue: StudioModel())
    _purchase = StateObject(wrappedValue: PurchaseManager.shared)

    // bundled OFL hand fonts give the sketchnotes their look
    let fonts = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
    FontBook.register(fontURLs: fonts)
  }

  var body: some Scene {
    WindowGroup {
      configuredContent
        #if os(macOS)
          .frame(minWidth: 980, minHeight: 680)
        #endif
        .onChange(of: scenePhase) { _, phase in
          if phase != .active { model.persistProjectForLifecycleTransition() }
        }
    }
    #if os(macOS)
      .windowStyle(.hiddenTitleBar)
    #endif
  }

  @ViewBuilder private var configuredContent: some View {
    #if DEBUG
      if ProcessInfo.processInfo.environment["VIDEONOTES_UI_TEST_LARGE_TEXT"] == "1" {
        content.dynamicTypeSize(.accessibility3)
      } else {
        content
      }
    #else
      content
    #endif
  }

  private var content: some View {
    ContentView()
      .environmentObject(model)
      .environmentObject(purchase)
  }
}
