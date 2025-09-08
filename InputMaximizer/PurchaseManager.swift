//  PurchaseManager.swift
//  InputMaximizer

import StoreKit
import SwiftUI

// MARK: - Product IDs (match your .storekit / App Store Connect)
enum IAP {
    static let creditsSmall  = "com.yourcompany.inputmaximizer.credits_10"
    static let creditsMedium = "com.yourcompany.inputmaximizer.credits_50"
    static let creditsLarge  = "com.yourcompany.inputmaximizer.credits_200"

    static let creditPacks: Set<String> = [creditsSmall, creditsMedium, creditsLarge]
}

// Optional: map productID -> credits (useful to show amounts in UI)
private let creditAmounts: [String: Int] = [
    IAP.creditsSmall: 10,
    IAP.creditsMedium: 50,
    IAP.creditsLarge: 200
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

    // MARK: - Purchase
    func buyCredits(_ product: Product) async {
        do {
            let result = try await product.purchase()
            try await handlePurchaseResult(result, purchasedID: product.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func credits(for product: Product) -> Int {
        creditAmounts[product.id] ?? 0
    }

    // MARK: - Internals
    private func handlePurchaseResult(_ result: Product.PurchaseResult,
                                      purchasedID: String) async throws {
        switch result {
        case .success(let verification):
            let tx = try checkVerified(verification)

            do {
                // 1) Read or refresh the receipt
                let receiptB64 = try await appReceiptBase64(refreshIfNeeded: true)

                // 2) Ask your proxy to verify & grant credits (server is source of truth)
                _ = try await GeneratorService.proxy.redeemReceipt(
                    deviceId: DeviceID.current,
                    receiptBase64: receiptB64
                )

                // 3) Finish transaction only after successful redeem
                await tx.finish()

                // 4) Nudge UI to refresh server balance
                NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)

            } catch {
                // Leave the transaction unfinished so we can retry redeem later (see updates observer)
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
            for await update in Transaction.updates {
                do {
                    let tx = try await self.checkVerified(update)
                    guard IAP.creditPacks.contains(tx.productID) else {
                        await tx.finish()
                        continue
                    }

                    // Attempt server redeem again (idempotent on server because of receipt)
                    let receiptB64 = try await self.appReceiptBase64(refreshIfNeeded: true)
                    _ = try await GeneratorService.proxy.redeemReceipt(
                        deviceId: DeviceID.current,
                        receiptBase64: receiptB64
                    )
                    await tx.finish()
                    await MainActor.run {
                        NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
                    }
                } catch {
                    // If redeem fails, don't finish; system will re-deliver later
                    await MainActor.run { self.lastError = "Auto-redeem failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    // MARK: - Receipt helper
    private func appReceiptBase64(refreshIfNeeded: Bool = true) async throws -> String {
        func loadReceipt() throws -> Data {
            guard let url = Bundle.main.appStoreReceiptURL,
                  let data = try? Data(contentsOf: url) else {
                throw NSError(domain: "Receipt", code: 1, userInfo: [NSLocalizedDescriptionKey: "No receipt file"])
            }
            return data
        }

        if let url = Bundle.main.appStoreReceiptURL,
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            return data.base64EncodedString()
        }

        guard refreshIfNeeded else {
            throw NSError(domain: "Receipt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing receipt"])
        }

        // iOS 15+: try AppStore.sync() first (optional but nice)
        if #available(iOS 15.0, *) {
            do { try await AppStore.sync() } catch { /* fall back */ }
            if let url = Bundle.main.appStoreReceiptURL,
               let data = try? Data(contentsOf: url),
               !data.isEmpty {
                return data.base64EncodedString()
            }
        }

        // Fallback: SKReceiptRefreshRequest
        final class Refresher: NSObject, SKRequestDelegate {
            var cont: CheckedContinuation<Void, Error>?
            func requestDidFinish(_ request: SKRequest) { cont?.resume() }
            func request(_ request: SKRequest, didFailWithError error: Error) { cont?.resume(throwing: error) }
        }
        let r = Refresher()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            r.cont = cont
            let req = SKReceiptRefreshRequest()
            req.delegate = r
            req.start()
        }

        let data = try loadReceipt()
        return data.base64EncodedString()
    }
}

extension Notification.Name {
    static let didPurchaseCredits = Notification.Name("didPurchaseCredits")
}

