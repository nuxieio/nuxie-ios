//
//  ActionHandler.swift
//  Bridge
//
//  Handles delegate calls from Nuxie flows and executes native actions.
//

import Foundation
import UIKit
import Nuxie

@MainActor
class ActionHandler: ObservableObject {
    @Published var logEntries: [LogEntry] = []
    @Published var showingAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""

    private var observer: NSObjectProtocol?

    init() {
        setupDelegateObserver()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func clearLog() {
        logEntries.removeAll()
    }

    // MARK: - Demo Actions

    /// Simulates receiving delegate calls for demo purposes
    func simulateAction(_ action: String, payload: [String: Any]? = nil) {
        handleCallDelegate(message: action, payload: payload)
    }

    // MARK: - Delegate Observer

    private func setupDelegateObserver() {
        // In a real app, listen for Nuxie delegate notifications
        // observer = NotificationCenter.default.addObserver(
        //     forName: .nuxieCallDelegate,
        //     object: nil,
        //     queue: .main
        // ) { [weak self] notification in
        //     self?.handleNotification(notification)
        // }
    }

    private func handleNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else { return }

        let payload = userInfo["payload"] as? [String: Any]
        handleCallDelegate(message: message, payload: payload)
    }

    private func handleCallDelegate(message: String, payload: [String: Any]?) {
        // Log the action
        let entry = LogEntry(
            timestamp: Date(),
            message: message,
            payload: payload
        )
        logEntries.insert(entry, at: 0)

        // Execute the native action
        switch message {
        case "haptic_feedback":
            executeHaptic(payload: payload)

        case "show_alert":
            executeAlert(payload: payload)

        case "open_url":
            executeOpenURL(payload: payload)

        case "share":
            executeShare(payload: payload)

        case "copy_to_clipboard":
            executeCopy(payload: payload)

        default:
            print("[Bridge] Unknown action: \(message)")
        }
    }

    // MARK: - Native Actions

    private func executeHaptic(payload: [String: Any]?) {
        let style = payload?["style"] as? String ?? "medium"

        let generator: UIImpactFeedbackGenerator
        switch style {
        case "light":
            generator = UIImpactFeedbackGenerator(style: .light)
        case "heavy":
            generator = UIImpactFeedbackGenerator(style: .heavy)
        case "rigid":
            generator = UIImpactFeedbackGenerator(style: .rigid)
        case "soft":
            generator = UIImpactFeedbackGenerator(style: .soft)
        default:
            generator = UIImpactFeedbackGenerator(style: .medium)
        }

        generator.impactOccurred()
    }

    private func executeAlert(payload: [String: Any]?) {
        alertTitle = payload?["title"] as? String ?? "Alert"
        alertMessage = payload?["body"] as? String ?? ""
        showingAlert = true
    }

    private func executeOpenURL(payload: [String: Any]?) {
        guard let urlString = payload?["url"] as? String,
              let url = URL(string: urlString) else { return }

        UIApplication.shared.open(url)
    }

    private func executeShare(payload: [String: Any]?) {
        guard let text = payload?["text"] as? String else { return }

        let activityVC = UIActivityViewController(
            activityItems: [text],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func executeCopy(payload: [String: Any]?) {
        guard let text = payload?["text"] as? String else { return }
        UIPasteboard.general.string = text
    }
}
