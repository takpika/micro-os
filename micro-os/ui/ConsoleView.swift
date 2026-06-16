import SwiftUI
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

struct ConsoleView: View {
    let lines: [ConsoleLine]
    let onInput: (String) -> Void
    @State private var pendingInput = ""
    @State private var isClearingPendingInput = false
    @State private var refocusTick = 0
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topLeading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(line.content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black)

                keyboardInput
            }
            .onTapGesture {
                // Touches pass through the (hit-test-disabled) keyboard view to
                // the scroll view, so a tap re-focuses the keyboard explicitly.
                isInputFocused = true
                refocusTick += 1
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var keyboardInput: some View {
        #if os(iOS) || os(tvOS) || os(visionOS)
        ConsoleKeyboardInputView(refocusTick: refocusTick) { text in
            onInput(text)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        #else
        TextField("", text: $pendingInput)
            .focused($isInputFocused)
            .autocorrectionDisabled()
            .opacity(0.01)
            .frame(width: 1, height: 1)
            .onChange(of: pendingInput) { oldValue, newValue in
                if isClearingPendingInput {
                    isClearingPendingInput = false
                    return
                }
                if newValue.hasPrefix(oldValue) {
                    let start = newValue.index(newValue.startIndex, offsetBy: oldValue.count)
                    onInput(String(newValue[start...]))
                } else if oldValue.hasPrefix(newValue) {
                    onInput("\u{7f}")
                }
            }
            .onSubmit {
                onInput("\n")
                isClearingPendingInput = true
                pendingInput.removeAll()
            }
        #endif
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
private struct ConsoleKeyboardInputView: UIViewRepresentable {
    var refocusTick: Int
    let onInput: (String) -> Void

    func makeUIView(context: Context) -> ConsoleInputView {
        let view = ConsoleInputView()
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

    func updateUIView(_ uiView: ConsoleInputView, context: Context) {
        context.coordinator.onInput = onInput
        uiView.onInput = {
            context.coordinator.onInput($0)
        }
        if context.coordinator.lastRefocusTick != refocusTick {
            context.coordinator.lastRefocusTick = refocusTick
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    final class Coordinator {
        var onInput: (String) -> Void
        var lastRefocusTick = 0

        init(onInput: @escaping (String) -> Void) {
            self.onInput = onInput
        }
    }
}

private final class ConsoleInputView: UIView, UIKeyInput {
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
        true
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
#endif
