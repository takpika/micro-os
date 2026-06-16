import SwiftUI

struct ANSIConsoleStyle {
    var foreground: Color
    var background: Color?
    var isBold: Bool = false
    var isUnderlined: Bool = false
}

private struct ANSIConsoleCell {
    var character: Character
    var style: ANSIConsoleStyle
}

@MainActor
final class ANSIConsoleParser {
    private var rows: [[ANSIConsoleCell]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var defaultForeground = Color.white
    private var style = ANSIConsoleStyle(foreground: .white)
    private var hasCustomStyle = false
    private var isCursorVisible = true
    private let maxRows = 2_000

    func write(_ text: String, defaultColor: Color) -> [ConsoleLine] {
        defaultForeground = defaultColor
        if !hasCustomStyle {
            style.foreground = defaultColor
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{001B}",
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               text[next] == "[" {
                index = consumeCSI(in: text, from: next)
                continue
            }

            switch character {
            case "\n":
                lineFeed()
            case "\r":
                cursorColumn = 0
            case "\u{0008}":
                cursorColumn = max(0, cursorColumn - 1)
            case "\t":
                let spaces = 4 - (cursorColumn % 4)
                for _ in 0..<spaces {
                    put(" ")
                }
            default:
                put(character)
            }
            index = text.index(after: index)
        }

        return renderedLines()
    }

    private func put(_ character: Character) {
        ensureCursor()
        while rows[cursorRow].count < cursorColumn {
            rows[cursorRow].append(ANSIConsoleCell(character: " ", style: style))
        }

        let cell = ANSIConsoleCell(character: character, style: style)
        if cursorColumn < rows[cursorRow].count {
            rows[cursorRow][cursorColumn] = cell
        } else {
            rows[cursorRow].append(cell)
        }
        cursorColumn += 1
    }

    private func lineFeed() {
        cursorRow += 1
        cursorColumn = 0
        ensureCursor()
    }

    private func ensureCursor() {
        while cursorRow >= rows.count {
            rows.append([])
        }
        if rows.count > maxRows {
            let removed = rows.count - maxRows
            rows.removeFirst(removed)
            cursorRow = max(0, cursorRow - removed)
            savedCursorRow = max(0, savedCursorRow - removed)
        }
    }

    private func consumeCSI(in text: String, from bracketIndex: String.Index) -> String.Index {
        var index = text.index(after: bracketIndex)
        var payload = ""

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character == "@" {
                applyCSI(payload: payload, final: character)
                return text.index(after: index)
            }

            payload.append(character)
            index = text.index(after: index)
        }

        return index
    }

    private func applyCSI(payload: String, final: Character) {
        if payload == "?25", final == "l" {
            isCursorVisible = false
            return
        }
        if payload == "?25", final == "h" {
            isCursorVisible = true
            return
        }

        let values = payload
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        func value(_ index: Int, default defaultValue: Int) -> Int {
            guard index < values.count, values[index] > 0 else { return defaultValue }
            return values[index]
        }

        switch final {
        case "m":
            applySGR(values.isEmpty ? [0] : values)
        case "H", "f":
            cursorRow = max(0, value(0, default: 1) - 1)
            cursorColumn = max(0, value(1, default: 1) - 1)
            ensureCursor()
        case "A":
            cursorRow = max(0, cursorRow - value(0, default: 1))
        case "B":
            cursorRow += value(0, default: 1)
            ensureCursor()
        case "C":
            cursorColumn += value(0, default: 1)
        case "D":
            cursorColumn = max(0, cursorColumn - value(0, default: 1))
        case "G":
            cursorColumn = max(0, value(0, default: 1) - 1)
        case "J":
            eraseDisplay(mode: values.first ?? 0)
        case "K":
            eraseLine(mode: values.first ?? 0)
        case "s":
            savedCursorRow = cursorRow
            savedCursorColumn = cursorColumn
        case "u":
            cursorRow = savedCursorRow
            cursorColumn = savedCursorColumn
            ensureCursor()
        default:
            break
        }
    }

