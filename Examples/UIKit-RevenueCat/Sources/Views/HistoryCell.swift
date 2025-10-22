//
//  HistoryCell.swift
//  MoodLog
//
//  Table view cell displaying a mood entry in the history list.
//

import UIKit

/// Table view cell for displaying mood history entries
final class HistoryCell: UITableViewCell {

    // MARK: - Properties

    static let reuseIdentifier = "HistoryCell"

    // MARK: - UI Components

    private let emojiLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .moodTextPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let noteLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .moodTextSecondary
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .moodCardBackground
        view.layer.cornerRadius = Constants.cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let colorIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 2
        return view
    }()

    // MARK: - Initialization

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        selectionStyle = .none

        // Add container
        contentView.addSubview(containerView)

        // Add components to container
        containerView.addSubview(colorIndicator)
        containerView.addSubview(emojiLabel)
        containerView.addSubview(dateLabel)
        containerView.addSubview(noteLabel)

        // Layout
        NSLayoutConstraint.activate([
            // Container
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Constants.standardPadding),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Constants.standardPadding),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            // Color indicator
            colorIndicator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            colorIndicator.topAnchor.constraint(equalTo: containerView.topAnchor),
            colorIndicator.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            colorIndicator.widthAnchor.constraint(equalToConstant: 4),

            // Emoji
            emojiLabel.leadingAnchor.constraint(equalTo: colorIndicator.trailingAnchor, constant: 12),
            emojiLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            emojiLabel.widthAnchor.constraint(equalToConstant: 40),

            // Date label
            dateLabel.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 12),
            dateLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),

            // Note label
            noteLabel.leadingAnchor.constraint(equalTo: dateLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            noteLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 4),
            noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -12)
        ])

        // Add subtle shadow
        containerView.addShadow(opacity: 0.05, radius: 4, offset: CGSize(width: 0, height: 1))
    }

    // MARK: - Configuration

    /// Configures the cell with a mood entry
    /// - Parameter entry: The mood entry to display
    func configure(with entry: MoodEntry) {
        emojiLabel.text = entry.emoji
        dateLabel.text = entry.shortDisplayDate
        colorIndicator.backgroundColor = entry.color

        if let note = entry.note, !note.isEmpty {
            noteLabel.text = note
            noteLabel.isHidden = false
        } else {
            noteLabel.text = nil
            noteLabel.isHidden = true
        }

        // Accessibility
        accessibilityLabel = "\(entry.displayDate), \(entry.moodLabel)"
        if entry.hasNote {
            accessibilityLabel? += ", Note: \(entry.note ?? "")"
        }
    }

    /// Animates the cell entrance
    func animateIn(delay: TimeInterval = 0) {
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 20)

        UIView.animate(
            withDuration: 0.4,
            delay: delay,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: .curveEaseOut,
            animations: {
                self.alpha = 1
                self.transform = .identity
            }
        )
    }
}
