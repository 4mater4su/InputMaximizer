//
//  PurchaseManager.swift
//  InputMaximizer
//
//  Created by Robin Geske on 07.09.25.
//

import StoreKit
import SwiftUI

// MARK: - Product IDs (match your .storekit / App Store Connect)
enum IAP {
    static let creditsSmall  = "com.yourcompany.inputmaximizer.credits_10"
    static let creditsMedium = "com.yourcompany.inputmaximizer.credits_50"
    static let creditsLarge  = "com.yourcompany.inputmaximizer.credits_200"

    static let creditPacks: Set<String> = [creditsSmall, creditsMedium, creditsLarge]
}

// Map productID -> credits
private let creditAmounts: [String: Int] = [
    IAP.creditsSmall: 10,
    IAP.creditsMedium: 50,
    IAP.creditsLarge: 200
]

@MainActor
final class PurchaseManager: ObservableObject {
    // Products
    @Published var creditProducts: [Product] = []

    // Local credit ledger (MVP)
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

    // MARK: - Load products
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: Array(IAP.creditPacks))
            creditProducts = products.sorted { credits(for: $0) < credits(for: $1) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Purchase credits
    func buyCredits(_ product: Product) async {
        do {
            let result = try await product.purchase()
            try await handlePurchaseResult(result, purchasedID: product.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Credits
    func credits(for product: Product) -> Int {
        creditAmounts[product.id] ?? 0
    }
    @discardableResult
    func spendOneCredit() -> Bool {
        guard creditBalance > 0 else { return false }
        creditBalance -= 1
        return true
    }
    func refundOneCreditIfNeeded() { creditBalance += 1 }
    func addCredits(_ amount: Int) { if amount > 0 { creditBalance += amount } }

    // MARK: - Internals
    private func handlePurchaseResult(_ result: Product.PurchaseResult,
                                      purchasedID: String) async throws {
        switch result {
        case .success(let verification):
            let tx = try checkVerified(verification)
            await tx.finish()
            addCredits(creditAmounts[purchasedID] ?? 0)
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
            guard let self else { return }
            for await update in Transaction.updates {
                if let tx = try? await self.checkVerified(update),
                   IAP.creditPacks.contains(tx.productID),
                   let amount = creditAmounts[tx.productID] {
                    await tx.finish()
                    await MainActor.run { self.addCredits(amount) }
                }
            }
        }
    }
}
