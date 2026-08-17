import SketchnoteEngine
import StoreKit
import XCTest

@testable import VideoNotes

#if os(iOS)
  import StoreKitTest
#endif

@MainActor
final class VideoNotesStoreKitTests: XCTestCase {
  func testGermanRuntimeCatalogLocalizesDynamicUIAndPluralForms() throws {
    let localizationPath = try XCTUnwrap(
      Bundle.main.path(forResource: "de", ofType: "lproj"))
    let german = try XCTUnwrap(Bundle(path: localizationPath))
    let format = "Illustriert"

    XCTAssertEqual(
      german.localizedString(forKey: "Subscribe", value: nil, table: nil), "Abonnieren")
    XCTAssertEqual(
      String.localizedStringWithFormat(
        german.localizedString(forKey: "%lld pages", value: nil, table: nil), 1),
      "1 Seite")
    XCTAssertEqual(
      String.localizedStringWithFormat(
        german.localizedString(forKey: "%lld pages", value: nil, table: nil), 2),
      "2 Seiten")
    let workspaceStatus = german.localizedString(
      forKey: "%lld pages · %@ · private, on-device · autosaved locally", value: nil,
      table: nil)
    XCTAssertEqual(
      String.localizedStringWithFormat(workspaceStatus, 1, format),
      "1 Seite · Illustriert · privat, auf diesem Gerät · lokal automatisch gespeichert")
    XCTAssertEqual(
      String.localizedStringWithFormat(
        german.localizedString(
          forKey: "%lld source-matched drawings", value: nil, table: nil), 1),
      "1 quellenabgeglichene Zeichnung")
  }

  func testLocalizedDisplayNamesDoNotChangeStableFormatIdentifiers() {
    XCTAssertEqual(NotePresentationFormat.evidenceFirst.rawValue, "evidenceFirst")
    XCTAssertEqual(PDFPageFormat.usLetter.rawValue, "usLetter")
    XCTAssertFalse(NotePresentationFormat.evidenceFirst.localizedDisplayName.isEmpty)
    XCTAssertFalse(PDFPageFormat.usLetter.localizedDisplayName.isEmpty)
    XCTAssertFalse(Palette.all[0].localizedDisplayName.isEmpty)
  }

  func testExpandedPresentationFormatsHaveStableUniqueLocalizedIdentifiers() throws {
    let newIdentifiers: [NotePresentationFormat: String] = [
      .cornellNotes: "cornellNotes",
      .hierarchicalOutline: "hierarchicalOutline",
      .timeline: "timeline",
      .qaFlashcards: "qaFlashcards",
      .examRevision: "examRevision",
      .tutorial: "tutorial",
      .decisionsAndActions: "decisionsAndActions",
    ]

    XCTAssertEqual(NotePresentationFormat.allCases.count, 14)
    for (format, identifier) in newIdentifiers {
      XCTAssertEqual(format.rawValue, identifier)
      XCTAssertFalse(format.localizedDisplayName.isEmpty)
    }
    XCTAssertEqual(
      Set(NotePresentationFormat.allCases.map(\.localizedDisplayName)).count,
      NotePresentationFormat.allCases.count)

    let localizationPath = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj"))
    let german = try XCTUnwrap(Bundle(path: localizationPath))
    XCTAssertEqual(
      german.localizedString(forKey: "Cornell Notes", value: nil, table: nil),
      "Cornell-Notizen")
    XCTAssertEqual(
      german.localizedString(forKey: "Decisions & Action Items", value: nil, table: nil),
      "Entscheidungen & Aufgaben")
  }

