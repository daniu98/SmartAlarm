import Foundation
import Testing

@testable import SmartAlarm

@MainActor
@Suite("Entitlements and the paywall")
struct EntitlementTests {
    @Test("Nothing is unlocked before a purchase")
    func lockedByDefault() async {
        let store = EntitlementStore(purchases: MockPurchaseProvider(purchased: false))
        await store.refresh()

        #expect(!store.isPro)
        for feature in ProFeature.allCases {
            #expect(!store.has(feature))
        }
    }

    @Test("A completed purchase unlocks everything")
    func purchaseUnlocks() async {
        let store = EntitlementStore(purchases: MockPurchaseProvider(purchased: false))
        let outcome = await store.purchase()

        #expect(outcome == .purchased)
        #expect(store.isPro)
        #expect(ProFeature.allCases.allSatisfy { store.has($0) })
    }

    @Test("Cancelling leaves the user where they were, with no error shown")
    func cancelIsNotAnError() async {
        let provider = MockPurchaseProvider(purchased: false)
        provider.outcome = .cancelled
        let store = EntitlementStore(purchases: provider)

        #expect(await store.purchase() == .cancelled)
        #expect(!store.isPro)
        #expect(store.lastErrorMessage == nil)
    }

    /// Ask to Buy: the purchase isn't finished, so nothing unlocks yet, but the screen has to
    /// say so rather than looking like a failure.
    @Test("A pending purchase waits for approval instead of unlocking")
    func pendingAwaitsApproval() async {
        let provider = MockPurchaseProvider(purchased: false)
        provider.outcome = .pending
        let store = EntitlementStore(purchases: provider)

        #expect(await store.purchase() == .pending)
        #expect(!store.isPro)
        #expect(store.isAwaitingApproval)
    }

    @Test("A failed purchase surfaces a message and unlocks nothing")
    func failureIsReported() async {
        let provider = MockPurchaseProvider(purchased: false)
        provider.error = PurchaseError.productUnavailable
        let store = EntitlementStore(purchases: provider)

        #expect(await store.purchase() == nil)
        #expect(!store.isPro)
        #expect(store.lastErrorMessage != nil)
    }

    @Test("Restore recovers a previous purchase")
    func restoreWorks() async {
        let store = EntitlementStore(purchases: MockPurchaseProvider(purchased: true))
        await store.restore()
        #expect(store.isPro)
    }

    @Test("Restoring with nothing to restore explains itself")
    func restoreWithoutPurchase() async {
        let store = EntitlementStore(purchases: MockPurchaseProvider(purchased: false))
        await store.restore()
        #expect(!store.isPro)
        #expect(store.lastErrorMessage != nil)
    }

    @Test("Concurrent taps only ever start one purchase")
    func purchaseIsNotReentrant() async {
        let provider = MockPurchaseProvider(purchased: false)
        let store = EntitlementStore(purchases: provider)

        async let first = store.purchase()
        async let second = store.purchase()
        _ = await (first, second)

        #expect(provider.purchaseCallCount == 1)
    }

    @Test("Free history is a week; Pro is everything")
    func historyWindow() {
        #expect(FreeTier.historyDays == 7)
        #expect(FreeTier.historyInterval == 7 * 24 * 60 * 60)
    }
}
