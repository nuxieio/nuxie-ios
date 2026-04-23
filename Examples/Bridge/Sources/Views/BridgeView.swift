//
//  BridgeView.swift
//  Bridge
//
//  Main view with action buttons and log display.
//

import SwiftUI
import Nuxie

struct BridgeView: View {
    @EnvironmentObject var actionHandler: ActionHandler

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Action buttons section
                    VStack(spacing: 12) {
                        Text("Trigger Actions")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ActionButton(
                                title: "Haptic Light",
                                icon: "hand.tap",
                                color: .blue
                            ) {
                                actionHandler.simulateAction("haptic_feedback", payload: ["style": "light"])
                            }

                            ActionButton(
                                title: "Haptic Heavy",
                                icon: "hand.tap.fill",
                                color: .purple
                            ) {
                                actionHandler.simulateAction("haptic_feedback", payload: ["style": "heavy"])
                            }

                            ActionButton(
                                title: "Show Alert",
                                icon: "exclamationmark.bubble",
                                color: .orange
                            ) {
                                actionHandler.simulateAction("show_alert", payload: [
                                    "title": "Hello!",
                                    "body": "This alert was triggered from a Nuxie flow."
                                ])
                            }

                            ActionButton(
                                title: "Open URL",
                                icon: "safari",
                                color: .cyan
                            ) {
                                actionHandler.simulateAction("open_url", payload: [
                                    "url": "https://nuxie.io"
                                ])
                            }

                            ActionButton(
                                title: "Share Text",
                                icon: "square.and.arrow.up",
                                color: .green
                            ) {
                                actionHandler.simulateAction("share", payload: [
                                    "text": "Check out Nuxie for mobile paywalls!"
                                ])
                            }

                            ActionButton(
                                title: "Copy Text",
                                icon: "doc.on.doc",
                                color: .indigo
                            ) {
                                actionHandler.simulateAction("copy_to_clipboard", payload: [
                                    "text": "Copied from Bridge demo!"
                                ])
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Log section
                    VStack(spacing: 12) {
                        HStack {
                            Text("Action Log")
                                .font(.headline)

                            Spacer()

                            if !actionHandler.logEntries.isEmpty {
                                Button("Clear") {
                                    withAnimation {
                                        actionHandler.clearLog()
                                    }
                                }
                                .font(.subheadline)
                            }
                        }

                        if actionHandler.logEntries.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "text.alignleft")
                                    .font(.title)
                                    .foregroundStyle(.secondary)

                                Text("No actions logged yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(actionHandler.logEntries) { entry in
                                    LogEntryView(entry: entry)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Bridge")
            .alert(actionHandler.alertTitle, isPresented: $actionHandler.showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                if !actionHandler.alertMessage.isEmpty {
                    Text(actionHandler.alertMessage)
                }
            }
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)

                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    BridgeView()
        .environmentObject(ActionHandler())
}
