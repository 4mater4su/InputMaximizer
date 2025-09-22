//  PurchaseManager.swift
//  InputMaximizer

import StoreKit
import SwiftUI

// MARK: - Product IDs (match your .storekit / App Store Connect)
enum IAP {
    static let creditsSmall  = "io.robinfederico.InputMaximizer.credits_10"
    static let creditsMedium = "io.robinfederico.InputMaximizer.credits_50"

    static let creditPacks: Set<String> = [creditsSmall, creditsMedium]
}

// Optional: map productID -> credits (useful to show amounts in UI)
private let creditAmounts: [String: Int] = [
    IAP.creditsSmall: 10,
    IAP.creditsMedium: 50,
]

@MainActor
final class PurchaseManager: ObservableObject {
    // Products
    @Published var creditProducts: [Product] = []

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

    func credits(for product: Product) -> Int {
        creditAmounts[product.id] ?? 0
    }

    // MARK: - Purchase
    func buyCredits(_ product: Product) async {
        do {
            let result = try await product.purchase()
            try await handlePurchaseResult(result, purchasedID: product.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Internals
    private func handlePurchaseResult(
        _ result: Product.PurchaseResult,
        purchasedID: String
    ) async throws {
        switch result {
        case .success(let verification):
            // Locally verify first (StoreKit 2)
            let tx: StoreKit.Transaction = try checkVerified(verification)

            do {
                if #available(iOS 18.0, *) {
                    // iOS 18+: send signed transaction JWS to server
                    let jws = verification.jwsRepresentation
                    try await GeneratorService.proxy.redeemSignedTransactions(
                        deviceId: DeviceID.current,
                        signedTransactions: [jws]
                    )
                } else {
                    // < iOS 18: fallback to legacy receipt flow
                    let receiptB64 = try await appReceiptBase64_legacy(refreshIfNeeded: true)
                    try await GeneratorService.proxy.redeemReceipt(
                        deviceId: DeviceID.current,
                        receiptBase64: receiptB64
                    )
                }

                // Finish only after the server grants credits
                await tx.finish()

                // Refresh UI / balance
                NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
            } catch {
                // Leave unfinished so we can retry via updates observer
                lastError = "Redeem failed: \(error.localizedDescription)"
                return
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

    // If the app was killed before redeeming, Apple will re-deliver transactions here.
    // We try redeeming again, then finish.
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            guard let self else { return }
            for await update in StoreKit.Transaction.updates {
                do {
                    let tx: StoreKit.Transaction = try await self.checkVerified(update)
                    guard IAP.creditPacks.contains(tx.productID) else {
                        await tx.finish()
                        continue
                    }

                    do {
                        if #available(iOS 18.0, *) {
                            // `update` is VerificationResult<Transaction>; use its JWS directly
                            let jws = update.jwsRepresentation
                            try await GeneratorService.proxy.redeemSignedTransactions(
                                deviceId: DeviceID.current,
                                signedTransactions: [jws]
                            )
                        } else {
                            let receiptB64 = try await self.appReceiptBase64_legacy(refreshIfNeeded: true)
                            try await GeneratorService.proxy.redeemReceipt(
                                deviceId: DeviceID.current,
                                receiptBase64: receiptB64
                            )
                        }

                        await tx.finish()
                        await MainActor.run {
                            NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
                        }
                    } catch {
                        // If redeem fails, don't finish; system will re-deliver later
                        await MainActor.run {
                            self.lastError = "Auto-redeem failed: \(error.localizedDescription)"
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.lastError = "Verification failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Legacy receipt helper (kept available even when your min target is iOS 18)
    // We intentionally DO NOT mark this as "obsoleted: 18.0" because if your deployment
    // target is iOS 18, referencing an obsoleted symbol is a compile error, even in
    // an #available(...) else branch. This keeps it callable in the < iOS 18 paths.
    @available(iOS 15.0, *)
    private func appReceiptBase64_legacy(refreshIfNeeded: Bool = true) async throws -> String {

        func loadReceiptDataIfPresent() -> Data? {
            // Access the same URL as Bundle.main.appStoreReceiptURL, but via KVC to
            // avoid referencing the deprecated symbol directly when building with iOS 18 SDK.
            let url = Bundle.main.value(forKey: "appStoreReceiptURL") as? URL
            guard let u = url, let data = try? Data(contentsOf: u), !data.isEmpty else { return nil }
            return data
        }

        // 1) If a receipt is already present and non-empty, return it.
        if let data = loadReceiptDataIfPresent() {
            return data.base64EncodedString()
        }

        // 2) If caller doesn’t want a refresh attempt, fail now.
        guard refreshIfNeeded else {
            throw NSError(domain: "Receipt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing receipt"])
        }

        // 3) Ask the App Store to sync the receipt (StoreKit 2).
        do { try await AppStore.sync() } catch {
            // Ignore; we’ll re-check below and error out if still missing.
        }

        // 4) Re-check after sync.
        if let data = loadReceiptDataIfPresent() {
            return data.base64EncodedString()
        }

        // 5) Still missing: report a clear error.
        throw NSError(domain: "Receipt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Receipt refresh did not produce a receipt"])
    }

}

// MARK: - Notification
extension Notification.Name {
    static let didPurchaseCredits = Notification.Name("didPurchaseCredits")
}

