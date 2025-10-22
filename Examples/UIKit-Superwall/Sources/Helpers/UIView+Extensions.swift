//
//  UIView+Extensions.swift
//  MoodLog
//
//  Convenience extensions for UIView including auto layout helpers and animations.
//

import UIKit

extension UIView {

    // MARK: - Auto Layout Helpers

    /// Pins all edges to superview with optional insets
    /// - Parameter insets: Edge insets (default: zero)
    func pinToSuperview(insets: UIEdgeInsets = .zero) {
        guard let superview = superview else { return }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: superview.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor, constant: -insets.right),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -insets.bottom)
        ])
    }

    /// Centers view in superview
    func centerInSuperview() {
        guard let superview = superview else { return }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: superview.centerXAnchor),
            centerYAnchor.constraint(equalTo: superview.centerYAnchor)
        ])
    }

    /// Sets width and height constraints
    /// - Parameters:
    ///   - width: Width constraint
    ///   - height: Height constraint
    func setSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        translatesAutoresizingMaskIntoConstraints = false
        if let width = width {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height = height {
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
    }

    // MARK: - Corner Radius

    /// Applies corner radius with optional masking
    /// - Parameters:
    ///   - radius: Corner radius
    ///   - corners: Specific corners to round (default: all)
    func roundCorners(radius: CGFloat, corners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]) {
        layer.cornerRadius = radius
        layer.maskedCorners = corners
        layer.masksToBounds = true
    }

    // MARK: - Shadow

    /// Adds a subtle shadow
    /// - Parameters:
    ///   - color: Shadow color (default: black)
    ///   - opacity: Shadow opacity (default: 0.1)
    ///   - radius: Shadow blur radius (default: 8)
    ///   - offset: Shadow offset (default: 0, 2)
    func addShadow(
        color: UIColor = .black,
        opacity: Float = 0.1,
        radius: CGFloat = 8,
        offset: CGSize = CGSize(width: 0, height: 2)
    ) {
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = offset
        layer.masksToBounds = false
    }

    // MARK: - Animations

    /// Animates a bounce effect (scale up then back to normal)
    /// - Parameters:
    ///   - scale: Peak scale (default: 1.1)
    ///   - completion: Optional completion handler
    func bounce(scale: CGFloat = 1.1, completion: (() -> Void)? = nil) {
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: .curveEaseOut,
            animations: {
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            },
            completion: { _ in
                UIView.animate(
                    withDuration: 0.15,
                    delay: 0,
                    options: .curveEaseIn,
                    animations: {
                        self.transform = .identity
                    },
                    completion: { _ in
                        completion?()
                    }
                )
            }
        )
    }

    /// Fades in the view
    /// - Parameters:
    ///   - duration: Animation duration (default: 0.3)
    ///   - completion: Optional completion handler
    func fadeIn(duration: TimeInterval = 0.3, completion: (() -> Void)? = nil) {
        alpha = 0
        UIView.animate(withDuration: duration, animations: {
            self.alpha = 1
        }, completion: { _ in
            completion?()
        })
    }

    /// Fades out the view
    /// - Parameters:
    ///   - duration: Animation duration (default: 0.3)
    ///   - completion: Optional completion handler
    func fadeOut(duration: TimeInterval = 0.3, completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: duration, animations: {
            self.alpha = 0
        }, completion: { _ in
            completion?()
        })
    }

    /// Slides in from bottom
    /// - Parameters:
    ///   - duration: Animation duration (default: 0.4)
    ///   - completion: Optional completion handler
    func slideInFromBottom(duration: TimeInterval = 0.4, completion: (() -> Void)? = nil) {
        transform = CGAffineTransform(translationX: 0, y: bounds.height)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: Constants.springDamping,
            initialSpringVelocity: Constants.springVelocity,
            options: .curveEaseOut,
            animations: {
                self.transform = .identity
            },
            completion: { _ in
                completion?()
            }
        )
    }

    /// Pulses the view (slight scale animation)
    func pulse() {
        UIView.animate(
            withDuration: 0.6,
            delay: 0,
            options: [.autoreverse, .repeat],
            animations: {
                self.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
            }
        )
    }

    /// Stops all animations on the view
    func stopAnimations() {
        layer.removeAllAnimations()
        transform = .identity
    }
}

// MARK: - UIStackView Helpers

extension UIStackView {

    /// Adds multiple arranged subviews at once
    /// - Parameter views: Array of views to add
    func addArrangedSubviews(_ views: [UIView]) {
        views.forEach { addArrangedSubview($0) }
    }

    /// Removes all arranged subviews
    func removeAllArrangedSubviews() {
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }
}

// MARK: - UIEdgeInsets Helpers

extension UIEdgeInsets {

    /// Creates insets with equal values on all sides
    /// - Parameter value: The inset value
    /// - Returns: UIEdgeInsets
    static func all(_ value: CGFloat) -> UIEdgeInsets {
        return UIEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    /// Creates insets with horizontal and vertical values
    /// - Parameters:
    ///   - horizontal: Left and right inset
    ///   - vertical: Top and bottom inset
    /// - Returns: UIEdgeInsets
    static func symmetric(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> UIEdgeInsets {
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
