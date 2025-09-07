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
                    HStack {
                        Text("Credits")
                        Spacer()
                        Text("\(purchases.creditBalance)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("Buy Credits…") {
                        BuyCreditsView(presentation: .push)
                            .environmentObject(purchases)
                    }

                    Button("Reload Products") {
                        Task { await purchases.refresh() }
                    }

                    Text("Credits are stored on this device only. Deleting the app removes unused credits.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
    }
}

