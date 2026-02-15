//
//  LockedFeatureView.swift
//  Lockbox
//
//  Shown when user tries to access a Pro feature without subscription.
//

import SwiftUI
import Nuxie

struct LockedFeatureView: View {
    @EnvironmentObject var noteStore: NoteStore

    let feature: String
    let description: String
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Unlock \(feature.capitalized)")
                        .font(.title2.bold())

                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: unlockFeature) {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .tint(.white)
                        }
                        Text("Upgrade to Pro")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isProcessing)

                Spacer()

                // Feature comparison
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pro includes:")
                        .font(.headline)

                    FeatureRow(icon: "folder.fill", text: "Unlimited folders")
                    FeatureRow(icon: "tag.fill", text: "Tag organization")
                    FeatureRow(icon: "square.and.arrow.up", text: "Export notes")
                    FeatureRow(icon: "cloud.fill", text: "Cloud sync")
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer()
            }
            .padding()
            .navigationTitle(feature.capitalized)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func unlockFeature() {
        isProcessing = true

        // Trigger the paywall flow
        NuxieSDK.shared.trigger("\(feature)_tapped", properties: [
            "source": "locked_tab"
        ]) { result in
            // For demo, simulate successful upgrade
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                noteStore.unlockPro()
                isProcessing = false
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    LockedFeatureView(feature: "folders", description: "Organize your notes into folders")
        .environmentObject(NoteStore())
}
