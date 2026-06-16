import SwiftUI
import UIKit
import ObjectiveC

private var hostingControllerAssociationKey: UInt8 = 0

fileprivate struct TerminalLine: Identifiable {
    let id: Int
    let content: AttributedString
}

fileprivate struct TerminalCell {
    var character: Character
    var foreground: Color
    var background: Color?
    var isBold: Bool
}

fileprivate final class TerminalANSIBuffer {
    private var rows: [[TerminalCell]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursorRow = 0
    private var savedCursorColumn = 0
    private var foreground = Color.white
    private var background: Color?
    private var isBold = false
    private var isCursorVisible = true
    private let maxRows = 1_000

    func write(_ text: String) -> [TerminalLine] {
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
                cursorRow += 1
                cursorColumn = 0
                ensureCursor()
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
        return render()
    }

    private func put(_ character: Character) {
        ensureCursor()
        while rows[cursorRow].count < cursorColumn {
            rows[cursorRow].append(cell(" "))
        }
        if cursorColumn < rows[cursorRow].count {
            rows[cursorRow][cursorColumn] = cell(character)
        } else {
            rows[cursorRow].append(cell(character))
        }
        cursorColumn += 1
    }

    private func cell(_ character: Character) -> TerminalCell {
        TerminalCell(character: character, foreground: foreground, background: background, isBold: isBold)
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
                    rows[cursorRow][index] = cell(" ")
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
                foreground = .white
                background = nil
                isBold = false
            case 1:
                isBold = true
            case 22:
                isBold = false
            case 30...37, 90...97:
                foreground = ansiColor(code)
            case 39:
                foreground = .white
            case 40...47, 100...107:
                background = ansiColor(code - 10)
            case 49:
                background = nil
            default:
                break
            }
        }
    }

    private func render() -> [TerminalLine] {
        var renderRows = rows
        if isCursorVisible {
            while cursorRow >= renderRows.count {
                renderRows.append([])
            }
            while cursorColumn >= renderRows[cursorRow].count {
                renderRows[cursorRow].append(cell(" "))
            }
            let character = renderRows[cursorRow][cursorColumn].character
            renderRows[cursorRow][cursorColumn] = TerminalCell(
                character: character,
                foreground: .black,
                background: .white,
                isBold: true
            )
        }

        return renderRows.enumerated().map { index, cells in
            var content = AttributedString()
            for cell in cells {
                var part = AttributedString(String(cell.character))
                part.foregroundColor = cell.foreground
                part.font = .system(size: 13, weight: cell.isBold ? .bold : .regular, design: .monospaced)
                if let background = cell.background {
                    part.backgroundColor = background
                }
                content += part
            }
            return TerminalLine(id: index, content: content)
        }
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

final class TerminalModel: ObservableObject {
    let ttyID: Int32
    @Published fileprivate var lines: [TerminalLine] = []
    @Published fileprivate var revision: Int = 0
    private let buffer = TerminalANSIBuffer()

    init() {
        ttyID = MicroOS.createPseudoTTY(name: "terminal")
        MicroOS.observePseudoTTYOutput(
            ttyID,
            callback: terminalOutputCallback,
            context: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func write(_ text: String) {
        MicroOS.writePseudoTTY(ttyID, text)
    }

    func input(_ text: String) {
        MicroOS.inputPseudoTTY(ttyID, text)
    }

    func append(_ text: String) {
        lines = buffer.write(text)
        revision += 1
    }
}

private let terminalOutputCallback: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, text, context in
    guard let text, let context else { return }
    let model = Unmanaged<TerminalModel>.fromOpaque(context).takeUnretainedValue()
    let value = String(cString: text)
    Task { @MainActor in
        model.append(value)
    }
}

struct TerminalRootView: View {
    @StateObject private var model: TerminalModel

    init(model: TerminalModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.lines) { line in
                                Text(line.content)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black)

                    TerminalKeyboardInputView { text in
                        model.input(text)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .contentShape(Rectangle())
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: model.revision) { _, _ in
                    if let last = model.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.black)
    }
}

private struct TerminalKeyboardInputView: UIViewRepresentable {
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.onInput = {
            context.coordinator.onInput($0)
        }
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.returnKeyType = .default
        return view
    }

    func updateUIView(_ uiView: TerminalInputView, context: Context) {
        context.coordinator.onInput = onInput
        uiView.onInput = {
            context.coordinator.onInput($0)
        }
        DispatchQueue.main.async {
            if uiView.window != nil, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    final class Coordinator {
        var onInput: (String) -> Void

        init(onInput: @escaping (String) -> Void) {
            self.onInput = onInput
        }
    }
}

private final class TerminalInputView: UIView, UIKeyInput {
    var onInput: ((String) -> Void)?
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    var hasText: Bool {
        false
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        super.touchesBegan(touches, with: event)
    }

    func insertText(_ text: String) {
        onInput?(text)
    }

    func deleteBackward() {
        onInput?("\u{7f}")
    }
}

@_cdecl("entry")
public func entry(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let terminal = makeTerminalPlatformView()
    let windowID = MicroOSWM.openWindow(title: "Terminal", platformView: terminal.view, width: 640, height: 420)
    if windowID < 0 {
        MicroOS.stderr("terminal: wm service is not available\n")
        return 1
    }

    if argc > 1, let argv, let dylibPointer = argv[1] {
        let dylib = String(cString: dylibPointer)
        let arguments = (2..<Int(argc)).compactMap { index -> String? in
            guard let pointer = argv[index] else { return nil }
            return String(cString: pointer)
        }
        let childPID = MicroOS.spawn(dylib: dylib, arguments: arguments, ttyID: terminal.ttyID)
        if childPID < 0 {
            MicroOS.stderr("terminal: failed to launch \(dylib)\n")
        }
    }

    MicroOS.keepAlive()
    return 0
}

private struct TerminalPlatformView {
    let view: UIView
    let ttyID: Int32
}

private func makeTerminalPlatformView() -> TerminalPlatformView {
    if Thread.isMainThread {
        return makeTerminalPlatformViewOnMain()
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: TerminalPlatformView?
    DispatchQueue.main.async {
        result = makeTerminalPlatformViewOnMain()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

private func makeTerminalPlatformViewOnMain() -> TerminalPlatformView {
    let model = TerminalModel()
    let controller = UIHostingController(rootView: TerminalRootView(model: model))
    controller.view.backgroundColor = .black

    let container = UIView()
    container.backgroundColor = .black
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(controller.view)
    NSLayoutConstraint.activate([
        controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        controller.view.topAnchor.constraint(equalTo: container.topAnchor),
        controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])

    objc_setAssociatedObject(container, &hostingControllerAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return TerminalPlatformView(view: container, ttyID: model.ttyID)
}
