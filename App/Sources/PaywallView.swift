import SwiftUI

struct PaywallView: View {
  @EnvironmentObject private var purchase: PurchaseManager

  private let privacyURL = URL(
    string: "https://github.com/lukekevinmclaughlin-oss/VideoNotes/blob/main/PRIVACY.md")!
  private let termsURL = URL(
    string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
  private let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

  var body: some View {
    ZStack {
      HUDBackground()
      ScrollView {
        VStack(spacing: 24) {
          Image(systemName: "play.rectangle.on.rectangle.fill")
            .font(.system(size: 76)).foregroundStyle(VNTheme.cyan)
            .shadow(color: VNTheme.cyan.opacity(0.6), radius: 25)
            .accessibilityHidden(true)
          Text("VideoNotes Pro").font(.system(size: 42, weight: .bold, design: .rounded))
          Text(
            "Turn one lecture video or audio file into source-cited, illustrated study notes. Analysis runs privately on this device."
          )
          .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 650)

          VStack(alignment: .leading, spacing: 13) {
            Label(
              "On-device transcription and slide OCR", systemImage: "waveform.and.magnifyingglass")
            Label(
              "Source-derived sketches with timestamped evidence", systemImage: "checkmark.shield")
            Label("Seven evidence-preserving note layouts", systemImage: "rectangle.3.group")
            Label("Digital, A4 and US Letter PDF formats", systemImage: "doc.richtext")
            Label(
              "Reading Mode plus PNG, PDF, Markdown, text, HTML and JSON export",
              systemImage: "text.page")
          }
          .font(.body.weight(.medium)).padding(24).glassPanel(cornerRadius: 24)

          purchaseOffer

          Button {
            Task { await purchase.purchase() }
          } label: {
            Group {
              if purchase.isBusy {
                ProgressView().controlSize(.small)
              } else {
                Text(purchase.purchaseButtonTitle)
              }
            }
            .font(.headline).frame(maxWidth: 430).padding(.vertical, 8)
          }
          .buttonStyle(GlassButtonStyle(tint: VNTheme.gold, prominent: true))
          .disabled(purchase.product == nil || purchase.isBusy || purchase.isLoadingProduct)

          Button("Restore Purchases") { Task { await purchase.restore() } }
            .buttonStyle(.plain)
            .disabled(purchase.isBusy)

          if let error = purchase.lastError {
            VStack(spacing: 10) {
              Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
              Button("Retry Store Connection") { Task { await purchase.refresh() } }
                .buttonStyle(GlassButtonStyle(tint: VNTheme.cyan))
                .disabled(purchase.isBusy)
            }
          }

          HStack(spacing: 18) {
            Link("Privacy", destination: privacyURL)
            Link("Terms", destination: termsURL)
            Link("Manage Subscription", destination: subscriptionsURL)
          }
          .font(.caption)

          Text(
            "Subscription renews automatically unless cancelled in App Store settings. Trial availability and pricing are determined by the App Store for your account."
          )
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .frame(maxWidth: 650)
        }
        .padding(34).frame(maxWidth: .infinity)
      }
    }
    .preferredColorScheme(.dark)
    .accessibilityIdentifier("paywall")
  }

  @ViewBuilder private var purchaseOffer: some View {
    if purchase.isLoadingProduct {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Loading current App Store offer…")
      }
      .font(.callout).foregroundStyle(.secondary)
    } else if let offer = purchase.offerDescription {
      Text(offer).font(.headline).multilineTextAlignment(.center)
    } else {
      Text("App Store pricing is temporarily unavailable.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }
}
