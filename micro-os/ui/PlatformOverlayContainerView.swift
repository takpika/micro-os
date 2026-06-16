import SwiftUI

#if os(macOS)
import AppKit

struct PlatformOverlayContainerView: NSViewRepresentable {
    let object: AnyObject

    func makeNSView(context: Context) -> NSView {
        guard let view = object as? NSView else {
            return NSView()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit

struct PlatformOverlayContainerView: UIViewRepresentable {
    let object: AnyObject

    func makeUIView(context: Context) -> UIView {
        guard let view = object as? UIView else {
            return UIView()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
