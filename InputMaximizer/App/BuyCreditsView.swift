//  BuyCreditsView.swift
//  InputMaximizer

import SwiftUI
import StoreKit

struct BuyCreditsView: View {
    enum Presentation { case modal, push }
    let presentation: Presentation

    @EnvironmentObject var purchases: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverBalance: Int = 0
    @State private var serverError: String?

    private func refreshServerBalance() async {
        do {
            serverBalance = try await GeneratorService.fetchServerBalance()
            serverError = nil
        } catch {
            serverError = error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Need more credits?").font(.title2).bold()
            Text("Credits are used each time you generate a lesson.")
                .foregroundStyle(.secondary)

            HStack {
                Text("Credits:")
                Spacer()
                Text("\(serverBalance)")
                    .font(.headline)
            }
            .padding(.top, 4)

            if let serverError {
                Text(serverError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if purchases.isLoading {
                ProgressView("Loading…")
                    .padding(.top, 12)
            } else if purchases.creditProducts.isEmpty {
                VStack(spacing: 8) {
                    Text("No credit packs available.")
                        .foregroundStyle(.secondary)
                    if let err = purchases.lastError {
                        Text(err).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(purchases.creditProducts, id: \.id) { product in
                        Button {
                            Task { await purchases.buyCredits(product) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName).bold()
                                    // Uses mapping in PurchaseManager
                                    Text("\(purchases.credits(for: product)) credits")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice).font(.headline)
                            }
                            .padding()
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Buy Credits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if purchases.creditProducts.isEmpty {
                await purchases.refresh()
            }
            await refreshServerBalance()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .didPurchaseCredits)
                .receive(on: RunLoop.main) // ✅ deliver on main
        ) { _ in
            Task {
                // refreshServerBalance() is @MainActor in our earlier patch
                await refreshServerBalance()
                // Dismiss must also be on the main actor
                await MainActor.run {
                    if presentation == .modal { dismiss() }
                }
            }
        }

    }
}

