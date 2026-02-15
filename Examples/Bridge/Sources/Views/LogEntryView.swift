//
//  LogEntryView.swift
//  Bridge
//
//  View for displaying a single log entry.
//

import SwiftUI

struct LogEntryView: View {
    let entry: LogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.formattedTime)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text(entry.message)
                    .font(.subheadline.monospaced())
                    .fontWeight(.medium)

                Spacer()

                if entry.payload != nil {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isExpanded, let payloadDesc = entry.payloadDescription {
                Text(payloadDesc)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.payload != nil {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}

#Preview {
    VStack {
        LogEntryView(entry: LogEntry(
            timestamp: Date(),
            message: "haptic_feedback",
            payload: ["style": "heavy"]
        ))

        LogEntryView(entry: LogEntry(
            timestamp: Date(),
            message: "show_alert",
            payload: ["title": "Hello!", "body": "This is a test"]
        ))

        LogEntryView(entry: LogEntry(
            timestamp: Date(),
            message: "copy_to_clipboard",
            payload: nil
        ))
    }
    .padding()
}
