import Darwin
import Foundation

final class PseudoTTY {
    let id: Int32
    let name: String
    private(set) var localFlags: UInt32 = 0x00000188
    private let lock = NSLock()
    private var stdinQueue = ""
    private var canonicalBuffer = ""
    private var escapeBuffer = ""
    private var outputObservers: [PseudoTTYOutputObserver] = []

    init(id: Int32, name: String) {
        self.id = id
        self.name = name
    }

    func enqueueInput(_ text: String) -> String {
        lock.lock()
        let echo = enqueueInputLocked(text)
        lock.unlock()
        return echo
    }

    func shouldEchoInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (localFlags & 0x00000008) != 0
    }

    func setLocalFlags(_ flags: UInt32) {
        lock.lock()
        let wasCanonical = isCanonicalMode
        localFlags = flags
        if wasCanonical && !isCanonicalMode && !canonicalBuffer.isEmpty {
            stdinQueue.append(canonicalBuffer)
            canonicalBuffer.removeAll()
            escapeBuffer.removeAll()
        }
        lock.unlock()
    }

    func getLocalFlags() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return localFlags
    }

    func write(_ text: String) {
        lock.lock()
        let observers = outputObservers
        lock.unlock()

        for observer in observers {
            text.withCString { pointer in
                observer.callback(id, pointer, observer.context)
            }
        }
    }

    func addOutputObserver(pid: Int32, callback: @escaping PseudoTTYOutputObserverCallback, context: UnsafeMutableRawPointer?) {
        lock.lock()
        outputObservers.append(PseudoTTYOutputObserver(pid: pid, callback: callback, context: context))
        lock.unlock()
    }

    func removeObservers(pid: Int32) {
        lock.lock()
        outputObservers.removeAll { $0.pid == pid }
        lock.unlock()
    }

    func read(maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        lock.lock()
        defer { lock.unlock() }
        guard !stdinQueue.isEmpty else { return "" }
        let count = min(maxBytes, stdinQueue.utf8.count)
        let end = stdinQueue.index(stdinQueue.startIndex, offsetBy: count)
        let result = String(stdinQueue[..<end])
        stdinQueue.removeSubrange(..<end)
        return result
    }

    private var isCanonicalMode: Bool {
        (localFlags & UInt32(ICANON)) != 0
    }

    private func enqueueInputLocked(_ text: String) -> String {
        guard isCanonicalMode else {
            stdinQueue.append(text)
            return text
        }

        var echo = ""
        for character in text {
            if !escapeBuffer.isEmpty || character == "\u{1b}" {
                echo.append(handleEscapeInputLocked(character))
                continue
            }

            switch character {
            case "\u{7f}", "\u{8}":
                echo.append(deletePreviousCharacterLocked())
            case "\r", "\n":
                canonicalBuffer.append("\n")
                stdinQueue.append(canonicalBuffer)
                canonicalBuffer.removeAll()
                echo.append("\n")
            default:
                canonicalBuffer.append(character)
                echo.append(character)
            }
        }
        return echo
    }

    private func handleEscapeInputLocked(_ character: Character) -> String {
        escapeBuffer.append(character)
        if escapeBuffer.count > 8 {
            escapeBuffer.removeAll()
            return ""
        }

        if escapeBuffer == "\u{1b}[3~" {
            escapeBuffer.removeAll()
            return deletePreviousCharacterLocked()
        }

        if let last = escapeBuffer.last, isEscapeSequenceTerminator(last) {
            escapeBuffer.removeAll()
            return ""
        }

        return ""
    }

    private func isEscapeSequenceTerminator(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return scalar.value >= 0x40 && scalar.value <= 0x7e
    }

    private func deletePreviousCharacterLocked() -> String {
        guard !canonicalBuffer.isEmpty else { return "" }
        canonicalBuffer.removeLast()
        return "\u{8} \u{8}"
    }
}

typealias PseudoTTYOutputObserverCallback = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

struct PseudoTTYOutputObserver {
    let pid: Int32
    let callback: PseudoTTYOutputObserverCallback
    let context: UnsafeMutableRawPointer?
}
