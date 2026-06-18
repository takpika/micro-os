import Darwin
import Foundation

typealias PseudoTTYCompletionProvider = (String) -> [String]

final class PseudoTTY {
    let id: Int32
    let name: String
    private(set) var localFlags: UInt32 = 0x00000188
    private let completionProvider: PseudoTTYCompletionProvider?
    private let lock = NSLock()
    private var stdinQueue = ""
    private var canonicalBuffer = ""
    private var canonicalCursorOffset = 0
    private var escapeBuffer = ""
    private var inputHistory: [String] = []
    private var historyDraft = ""
    private var historyIndex: Int?
    private var outputObservers: [PseudoTTYOutputObserver] = []

    init(id: Int32, name: String, completionProvider: PseudoTTYCompletionProvider? = nil) {
        self.id = id
        self.name = name
        self.completionProvider = completionProvider
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
            canonicalCursorOffset = 0
            escapeBuffer.removeAll()
            resetHistoryNavigationLocked()
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
            case "\u{3}":
                echo.append(interruptInputLocked())
            case "\t":
                echo.append(completeInputLocked())
            case "\u{7f}", "\u{8}":
                echo.append(deletePreviousCharacterLocked())
            case "\r", "\n":
                appendHistoryLocked(canonicalBuffer)
                canonicalBuffer.append("\n")
                stdinQueue.append(canonicalBuffer)
                canonicalBuffer.removeAll()
                canonicalCursorOffset = 0
                resetHistoryNavigationLocked()
                echo.append("\n")
            default:
                echo.append(insertCharacterLocked(character))
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

        if escapeBuffer == "\u{1b}" || escapeBuffer == "\u{1b}[" {
            return ""
        }

        if escapeBuffer == "\u{1b}[3~" {
            escapeBuffer.removeAll()
            return deleteCharacterAtCursorLocked()
        }

        if escapeBuffer == "\u{1b}[D" {
            escapeBuffer.removeAll()
            return moveCursorLeftLocked()
        }

        if escapeBuffer == "\u{1b}[C" {
            escapeBuffer.removeAll()
            return moveCursorRightLocked()
        }

        if escapeBuffer == "\u{1b}[A" {
            escapeBuffer.removeAll()
            return moveHistoryUpLocked()
        }

        if escapeBuffer == "\u{1b}[B" {
            escapeBuffer.removeAll()
            return moveHistoryDownLocked()
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

    private func insertCharacterLocked(_ character: Character) -> String {
        resetHistoryNavigationLocked()
        let index = canonicalIndex(offset: canonicalCursorOffset)
        canonicalBuffer.insert(character, at: index)
        canonicalCursorOffset += 1

        let tail = String(canonicalBuffer[canonicalIndex(offset: canonicalCursorOffset)...])
        guard !tail.isEmpty else { return String(character) }
        return String(character) + tail + moveCursorLeftSequence(count: tail.count)
    }

    private func deletePreviousCharacterLocked() -> String {
        guard canonicalCursorOffset > 0 else { return "" }
        resetHistoryNavigationLocked()
        let index = canonicalIndex(offset: canonicalCursorOffset - 1)
        canonicalBuffer.remove(at: index)
        canonicalCursorOffset -= 1

        let tail = String(canonicalBuffer[canonicalIndex(offset: canonicalCursorOffset)...])
        guard !tail.isEmpty else { return "\u{8} \u{8}" }
        return "\u{1b}[D" + tail + " " + moveCursorLeftSequence(count: tail.count + 1)
    }

    private func deleteCharacterAtCursorLocked() -> String {
        guard canonicalCursorOffset < canonicalBuffer.count else { return "" }
        resetHistoryNavigationLocked()
        let index = canonicalIndex(offset: canonicalCursorOffset)
        canonicalBuffer.remove(at: index)
        let tail = String(canonicalBuffer[canonicalIndex(offset: canonicalCursorOffset)...])
        return tail + " " + moveCursorLeftSequence(count: tail.count + 1)
    }

    private func moveCursorLeftLocked() -> String {
        guard canonicalCursorOffset > 0 else { return "" }
        canonicalCursorOffset -= 1
        return "\u{1b}[D"
    }

    private func moveCursorRightLocked() -> String {
        guard canonicalCursorOffset < canonicalBuffer.count else { return "" }
        canonicalCursorOffset += 1
        return "\u{1b}[C"
    }

    private func interruptInputLocked() -> String {
        canonicalBuffer.removeAll()
        canonicalCursorOffset = 0
        escapeBuffer.removeAll()
        resetHistoryNavigationLocked()
        stdinQueue.append("\n")
        return "^C\n"
    }

    private func completeInputLocked() -> String {
        guard let completionProvider else { return "" }
        resetHistoryNavigationLocked()

        let wordRange = currentWordRangeLocked()
        let prefix = String(canonicalBuffer[wordRange])
        let candidates = completionProvider(prefix)
        guard !candidates.isEmpty else { return "" }

        if candidates.count == 1 {
            return replaceRangeLocked(wordRange, with: candidates[0])
        }

        let common = longestCommonPrefix(candidates)
        if common.count > prefix.count {
            return replaceRangeLocked(wordRange, with: common)
        }

        return ""
    }

    private func moveHistoryUpLocked() -> String {
        guard !inputHistory.isEmpty else { return "" }
        if historyIndex == nil {
            historyDraft = canonicalBuffer
            historyIndex = inputHistory.count - 1
        } else if let index = historyIndex, index > 0 {
            historyIndex = index - 1
        }
        guard let index = historyIndex else { return "" }
        return replaceCanonicalBufferLocked(inputHistory[index])
    }

    private func moveHistoryDownLocked() -> String {
        guard let index = historyIndex else { return "" }
        if index + 1 < inputHistory.count {
            historyIndex = index + 1
            return replaceCanonicalBufferLocked(inputHistory[index + 1])
        }
        historyIndex = nil
        let draft = historyDraft
        historyDraft = ""
        return replaceCanonicalBufferLocked(draft)
    }

    private func replaceCanonicalBufferLocked(_ replacement: String) -> String {
        let oldCount = canonicalBuffer.count
        let oldCursorOffset = canonicalCursorOffset
        canonicalBuffer = replacement
        canonicalCursorOffset = replacement.count

        let clearCount = max(0, oldCount - replacement.count)
        return moveCursorLeftSequence(count: oldCursorOffset)
            + replacement
            + String(repeating: " ", count: clearCount)
            + moveCursorLeftSequence(count: clearCount)
    }

    private func replaceRangeLocked(_ range: Range<String.Index>, with replacement: String) -> String {
        let oldBuffer = canonicalBuffer
        let oldCursorOffset = canonicalCursorOffset
        let rangeStartOffset = oldBuffer.distance(from: oldBuffer.startIndex, to: range.lowerBound)

        canonicalBuffer.replaceSubrange(range, with: replacement)
        canonicalCursorOffset = rangeStartOffset + replacement.count

        let suffixStart = canonicalIndex(offset: canonicalCursorOffset)
        let suffix = String(canonicalBuffer[suffixStart...])
        let oldTailCount = oldBuffer.count - rangeStartOffset
        let newTailCount = replacement.count + suffix.count
        let clearCount = max(0, oldTailCount - newTailCount)

        return moveCursorLeftSequence(count: oldCursorOffset - rangeStartOffset)
            + replacement
            + suffix
            + String(repeating: " ", count: clearCount)
            + moveCursorLeftSequence(count: suffix.count + clearCount)
    }

    private func currentWordRangeLocked() -> Range<String.Index> {
        let cursor = canonicalIndex(offset: canonicalCursorOffset)
        var start = cursor
        while start > canonicalBuffer.startIndex {
            let previous = canonicalBuffer.index(before: start)
            if isWordSeparator(canonicalBuffer[previous]) { break }
            start = previous
        }

        var end = cursor
        while end < canonicalBuffer.endIndex, !isWordSeparator(canonicalBuffer[end]) {
            end = canonicalBuffer.index(after: end)
        }
        return start..<end
    }

    private func isWordSeparator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
    }

    private func longestCommonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix), !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        return prefix
    }

    private func appendHistoryLocked(_ line: String) {
        guard !line.isEmpty, inputHistory.last != line else { return }
        inputHistory.append(line)
        if inputHistory.count > 100 {
            inputHistory.removeFirst(inputHistory.count - 100)
        }
    }

    private func resetHistoryNavigationLocked() {
        historyIndex = nil
        historyDraft = ""
    }

    private func canonicalIndex(offset: Int) -> String.Index {
        let boundedOffset = min(max(0, offset), canonicalBuffer.count)
        return canonicalBuffer.index(canonicalBuffer.startIndex, offsetBy: boundedOffset)
    }

    private func moveCursorLeftSequence(count: Int) -> String {
        String(repeating: "\u{1b}[D", count: max(0, count))
    }
}

typealias PseudoTTYOutputObserverCallback = @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

struct PseudoTTYOutputObserver {
    let pid: Int32
    let callback: PseudoTTYOutputObserverCallback
    let context: UnsafeMutableRawPointer?
}
