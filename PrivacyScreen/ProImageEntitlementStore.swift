import SwiftUI

let proImageAttachmentProductID = "com.domenico.privacyscreen.pro.images.monthly"
private let cryptoscreenPrivacyURL = URL(string: "https://cryptoscreen.app/privacy")!
private let appleStandardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

#if APPCLIP
@MainActor
final class ProImageEntitlementStore: ObservableObject {
  @Published private(set) var isImageAttachmentUnlocked = false
}

struct ProImageAttachmentPaywallView: View {
  @ObservedObject var entitlementStore: ProImageEntitlementStore

  var body: some View {
    EmptyView()
  }
}
#else
import StoreKit

@MainActor
final class ProImageEntitlementStore: ObservableObject {
  @Published private(set) var products: [Product] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isPurchasing = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var isImageAttachmentUnlocked: Bool

  private let productIDs = [proImageAttachmentProductID]
  private let defaults: UserDefaults
  private let cachedUnlockKey = "cryptoscreen.pro.imageAttachmentsUnlocked"
  private var transactionUpdatesTask: Task<Void, Never>?

  var imageAttachmentProduct: Product? {
    products.first { $0.id == proImageAttachmentProductID }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isImageAttachmentUnlocked = defaults.bool(forKey: cachedUnlockKey)

    transactionUpdatesTask = Task { [weak self] in
      for await update in Transaction.updates {
        guard let self else {
          return
        }

        if case .verified(let transaction) = update {
          await transaction.finish()
        }

        await self.refreshEntitlements()
      }
    }

    Task {
      await refresh()
    }
  }

  deinit {
    transactionUpdatesTask?.cancel()
  }

  func refresh() async {
    isLoading = true
    errorMessage = nil

    do {
      products = try await Product.products(for: productIDs).sorted { $0.displayName < $1.displayName }
    } catch {
      errorMessage = "Could not load Pro."
    }

    await refreshEntitlements()
    isLoading = false
  }

  func purchaseImageAttachments() async {
    guard let product = imageAttachmentProduct else {
      errorMessage = "Pro is not available yet."
      return
    }

    isPurchasing = true
    errorMessage = nil
    defer {
      isPurchasing = false
    }

    do {
      let result = try await product.purchase()

      switch result {
      case .success(let verification):
        let transaction = try checkVerified(verification)
        await transaction.finish()
        await refreshEntitlements()
      case .pending:
        errorMessage = "Purchase pending approval."
      case .userCancelled:
        break
      @unknown default:
        errorMessage = "Could not complete purchase."
      }
    } catch {
      errorMessage = "Could not complete purchase."
    }
  }

  func restorePurchases() async {
    isLoading = true
    errorMessage = nil
    defer {
      isLoading = false
    }

    do {
      try await AppStore.sync()
      await refreshEntitlements()
      if !isImageAttachmentUnlocked {
        errorMessage = "No active Pro purchase found."
      }
    } catch {
      errorMessage = "Could not restore purchases."
    }
  }

  private func refreshEntitlements() async {
    var isUnlocked = false

    for await entitlement in Transaction.currentEntitlements {
      guard case .verified(let transaction) = entitlement,
            productIDs.contains(transaction.productID),
            transaction.revocationDate == nil,
            !transaction.isUpgraded else {
        continue
      }

      if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
        continue
      }

      isUnlocked = true
      break
    }

    isImageAttachmentUnlocked = isUnlocked
    defaults.set(isUnlocked, forKey: cachedUnlockKey)
  }

  private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .verified(let value):
      return value
    case .unverified:
      throw ProImageEntitlementError.unverifiedTransaction
    }
  }
}

private enum ProImageEntitlementError: Error {
  case unverifiedTransaction
}

struct ProImageAttachmentPaywallView: View {
  @ObservedObject var entitlementStore: ProImageEntitlementStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Image(systemName: "photo.badge.plus")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))

          Text("Image attachments are now Pro")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)

          Text("cryptoscreen is out of beta. Reading images and sending text-only messages stay free; sending encrypted images is a monthly subscription that supports private storage, bandwidth, and ongoing development.")
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.68))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 12) {
          ProPaywallFeatureRow(text: "Images are encrypted on your device before upload", systemImage: "lock.fill")
          ProPaywallFeatureRow(text: "Subscription helps cover private storage and bandwidth", systemImage: "externaldrive.fill")
          ProPaywallFeatureRow(text: "Recipients can open image messages for free", systemImage: "person.crop.circle.badge.checkmark")
        }

        Spacer(minLength: 0)

        VStack(spacing: 10) {
          Button {
            Task {
              await entitlementStore.purchaseImageAttachments()
              if entitlementStore.isImageAttachmentUnlocked {
                dismiss()
              }
            }
          } label: {
            Label(primaryButtonTitle, systemImage: entitlementStore.isPurchasing ? "hourglass" : "sparkles")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ProPrimaryActionButtonStyle())
          .disabled(entitlementStore.isLoading || entitlementStore.isPurchasing || entitlementStore.imageAttachmentProduct == nil)

          Button {
            Task {
              await entitlementStore.restorePurchases()
              if entitlementStore.isImageAttachmentUnlocked {
                dismiss()
              }
            }
          } label: {
            Label("Restore purchase", systemImage: "arrow.clockwise")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(ProSecondaryActionButtonStyle())
          .disabled(entitlementStore.isLoading || entitlementStore.isPurchasing)

          if let errorMessage = entitlementStore.errorMessage {
            Text(errorMessage)
              .font(.system(size: 13, weight: .medium, design: .rounded))
              .foregroundStyle(Color(red: 1.0, green: 0.68, blue: 0.38))
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          Text(subscriptionDisclosure)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.46))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 14) {
            Link("Privacy", destination: cryptoscreenPrivacyURL)
            Link("Terms", destination: appleStandardEULAURL)
          }
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(red: 0.045, green: 0.047, blue: 0.043))
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
        }
      }
      .toolbarColorScheme(.dark, for: .navigationBar)
      .task {
        await entitlementStore.refresh()
      }
    }
  }

  private var primaryButtonTitle: String {
    if entitlementStore.isPurchasing {
      return "Purchasing..."
    }

    if entitlementStore.isLoading && entitlementStore.imageAttachmentProduct == nil {
      return "Loading Pro..."
    }

    if let product = entitlementStore.imageAttachmentProduct {
      return "Start Pro - \(product.displayPrice)/month"
    }

    return "Pro unavailable"
  }

  private var subscriptionDisclosure: String {
    if let product = entitlementStore.imageAttachmentProduct {
      return "\(product.displayName) renews monthly at \(product.displayPrice) unless canceled in App Store settings."
    }

    return "Renews monthly unless canceled in App Store settings."
  }
}

private struct ProPaywallFeatureRow: View {
  let text: String
  let systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color(red: 0.48, green: 1.0, blue: 0.70))
        .frame(width: 22)

      Text(text)
        .font(.system(size: 15, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.74))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ProPrimaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.055, green: 0.075, blue: 0.06))
      .padding(.vertical, 15)
      .background(
        configuration.isPressed ? Color(red: 0.48, green: 1.0, blue: 0.70).opacity(0.78) : Color(red: 0.48, green: 1.0, blue: 0.70),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
  }
}

private struct ProSecondaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold, design: .rounded))
      .foregroundStyle(Color(red: 0.965, green: 0.965, blue: 0.92))
      .padding(.vertical, 13)
      .background(
        configuration.isPressed ? Color.white.opacity(0.14) : Color.white.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
  }
}
#endif