  func testConfigurationProvidesMonthlySubscriptionAndTrial() async throws {
    let configurationURL = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "VideoNotes", withExtension: "storekit"))
    let configurationData = try Data(contentsOf: configurationURL)
    let configuration = try XCTUnwrap(
      JSONSerialization.jsonObject(with: configurationData) as? [String: Any])
    let groups = try XCTUnwrap(configuration["subscriptionGroups"] as? [[String: Any]])
    let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
    let subscription = try XCTUnwrap(
      subscriptions.first { $0["productID"] as? String == PurchaseManager.monthlyID })
    let introductoryOffer = try XCTUnwrap(
      subscription["introductoryOffer"] as? [String: Any])

    XCTAssertEqual(subscription["recurringSubscriptionPeriod"] as? String, "P1M")
    XCTAssertEqual(subscription["displayPrice"] as? String, "9.99")
    XCTAssertEqual(introductoryOffer["subscriptionPeriod"] as? String, "P1W")
    XCTAssertEqual(introductoryOffer["paymentMode"] as? String, "free")

    #if os(iOS)
      let session = try SKTestSession(configurationFileNamed: "VideoNotes")
      session.disableDialogs = true
      session.resetToDefaultState()
      session.clearTransactions()

      let products = try await Product.products(for: [PurchaseManager.monthlyID])
      let product = try XCTUnwrap(products.first)

      XCTAssertEqual(product.id, PurchaseManager.monthlyID)
      XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
      XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
      XCTAssertEqual(product.subscription?.introductoryOffer?.period.value, 7)
      XCTAssertEqual(product.subscription?.introductoryOffer?.period.unit, .day)
      XCTAssertEqual(product.subscription?.introductoryOffer?.paymentMode, .freeTrial)
      XCTAssertEqual(
        product.subscription.map { PurchaseManager.periodLabel($0.subscriptionPeriod) }, "month")
      XCTAssertEqual(
        product.subscription?.introductoryOffer.map { PurchaseManager.periodLabel($0.period) },
        "7 days")
    #endif
  }

  func testPurchaseStateMachineUnlocksVerifiedMockEntitlement() async {
    let store = MockSubscriptionStore()
    let purchase = PurchaseManager(
      store: store, observesTransactions: false, refreshesAutomatically: false)

    await purchase.refresh()

    XCTAssertEqual(purchase.billingDescription, "€9.99 per month")
    XCTAssertEqual(purchase.offerDescription, "7 Days free, then €9.99 per month")
    XCTAssertEqual(purchase.purchaseButtonTitle, "Start 7 Days Free Trial")
    await purchase.purchase()
    XCTAssertTrue(purchase.hasAccess)
    XCTAssertEqual(store.purchaseCount, 1)
    XCTAssertFalse(purchase.isBusy)
    XCTAssertNil(purchase.lastError)
  }

  func testPendingPurchaseAndRestoreStatesAreExplicit() async {
    let store = MockSubscriptionStore()
    store.purchaseOutcome = .pending
    let purchase = PurchaseManager(
      store: store, observesTransactions: false, refreshesAutomatically: false)
    await purchase.refresh()

    await purchase.purchase()

    XCTAssertFalse(purchase.hasAccess)
    XCTAssertEqual(purchase.lastError, "Your purchase is pending approval.")

    store.activatesOnRestore = true
    await purchase.restore()
    XCTAssertTrue(purchase.hasAccess)
    XCTAssertEqual(store.restoreCount, 1)
    XCTAssertNil(purchase.lastError)
  }

  func testStoreLoadFailureClearsProductAndSurfacesRetryableError() async {
    let store = MockSubscriptionStore()
    store.loadError = SubscriptionStoreError.productUnavailable
    let purchase = PurchaseManager(
      store: store, observesTransactions: false, refreshesAutomatically: false)

    await purchase.refresh()

    XCTAssertNil(purchase.product)
    XCTAssertFalse(purchase.isLoadingProduct)
    XCTAssertFalse(purchase.hasAccess)
    XCTAssertEqual(purchase.lastError, "The subscription is temporarily unavailable.")
  }

  func testDuplicatePurchaseTapIsIgnoredWhileTransactionIsInFlight() async {
    let store = MockSubscriptionStore()
    store.purchaseDelayNanoseconds = 120_000_000
    let purchase = PurchaseManager(
      store: store, observesTransactions: false, refreshesAutomatically: false)
    await purchase.refresh()

    let firstPurchase = Task { await purchase.purchase() }
    try? await Task.sleep(nanoseconds: 20_000_000)
    await purchase.purchase()
    await firstPurchase.value

    XCTAssertEqual(store.purchaseCount, 1)
    XCTAssertTrue(purchase.hasAccess)
  }
}

@MainActor
private final class MockSubscriptionStore: SubscriptionStoreServing {
  var product = SubscriptionProductInfo(
    id: PurchaseManager.monthlyID, displayPrice: "€9.99", periodLabel: "month",
    introductoryOffer: .init(periodLabel: "7 days", isFreeTrial: true))
  var isEligible = true
  var purchaseOutcome: SubscriptionPurchaseOutcome = .purchased
  var activeEntitlement = false
  var activatesOnRestore = false
  var loadError: Error?
  var purchaseDelayNanoseconds: UInt64 = 0
  var purchaseCount = 0
  var restoreCount = 0

  func loadProduct(id: String) async throws -> SubscriptionProductInfo {
    if let loadError { throw loadError }
    return product
  }

  func isEligibleForIntroOffer(productID: String) async -> Bool { isEligible }

  func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome {
    purchaseCount += 1
    if purchaseDelayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: purchaseDelayNanoseconds)
    }
    if purchaseOutcome == .purchased { activeEntitlement = true }
    return purchaseOutcome
  }

  func restore() async throws {
    restoreCount += 1
    if activatesOnRestore { activeEntitlement = true }
  }

  func hasActiveEntitlement(productID: String) async -> Bool { activeEntitlement }
}
