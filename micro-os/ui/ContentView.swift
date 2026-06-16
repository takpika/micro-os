import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @EnvironmentObject private var kernel: MicroKernel

    var body: some View {
        ZStack {
            ConsoleView(lines: kernel.consoleLines) { input in
                kernel.enqueueStdin(input)
            }

            ForEach(kernel.overlays) { overlay in
                overlayView(overlay)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
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
