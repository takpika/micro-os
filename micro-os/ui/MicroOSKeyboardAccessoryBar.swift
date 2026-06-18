import UIKit

enum MicroOSKeyboardUIKitMapper {
    static func event(for key: UIKey) -> MicroOSKeyboardEvent {
        let modifiers = MicroOSKeyboardModifiers(uiKeyModifiers: key.modifierFlags)
        let keyboardKey = microOSKey(for: key.keyCode)
        let text: String
        if keyboardKey == .text {
            text = modifiers.isEmpty
                ? key.characters
                : key.charactersIgnoringModifiers
        } else {
            text = ""
        }
        return MicroOSKeyboardEvent(key: keyboardKey, modifiers: modifiers, text: text)
    }

    private static func microOSKey(for usage: UIKeyboardHIDUsage) -> MicroOSKeyboardKey {
        switch usage.rawValue {
        case 0x28, 0x9e:
            return .returnKey
        case 0x2b:
            return .tab
        case 0x29:
            return .escape
        case 0x50:
            return .leftArrow
        case 0x51:
            return .downArrow
        case 0x52:
            return .upArrow
        case 0x4f:
            return .rightArrow
        case 0x2a, 0x4c:
            return .delete
        case 0x2c:
            return .space
        default:
            return .text
        }
    }
}

extension MicroOSKeyboardModifiers {
    init(uiKeyModifiers: UIKeyModifierFlags) {
        self = []
        if uiKeyModifiers.contains(.control) {
            insert(.control)
        }
        if uiKeyModifiers.contains(.alternate) {
            insert(.option)
        }
        if uiKeyModifiers.contains(.command) {
            insert(.command)
        }
    }
}

final class MicroOSKeyboardAccessoryBar: UIInputView {
    private enum Key {
        case modifier(String, String, MicroOSKeyboardModifiers)
        case action(String, String, MicroOSKeyboardKey)

        var symbolName: String {
            switch self {
            case .modifier(_, let symbolName, _), .action(_, let symbolName, _):
                symbolName
            }
        }

        var title: String {
            switch self {
            case .modifier(let title, _, _), .action(let title, _, _):
                title
            }
        }
    }

    private let sendEvent: (MicroOSKeyboardEvent) -> Void
    private var activeModifiers: MicroOSKeyboardModifiers = []
    private var modifierButtons: [MicroOSKeyboardModifiers: UIButton] = [:]

    init(sendEvent: @escaping (MicroOSKeyboardEvent) -> Void) {
        self.sendEvent = sendEvent
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 58), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        backgroundColor = .clear
        heightAnchor.constraint(equalToConstant: 58).isActive = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 58)
    }

    func insertText(_ text: String) {
        emit(.text, text: text)
    }

    func sendSystemKey(_ key: MicroOSKeyboardKey) {
        emit(key)
    }

    private func setup() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        blur.contentView.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        let keys: [Key] = [
            .modifier("Ctrl", "control", .control),
            .modifier("Option", "option", .option),
            .modifier("Command", "command", .command),
            .action("Tab", "arrow.right.to.line", .tab),
            .action("Esc", "escape", .escape),
            .action("Left", "arrow.left", .leftArrow),
            .action("Down", "arrow.down", .downArrow),
            .action("Up", "arrow.up", .upArrow),
            .action("Right", "arrow.right", .rightArrow)
        ]

        for key in keys {
            let button = makeButton(for: key)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 50).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            if case .modifier(_, _, let modifier) = key {
                modifierButtons[modifier] = button
            }
        }

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func makeButton(for key: Key) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: key.symbolName)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        configuration.imagePlacement = .top
        configuration.baseBackgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.68)
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.accessibilityLabel = key.title
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        button.layer.borderWidth = 0.5
        button.layer.cornerCurve = .continuous

        switch key {
        case .modifier(_, _, let modifier):
            button.addAction(UIAction { [weak self] _ in
                self?.toggle(modifier)
            }, for: .touchUpInside)
        case .action(_, _, let actionKey):
            button.addAction(UIAction { [weak self] _ in
                self?.emit(actionKey)
            }, for: .touchUpInside)
        }
        return button
    }

    private func toggle(_ modifier: MicroOSKeyboardModifiers) {
        if activeModifiers.contains(modifier) {
            activeModifiers.remove(modifier)
        } else {
            activeModifiers.insert(modifier)
        }
        updateModifierButtons()
    }

    private func emit(_ key: MicroOSKeyboardKey, text: String = "") {
        sendEvent(MicroOSKeyboardEvent(key: key, modifiers: activeModifiers, text: text))
        clearOneShotModifiers()
    }

    private func clearOneShotModifiers() {
        guard !activeModifiers.isEmpty else { return }
        activeModifiers = []
        updateModifierButtons()
    }

    private func updateModifierButtons() {
        for (modifier, button) in modifierButtons {
            update(button: button, isActive: activeModifiers.contains(modifier))
        }
    }

    private func update(button: UIButton, isActive: Bool) {
        var configuration = button.configuration
        configuration?.baseBackgroundColor = isActive
            ? UIColor.systemBlue.withAlphaComponent(0.72)
            : UIColor.secondarySystemFill.withAlphaComponent(0.68)
        configuration?.baseForegroundColor = isActive ? .white : .label
        button.configuration = configuration
    }
}
