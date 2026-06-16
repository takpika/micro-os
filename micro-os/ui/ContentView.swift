import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @EnvironmentObject private var kernel: MicroKernel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar

                ZStack {
                    ConsoleView(lines: kernel.consoleLines) { input in
                        kernel.enqueueStdin(input)
                    }

                    ForEach(kernel.overlays) { overlay in
                        overlayView(overlay)
                    }
                }
            }
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("microOS")
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(.white)

            // Launch is the shell's job now, so the dylib/argv fields are gone.
            Spacer()

            Button {
                dismissKeyboard()
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(.bordered)
            .help("dismiss keyboard")

            Button {
                kernel.terminateAllProcesses()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .help("request process termination")

            Button {
                kernel.triggerPanic("manual kernel panic")
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .help("kernel panic")
        }
        .padding(12)
        .background(Color(white: 0.06))
    }

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func cgFloat(_ value: Double?) -> CGFloat? {
        guard let value else { return nil }
        return CGFloat(value)
    }

    @ViewBuilder
    private func overlayView(_ overlay: UIOverlay) -> some View {
        if overlay.frame.isFullscreen {
            PlatformOverlayContainerView(object: overlay.object)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PlatformOverlayContainerView(object: overlay.object)
                .frame(width: cgFloat(overlay.frame.width), height: cgFloat(overlay.frame.height))
                .position(x: overlay.frame.x, y: overlay.frame.y)
        }
    }
}
