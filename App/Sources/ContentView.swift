import AVKit
import Accessibility
import SketchnoteEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @State private var showPaywall = false
  @EnvironmentObject private var model: StudioModel
  @EnvironmentObject private var purchase: PurchaseManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showImporter = false
  @State private var showPDFExporter = false
  @State private var showSemanticExporter = false
  @State private var showPNGFolderPicker = false
  @State private var feedback: AppFeedback?
  @State private var pdfExportData = Data()
  @State private var semanticExportData = Data()
  @State private var semanticExportFormat: SemanticNoteExportFormat = .markdown
  @State private var isDropTargeted = false
  @State private var zoomedPage: Int?
  @State private var showEvidence = false
  @State private var showReadingMode = false
  @State private var showFormatPicker = false
  @State private var showResetConfirmation = false
  @State private var scrolledPageID: Int?
  @State private var shuffleSpins = 0.0

  static let mediaTypes: [UTType] = [
    .movie, .video, .mpeg4Movie, .quickTimeMovie,
    .audio, .mp3, .wav, .aiff, .mpeg4Audio,
  ]
  static let mediaExtensions = [
    "mp4", "mov", "m4v", "mpg", "mpeg", "mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "caf",
  ]

  var body: some View {
    // Freemium: the workspace is always available; Pro gates volume, not entry.
    workspace
      .sheet(isPresented: $showPaywall) { PaywallView() }
  }

  private var workspace: some View {
    ZStack {
      HUDBackground(reduceLoad: model.phase.isProcessing)
      VStack(spacing: 0) {
        header
          .padding(.horizontal, 18).padding(.top, 14)
        ZStack {
          switch model.phase {
          case .empty: emptyState.transition(phaseTransition)
          case .analyzing, .illustrating: progressState.transition(phaseTransition)
          case .ready: studio.transition(phaseTransition)
          case .failed(let message): failedState(message).transition(phaseTransition)
          }
        }
        .animation(
          reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: phaseKey
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      dropVeil
      toastOverlay
    }
    .preferredColorScheme(.dark)
    // Each file dialog is hosted on its own background anchor. SwiftUI does not
    // reliably support multiple `.fileImporter`/`.fileExporter` modifiers stacked
    // on a single view — they clobber one another, which left the Import / Try
    // Another File buttons doing nothing after the first use. Separate anchors
    // give every dialog an independent presentation context.
    .background {
      Color.clear.fileImporter(
        isPresented: $showImporter, allowedContentTypes: Self.mediaTypes,
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          if let url = urls.first {
            // One import consumes exactly one free analysis. This was previously
            // nested twice, which burned two of the three daily credits per file.
            if purchase.consumeFreeAnalysis() {
              model.analyze(url)
            } else {
              showPaywall = true
            }
          }
        case .failure(let error):
          showFeedback(
            String(localized: "Could not open that file: \(error.localizedDescription)"),
            success: false)
        }
      }
    }
    .background {
      Color.clear.fileExporter(
        isPresented: $showPDFExporter,
        document: PDFExportDocument(data: pdfExportData),
        contentType: .pdf,
        defaultFilename: String(
          localized: "\(model.sourceName.isEmpty ? "VideoNotes" : model.sourceName) — Sketchnotes")
      ) { result in
        switch result {
        case .success: showFeedback(String(localized: "PDF saved"), success: true)
        case .failure(let error):
          showFeedback(
            String(localized: "PDF could not be saved: \(error.localizedDescription)"),
            success: false)
        }
      }
    }
    .background {
      Color.clear.fileExporter(
        isPresented: $showSemanticExporter,
        document: SemanticExportDocument(data: semanticExportData),
        contentType: semanticExportFormat.contentType,
        defaultFilename: String(
          localized: "\(model.sourceName.isEmpty ? "VideoNotes" : model.sourceName) — Notes")
      ) { result in
        switch result {
        case .success:
          showFeedback(
            String(localized: "\(semanticExportFormat.displayName) saved"), success: true)
        case .failure(let error):
          showFeedback(
            String(
              localized:
                "\(semanticExportFormat.displayName) could not be saved: \(error.localizedDescription)"
            ),
            success: false)
        }
      }
    }
    .background {
      Color.clear.fileImporter(isPresented: $showPNGFolderPicker, allowedContentTypes: [.folder]) {
        result in
        switch result {
        case .success(let folder):
          do {
            try model.exportPNGs(to: folder)
            showFeedback(String(localized: "\(model.pageCount) PNG pages saved"), success: true)
          } catch {
            showFeedback(
              String(localized: "PNG pages could not be saved: \(error.localizedDescription)"),
              success: false)
          }
        case .failure(let error):
          showFeedback(
            String(
              localized:
                "A PNG destination could not be selected: \(error.localizedDescription)"),
            success: false)
        }
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard
        let url = urls.first(where: { Self.mediaExtensions.contains($0.pathExtension.lowercased()) }
        )
          ?? urls.first
      else { return false }
      model.analyze(url)
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
    .sheet(isPresented: Binding(get: { zoomedPage != nil }, set: { if !$0 { zoomedPage = nil } })) {
      if let index = zoomedPage, index < model.pages.count {
        PageZoomView(page: model.pages[index], index: index, total: model.pageCount)
      }
    }
    .sheet(isPresented: $showEvidence) {
      EvidenceInspector(
        items: model.sourceEvidence, report: model.groundingReport,
        sourceName: model.sourceName)
    }
    .sheet(isPresented: $showReadingMode) {
      ReadingOutlineView(pages: model.readingPages, sourceName: model.sourceName)
    }
    .sheet(isPresented: $showFormatPicker) {
      NoteFormatPickerView()
    }
    .confirmationDialog(
      "Start a new analysis?", isPresented: $showResetConfirmation, titleVisibility: .visible
    ) {
      Button("Start New", role: .destructive) { model.reset() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The current generated notes will be removed from this workspace.")
    }
    .onAppear { model.applyDebugHooksOnLaunch() }
    .onChange(of: scrolledPageID) { _, new in if let new { model.currentPage = new } }
    .onChange(of: model.sourceName) { _, _ in scrolledPageID = 0 }
    .onChange(of: model.pageCount) { _, count in
      if count > 0, model.currentPage >= count { scrolledPageID = max(0, count - 1) }
    }
    .onChange(of: model.stageIndex) { _, index in
      guard model.phase == .analyzing || model.phase == .illustrating else { return }
      AccessibilityNotification.Announcement(
        String(localized: "Step \(index + 1) of \(Self.stages.count): \(Self.stages[index].1)")
      ).post()
    }
    .onChange(of: model.sessionNotice, initial: true) { _, notice in
      guard let notice else { return }
      showFeedback(notice, success: model.sessionNoticeIsSuccess)
      model.consumeSessionNotice()
    }
    .accessibilityIdentifier("workspace")
  }

  private var phaseKey: Int {
    switch model.phase {
    case .empty: 0
    case .analyzing, .illustrating: 1
    case .ready: 2
    case .failed: 3
    }
  }

  private var phaseTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .offset(y: 10)),
        removal: .opacity)
  }

  private func showFeedback(_ text: String, success: Bool) {
    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
      feedback = AppFeedback(text: text, success: success)
    }
    AccessibilityNotification.Announcement(text).post()
  }

  // MARK: - drop veil

  @ViewBuilder private var dropVeil: some View {
    if isDropTargeted {
      ZStack {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
          .fill(VNTheme.cyan.opacity(0.08))
        RoundedRectangle(cornerRadius: 30, style: .continuous)
          .strokeBorder(VNTheme.cyan, style: StrokeStyle(lineWidth: 2.5, dash: [12, 10]))
        VStack(spacing: 12) {
          Image(systemName: "arrow.down.doc.fill").font(.system(size: 52)).foregroundStyle(
            VNTheme.cyan)
          Text("Drop to analyze").font(.title2.weight(.semibold))
        }
        .padding(30).glassPanel()
      }
      .padding(24)
      .transition(.opacity)
      .allowsHitTesting(false)
    }
  }

  private var toastOverlay: some View {
    VStack {
      Spacer()
      if let feedback {
        Toast(
          text: feedback.text,
          icon: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
          tint: feedback.success ? VNTheme.mint : .orange
        )
        .padding(.bottom, 96)
        .task(id: feedback.id) {
          try? await Task.sleep(for: .seconds(3))
          guard self.feedback?.id == feedback.id else { return }
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { self.feedback = nil }
        }
      }
    }
    .allowsHitTesting(false)
  }

  // MARK: - header

  private var header: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        HStack(spacing: 10) {
          Image(systemName: "play.rectangle.on.rectangle.fill")
            .font(.title2).foregroundStyle(VNTheme.cyan.gradient)
            .accessibilityHidden(true)
          Text("VideoNotes").font(.headline).lineLimit(1).minimumScaleFactor(0.65)
          Spacer(minLength: 4)
          if model.phase == .ready {
            Button {
              showResetConfirmation = true
            } label: {
              Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(GlassButtonStyle()).accessibilityLabel("New analysis")
          }
          Button {
            showImporter = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
          .accessibilityLabel("Import video or audio")
          .accessibilityIdentifier("import-media-button")
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 14) {
            brand
            Spacer(minLength: 18)
            headerActions
          }
          VStack(spacing: 12) {
            HStack {
              brand
              Spacer()
            }
            HStack {
              Spacer()
              headerActions
            }
          }
        }
      }
    }
    .padding(.horizontal, 18).padding(.vertical, 12)
    .glassPanel(cornerRadius: 20)
  }

  private var brand: some View {
    HStack(spacing: 12) {
      Image(systemName: "play.rectangle.on.rectangle.fill")
        .font(.title3)
        .foregroundStyle(VNTheme.cyan.gradient)
        .shadow(color: VNTheme.cyan.opacity(0.7), radius: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text("VideoNotes").font(.headline)
        Text("LECTURE → ILLUSTRATED NOTES").font(.caption2.weight(.bold)).tracking(1.4)
          .foregroundStyle(VNTheme.cyan.opacity(0.8))
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var headerActions: some View {
    HStack(spacing: 10) {
      if model.phase == .ready {
        Button {
          showResetConfirmation = true
        } label: {
          Label("New", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(GlassButtonStyle())
      }
      Button {
        showImporter = true
      } label: {
        ViewThatFits {
          Label("Import Video/Audio", systemImage: "plus")
          Label("Import", systemImage: "plus")
        }
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
      .accessibilityIdentifier("import-media-button")
    }
  }

  // MARK: - empty

  private var emptyState: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 22) {
          Spacer(minLength: 16)
          if dynamicTypeSize.isAccessibilitySize {
            emptyTitle
            emptyCTA
            emptyDescriptionText
            BreathingReticle().scaleEffect(0.62).frame(height: 140)
          } else {
            BreathingReticle()
            emptyTitle
            emptyDescriptionText
            emptyCTA
          }
          Text("MP4 · MOV · M4V · MP3 · M4A · WAV · private, on-device analysis")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Spacer(minLength: 16)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("empty-state")
  }

  private var emptyTitle: some View {
    Text("Turn a lecture into illustrated notes")
      .font(.largeTitle.bold()).fontDesign(.rounded).multilineTextAlignment(.center)
  }

  private var emptyDescriptionText: some View {
    Text(emptyDescription)
      .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
      .frame(maxWidth: 690)
  }

  private var emptyCTA: some View {
    Button {
      showImporter = true
    } label: {
      Label("Choose a Video or Audio File", systemImage: "film.stack")
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
    .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan, prominent: true))
    .keyboardShortcut("o", modifiers: .command)
    .accessibilityIdentifier("empty-import-button")
  }

  private var emptyDescription: String {
    #if os(macOS)
      String(
        localized:
          "Drop in one video or audio file. VideoNotes listens and reads on this device, then draws hand-sketched infographic pages you can save or share."
      )
    #else
      String(
        localized:
          "Choose one video or audio file. VideoNotes listens and reads on this device, then draws hand-sketched infographic pages you can save or share."
      )
    #endif
  }

  // MARK: - progress

  private static let stages: [(String, String)] = [
    ("waveform", String(localized: "Listen")),
    ("viewfinder", String(localized: "Read")),
    ("square.stack.3d.up", String(localized: "Structure")),
    ("paintbrush.pointed", String(localized: "Illustrate")),
  ]

  private var progressState: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 30) {
          Spacer(minLength: 18)
          // pipeline step indicator
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
              ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, stage in
                stageBadge(index: index, icon: stage.0, title: stage.1)
                if index < Self.stages.count - 1 {
                  Rectangle()
                    .fill(index < model.stageIndex ? VNTheme.cyan : Color.white.opacity(0.14))
                    .frame(width: 54, height: 2)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 22)
                }
              }
            }
            .padding(.horizontal, 30).padding(.vertical, 22)
            .glassPanel()
            compactStageIndicator
          }

          Text(model.stageText.isEmpty ? String(localized: "Working…") : model.stageText)
            .font(.title3.weight(.medium))
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.stageText)

          if let progress = model.scanProgress {
            ProgressView(value: progress).tint(VNTheme.gold).frame(maxWidth: 460)
          } else {
            ProgressView().tint(VNTheme.gold)
          }

          Text("Transcription and OCR run on this device — nothing is uploaded")
            .font(.callout).foregroundStyle(.secondary)

          Button {
            model.cancelAnalysis()
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
          .buttonStyle(GlassButtonStyle(tint: .white.opacity(0.85)))
          .keyboardShortcut(.cancelAction)
          Spacer(minLength: 18)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
    }
  }

  private var compactStageIndicator: some View {
    HStack(spacing: 14) {
      stageBadge(
        index: model.stageIndex, icon: Self.stages[model.stageIndex].0,
        title: Self.stages[model.stageIndex].1)
      VStack(alignment: .leading, spacing: 4) {
        Text("Step \(model.stageIndex + 1) of \(Self.stages.count)")
          .font(.caption.weight(.bold)).foregroundStyle(VNTheme.cyan)
        Text("Preparing source-grounded notes").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(18).glassPanel(cornerRadius: 20)
  }

  private func stageBadge(index: Int, icon: String, title: String) -> some View {
    let state: Double = index < model.stageIndex ? 1 : (index == model.stageIndex ? 0.5 : 0)
    return VStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(state > 0 ? VNTheme.cyan.opacity(0.16) : Color.white.opacity(0.05))
          .frame(width: 52, height: 52)
        Circle()
          .strokeBorder(state > 0 ? VNTheme.cyan : Color.white.opacity(0.2), lineWidth: 1.6)
          .frame(width: 52, height: 52)
        if index < model.stageIndex {
          Image(systemName: "checkmark").font(.system(size: 19, weight: .bold))
            .foregroundStyle(VNTheme.cyan)
            .transition(.scale.combined(with: .opacity))
        } else {
          Image(systemName: icon).font(.system(size: 20))
            .foregroundStyle(state > 0 ? VNTheme.cyan : .white.opacity(0.45))
            .symbolEffect(.pulse, isActive: index == model.stageIndex && !reduceMotion)
        }
      }
      .shadow(color: VNTheme.cyan.opacity(index == model.stageIndex ? 0.5 : 0), radius: 12)
      Text(title).font(.caption.weight(.semibold))
        .foregroundStyle(state > 0 ? .primary : .secondary)
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8),
      value: model.stageIndex)
  }

  // MARK: - failed

  private func failedState(_ message: String) -> some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 18) {
          Spacer(minLength: 24)
          Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64))
            .foregroundStyle(.orange)
          Text(
            model.isSemanticExportReady
              ? String(localized: "Visual export could not be prepared")
              : String(localized: "Could not analyze this file")
          )
          .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
          Text(message).font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).frame(maxWidth: 560)
          if model.isSemanticExportReady {
            Text(
              "The typed, source-cited notes are still available. Export them below while you retry the visual layout."
            )
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).frame(maxWidth: 560)
            Menu {
              ForEach(SemanticNoteExportFormat.allCases) { format in
                Button {
                  beginSemanticExport(format)
                } label: {
                  Label(format.displayName, systemImage: format.icon)
                }
              }
            } label: {
              Label("Export Text Notes", systemImage: "doc.text")
            }
            .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
            .accessibilityIdentifier("failed-semantic-export-menu")
          }
          if model.failureCanOpenSettings, let url = settingsURL {
            Link(destination: url) { Label("Open Speech Settings", systemImage: "gear") }
              .buttonStyle(GlassButtonStyle(tint: VNTheme.gold))
          }
          HStack(spacing: 12) {
            if model.sourceURL != nil {
              Button {
                model.retryCurrentSource()
              } label: {
                Label("Retry", systemImage: "arrow.clockwise")
              }
              .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan, prominent: true))
            }
            Button {
              showImporter = true
            } label: {
              Label("Try Another File", systemImage: "film.stack")
            }
            .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
          }
          Spacer(minLength: 24)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
    }
  }

  private var settingsURL: URL? {
    #if os(macOS)
      URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    #else
      URL(string: "app-settings:")
    #endif
  }

  // MARK: - studio

  private var studio: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        studioHeader(horizontal: true)
        studioHeader(horizontal: false)
      }
      .padding(.horizontal, 24).padding(.vertical, 14)

      pageCarousel

      pageNavigator
        .padding(.top, 6)

      styleBar
        .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 10)
    }
    .overlay(alignment: .topTrailing) {
      if model.isUpdatingStyle {
        Label("Updating style…", systemImage: "paintbrush.pointed")
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 9)
          .glassPanel(cornerRadius: 18)
          .padding(20)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86),
      value: model.isUpdatingStyle
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("studio")
    #if os(macOS)
      .focusable()
      .focusEffectDisabled()
      .onKeyPress(.leftArrow) {
        step(-1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        step(1)
        return .handled
      }
    #endif
  }

  @ViewBuilder private func studioHeader(horizontal: Bool) -> some View {
    let title = VStack(alignment: .leading, spacing: 4) {
      Text(model.sourceName).font(.title.bold()).lineLimit(1)
      Text(
        String(
          localized:
            "\(model.pageCount) pages · \(model.presentationFormat.localizedDisplayName) · private, on-device · autosaved locally"
        )
      )
      .font(.subheadline).foregroundStyle(.secondary)
      .accessibilityIdentifier("studio-subtitle")
    }
    let evidence = HStack(spacing: 8) {
      if let report = model.groundingReport {
        if report.sourceIllustrations > 0 {
          EvidencePill(
            label: report.illustrationLabel,
            icon: report.verifiedSourceIllustrations == report.sourceIllustrations
              ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
            tint: report.illustrationTint
          )
          .accessibilityIdentifier("source-illustration-trust")
        }
        EvidencePill(
          label: report.coverageLabel, icon: report.coverageIcon, tint: report.coverageTint)
        EvidencePill(
          label: report.citationLabel,
          icon: report.requiresReview ? "exclamationmark.triangle" : "checkmark.seal",
          tint: report.requiresReview ? .orange : VNTheme.mint)
        if report.hasSpeechEvidence {
          EvidencePill(
            label: String(localized: "\(report.transcriptSegments) speech segments"),
            icon: "waveform",
            tint: VNTheme.cyan)
        }
        if report.hasVisualEvidence {
          EvidencePill(
            label: String(localized: "\(report.visualMoments) key scenes"), icon: "viewfinder",
            tint: VNTheme.gold)
        }
      }
    }
    if horizontal {
      HStack(alignment: .center, spacing: 18) {
        title
        Spacer(minLength: 16)
        evidence
        transcriptNotice
      }
    } else {
      VStack(alignment: .leading, spacing: 10) {
        title
        ScrollView(.horizontal, showsIndicators: false) { evidence }
        transcriptNotice
      }
    }
  }

  @ViewBuilder private var transcriptNotice: some View {
    if let notice = model.transcriptNotice {
      Label(notice, systemImage: "info.circle.fill")
        .font(.caption).foregroundStyle(.orange)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassPanel(cornerRadius: 12)
        .frame(maxWidth: 360, alignment: .leading)
    }
  }

  private func step(_ delta: Int) {
    let target = min(max(0, model.currentPage + delta), model.pageCount - 1)
    model.currentPage = target
    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) {
      scrolledPageID = target
    }
    AccessibilityNotification.Announcement(
      String(localized: "Page \(target + 1) of \(model.pageCount)")
    ).post()
  }

  private var pageCarousel: some View {
    GeometryReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 30) {
          ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
            PageCard(
              page: page, index: index,
              accessibilityTitle: model.readingPages.indices.contains(index)
                ? model.readingPages[index].title
                : String(localized: "Illustrated note page \(index + 1)"),
              entranceDelay: reduceMotion ? 0 : Double(min(index, 6)) * 0.05
            ) {
              zoomedPage = index
            }
            .frame(maxHeight: proxy.size.height - 10)
            .id(index)
          }
        }
        .scrollTargetLayout()
        .padding(
          .horizontal, max(24, (proxy.size.width - (proxy.size.height - 10) * 1080 / 1920) / 2)
        )
        .padding(.vertical, 5)
      }
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $scrolledPageID)
      .scrollIndicators(.hidden)
    }
  }

  private var pageNavigator: some View {
    HStack(spacing: 14) {
      Button {
        step(-1)
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(GlassButtonStyle()).disabled(model.currentPage <= 0)
      .accessibilityLabel("Previous page")
      .accessibilityIdentifier("previous-page-button")
      Text(
        String(
          localized:
            "Page \(min(model.currentPage + 1, max(model.pageCount, 1))) of \(max(model.pageCount, 1))"
        )
      )
      .font(.callout.weight(.semibold)).monospacedDigit().frame(minWidth: 104)
      .accessibilityIdentifier("page-status")
      Button {
        step(1)
      } label: {
        Image(systemName: "chevron.right")
      }
      .buttonStyle(GlassButtonStyle()).disabled(model.currentPage >= model.pageCount - 1)
      .accessibilityLabel("Next page")
      .accessibilityIdentifier("next-page-button")
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
      value: model.currentPage)
  }

  @ViewBuilder private var styleBar: some View {
    ViewThatFits(in: .horizontal) {
      expandedStyleBar
      compactStyleBar
    }
  }

  private var expandedStyleBar: some View {
    HStack(spacing: 14) {
      palettePicker

      Divider().frame(height: 22)

      Toggle(isOn: $model.compact) {
        Text("Compact").font(.callout.weight(.medium))
      }
      .toggleStyle(.switch).tint(VNTheme.cyan)
      #if os(macOS)
        .controlSize(.small)
      #endif

      Button {
        showFormatPicker = true
      } label: {
        Label(model.presentationFormat.displayName, systemImage: "rectangle.3.group")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
      .accessibilityIdentifier("format-picker-button")

      Button {
        shuffleSpins += 1
        model.shuffleStyle()
      } label: {
        Label {
          Text("Regenerate layout")
        } icon: {
          Image(systemName: "dice")
            .rotationEffect(.degrees(shuffleSpins * 360))
            .animation(
              reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.7),
              value: shuffleSpins)
        }
      }
      .buttonStyle(GlassButtonStyle())

      Spacer(minLength: 10)

      if let pdfURL = model.pdfURL {
        ShareLink(item: pdfURL) { Label("Share", systemImage: "square.and.arrow.up") }
          .buttonStyle(GlassButtonStyle())
          .disabled(!model.isExportReady)
      }
      Button {
        showEvidence = true
      } label: {
        Label("Evidence", systemImage: "checkmark.shield")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.mint))
      Button {
        showReadingMode = true
      } label: {
        Label("Read", systemImage: "text.alignleft")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
      Menu {
        ForEach(SemanticNoteExportFormat.allCases) { format in
          Button {
            beginSemanticExport(format)
          } label: {
            Label(format.displayName, systemImage: format.icon)
          }
        }
      } label: {
        Label("Text", systemImage: "doc.text")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
      .disabled(!model.isSemanticExportReady)
      .accessibilityIdentifier("semantic-export-menu")
      Button {
        showPNGFolderPicker = true
      } label: {
        Label("Save PNGs", systemImage: "photo.stack")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.gold))
      .disabled(!model.isExportReady)
      .accessibilityIdentifier("export-png-button")
      Button {
        beginPDFExport()
      } label: {
        Label("Export PDF", systemImage: "doc.richtext")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
      .disabled(!model.isExportReady)
      .keyboardShortcut("e", modifiers: .command)
      .accessibilityIdentifier("export-pdf-button")
    }
    .padding(.horizontal, 18).padding(.vertical, 12)
    .glassPanel(cornerRadius: 24)
  }

  private var compactStyleBar: some View {
    HStack(spacing: 10) {
      Menu {
        ForEach(Array(Palette.all.enumerated()), id: \.offset) { index, palette in
          Button {
            model.paletteIndex = index
          } label: {
            Label(
              palette.localizedDisplayName,
              systemImage: model.paletteIndex == index ? "checkmark.circle.fill" : "circle")
          }
        }
      } label: {
        Label("Palette", systemImage: "paintpalette")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
      Spacer(minLength: 4)
      Button {
        beginPDFExport()
      } label: {
        Label("Export", systemImage: "doc.richtext")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
      .disabled(!model.isExportReady)
      .accessibilityIdentifier("export-pdf-button")
      Menu {
        Button {
          showFormatPicker = true
        } label: {
          Label("Note & PDF Formats", systemImage: "rectangle.3.group")
        }
        .accessibilityIdentifier("format-picker-button")
        Button {
          showEvidence = true
        } label: {
          Label("Source Evidence", systemImage: "checkmark.shield")
        }
        Button {
          showReadingMode = true
        } label: {
          Label("Reading Mode", systemImage: "text.alignleft")
        }
        Button {
          showPNGFolderPicker = true
        } label: {
          Label("Save PNG Pages", systemImage: "photo.stack")
        }
        .disabled(!model.isExportReady)
        Section("Semantic Exports") {
          ForEach(SemanticNoteExportFormat.allCases) { format in
            Button {
              beginSemanticExport(format)
            } label: {
              Label(format.displayName, systemImage: format.icon)
            }
            .disabled(!model.isSemanticExportReady)
            .accessibilityIdentifier("semantic-export-\(format.rawValue)")
          }
        }
        Button {
          shuffleSpins += 1
          model.shuffleStyle()
        } label: {
          Label("Regenerate Layout", systemImage: "dice")
        }
        Toggle("Compact Notes", isOn: $model.compact)
        if let pdfURL = model.pdfURL {
          ShareLink(item: pdfURL) { Label("Share PDF", systemImage: "square.and.arrow.up") }
            .disabled(!model.isExportReady)
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .buttonStyle(GlassButtonStyle())
      .accessibilityLabel("More note actions")
      .accessibilityIdentifier("more-note-actions-button")
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .glassPanel(cornerRadius: 22)
  }

  private func beginPDFExport() {
    guard let data = model.pdfData(), !data.isEmpty else {
      showFeedback(String(localized: "The PDF is not ready yet."), success: false)
      return
    }
    pdfExportData = data
    showPDFExporter = true
  }

  private func beginSemanticExport(_ format: SemanticNoteExportFormat) {
    guard let data = model.semanticNotes(format: format), !data.isEmpty else {
      showFeedback(String(localized: "The semantic notes are not ready yet."), success: false)
      return
    }
    semanticExportFormat = format
    semanticExportData = data
    showSemanticExporter = true
  }

  private var palettePicker: some View {
    HStack(spacing: 8) {
      ForEach(Array(Palette.all.enumerated()), id: \.offset) { index, palette in
        Button {
          withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
            model.paletteIndex = index
          }
        } label: {
          ZStack {
            Circle().fill(Color(cgColor: palette.paper)).frame(width: 26, height: 26)
            Circle().trim(from: 0, to: 0.5).fill(Color(cgColor: palette.highlight))
              .frame(width: 26, height: 26).rotationEffect(.degrees(90))
            Circle().strokeBorder(
              model.paletteIndex == index ? VNTheme.cyan : .white.opacity(0.25),
              lineWidth: model.paletteIndex == index ? 2.2 : 1
            )
            .frame(width: 30, height: 30)
          }
          .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .hoverGlow()
        .scaleEffect(model.paletteIndex == index ? 1.1 : 1)
        .help(palette.localizedDisplayName)
        .accessibilityLabel(Text(palette.localizedDisplayName))
        .accessibilityAddTraits(model.paletteIndex == index ? .isSelected : [])
      }
    }
    .animation(
      reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
      value: model.paletteIndex)
  }
}

private struct AppFeedback: Identifiable {
  let id = UUID()
  let text: String
  let success: Bool
}

private struct EvidencePill: View {
  let label: String
  let icon: String
  let tint: Color

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(tint.opacity(0.09), in: Capsule())
      .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 1))
      .fixedSize()
      .accessibilityLabel(label)
  }
}

extension NotePresentationFormat {
  fileprivate var displayName: String { localizedDisplayName }

  fileprivate var icon: String {
    switch self {
    case .illustrated: return "paintbrush.pointed"
    case .detailed: return "doc.text.image"
    case .condensed: return "rectangle.grid.2x2"
    case .evidenceFirst: return "checkmark.shield"
    case .focusCards: return "rectangle.stack"
    case .quickReview: return "bolt.fill"
    case .studyGuide: return "graduationcap.fill"
    case .cornellNotes: return "rectangle.split.2x1"
    case .hierarchicalOutline: return "list.bullet.indent"
    case .timeline: return "clock"
    case .qaFlashcards: return "questionmark.bubble"
    case .examRevision: return "checkmark.seal"
    case .tutorial: return "list.number"
    case .decisionsAndActions: return "checklist"
    }
  }

  fileprivate var detail: String {
    switch self {
    case .illustrated:
      return String(
        localized: "Balanced visual storytelling with a cover and safe topic pairing.")
    case .detailed:
      return String(
        localized: "One complete source section per page for maximum room and legibility.")
    case .condensed:
      return String(
        localized:
          "A denser review set that pairs only sections proven to fit without dropping content.")
    case .evidenceFirst:
      return String(
        localized: "Chronological, source-cited sections with no synthesized cover page.")
    case .focusCards:
      return String(
        localized:
          "One complete idea per card, in the original lesson order and without a cover.")
    case .quickReview:
      return String(
        localized:
          "A compact, cover-free refresher that safely pairs shorter source sections.")
    case .studyGuide:
      return String(
        localized:
          "A complete study sequence that brings summaries and definitions forward for revision.")
    case .cornellNotes:
      return String(
        localized:
          "Source-provided definitions lead as cues, complete notes follow in source order, and summaries close the set."
      )
    case .hierarchicalOutline:
      return String(
        localized:
          "Groups complete source sections by semantic level—concepts, definitions, methods, processes, comparisons, quotes, then review."
      )
    case .timeline:
      return String(
        localized:
          "Orders dated source sections chronologically, safely pairing short adjacent moments; undated review material stays last."
      )
    case .qaFlashcards:
      return String(
        localized:
          "Prioritizes source-provided definitions and topic headings as study-card prompts; it never generates questions, and remaining material stays as reference cards."
      )
    case .examRevision:
      return String(
        localized:
          "Puts summaries, definitions and comparisons first, then safely pairs shorter source material for rapid revision."
      )
    case .tutorial:
      return String(
        localized:
          "Leads with source-provided processes and methods, then retains every remaining section as ordered reference material."
      )
    case .decisionsAndActions:
      return String(
        localized:
          "Surfaces source-provided comparisons, processes and methods first; it never invents decisions or tasks, and retains everything else as reference."
      )
    }
  }
}

extension PDFPageFormat {
  fileprivate var displayName: String { localizedDisplayName }

  fileprivate var detail: String {
    switch self {
    case .digital:
      return String(localized: "Full-resolution portrait pages for screens and sharing.")
    case .a4:
      return String(localized: "Standard international print pages with centered artwork.")
    case .usLetter:
      return String(localized: "North American print pages with centered artwork.")
    }
  }
}

private struct NoteFormatPickerView: View {
  @EnvironmentObject private var model: StudioModel
  @Environment(\.dismiss) private var dismiss

  private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

  var body: some View {
    NavigationStack {
      ZStack {
        HUDBackground()
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Note presentation").font(.title2.bold()).fontDesign(.rounded)
              Text(
                "Every format uses the same extracted evidence. Changing presentation never invents, paraphrases or removes source sections."
              )
              .font(.callout).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
              ForEach(NotePresentationFormat.allCases, id: \.self) { format in
                formatCard(format)
              }
            }

            VStack(alignment: .leading, spacing: 12) {
              Text("PDF paper").font(.headline)
              Picker("PDF paper", selection: $model.pdfPageFormat) {
                ForEach(PDFPageFormat.allCases, id: \.self) { paper in
                  Text(paper.displayName).tag(paper)
                }
              }
              .pickerStyle(.segmented)
              Text(model.pdfPageFormat.detail).font(.caption).foregroundStyle(.secondary)
              Text("PNG exports remain full-resolution 9:16 pages.")
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(18).glassPanel(cornerRadius: 20)

            VStack(alignment: .leading, spacing: 10) {
              Text("Semantic exports").font(.headline)
              Text(
                "Export the same source-cited notes as Markdown, plain text, a styled accessible HTML page, or structured JSON."
              )
              .font(.callout).foregroundStyle(.secondary)
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { semanticFormatLabels }
                VStack(alignment: .leading, spacing: 8) { semanticFormatLabels }
              }
            }
            .padding(18).glassPanel(cornerRadius: 20)
          }
          .padding(18)
        }
        .scrollIndicators(.hidden)
      }
      .navigationTitle("Formats")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("format-picker-done-button")
        }
      }
    }
    .preferredColorScheme(.dark)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("format-picker")
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 650)
    #endif
  }

  @ViewBuilder private var semanticFormatLabels: some View {
    ForEach(SemanticNoteExportFormat.allCases) { format in
      Label(format.displayName, systemImage: format.icon)
        .font(.caption.weight(.semibold)).foregroundStyle(VNTheme.cyan)
    }
  }

  private func formatCard(_ format: NotePresentationFormat) -> some View {
    let selected = model.presentationFormat == format
    return Button {
      model.presentationFormat = format
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: format.icon).font(.title2).foregroundStyle(VNTheme.cyan)
          Spacer()
          if selected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(VNTheme.mint)
          }
        }
        Text(format.displayName).font(.headline)
        Text(format.detail).font(.callout).foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
        if let count = model.pageCount(for: format) {
          Text(String(localized: "\(count) pages"))
            .font(.caption.weight(.semibold)).foregroundStyle(VNTheme.gold)
        }
      }
      .padding(18).frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
      .background(selected ? VNTheme.cyan.opacity(0.08) : .clear)
      .glassPanel(cornerRadius: 20)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("format-\(format.rawValue)")
  }
}

