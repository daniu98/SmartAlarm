import Foundation

/// The single source of truth for what the user has paid for.
///
/// Fails *closed* on load errors but *open* on nothing: if the App Store can't be reached, a
/// previously-purchased user keeps what they bought, because `isPurchased()` reads the local
/// entitlement cache rather than the network.
@MainActor
@Observable
final class EntitlementStore {
    private let purchases: any PurchaseProviding

    private(set) var isPro = false
    private(set) var product: StoreProduct?
    private(set) var isWorking = false
    private(set) var lastErrorMessage: String?
    /// Set after an Ask-to-Buy style purchase that hasn't been approved yet.
    private(set) var isAwaitingApproval = false

    init(purchases: any PurchaseProviding) {
        self.purchases = purchases
    }

    func has(_ feature: ProFeature) -> Bool {
        isPro
    }

    #if DEBUG
    /// Flips entitlement without a transaction. The StoreKit configuration file only applies
    /// when Xcode launches the app, so this is the only way to exercise both states from the
    /// command line — and it saves buying the thing on every clean install.
    func setDebugOverride(_ value: Bool) {
        isPro = value
    }
    #endif

    func refresh() async {
        isPro = await purchases.isPurchased()
        product = try? await purchases.loadProduct()
    }

    /// Long-lived: catches purchases made on another device, and Ask-to-Buy approvals.
    func observeUpdates() async {
        for await purchased in purchases.entitlementUpdates() {
            isPro = purchased
            if purchased { isAwaitingApproval = false }
        }
    }

    @discardableResult
    func purchase() async -> PurchaseOutcome? {
        guard !isWorking else { return nil }
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            let outcome = try await purchases.purchase()
            switch outcome {
            case .purchased, .alreadyOwned:
                isPro = true
                isAwaitingApproval = false
            case .pending:
                isAwaitingApproval = true
            case .cancelled:
                break
            }
            return outcome
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            let restored = try await purchases.restore()
            isPro = restored
            if !restored {
                lastErrorMessage = "No previous purchase found on this Apple Account."
            }
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Used in tests, previews, and the debug menu.
final class MockPurchaseProvider: PurchaseProviding, @unchecked Sendable {
    var purchased: Bool
    var outcome: PurchaseOutcome = .purchased
    var error: Error?
    private(set) var purchaseCallCount = 0

    init(purchased: Bool = false) {
        self.purchased = purchased
    }

    func loadProduct() async throws -> StoreProduct? {
        StoreProduct(
            id: StoreKitPurchaseProvider.proProductID,
            displayName: "SmartyAlarm Pro",
            displayPrice: "$7.99",
            description: "Calendar, weather and full history."
        )
    }

    func isPurchased() async -> Bool { purchased }

    func purchase() async throws -> PurchaseOutcome {
        purchaseCallCount += 1
        if let error { throw error }
        if outcome == .purchased { purchased = true }
        return outcome
    }

    func restore() async throws -> Bool {
        if let error { throw error }
        return purchased
    }

    func entitlementUpdates() -> AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}
