//
//  SettingsView.swift
//  Lockbox
//
//  App settings including Pro status and restore purchases.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var noteStore: NoteStore
    @State private var showingRestoreAlert = false

    var body: some View {
        NavigationStack {
            List {
                // Subscription section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Plan")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text(noteStore.hasPro ? "Pro" : "Free")
                                .font(.headline)
                        }

                        Spacer()

                        if noteStore.hasPro {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title2)
                        }
                    }
                    .padding(.vertical, 4)

                    if !noteStore.hasPro {
                        Button("Upgrade to Pro") {
                            // Would trigger paywall
                            noteStore.unlockPro()
                        }
                    }

                    Button("Restore Purchases") {
                        restorePurchases()
                    }
                } header: {
                    Text("Subscription")
                }

                // Features section
                Section {
                    FeatureComparisonRow(
                        feature: "Notes",
                        free: "Unlimited",
                        pro: "Unlimited"
                    )
                    FeatureComparisonRow(
                        feature: "Folders",
                        free: "—",
                        pro: "Unlimited"
                    )
                    FeatureComparisonRow(
                        feature: "Tags",
                        free: "—",
                        pro: "Unlimited"
                    )
                    FeatureComparisonRow(
                        feature: "Export",
                        free: "—",
                        pro: "All formats"
                    )
                } header: {
                    Text("Features")
                }

                // About section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert("Purchases Restored", isPresented: $showingRestoreAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(noteStore.hasPro
                    ? "Your Pro subscription has been restored."
                    : "No previous purchases found.")
            }
        }
    }

    private func restorePurchases() {
        noteStore.restorePurchases()
        showingRestoreAlert = true
    }
}

struct FeatureComparisonRow: View {
    let feature: String
    let free: String
    let pro: String

    var body: some View {
        HStack {
            Text(feature)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(free)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pro)
                    .font(.caption)
                    .foregroundStyle(.accentColor)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(NoteStore())
}
