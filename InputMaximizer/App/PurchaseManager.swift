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
            print("ℹ️ PurchaseManager.refresh(): requesting products: \(Array(IAP.creditPacks))")
            let products = try await Product.products(for: Array(IAP.creditPacks))
            products.forEach { p in
                print("✅ Loaded product: id=\(p.id) name=\(p.displayName) price=\(p.displayPrice)")
            }
            creditProducts = products.sorted { credits(for: $0) < credits(for: $1) }
            print("ℹ️ PurchaseManager.refresh(): sorted products = \(creditProducts.map { $0.id })")
        } catch {
            lastError = error.localizedDescription
            print("❌ PurchaseManager.refresh() error: \(error.localizedDescription)")
        }
    }

    func credits(for product: Product) -> Int {
        creditAmounts[product.id] ?? 0
    }

    // MARK: - Purchase
    func buyCredits(_ product: Product) async {
        do {
            print("🛒 buyCredits(): purchasing \(product.id)")
            let result = try await product.purchase()
            print("🧾 buyCredits(): purchase result = \(result)")
            try await handlePurchaseResult(result, purchasedID: product.id)
        } catch {
            lastError = error.localizedDescription
            print("❌ buyCredits() error: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals
    private func handlePurchaseResult(
        _ result: Product.PurchaseResult,
        purchasedID: String
    ) async throws {
        print("➡️ handlePurchaseResult(): entered for product \(purchasedID) with result=\(result)")

        switch result {
        case .success(let verification):
            print("✅ Purchase success. Attempting verification…")
            let tx: StoreKit.Transaction = try checkVerified(verification)
            print("🔏 Verified tx: id=\(tx.id) productID=\(tx.productID) env=\(tx.environment) purchaseDate=\(tx.purchaseDate)")

            do {
                var redeemed = false
                if #available(iOS 18.0, *) {
                    do {
                        let jws = verification.jwsRepresentation
                        print("🔁 Redeem path: JWS (iOS 18+). JWS length=\(jws.count)")
                        let res = try await GeneratorService.proxy.redeemSignedTransactions(
                            deviceId: DeviceID.current,
                            signedTransactions: [jws]
                        )
                        print("✅ JWS redeem OK: granted=\(res.granted) balance=\(res.balance)")
                        redeemed = true
                    } catch {
                        print("⚠️ JWS redeem failed: \(error.localizedDescription). Falling back to legacy receipt…")
                    }
                }

                if !redeemed {
                    let receiptB64 = try await appReceiptBase64_legacy(refreshIfNeeded: true)
                    print("🔁 Redeem path: legacy receipt. receiptB64.len=\(receiptB64.count)")
                    let res = try await GeneratorService.proxy.redeemReceipt(
                        deviceId: DeviceID.current,
                        receiptBase64: receiptB64
                    )
                    print("✅ Legacy redeem OK: granted=\(res.granted) balance=\(res.balance)")
                }

                await tx.finish()
                print("🧹 Finished transaction id=\(tx.id)")
                NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
                print("🔔 Posted .didPurchaseCredits")

            } catch {
                lastError = "Redeem failed: \(error.localizedDescription)"
                print("❌ handlePurchaseResult(): redeem failed. Leaving tx unfinished so system re-delivers. error=\(error.localizedDescription)")
                return
            }

        case .userCancelled:
            print("🟡 handlePurchaseResult(): user cancelled")
        case .pending:
            print("🟠 handlePurchaseResult(): pending")
        @unknown default:
            print("❓ handlePurchaseResult(): unknown result")
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
            print("👂 observeTransactionUpdates(): started")
            for await update in StoreKit.Transaction.updates {
                do {
                    let tx: StoreKit.Transaction = try await self.checkVerified(update)
                    print("🔁 Re-delivered tx: id=\(tx.id) productID=\(tx.productID) env=\(tx.environment)")
                    guard IAP.creditPacks.contains(tx.productID) else {
                        print("↩️ Not a credit product. Finishing.")
                        await tx.finish()
                        continue
                    }

                    do {
                        if #available(iOS 18.0, *) {
                            do {
                                let jws = update.jwsRepresentation
                                print("🔁 Auto-redeem JWS path. JWS len=\(jws.count)")
                                do {
                                    let res = try await GeneratorService.proxy.redeemSignedTransactions(
                                        deviceId: DeviceID.current,
                                        signedTransactions: [jws]
                                    )
                                    print("✅ Auto-redeem JWS OK: granted=\(res.granted) balance=\(res.balance)")
                                } catch {
                                    print("⚠️ Auto-redeem JWS failed: \(error.localizedDescription). Trying legacy receipt…")
                                    let receiptB64 = try await self.appReceiptBase64_legacy(refreshIfNeeded: true)
                                    let res = try await GeneratorService.proxy.redeemReceipt(
                                        deviceId: DeviceID.current,
                                        receiptBase64: receiptB64
                                    )
                                    print("✅ Auto-redeem legacy OK: granted=\(res.granted) balance=\(res.balance)")
                                }
                                await tx.finish()
                                print("🧹 Finished re-delivered tx \(tx.id)")
                                await MainActor.run {
                                    NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
                                }
                            } catch {
                                await MainActor.run { self.lastError = "Auto-redeem failed: \(error.localizedDescription)" }
                                print("❌ Auto-redeem outer catch: \(error.localizedDescription)")
                            }
                        } else {
                            let receiptB64 = try await self.appReceiptBase64_legacy(refreshIfNeeded: true)
                            let res = try await GeneratorService.proxy.redeemReceipt(
                                deviceId: DeviceID.current,
                                receiptBase64: receiptB64
                            )
                            print("✅ Auto-redeem (<iOS18) OK: granted=\(res.granted) balance=\(res.balance)")
                            await tx.finish()
                            await MainActor.run {
                                NotificationCenter.default.post(name: .didPurchaseCredits, object: nil)
                            }
                        }
                    } catch {
                        await MainActor.run { self.lastError = "Auto-redeem failed: \(error.localizedDescription)" }
                        print("❌ observeTransactionUpdates(): inner error \(error.localizedDescription)")
                    }
                } catch {
                    await MainActor.run { self.lastError = "Verification failed: \(error.localizedDescription)" }
                    print("❌ observeTransactionUpdates(): verification failed \(error.localizedDescription)")
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
            let url = Bundle.main.value(forKey: "appStoreReceiptURL") as? URL
            let data = (url.flatMap { try? Data(contentsOf: $0) }) ?? Data()
            print("🧾 appReceiptBase64_legacy(): receipt at \(String(describing: url)) size=\(data.count) bytes")
            return data.isEmpty ? nil : data
        }

        if let data = loadReceiptDataIfPresent() {
            print("🧾 Using existing receipt")
            return data.base64EncodedString()
        }

        guard refreshIfNeeded else {
            print("🧾 No receipt and refreshIfNeeded=false")
            throw NSError(domain: "Receipt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing receipt"])
        }

        print("🔄 Requesting AppStore.sync() for receipt…")
        do { try await AppStore.sync() } catch {
            print("⚠️ AppStore.sync() error: \(error.localizedDescription)")
        }

        if let data = loadReceiptDataIfPresent() {
            print("🧾 Got receipt after sync")
            return data.base64EncodedString()
        }

        print("❌ Still no receipt after sync")
        throw NSError(domain: "Receipt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Receipt refresh did not produce a receipt"])
    }

}

// MARK: - Notification
extension Notification.Name {
    static let didPurchaseCredits = Notification.Name("didPurchaseCredits")
}

