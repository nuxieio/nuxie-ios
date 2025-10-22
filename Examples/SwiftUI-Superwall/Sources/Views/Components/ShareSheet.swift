//
//  ShareSheet.swift
//  MoodLog
//
//  UIActivityViewController wrapper for SwiftUI.
//  Provides CSV export sharing functionality for iOS 15 compatibility.
//

import SwiftUI
import UIKit

/// A SwiftUI wrapper for UIActivityViewController
/// Used for sharing CSV exports (iOS 15 compatible alternative to ShareLink)
struct ShareSheet: UIViewControllerRepresentable {

    // MARK: - Properties

    let items: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed
    }
}

// MARK: - Preview

struct ShareSheet_Previews: PreviewProvider {
    static var previews: some View {
        Text("Share Sheet Preview")
            .sheet(isPresented: .constant(false)) {
                ShareSheet(items: ["Sample text to share"])
            }
    }
}
