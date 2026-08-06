import Foundation
import StoreKit

struct StoreProduct: Sendable, Hashable {
    var id: String
    var displayName: String
    var displayPrice: String
    var description: String
}

enum PurchaseOutcome: Sendable, Hashable {
    case purchased
    case cancelled
    /// Awaiting approval — Ask to Buy, or a payment method that needs confirming.
    case pending
    case alreadyOwned
}

enum PurchaseError: LocalizedError {
    case productUnavailable
    case verificationFailed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "The upgrade isn't available right now. Check your connection and try again."
        case .verificationFailed:
            "The App Store couldn't verify that purchase."
        case .failed(let detail):
            detail
        }
    }
}

/// Behind a protocol like every other external dependency, so entitlement logic can be tested
/// without the App Store in the loop.
protocol PurchaseProviding: Sendable {
    func loadProduct() async throws -> StoreProduct?
    func isPurchased() async -> Bool
    func purchase() async throws -> PurchaseOutcome
    func restore() async throws -> Bool
    /// Fires whenever entitlements change — including purchases made on another device.
    func entitlementUpdates() -> AsyncStream<Bool>
}

/// StoreKit 2. A single non-consumable: buy once, owned forever.
///
/// Deliberately not a subscription. The app has no ongoing server cost to fund, so charging
/// rent for something that runs entirely on the user's own phone would be hard to defend —
/// and users say so in reviews.
struct StoreKitPurchaseProvider: PurchaseProviding {
    static let proProductID = "com.danielxiao.SmartAlarm.pro"

    func loadProduct() async throws -> StoreProduct? {
        do {
            let products = try await Product.products(for: [Self.proProductID])
            guard let product = products.first else { return nil }
            return StoreProduct(
                id: product.id,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                description: product.description
            )
        } catch {
            throw PurchaseError.failed(error.localizedDescription)
        }
    }

    func isPurchased() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func purchase() async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [Self.proProductID]).first else {
            throw PurchaseError.productUnavailable
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw PurchaseError.failed(error.localizedDescription)
        }

        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw PurchaseError.verificationFailed
            }
            await transaction.finish()
            return .purchased
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            throw PurchaseError.failed(error.localizedDescription)
        }
        return await isPurchased()
    }

    func entitlementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result else { continue }
                    await transaction.finish()
                    continuation.yield(await isPurchased())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
