//
//  PersonaResultCard.swift
//  Persona
//
//  Card displaying a quiz result.
//

import SwiftUI

struct PersonaResultCard: View {
    let result: PersonaResult
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(result.personaType.emoji)
                    .font(.system(size: 44))

                VStack(alignment: .leading, spacing: 4) {
                    if isLatest {
                        Text("Your Persona")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(result.personaType.rawValue)
                        .font(.title2.bold())

                    Text("Hi, \(result.userName)!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLatest {
                    ShareLink(
                        item: "I'm \(result.personaType.rawValue)! Take the Persona quiz to find yours.",
                        subject: Text("My Persona Result"),
                        message: Text("I just discovered my persona type!")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Description
            if isLatest {
                Text(result.personaType.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Traits
            VStack(alignment: .leading, spacing: 8) {
                Text("Key Traits")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 8) {
                    ForEach(result.personaType.traits, id: \.self) { trait in
                        Text(trait)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(result.personaType.color.opacity(0.15))
                            .foregroundStyle(result.personaType.color)
                            .clipShape(Capsule())
                    }
                }
            }

            // Date
            Text(result.formattedDate)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isLatest {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(result.personaType.color.opacity(0.3), lineWidth: 2)
            }
        }
    }
}

/// Simple flow layout for traits
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )

        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            ), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
                self.size.width = max(self.size.width, currentX - spacing)
            }

            self.size.height = currentY + lineHeight
        }
    }
}

#Preview {
    VStack {
        PersonaResultCard(
            result: PersonaResult(
                personaType: .visionary,
                userName: "Sarah"
            ),
            isLatest: true
        )

        PersonaResultCard(
            result: PersonaResult(
                personaType: .creator,
                userName: "Sarah"
            ),
            isLatest: false
        )
    }
    .padding()
}