private struct EvidenceInspector: View {
  let items: [StudioModel.EvidenceItem]
  let report: StudioModel.GroundingReport?
  let sourceName: String

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: StudioModel
  @State private var filter: StudioModel.EvidenceItem.Kind?
  @State private var query = ""
  @State private var destination: EvidenceDestination?

  private var filteredItems: [StudioModel.EvidenceItem] {
    let liveItems = model.sourceEvidence.isEmpty ? items : model.sourceEvidence
    return liveItems.filter { item in
      (filter == nil || item.kind == filter)
        && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
          || item.detail.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        HUDBackground()
        VStack(spacing: 14) {
          summary
          filterBar
          if filteredItems.isEmpty {
            ContentUnavailableView(
              "No matching evidence", systemImage: "magnifyingglass",
              description: Text("Try another filter or search term.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            ScrollView {
              LazyVStack(spacing: 10) {
                ForEach(filteredItems) { item in evidenceRow(item) }
              }
              .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
          }
        }
        .padding(18)
      }
      .navigationTitle("Source Evidence")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .searchable(text: $query, prompt: "Search speech and on-screen text")
    }
    .preferredColorScheme(.dark)
    .sheet(item: $destination) { destination in
      switch destination {
      case .edit(let item): EvidenceCorrectionEditor(item: item)
      case .preview(let item):
        if let url = model.sourceURL { SourceEvidencePreview(url: url, item: item) }
      }
    }
    #if os(macOS)
      .frame(minWidth: 680, minHeight: 720)
    #endif
  }

  private var summary: some View {
    let tint = report?.requiresReview == true ? Color.orange : VNTheme.mint
    let icon =
      report?.requiresReview == true ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
    return HStack(spacing: 14) {
      ZStack {
        Circle().fill(tint.opacity(0.12)).frame(width: 48, height: 48)
        Image(systemName: icon).foregroundStyle(tint)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(sourceName).font(.headline).lineLimit(1)
        Text(
          report?.requiresReview == true
            ? String(
              localized:
                "Some sections are synthesized or use limited evidence. Review them before sharing."
            )
            : String(
              localized:
                "Review exactly what VideoNotes extracted before trusting or sharing the result.")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if let report {
        Text(TimeFormat.mmss(report.duration))
          .font(.system(.callout, design: .monospaced).weight(.semibold))
          .foregroundStyle(VNTheme.cyan)
      }
    }
    .padding(16)
    .glassPanel(cornerRadius: 18)
  }

  private var filterBar: some View {
    HStack(spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          filterButton(String(localized: "All"), icon: "square.stack.3d.up", kind: nil)
          ForEach(StudioModel.EvidenceItem.Kind.allCases, id: \.self) { kind in
            filterButton(kind.displayName, icon: kind.icon, kind: kind)
          }
        }
      }
      Spacer()
      Text(String(localized: "\(filteredItems.count) items"))
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func filterButton(_ label: String, icon: String, kind: StudioModel.EvidenceItem.Kind?)
    -> some View
  {
    Button {
      withAnimation(.easeOut(duration: 0.18)) { filter = kind }
    } label: {
      Label(label, systemImage: icon)
    }
    .buttonStyle(GlassButtonStyle(tint: kind?.tint ?? VNTheme.cyan, prominent: filter == kind))
    .accessibilityAddTraits(filter == kind ? .isSelected : [])
  }

  private func evidenceRow(_ item: StudioModel.EvidenceItem) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 14) {
        evidenceTime(item).frame(width: 62)
        evidenceText(item)
        Spacer(minLength: 0)
        VStack(spacing: 8) {
          previewButton(item)
          correctionButton(item)
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 10) {
          evidenceTime(item)
          Spacer(minLength: 8)
          HStack(spacing: 8) {
            previewButton(item)
            correctionButton(item)
          }
        }
        evidenceText(item)
      }
    }
    .padding(14)
    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(item.kind.tint.opacity(0.16), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
  }

  private func evidenceTime(_ item: StudioModel.EvidenceItem) -> some View {
    VStack(spacing: 5) {
      Image(systemName: item.kind.icon).font(.system(size: 16, weight: .semibold))
      Text(TimeFormat.mmss(item.time)).font(.system(.caption2, design: .monospaced).weight(.bold))
    }
    .foregroundStyle(item.kind.tint)
  }

  private func evidenceText(_ item: StudioModel.EvidenceItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(item.title).font(.callout.weight(.semibold))
        if item.hasTrace {
          Label("traced", systemImage: "scribble.variable")
            .font(.caption2.weight(.semibold)).foregroundStyle(VNTheme.mint)
        }
      }
      Text(item.detail).font(.callout).foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder private func previewButton(_ item: StudioModel.EvidenceItem) -> some View {
    if model.sourceURL != nil {
      Button {
        destination = .preview(item)
      } label: {
        Image(systemName: "play.fill")
      }
      .buttonStyle(GlassButtonStyle(tint: VNTheme.gold))
      .accessibilityLabel(
        String(localized: "Preview source at \(TimeFormat.mmss(item.time))"))
    }
  }

  private func correctionButton(_ item: StudioModel.EvidenceItem) -> some View {
    Button {
      destination = .edit(item)
    } label: {
      Image(systemName: "pencil")
    }
    .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
    .accessibilityLabel(String(localized: "Correct extracted evidence"))
  }
}

private enum EvidenceDestination: Identifiable {
  case edit(StudioModel.EvidenceItem)
  case preview(StudioModel.EvidenceItem)
  var id: String {
    switch self {
    case .edit(let item): return "edit-\(item.id)"
    case .preview(let item): return "preview-\(item.id)"
    }
  }
}

private struct EvidenceCorrectionEditor: View {
  let item: StudioModel.EvidenceItem
  @EnvironmentObject private var model: StudioModel
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var error: String?

