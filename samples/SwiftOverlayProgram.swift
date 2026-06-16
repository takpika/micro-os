import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
import ObjectiveC
#endif

#if os(iOS) || os(tvOS) || os(visionOS)
private var hostingControllerAssociationKey: UInt8 = 0
#endif

struct SwiftDylibOverlay: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "swift")
                .font(.system(size: 28, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("SwiftUI View")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("from Swift dylib")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(red: 0.86, green: 0.22, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

@_cdecl("entry")
public func entry(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    MicroOS.stdout("Swift dylib entry mounted a SwiftUI overlay\n")

    let platformView = makeOverlayPlatformView()
    MicroOS.overlayFullscreen(platformView)

    MicroOS.keepAlive()
    return 0
}

private func makeOverlayPlatformView() -> PlatformOverlayView {
    if Thread.isMainThread {
        return makeOverlayPlatformViewOnMain()
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: PlatformOverlayView?
    DispatchQueue.main.async {
        result = makeOverlayPlatformViewOnMain()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

private func makeOverlayPlatformViewOnMain() -> PlatformOverlayView {
    #if os(macOS)
    let platformView = NSHostingView(rootView: SwiftDylibOverlay())
    #elseif os(iOS) || os(tvOS) || os(visionOS)
    let controller = UIHostingController(rootView: SwiftDylibOverlay())
    controller.view.backgroundColor = .clear
    let platformView = controller.view!
    objc_setAssociatedObject(platformView, &hostingControllerAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    #endif
    return platformView
}
