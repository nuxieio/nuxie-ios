//
//  ViewModifiers.swift
//  MoodLog
//
//  Custom ViewModifiers for consistent styling and animations.
//

import SwiftUI

// MARK: - Card Style

/// Applies a card-like appearance with shadow and corner radius
struct CardStyle: ViewModifier {
    var backgroundColor: Color = .moodCardBackground
    var cornerRadius: CGFloat = Constants.cornerRadius
    var shadowRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .cornerRadius(cornerRadius)
            .shadow(color: Color.black.opacity(0.1), radius: shadowRadius, x: 0, y: 4)
    }
}

extension View {
    /// Applies card styling to a view
    func cardStyle(
        backgroundColor: Color = .moodCardBackground,
        cornerRadius: CGFloat = Constants.cornerRadius,
        shadowRadius: CGFloat = 8
    ) -> some View {
        modifier(CardStyle(
            backgroundColor: backgroundColor,
            cornerRadius: cornerRadius,
            shadowRadius: shadowRadius
        ))
    }
}

// MARK: - Scale Button Style

/// A button style that scales down when pressed
struct ScaleButtonStyle: ButtonStyle {
    var scaleAmount: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Bounce Animation

/// Applies a bouncy entrance animation
struct BounceAnimation: ViewModifier {
    var delay: Double = 0

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(appeared ? 1.0 : 0.8)
            .opacity(appeared ? 1.0 : 0)
            .onAppear {
                withAnimation(
                    .spring(
                        response: Constants.springDamping,
                        dampingFraction: Constants.springDamping
                    ).delay(delay)
                ) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Applies bounce entrance animation
    func bounceAnimation(delay: Double = 0) -> some View {
        modifier(BounceAnimation(delay: delay))
    }
}

// MARK: - Shake Animation

/// Applies a shake animation (useful for errors)
struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(
                translationX: amount * sin(animatableData * .pi * CGFloat(shakesPerUnit)),
                y: 0
            )
        )
    }
}

extension View {
    /// Shakes the view when the shake number changes
    func shake(with shakeNumber: Int) -> some View {
        modifier(Shake(animatableData: CGFloat(shakeNumber)))
    }
}

// MARK: - Shimmer Effect

/// Applies a shimmer/loading effect
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        Color.white.opacity(0.3),
                        .clear
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
                .mask(content)
            )
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 1.5)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}

extension View {
    /// Applies shimmer loading effect
    func shimmer() -> some View {
        modifier(Shimmer())
    }
}

// MARK: - Pro Badge

/// Adds a "PRO" badge overlay
struct ProBadge: ViewModifier {
    var alignment: Alignment = .topTrailing
    var size: CGFloat = 40

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.moodProGradientStart, .moodProGradientEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: size, height: size)

                    Text("PRO")
                        .font(.system(size: size * 0.3, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2),
                alignment: alignment
            )
    }
}

extension View {
    /// Adds a PRO badge to the view
    func proBadge(alignment: Alignment = .topTrailing, size: CGFloat = 40) -> some View {
        modifier(ProBadge(alignment: alignment, size: size))
    }
}
