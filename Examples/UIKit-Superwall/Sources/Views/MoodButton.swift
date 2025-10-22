//
//  MoodButton.swift
//  MoodLog
//
//  Custom button for mood selection with emoji and smooth animations.
//

import UIKit

/// A custom button that displays a mood emoji with selection state
final class MoodButton: UIButton {

    // MARK: - Properties

    /// The mood value this button represents (1-5)
    let moodValue: Int

    /// Whether this button is currently selected
    override var isSelected: Bool {
        didSet {
            updateAppearance(animated: true)
        }
    }

    /// Whether the button is highlighted (touch down)
    override var isHighlighted: Bool {
        didSet {
            if isHighlighted {
                // Provide haptic feedback on touch down
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.impactOccurred()

                // Slight scale down
                UIView.animate(withDuration: 0.1) {
                    self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
                }
            } else {
                // Scale back up
                UIView.animate(withDuration: 0.1) {
                    self.transform = .identity
                }
            }
        }
    }

    // MARK: - UI Components

    private let emojiLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 40)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = Constants.cornerRadius
        view.layer.borderWidth = 2
        view.isUserInteractionEnabled = false
        return view
    }()

    // MARK: - Initialization

    /// Creates a mood button
    /// - Parameter moodValue: The mood value (1-5)
    init(moodValue: Int) {
        self.moodValue = moodValue
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        // Configure button
        translatesAutoresizingMaskIntoConstraints = false

        // Add container view
        addSubview(containerView)
        containerView.pinToSuperview()

        // Add emoji label
        containerView.addSubview(emojiLabel)
        emojiLabel.centerInSuperview()

        // Set size
        setSize(width: Constants.moodButtonSize, height: Constants.moodButtonSize)

        // Set emoji
        emojiLabel.text = Constants.moodEmojis[moodValue]

        // Set accessibility
        accessibilityLabel = Constants.moodLabels[moodValue]
        accessibilityTraits = .button

        // Initial appearance
        updateAppearance(animated: false)

        // Add shadow
        containerView.addShadow(radius: 4, offset: CGSize(width: 0, height: 2))
    }

    // MARK: - Appearance

    private func updateAppearance(animated: Bool) {
        let changes = {
            if self.isSelected {
                // Selected state: colored background, white emoji
                self.containerView.backgroundColor = UIColor.color(for: self.moodValue)
                self.containerView.layer.borderColor = UIColor.color(for: self.moodValue).cgColor
                self.emojiLabel.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)

                // Add subtle glow effect
                self.containerView.layer.shadowOpacity = 0.3
                self.containerView.layer.shadowColor = UIColor.color(for: self.moodValue).cgColor
            } else {
                // Unselected state: transparent background, colored border
                self.containerView.backgroundColor = UIColor.moodCardBackground
                self.containerView.layer.borderColor = UIColor.moodSeparator.cgColor
                self.emojiLabel.transform = .identity

                // Remove glow
                self.containerView.layer.shadowOpacity = 0.1
                self.containerView.layer.shadowColor = UIColor.black.cgColor
            }
        }

        if animated {
            UIView.animate(
                withDuration: Constants.animationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.springDamping,
                initialSpringVelocity: Constants.springVelocity,
                options: .curveEaseInOut,
                animations: changes
            )
        } else {
            changes()
        }
    }

    /// Animates a "selected" bounce effect
    func animateSelection() {
        bounce(scale: 1.15)
    }
}