  init(item: StudioModel.EvidenceItem) {
    self.item = item
    _text = State(initialValue: item.detail)
  }

  var body: some View {
    NavigationStack {
      ZStack {
        HUDBackground()
        VStack(alignment: .leading, spacing: 16) {
          Label(
            String(
              localized:
                "\(item.kind.displayName) evidence · \(TimeFormat.mmss(item.time))"),
            systemImage: item.kind.icon
          )
          .font(.headline).foregroundStyle(item.kind.tint)
          Text(
            item.kind == .visual
              ? String(
                localized:
                  "Correct the OCR exactly as it appears. Keep separate on-screen lines on separate lines."
              )
              : String(
                localized:
                  "Correct the spoken transcript without adding information that was not said.")
          )
          .font(.callout).foregroundStyle(.secondary)
          TextEditor(text: $text)
            .font(.body).scrollContentBackground(.hidden).padding(10)
            .frame(minHeight: 260)
            .glassPanel(cornerRadius: 18)
          if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          Button {
            do {
              try model.applyCorrection(to: item, text: text)
              dismiss()
            } catch {
              self.error = error.localizedDescription
            }
          } label: {
            Label("Apply & Regenerate Notes", systemImage: "arrow.triangle.2.circlepath")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(GlassButtonStyle(tint: VNTheme.mint, prominent: true))
        }
        .padding(20)
      }
      .navigationTitle("Correct Evidence")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .preferredColorScheme(.dark)
    #if os(macOS)
      .frame(minWidth: 600, minHeight: 520)
    #endif
  }
}

private struct SourceEvidencePreview: View {
  let url: URL
  let item: StudioModel.EvidenceItem
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer
  @State private var hasSecurityAccess = false

  init(url: URL, item: StudioModel.EvidenceItem) {
    self.url = url
    self.item = item
    _player = State(initialValue: AVPlayer())
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        NativeVideoPlayer(player: player)
      }
      .navigationTitle(String(localized: "Source · \(TimeFormat.mmss(item.time))"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .preferredColorScheme(.dark)
    .onAppear {
      hasSecurityAccess = url.startAccessingSecurityScopedResource()
      player.pause()
      player.replaceCurrentItem(with: AVPlayerItem(url: url))
      player.seek(
        to: CMTime(seconds: item.time, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero)
    }
    .onDisappear {
      player.pause()
      if hasSecurityAccess { url.stopAccessingSecurityScopedResource() }
    }
    #if os(macOS)
      .frame(minWidth: 760, minHeight: 520)
    #endif
  }
}

#if os(macOS)
  private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
      let view = AVPlayerView()
      view.controlsStyle = .floating
      view.videoGravity = .resizeAspect
      view.player = player
      return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
      if view.player !== player { view.player = player }
    }
  }
#else
  private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
      let controller = AVPlayerViewController()
      controller.videoGravity = .resizeAspect
      controller.player = player
      return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
      if controller.player !== player { controller.player = player }
    }
  }
#endif

private struct ReadingOutlineView: View {
  let pages: [StudioModel.ReadingPage]
  let sourceName: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        HUDBackground()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(pages) { page in
              VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                  Text("PAGE \(page.id + 1)")
                    .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(VNTheme.cyan)
                  Spacer()
                  if !page.sourceTimes.isEmpty {
                    Text(page.sourceTimes.map(TimeFormat.mmss).joined(separator: " · "))
                      .font(.system(.caption, design: .monospaced)).foregroundStyle(VNTheme.gold)
                  }
                }
                Text(page.title).font(.title2.bold()).fontDesign(.rounded)
                  .accessibilityAddTraits(.isHeader)
                Text(page.detail).font(.body).foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              .padding(18)
              .frame(maxWidth: .infinity, alignment: .leading)
              .glassPanel(cornerRadius: 20)
            }
          }
          .padding(18)
        }
        .scrollIndicators(.hidden)
      }
      .navigationTitle(sourceName.isEmpty ? String(localized: "Reading Mode") : sourceName)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .preferredColorScheme(.dark)
    #if os(macOS)
      .frame(minWidth: 640, minHeight: 720)
    #endif
  }
}