    private func eraseDisplay(mode: Int) {
        ensureCursor()
        switch mode {
        case 1:
            for row in 0..<cursorRow {
                rows[row].removeAll()
            }
            eraseLine(mode: 1)
        case 2, 3:
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows.count {
                rows.removeSubrange((cursorRow + 1)..<rows.count)
            }
        }
    }

    private func eraseLine(mode: Int) {
        ensureCursor()
        switch mode {
        case 1:
            guard !rows[cursorRow].isEmpty else { return }
            let end = min(cursorColumn, rows[cursorRow].count - 1)
            if end >= 0 {
                for index in 0...end {
                    rows[cursorRow][index] = ANSIConsoleCell(character: " ", style: style)
                }
            }
        case 2:
            rows[cursorRow].removeAll()
            cursorColumn = 0
        default:
            if cursorColumn < rows[cursorRow].count {
                rows[cursorRow].removeSubrange(cursorColumn..<rows[cursorRow].count)
            }
        }
    }

    private func applySGR(_ codes: [Int]) {
        for code in codes {
            switch code {
            case 0:
                style = ANSIConsoleStyle(foreground: defaultForeground)
                hasCustomStyle = false
            case 1:
                style.isBold = true
                hasCustomStyle = true
            case 4:
                style.isUnderlined = true
                hasCustomStyle = true
            case 22:
                style.isBold = false
            case 24:
                style.isUnderlined = false
            case 30...37, 90...97:
                style.foreground = ansiColor(code)
                hasCustomStyle = true
            case 39:
                style.foreground = defaultForeground
            case 40...47, 100...107:
                style.background = ansiColor(code - 10)
                hasCustomStyle = true
            case 49:
                style.background = nil
            default:
                break
            }
        }
    }

    private func renderedLines() -> [ConsoleLine] {
        var renderRows = rows
        if isCursorVisible {
            while cursorRow >= renderRows.count {
                renderRows.append([])
            }
            while cursorColumn >= renderRows[cursorRow].count {
                renderRows[cursorRow].append(ANSIConsoleCell(character: " ", style: style))
            }
            let cell = renderRows[cursorRow][cursorColumn]
            renderRows[cursorRow][cursorColumn] = ANSIConsoleCell(
                character: cell.character,
                style: ANSIConsoleStyle(foreground: .black, background: .white, isBold: true)
            )
        }

        return renderRows.enumerated().map { index, row in
            ConsoleLine(id: index, content: attributed(row))
        }
    }

    private func attributed(_ cells: [ANSIConsoleCell]) -> AttributedString {
        var result = AttributedString()
        for cell in cells {
            var part = AttributedString(String(cell.character))
            part.foregroundColor = cell.style.foreground
            part.font = .system(size: 13, weight: cell.style.isBold ? .bold : .regular, design: .monospaced)
            if let background = cell.style.background {
                part.backgroundColor = background
            }
            if cell.style.isUnderlined {
                part.underlineStyle = .single
            }
            result += part
        }
        return result
    }

    private func ansiColor(_ code: Int) -> Color {
        switch code {
        case 30: return .black
        case 31: return .red
        case 32: return .green
        case 33: return .yellow
        case 34: return .blue
        case 35: return .purple
        case 36: return .cyan
        case 37: return .white
        case 90: return Color(white: 0.55)
        case 91: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case 92: return Color(red: 0.4, green: 1.0, blue: 0.4)
        case 93: return Color(red: 1.0, green: 0.85, blue: 0.25)
        case 94: return Color(red: 0.35, green: 0.55, blue: 1.0)
        case 95: return Color(red: 1.0, green: 0.45, blue: 1.0)
        case 96: return Color(red: 0.35, green: 1.0, blue: 1.0)
        case 97: return .white
        default: return .white
        }
    }
}
