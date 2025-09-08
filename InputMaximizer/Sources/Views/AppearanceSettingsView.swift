//
//  AppearanceSettingsView.swift
//  InputMaximizer
//
//  Created by Robin Geske on 01.09.25.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var purchases: PurchaseManager
    @AppStorage("appearancePreference") private var appearanceRaw: String = AppearancePreference.system.rawValue
    
    @State private var showBuyCredits = false
    
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
        NavigationStack {
            Form {
                Picker("App Appearance", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.title).tag(pref.rawValue)
                    }
                }
                .pickerStyle(.inline)
                
                Section("Billing & Credits") {
                    // (A) Local (IAP) credits if you still keep them
                    HStack {
                        Text("Device Credits")
                        Spacer()
                        Text("\(purchases.creditBalance)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    // (B) Server credits (source of truth for proxy)
                    HStack {
                        Text("Server Credits")
                        Spacer()
                        Text("\(serverBalance)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if let serverError {
                        Text("Server balance error: \(serverError)")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    NavigationLink("Buy Credits…") {
                        BuyCreditsView(presentation: .push)
                            .environmentObject(purchases)
                    }

                    Button("Reload Products") {
                        Task { await purchases.refresh() }
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Appearance")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await refreshServerBalance() }
        .onReceive(NotificationCenter.default.publisher(for: .didPurchaseCredits)) { _ in
            Task { await refreshServerBalance() }
        }
    }
}