// MARK: - page card

/// A page in the carousel: staggered entrance, hover lift + tilt, click to zoom.
struct PageCard: View {
  let page: CGImage
  let index: Int
  let accessibilityTitle: String
  let entranceDelay: Double
  let onTap: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false
  @State private var hoverPoint: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      Image(decorative: page, scale: 2)
        .resizable()
        .aspectRatio(CGSize(width: 1080, height: 1920), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
          Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white)
            .padding(7)
            .background(.black.opacity(0.55), in: Circle())
            .padding(10)
        }
        .shadow(
          color: .black.opacity(hoverPoint != nil ? 0.62 : 0.45),
          radius: hoverPoint != nil ? 26 : 16, y: hoverPoint != nil ? 14 : 8
        )
        .rotation3DEffect(.degrees(tiltX(in: proxy.size)), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(tiltY(in: proxy.size)), axis: (x: 0, y: 1, z: 0))
        .scaleEffect(hoverPoint != nil && !reduceMotion ? 1.012 : 1)
        #if os(macOS)
          .onContinuousHover { phase in
            guard !reduceMotion else { return }
            switch phase {
            case .active(let point): hoverPoint = point
            case .ended: hoverPoint = nil
            }
          }
        #endif
        .onTapGesture(perform: onTap)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Page \(index + 1): \(accessibilityTitle)"))
        .accessibilityIdentifier("note-page-\(index + 1)")
        .accessibilityHint(String(localized: "Opens a zoomed preview"))
        .accessibilityAction(named: "Open preview", onTap)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 26)
        .animation(
          reduceMotion
            ? nil : .spring(response: 0.55, dampingFraction: 0.8).delay(entranceDelay),
          value: appeared
        )
        .animation(
          reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
          value: hoverPoint != nil)
    }
    .aspectRatio(CGSize(width: 1080, height: 1920), contentMode: .fit)
    .task { appeared = true }
  }

  private func tiltX(in size: CGSize) -> Double {
    guard let p = hoverPoint, size.height > 0, !reduceMotion else { return 0 }
    return -Double((p.y / size.height) - 0.5) * 3.4
  }
  private func tiltY(in size: CGSize) -> Double {
    guard let p = hoverPoint, size.width > 0, !reduceMotion else { return 0 }
    return Double((p.x / size.width) - 0.5) * 3.4
  }
}

