import Foundation

struct MicroOSKeyboardModifiers: OptionSet, Hashable {
    let rawValue: UInt32

    static let control = MicroOSKeyboardModifiers(rawValue: 1 << 0)
    static let option = MicroOSKeyboardModifiers(rawValue: 1 << 1)
    static let command = MicroOSKeyboardModifiers(rawValue: 1 << 2)
}

enum MicroOSKeyboardKey: Int32 {
    case text = 0
    case tab = 1
    case escape = 2
    case leftArrow = 3
    case downArrow = 4
    case upArrow = 5
    case rightArrow = 6
    case delete = 7
    case returnKey = 8
    case space = 9
}

enum MicroOSKeyboardEventPhase: Int32 {
    case keyDown = 0
    case keyUp = 1
    case keyRepeat = 2
    case modifiersChanged = 3
}

struct MicroOSKeyboardEvent {
    let key: MicroOSKeyboardKey
    let modifiers: MicroOSKeyboardModifiers
    let text: String

    init(key: MicroOSKeyboardKey, modifiers: MicroOSKeyboardModifiers = [], text: String = "") {
        self.key = key
        self.modifiers = modifiers
        self.text = text
    }
}

public typealias MicroOSKeyboardSinkCallback = @convention(c) (
    Int32,
    Int32,
    UInt32,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void

struct MicroOSKeyboardSink {
    let callback: MicroOSKeyboardSinkCallback
    let context: UnsafeMutableRawPointer?
}

enum MicroOSKeyboardTTYTranslator {
    static func text(for event: MicroOSKeyboardEvent) -> String? {
        guard !event.modifiers.contains(.command) else { return nil }

        var result: String
        switch event.key {
        case .text:
            result = event.text
        case .tab:
            result = "\t"
        case .escape:
            result = "\u{1b}"
        case .leftArrow:
            result = "\u{1b}[D"
        case .downArrow:
            result = "\u{1b}[B"
        case .upArrow:
            result = "\u{1b}[A"
        case .rightArrow:
            result = "\u{1b}[C"
        case .delete:
            result = "\u{7f}"
        case .returnKey:
            result = "\n"
        case .space:
            result = " "
        }

        if event.modifiers.contains(.control), let controlText = controlSequence(for: result) {
            result = controlText
        }
        if event.modifiers.contains(.option) {
            result = "\u{1b}" + result
        }
        return result
    }

    private static func controlSequence(for text: String) -> String? {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        let value = scalar.value
        if value >= 64, value <= 95 {
            return String(UnicodeScalar(value - 64)!)
        }
        if value >= 97, value <= 122 {
            return String(UnicodeScalar(value - 96)!)
        }
        switch scalar {
        case " ":
            return "\u{0}"
        case "?":
            return "\u{7f}"
        default:
            return nil
        }
    }
}
