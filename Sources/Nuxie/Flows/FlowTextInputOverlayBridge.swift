#if canImport(RiveRuntime) && canImport(UIKit)
import Foundation
import RiveRuntime
import UIKit

@MainActor
final class FlowTextInputOverlayBridge: NSObject, UITextFieldDelegate, UITextViewDelegate {
    private final class TextField: UITextField {
        override func textRect(forBounds bounds: CGRect) -> CGRect { bounds }
        override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds }
        override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds }
    }

    private enum Control {
        case field(TextField)
        case textView(UITextView)

        var view: UIView {
            switch self {
            case .field(let field):
                return field
            case .textView(let textView):
                return textView
            }
        }

        var text: String {
            get {
                switch self {
                case .field(let field):
                    return field.text ?? ""
                case .textView(let textView):
                    return textView.text ?? ""
                }
            }
            nonmutating set {
                switch self {
                case .field(let field):
                    field.text = newValue
                case .textView(let textView):
                    textView.text = newValue
                }
            }
        }
    }

    private struct Binding {
        let input: FlowArtifactTextInput
        let control: Control
    }

    private weak var riveView: RiveView?
    private weak var riveViewModel: RiveViewModel?
    private var activeScreen: FlowArtifactScreen?
    private var bindingsByInputId: [String: Binding] = [:]
    private var hidden = false

    func bind(
        screenId: String,
        artifact: LoadedFlowArtifact,
        riveView: RiveView,
        riveViewModel: RiveViewModel
    ) {
        clear()

        self.riveView = riveView
        self.riveViewModel = riveViewModel
        activeScreen = artifact.manifest.screens.first { $0.screenId == screenId }

        guard activeScreen != nil else {
            return
        }

        for input in artifact.manifest.textInputs where input.screenId == screenId && input.editable {
            let control = makeControl(for: input)
            control.view.accessibilityIdentifier = "nuxie-text-input-\(input.inputId)"
            control.view.isAccessibilityElement = true
            control.view.isHidden = hidden
            control.text = riveViewModel.getTextRunValue(input.riveTextRunName) ?? input.value

            if input.secureTextEntry == true {
                try? riveViewModel.setTextRunValue(input.riveTextRunName, textValue: "")
            }

            riveView.addSubview(control.view)
            bindingsByInputId[input.inputId] = Binding(input: input, control: control)
        }

        layout()
    }

    func clear() {
        for binding in bindingsByInputId.values {
            binding.control.view.removeFromSuperview()
        }
        bindingsByInputId.removeAll()
        activeScreen = nil
        riveView = nil
        riveViewModel = nil
    }

    func setHidden(_ isHidden: Bool) {
        hidden = isHidden
        for binding in bindingsByInputId.values {
            binding.control.view.isHidden = isHidden
        }
    }

    func layout() {
        guard let riveView,
              let screen = activeScreen else {
            return
        }

        let metrics = Self.contentMetrics(
            viewBounds: riveView.bounds,
            screenWidth: screen.width,
            screenHeight: screen.height
        )

        for binding in bindingsByInputId.values {
            let frame = Self.frame(
                for: binding.input.overlay,
                metrics: metrics
            )
            applyStyle(binding.input.style, to: binding.control, scale: metrics.scale, secure: binding.input.secureTextEntry == true)

            UIView.performWithoutAnimation {
                binding.control.view.transform = .identity
                binding.control.view.bounds = CGRect(origin: .zero, size: frame.size)
                binding.control.view.center = CGPoint(x: frame.midX, y: frame.midY)
                if binding.input.overlay.rotation != 0 {
                    binding.control.view.transform = CGAffineTransform(rotationAngle: CGFloat(binding.input.overlay.rotation))
                }
            }
        }
    }

    static func contentMetrics(
        viewBounds: CGRect,
        screenWidth: Double,
        screenHeight: Double
    ) -> (origin: CGPoint, scale: CGFloat) {
        guard screenWidth > 0,
              screenHeight > 0,
              viewBounds.width > 0,
              viewBounds.height > 0 else {
            return (.zero, 1)
        }

        let scale = min(
            viewBounds.width / CGFloat(screenWidth),
            viewBounds.height / CGFloat(screenHeight)
        )
        let contentWidth = CGFloat(screenWidth) * scale
        let contentHeight = CGFloat(screenHeight) * scale
        return (
            CGPoint(
                x: viewBounds.minX + (viewBounds.width - contentWidth) / 2,
                y: viewBounds.minY + (viewBounds.height - contentHeight) / 2
            ),
            scale
        )
    }

    static func frame(
        for overlay: FlowArtifactTextInputOverlay,
        metrics: (origin: CGPoint, scale: CGFloat)
    ) -> CGRect {
        let scaleX = max(0, CGFloat(overlay.scaleX))
        let scaleY = max(0, CGFloat(overlay.scaleY))
        return CGRect(
            x: metrics.origin.x + CGFloat(overlay.x) * metrics.scale,
            y: metrics.origin.y + CGFloat(overlay.y) * metrics.scale,
            width: CGFloat(overlay.width) * metrics.scale * scaleX,
            height: CGFloat(overlay.height) * metrics.scale * scaleY
        )
    }

    private func makeControl(for input: FlowArtifactTextInput) -> Control {
        if input.multiline == true {
            let textView = UITextView(frame: .zero)
            textView.delegate = self
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = true
            textView.keyboardType = Self.keyboardType(input.keyboardType)
            textView.autocorrectionType = .default
            textView.spellCheckingType = .default
            return .textView(textView)
        }

        let field = TextField(frame: .zero)
        field.delegate = self
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.placeholder = input.placeholder
        field.keyboardType = Self.keyboardType(input.keyboardType)
        field.isSecureTextEntry = input.secureTextEntry == true
        field.returnKeyType = .done
        field.autocorrectionType = .default
        field.spellCheckingType = .default
        field.addTarget(self, action: #selector(textFieldEditingChanged(_:)), for: .editingChanged)
        return .field(field)
    }

    private func applyStyle(
        _ style: FlowArtifactTextInputStyle,
        to control: Control,
        scale: CGFloat,
        secure: Bool
    ) {
        let fontSize = max(1, CGFloat(style.fontSize) * scale)
        let font = Self.font(for: style, size: fontSize)
        let color = UIColor(nuxieARGB: style.color)
        let textColor: UIColor = secure ? color : .clear
        let alignment = Self.textAlignment(style.textAlign)

        switch control {
        case .field(let field):
            field.font = font
            field.textAlignment = alignment
            field.textColor = textColor
            field.tintColor = color
            field.adjustsFontSizeToFitWidth = false

            var attributes = field.defaultTextAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = textColor
            if style.letterSpacing != 0 {
                attributes[.kern] = CGFloat(style.letterSpacing) * scale
            } else {
                attributes.removeValue(forKey: .kern)
            }
            if style.lineHeight > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = CGFloat(style.lineHeight) * scale
                paragraph.maximumLineHeight = CGFloat(style.lineHeight) * scale
                paragraph.alignment = alignment
                attributes[.paragraphStyle] = paragraph
            } else {
                attributes.removeValue(forKey: .paragraphStyle)
            }
            field.defaultTextAttributes = attributes

            if let placeholder = field.placeholder, !placeholder.isEmpty {
                field.attributedPlaceholder = NSAttributedString(
                    string: placeholder,
                    attributes: [
                        .font: font,
                        .foregroundColor: color.withAlphaComponent(0.45),
                    ]
                )
            }

        case .textView(let textView):
            textView.font = font
            textView.textAlignment = alignment
            textView.textColor = textColor
            textView.tintColor = color

            var attributes = textView.typingAttributes
            attributes[.font] = font
            attributes[.foregroundColor] = textColor
            if style.letterSpacing != 0 {
                attributes[.kern] = CGFloat(style.letterSpacing) * scale
            } else {
                attributes.removeValue(forKey: .kern)
            }
            if style.lineHeight > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = CGFloat(style.lineHeight) * scale
                paragraph.maximumLineHeight = CGFloat(style.lineHeight) * scale
                paragraph.alignment = alignment
                attributes[.paragraphStyle] = paragraph
            } else {
                attributes.removeValue(forKey: .paragraphStyle)
            }
            textView.typingAttributes = attributes
        }
    }

    @objc private func textFieldEditingChanged(_ sender: UITextField) {
        propagateTextChange(from: sender)
    }

    func textViewDidChange(_ textView: UITextView) {
        propagateTextChange(from: textView)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        shouldAllowChange(currentText: textField.text ?? "", range: range, replacement: string, control: textField)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        shouldAllowChange(currentText: textView.text ?? "", range: range, replacement: text, control: textView)
    }

    private func shouldAllowChange(
        currentText: String,
        range: NSRange,
        replacement: String,
        control: UIView
    ) -> Bool {
        guard let input = binding(for: control)?.input,
              let maxLength = input.maxLength,
              maxLength > 0,
              let textRange = Range(range, in: currentText) else {
            return true
        }

        let nextText = currentText.replacingCharacters(in: textRange, with: replacement)
        return nextText.count <= maxLength
    }

    private func propagateTextChange(from control: UIView) {
        guard let binding = binding(for: control),
              let riveViewModel else {
            return
        }

        let nextText = binding.control.text
        let renderedText = binding.input.secureTextEntry == true ? "" : nextText

        do {
            try riveViewModel.setTextRunValue(binding.input.riveTextRunName, textValue: renderedText)
        } catch {
            LogWarning("FlowTextInputOverlayBridge: failed to update text run \(binding.input.riveTextRunName): \(error)")
        }
    }

    private func binding(for control: UIView) -> Binding? {
        bindingsByInputId.values.first { $0.control.view === control }
    }

    private static func font(for style: FlowArtifactTextInputStyle, size: CGFloat) -> UIFont {
        if let postScriptName = FlowRuntimeFontRegistry.postScriptName(forRiveUniqueName: style.fontAssetRiveUniqueName),
           let font = UIFont(name: postScriptName, size: size) {
            return font
        }

        let traits: UIFontDescriptor.SymbolicTraits = style.fontStyle == "italic" ? .traitItalic : []
        let descriptor = UIFont.systemFont(ofSize: size, weight: fontWeight(style.fontWeight))
            .fontDescriptor
            .withSymbolicTraits(traits)
        if let descriptor {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.systemFont(ofSize: size, weight: fontWeight(style.fontWeight))
    }

    private static func fontWeight(_ value: String) -> UIFont.Weight {
        guard let weight = Int(value) else {
            return .regular
        }

        switch weight {
        case ..<250:
            return .ultraLight
        case 250..<350:
            return .light
        case 350..<450:
            return .regular
        case 450..<550:
            return .medium
        case 550..<650:
            return .semibold
        case 650..<750:
            return .bold
        case 750..<850:
            return .heavy
        default:
            return .black
        }
    }

    private static func textAlignment(_ value: String?) -> NSTextAlignment {
        switch value?.lowercased() {
        case "center":
            return .center
        case "right", "end":
            return .right
        case "justify":
            return .justified
        default:
            return .left
        }
    }

    private static func keyboardType(_ value: String?) -> UIKeyboardType {
        switch value?.lowercased() {
        case "email", "email-address":
            return .emailAddress
        case "number", "number-pad", "numeric":
            return .numberPad
        case "decimal", "decimal-pad":
            return .decimalPad
        case "phone", "phone-pad", "tel":
            return .phonePad
        case "url":
            return .URL
        default:
            return .default
        }
    }
}

private extension UIColor {
    convenience init(nuxieARGB value: UInt32) {
        let alpha = CGFloat((value >> 24) & 0xff) / 255
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