// MARK: - zoom viewer

struct PageZoomView: View {
  let page: CGImage
  let index: Int
  let total: Int
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var zoom: CGFloat = 1
  @GestureState private var pinch: CGFloat = 1

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.ignoresSafeArea()
      GeometryReader { proxy in
        let fitWidth = min(proxy.size.width - 72, (proxy.size.height - 72) * 1080 / 1920)
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
          Image(decorative: page, scale: 2)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: max(200, fitWidth) * zoom * pinch)
            .padding(36)
            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
        }
        .gesture(
          MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom = min(4, max(0.6, zoom * value.magnification)) }
        )
        .onTapGesture(count: 2) {
          setZoom(zoom > 1.4 ? 1 : 2)
        }
      }

      HStack(spacing: 10) {
        Text(String(localized: "Page \(index + 1) of \(total)"))
          .font(.callout.weight(.medium)).foregroundStyle(.secondary)
        Button {
          setZoom(max(0.6, zoom - 0.25))
        } label: {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(GlassButtonStyle())
        .keyboardShortcut("-", modifiers: .command)
        .accessibilityLabel(String(localized: "Zoom out"))
        Button {
          setZoom(min(4, zoom + 0.25))
        } label: {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(GlassButtonStyle())
        .keyboardShortcut("+", modifiers: .command)
        .accessibilityLabel(String(localized: "Zoom in"))
        Text("\(Int(zoom * 100))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(minWidth: 42)
          .accessibilityLabel(String(localized: "Zoom \(Int(zoom * 100)) percent"))
        Button {
          setZoom(1)
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel(String(localized: "Reset zoom"))
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(GlassButtonStyle())
        .accessibilityLabel(String(localized: "Close preview"))
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)
    }
    #if os(macOS)
      .frame(minWidth: 640, minHeight: 700)
    #endif
    .preferredColorScheme(.dark)
  }

  private func setZoom(_ value: CGFloat) {
    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
      zoom = value
    }
  }
}

