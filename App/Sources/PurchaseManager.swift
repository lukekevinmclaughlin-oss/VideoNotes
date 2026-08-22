import Foundation
import StoreKit

struct SubscriptionProductInfo: Equatable, Sendable {
  struct IntroductoryOffer: Equatable, Sendable {
    var periodLabel: String
    var isFreeTrial: Bool
  }

  var id: String
  var displayPrice: String
  var periodLabel: String
  var introductoryOffer: IntroductoryOffer?
}

enum SubscriptionPurchaseOutcome: Equatable, Sendable {
  case purchased
  case pending
  case userCancelled
}

@MainActor
protocol SubscriptionStoreServing: AnyObject {
  func loadProduct(id: String) async throws -> SubscriptionProductInfo
  func isEligibleForIntroOffer(productID: String) async -> Bool
  func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome
  func restore() async throws
  func hasActiveEntitlement(productID: String) async -> Bool
}

@MainActor
final class StoreKitSubscriptionStore: SubscriptionStoreServing {
  private var products: [String: Product] = [:]

  func loadProduct(id: String) async throws -> SubscriptionProductInfo {
    guard let product = try await Product.products(for: [id]).first else {
      throw SubscriptionStoreError.productUnavailable
    }
    products[id] = product
    let offer = product.subscription?.introductoryOffer
    return SubscriptionProductInfo(
      id: product.id, displayPrice: product.displayPrice,
      periodLabel: product.subscription.map {
        PurchaseManager.periodLabel($0.subscriptionPeriod)
      } ?? String(localized: "billing period"),
      introductoryOffer: offer.map {
        SubscriptionProductInfo.IntroductoryOffer(
          periodLabel: PurchaseManager.periodLabel($0.period),
          isFreeTrial: $0.paymentMode == .freeTrial)
      })
  }

  func isEligibleForIntroOffer(productID: String) async -> Bool {
    guard let subscription = products[productID]?.subscription else { return false }
    return await subscription.isEligibleForIntroOffer
  }

  func purchase(productID: String) async throws -> SubscriptionPurchaseOutcome {
    guard let product = products[productID] else {
      throw SubscriptionStoreError.productUnavailable
    }
    switch try await product.purchase() {
    case .success(let result):
      guard case .verified(let transaction) = result else {
        throw SubscriptionStoreError.verification
      }
      await transaction.finish()
      return .purchased
    case .pending:
      return .pending
    case .userCancelled:
      return .userCancelled
    @unknown default:
      return .userCancelled
    }
  }

  func restore() async throws { try await AppStore.sync() }

  func hasActiveEntitlement(productID: String) async -> Bool {
    for await result in Transaction.currentEntitlements {
      if case .verified(let transaction) = result,
        transaction.productID == productID,
        transaction.revocationDate == nil,
        (transaction.expirationDate ?? .distantFuture) > Date()
      {
        return true
      }
    }
    return false
  }
}

enum SubscriptionStoreError: LocalizedError {
  case verification
  case productUnavailable

  var errorDescription: String? {
    switch self {
    case .verification:
      return String(localized: "The App Store purchase could not be verified.")
    case .productUnavailable:
      return String(localized: "The subscription is temporarily unavailable.")
    }
  }
}

@MainActor
final class PurchaseManager: ObservableObject {
  static let monthlyID = "com.lukemclaughlin.videonotes.pro.monthly"
  static let annualID = "com.lukemclaughlin.videonotes.pro.annual"
  static let shared = PurchaseManager()

  // Freemium: the app is free (3 analyses/day); Pro is unlimited.
  @Published private(set) var hasAccess = false
  @Published private(set) var isLoadingEntitlement = true
  @Published private(set) var isLoadingProduct = true
  @Published private(set) var isBusy = false
  @Published private(set) var isEligibleForIntroOffer = false
  @Published private(set) var product: SubscriptionProductInfo?
  @Published var lastError: String?

  private let store: SubscriptionStoreServing
  private var updatesTask: Task<Void, Never>?

