//
//  PurchaseManager.swift
//  InputMaximizer
//
//  Created by Robin Geske on 07.09.25.
//

import StoreKit
import SwiftUI

// MARK: - Product IDs (update these in App Store Connect later)
enum IAP {
    static let proUnlock     = "com.yourcompany.inputmaximizer.pro_unlock"
    static let creditsSmall  = "com.yourcompany.inputmaximizer.credits_10"
    static let creditsMedium = "com.yourcompany.inputmaximizer.credits_50"
    static let creditsLarge  = "com.yourcompany.inputmaximizer.credits_200"

    static let creditPacks: Set<String> = [creditsSmall, creditsMedium, creditsLarge]
    static let allIDs: Set<String> = Set([proUnlock]).union(creditPacks)
}

// Internal mapping: productID -> credits granted
private let _creditAmounts: [String: Int] = [
    IAP.creditsSmall: 10,
    IAP.creditsMedium: 50,
    IAP.creditsLarge: 200
]

@MainActor
final class PurchaseManager: ObservableObject {

    // Expose initial unlock credits to UI
    let initialUnlockCredits: Int = 20

    // Products
    @Published var unlockProduct: Product?
    @Published var creditProducts: [Product] = []

    // Entitlement & credits (device-local for MVP)
    @Published var hasProUnlock = false
    @AppStorage("credits.balance") private(set) var creditBalance: Int = 0

    // UI state
    @Published var isLoading = false
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactionUpdates()
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Store loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: Array(IAP.allIDs))
            unlockProduct = products.first(where: { $0.id == IAP.proUnlock })
            creditProducts = products
                .filter { IAP.creditPacks.contains($0.id) }
                .sorted { $0.price < $1.price }

            await updateEntitlementFromCurrentTransactions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Purchase flows

    func buyUnlock() async {
        guard let product = unlockProduct else { return }
        do {
            let result = try await product.purchase()
            try await handlePurchaseResult(result, isUnlock: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func buyCredits(_ product: Product) async {
        do {
            let result = try await product.purchase()
            try await handlePurchaseResult(result, isUnlock: false, purchasedID: product.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await updateEntitlementFromCurrentTransactions()
            // Note: consumables are not restorable
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Credits helpers

    func credits(for product: Product) -> Int {
        _creditAmounts[product.id] ?? 0
    }

    @discardableResult
    func spendOneCredit() -> Bool {
        guard creditBalance > 0 else { return false }
        creditBalance -= 1
        return true
    }

    func refundOneCreditIfNeeded() {
        creditBalance += 1
    }

    func addCredits(_ amount: Int) {
        guard amount > 0 else { return }
        creditBalance += amount
    }

    // MARK: - Internals

    private func handlePurchaseResult(_ result: Product.PurchaseResult,
                                      isUnlock: Bool,
                                      purchasedID: String? = nil) async throws {
        switch result {
        case .success(let verification):
            let tx = try checkVerified(verification)
            await tx.finish()

            if isUnlock {
                let wasUnlocked = hasProUnlock
                await updateEntitlementFromCurrentTransactions()
                if !wasUnlocked && hasProUnlock {
                    addCredits(initialUnlockCredits)
                }
            } else if let id = purchasedID {
                addCredits(_creditAmounts[id] ?? 0)
            }

        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe): return safe
        }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if let tx = try? await self.checkVerified(update) {
                    await tx.finish()
                    await self.updateEntitlementFromCurrentTransactions()
                }
            }
        }
    }

    private func updateEntitlementFromCurrentTransactions() async {
        var unlocked = false

        for await entitlement in Transaction.currentEntitlements {
            // entitlement: VerificationResult<Transaction>
            guard let tx = try? checkVerified(entitlement) else { continue }

            if tx.productID == IAP.proUnlock,
               tx.productType == .nonConsumable,
               tx.revocationDate == nil {
                unlocked = true
            }
        }

        await MainActor.run {
            self.hasProUnlock = unlocked
        }
    }
}