private struct AccessLoadingView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      HUDBackground()
      VStack(spacing: 16) {
        Image(systemName: "play.rectangle.on.rectangle.fill")
          .font(.system(size: 46)).foregroundStyle(VNTheme.cyan)
          .symbolEffect(.pulse, isActive: !reduceMotion)
        ProgressView().tint(VNTheme.gold)
        Text("Checking VideoNotes access…").font(.callout).foregroundStyle(.secondary)
      }
      .padding(28).glassPanel(cornerRadius: 24)
    }
    .preferredColorScheme(.dark)
  }
}

/// FileDocument wrapper for the PDF exporter.
struct PDFExportDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.pdf]
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct SemanticExportDocument: FileDocument {
  static let readableContentTypes: [UTType] = [
    UTType(filenameExtension: "md") ?? .plainText, .plainText, .html, .json,
  ]
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

// MARK: - breathing reticle (empty state)

struct BreathingReticle: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var breathe = false

  var body: some View {
    ZStack {
      Circle().stroke(VNTheme.cyan.opacity(0.18), lineWidth: 1)
        .frame(width: 230, height: 230)
        .scaleEffect(breathe ? 1.05 : 0.97)
      Circle().stroke(VNTheme.cyan.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [7, 9]))
        .frame(width: 175, height: 175)
        .rotationEffect(.degrees(breathe ? 14 : 0))
      Image(systemName: "wand.and.stars")
        .font(.system(size: 80)).foregroundStyle(VNTheme.cyan)
        .symbolEffect(.pulse, isActive: !reduceMotion)
    }
    .shadow(color: VNTheme.cyan.opacity(0.3), radius: 24)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breathe = true }
    }
  }
}