  init(
    store: SubscriptionStoreServing? = nil,
    observesTransactions: Bool = true,
    refreshesAutomatically: Bool = true
  ) {
    self.store = store ?? StoreKitSubscriptionStore()
    #if DEBUG
      if ProcessInfo.processInfo.environment["VIDEONOTES_DEMO"] == "1" {
        hasAccess = true
        isLoadingEntitlement = false
        isLoadingProduct = false
        return
      }
    #endif
        #if DIRECT_DISTRIBUTION
        hasAccess = true
        #endif
    if observesTransactions { updatesTask = listen() }
    if refreshesAutomatically {
      Task { await refresh() }
    } else {
      isLoadingProduct = false
      isLoadingEntitlement = false
    }
  }

  var billingDescription: String? {
    guard let product else { return nil }
    return String(localized: "\(product.displayPrice) per \(product.periodLabel)")
  }

  var offerDescription: String? {
    guard isEligibleForIntroOffer,
      let offer = product?.introductoryOffer,
      offer.isFreeTrial,
      let billingDescription
    else { return billingDescription }
    return String(
      localized: "\(offer.periodLabel.localizedCapitalized) free, then \(billingDescription)")
  }

  var purchaseButtonTitle: String {
    guard isEligibleForIntroOffer,
      let offer = product?.introductoryOffer,
      offer.isFreeTrial
    else { return String(localized: "Subscribe") }
    return String(localized: "Start \(offer.periodLabel.localizedCapitalized) Free Trial")
  }

  func refresh() async {
    isLoadingProduct = true
    lastError = nil
    do {
      let loaded = try await store.loadProduct(id: Self.monthlyID)
      product = loaded
      isEligibleForIntroOffer = await store.isEligibleForIntroOffer(productID: loaded.id)
    } catch {
      product = nil
      isEligibleForIntroOffer = false
      lastError = error.localizedDescription
    }
    isLoadingProduct = false
    await updateEntitlement()
  }

  func purchase() async {
    guard !isBusy else { return }
    guard let product else {
      lastError = SubscriptionStoreError.productUnavailable.localizedDescription
      return
    }
    isBusy = true
    defer { isBusy = false }
    lastError = nil
    do {
      switch try await store.purchase(productID: product.id) {
      case .purchased:
        await updateEntitlement()
      case .pending:
        lastError = String(localized: "Your purchase is pending approval.")
      case .userCancelled:
        break
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  func restore() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    lastError = nil
    do {
      try await store.restore()
      await updateEntitlement()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func updateEntitlement() async {
    var active = await store.hasActiveEntitlement(productID: Self.monthlyID)
    #if DEBUG
      active = active || ProcessInfo.processInfo.environment["VIDEONOTES_DEMO"] == "1"
    #endif
        #if DIRECT_DISTRIBUTION
        active = true
        #endif
    hasAccess = active
    isLoadingEntitlement = false
  }

  private func listen() -> Task<Void, Never> {
    Task { [weak self] in
      for await result in Transaction.updates {
        if case .verified(let transaction) = result { await transaction.finish() }
        await self?.updateEntitlement()
      }
    }
  }

  static func periodLabel(_ period: Product.SubscriptionPeriod) -> String {
    switch period.unit {
    case .day:
      return period.value == 1
        ? String(localized: "day") : String(localized: "\(period.value) days")
    case .week:
      return period.value == 1
        ? String(localized: "week") : String(localized: "\(period.value) weeks")
    case .month:
      return period.value == 1
        ? String(localized: "month") : String(localized: "\(period.value) months")
    case .year:
      return period.value == 1
        ? String(localized: "year") : String(localized: "\(period.value) years")
    default:
      return period.value == 1
        ? String(localized: "period") : String(localized: "\(period.value) periods")
    }
  }
}


extension PurchaseManager {
  static let dailyFreeAnalyses = 3

  /// Consume one of today's free analyses. Pro always passes.
  func consumeFreeAnalysis() -> Bool {
    guard !hasAccess else { return true }
    let today = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
    let d = UserDefaults.standard
    if d.string(forKey: "vn.freeDay") != today {
      d.set(today, forKey: "vn.freeDay")
      d.set(0, forKey: "vn.freeUsed")
    }
    let used = d.integer(forKey: "vn.freeUsed")
    guard used < Self.dailyFreeAnalyses else { return false }
    d.set(used + 1, forKey: "vn.freeUsed")
    return true
  }
}
