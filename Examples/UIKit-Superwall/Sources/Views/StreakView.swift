//
//  StreakView.swift
//  MoodLog
//
//  Displays the user's current mood logging streak with animation.
//

import UIKit

/// View that displays the current streak with an animated flame emoji
final class StreakView: UIView {

    // MARK: - Properties

    private var currentStreak: Int = 0

    // MARK: - UI Components

    private let flameLabel: UILabel = {
        let label = UILabel()
        label.text = "🔥"
        label.font = .systemFont(ofSize: 24)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let streakLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .moodTextPrimary
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let descriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "day streak"
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .moodTextSecondary
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let containerStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let textStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        // Add background
        backgroundColor = .moodCardBackground
        layer.cornerRadius = Constants.cornerRadius
        addShadow(opacity: 0.08, radius: 6)

        // Build stack
        textStack.addArrangedSubviews([streakLabel, descriptionLabel])
        containerStack.addArrangedSubviews([flameLabel, textStack])

        addSubview(containerStack)

        // Layout
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        // Initial state
        updateStreak(0, animated: false)

        // Add tap gesture for tooltip (optional)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tapGesture)
        isUserInteractionEnabled = true
    }

    // MARK: - Public Methods

    /// Updates the displayed streak
    /// - Parameters:
    ///   - streak: The new streak value
    ///   - animated: Whether to animate the change
    func updateStreak(_ streak: Int, animated: Bool) {
        let oldStreak = currentStreak
        currentStreak = streak

        // Update text
        streakLabel.text = "\(streak)"
        descriptionLabel.text = streak == 1 ? "day streak" : "day streak"

        // Accessibility
        accessibilityLabel = "\(streak) day streak"
        accessibilityHint = "Tap for more information about streaks"

        // Animate if streak increased
        if animated && streak > oldStreak && streak > 0 {
            animateStreakIncrease()
        }

        // Show/hide flame based on streak
        updateFlameVisibility(animated: animated)
    }

    // MARK: - Private Methods

    private func updateFlameVisibility(animated: Bool) {
        let shouldShowFlame = currentStreak > 0

        if animated {
            UIView.animate(withDuration: 0.3) {
                self.flameLabel.alpha = shouldShowFlame ? 1.0 : 0.3
                self.flameLabel.transform = shouldShowFlame ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            }
        } else {
            flameLabel.alpha = shouldShowFlame ? 1.0 : 0.3
            flameLabel.transform = shouldShowFlame ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
        }
    }

    private func animateStreakIncrease() {
        // Provide haptic feedback
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)

        // Bounce animation for the whole view
        bounce(scale: 1.08)

        // Pulse the flame
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                self.flameLabel.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            },
            completion: { _ in
                UIView.animate(withDuration: 0.2) {
                    self.flameLabel.transform = .identity
                }
            }
        )

        // Number count-up animation would go here
        // For simplicity, we're just updating the text directly
    }

    @objc private func handleTap() {
        // Show a tooltip explaining streaks
        showStreakExplanation()
    }

    private func showStreakExplanation() {
        // Create a simple alert explaining streaks
        guard let viewController = findViewController() else { return }

        let message: String
        if currentStreak == 0 {
            message = "Log your mood today to start a streak! Streaks track consecutive days you've logged your mood."
        } else if currentStreak == 1 {
            message = "Great start! Keep logging daily to build your streak. Streaks help you stay consistent with mood tracking."
        } else {
            message = "Amazing! You've logged your mood for \(currentStreak) consecutive days. Keep it up!"
        }

        let alert = UIAlertController(
            title: "🔥 Streak",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Got it!", style: .default))

        viewController.present(alert, animated: true)
    }

    // Helper to find the view controller
    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while responder != nil {
            if let viewController = responder as? UIViewController {
                return viewController
            }
            responder = responder?.next
        }
        return nil
    }
}
