import Foundation
import SwiftUI
import ObjectiveC

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@_silgen_name("micro_os_appkit_user_main")
private func micro_os_appkit_user_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

// Implemented in the AppKit shim: flags the surface window for an app-driven close
// (the shim's run loop then runs -performClose: -> windowShouldClose: -> confirm).
@_silgen_name("micro_os_appkit_request_close")
private func micro_os_appkit_request_close(_ windowID: Int32)

// Implemented in the AppKit shim: show/hide this surface's soft keyboard (hardware
// keys are unaffected — they follow first-responder state, which wm drives).
@_silgen_name("micro_os_appkit_toggle_soft_keyboard")
private func micro_os_appkit_toggle_soft_keyboard(_ surface: UnsafeMutableRawPointer?)

// A blue dot in the window chrome, built in SwiftUI to match SwiftUIWindow's own
// traffic-light buttons (same shape/size/alignment, and SwiftUI handles the tap).
private struct KeyboardDot: View {
    let toggle: () -> Void
    var body: some View {
        ZStack {
            Circle().fill(Color.black).frame(width: 19, height: 19)
            Image(systemName: "circle.fill").font(.system(size: 20)).foregroundColor(.blue)
        }
        .contentShape(Circle())
        .onTapGesture { toggle() }
    }
}

@_silgen_name("micro_os_gui_deliver_event")
private func micro_os_gui_deliver_event(
    _ windowID: Int32,
    _ controlID: UnsafePointer<CChar>?,
    _ eventName: UnsafePointer<CChar>?
)

private var hostingControllerAssociationKey: UInt8 = 0

@MainActor
private var modelsByWindowID: [Int32: MacGUIWindowModel] = [:]

private struct MacGUIElement: Identifiable {
    let id: Int
    let kind: String
    let first: String
    let second: String
}

@MainActor
private final class MacGUIWindowModel: ObservableObject {
    @Published var elements: [MacGUIElement]
    var windowID: Int32 = -1

    init(document: String) {
        self.elements = parseDocument(document)
    }

    func update(document: String) {
        elements = parseDocument(document)
    }
}

private struct MacGUIWindowView: View {
    @ObservedObject var model: MacGUIWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.elements) { element in
                    switch element.kind {
                    case "label":
                        Text(element.first)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case "button":
                        Button(element.second.isEmpty ? element.first : element.second) {
                            sendEvent(windowID: model.windowID, controlID: element.first, eventName: "click")
                        }
                        .buttonStyle(.borderedProminent)
                    case "divider":
                        Divider()
                    case "spacer":
                        Spacer(minLength: 12)
                    default:
                        Text(element.first)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        .background(Color(uiColor: .systemBackground))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
}

@_cdecl("entry")
public func entry(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    micro_os_appkit_user_main(argc, argv)
}

/// Open a real platform view (e.g. a CAMetalLayer-backed UIView from the
/// real-surface AppKit shim) as a window through the wm service. This is the
/// same MicroOSWM.openWindow path the structural vcocoa windows use, so a Metal
/// app is displayed by wm exactly like any other vcocoa window. The view is
/// borrowed (unretained); MicroOSWM retains it for the window's lifetime.
/// Returns the window id, or -1 if wm is not running.
@_cdecl("micro_os_vcocoa_open_platform_window")
public func micro_os_vcocoa_open_platform_window(
    _ title: UnsafePointer<CChar>?,
    _ view: UnsafeMutableRawPointer?,
    _ width: Double,
    _ height: Double
) -> Int32 {
    guard let view else { return -1 }
    let platformView = Unmanaged<PlatformOverlayView>.fromOpaque(view).takeUnretainedValue()
    let resolvedTitle = title.map { String(cString: $0) } ?? "Untitled"
    let windowID = MicroOSWM.openWindow(
        title: resolvedTitle,
        platformView: platformView,
        width: width > 0 ? width : 800,
        height: height > 0 ? height : 600
    )
    // Route the wm window's close (X) button back to the shim so it runs the
    // app's own close path (-performClose: -> windowShouldClose: confirm) rather
    // than the window silently vanishing while the process keeps running.
    if windowID >= 0 {
        MicroOSWM.setCloseHandler(windowID: windowID) { wid, _ in
            micro_os_appkit_request_close(wid)
        }
        // A vcocoa surface takes key input: add a SwiftUI keyboard toggle to the
        // chrome. It only shows/hides the soft keyboard — hardware keys follow the
        // active window (wm sets first responder). wm just hosts the view.
        let surfacePtr = view   // raw pointer, valid for the window's lifetime
        MicroOSWM.addChromeView(windowID: windowID, view: AnyView(KeyboardDot {
            micro_os_appkit_toggle_soft_keyboard(surfacePtr)
        }))
    }
    return windowID
}

/// Change a shown window's title (e.g. from the app's SetWindowText equivalent).
@_cdecl("micro_os_vcocoa_set_window_title")
public func micro_os_vcocoa_set_window_title(_ windowID: Int32, _ title: UnsafePointer<CChar>?) {
    MicroOSWM.setTitle(windowID: windowID, title: title.map { String(cString: $0) } ?? "")
}

/// Change a shown window's permission (e.g. "Resize" off for a fixed-size window).
@_cdecl("micro_os_vcocoa_set_window_permission")
public func micro_os_vcocoa_set_window_permission(_ windowID: Int32, _ key: UnsafePointer<CChar>?, _ enabled: Int32) {
    MicroOSWM.setPermission(windowID: windowID, key: key.map { String(cString: $0) } ?? "", enabled: enabled != 0)
}

/// Toggle a shown window to/from fullscreen (the app's -toggleFullScreen:).
@_cdecl("micro_os_vcocoa_set_fullscreen")
public func micro_os_vcocoa_set_fullscreen(_ windowID: Int32, _ on: Int32) {
    MicroOSWM.setFullscreen(windowID: windowID, on: on != 0)
}

@_cdecl("micro_os_gui_host_open_window")
public func micro_os_gui_host_open_window(
    _ title: UnsafePointer<CChar>?,
    _ document: UnsafePointer<CChar>?,
    _ width: Double,
    _ height: Double
) -> Int32 {
    let resolvedTitle = title.map { String(cString: $0) } ?? "Untitled"
    let resolvedDocument = document.map { String(cString: $0) } ?? "v1\n"

    if Thread.isMainThread {
        var result: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            result = openWindowFromProcessThread(title: resolvedTitle, document: resolvedDocument, width: width, height: height)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    return openWindowFromProcessThread(title: resolvedTitle, document: resolvedDocument, width: width, height: height)
}

private func openWindowFromProcessThread(title: String, document: String, width: Double, height: Double) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    var model: MacGUIWindowModel?
    var platformView: PlatformOverlayView?

    DispatchQueue.main.async {
        let payload = MainActor.assumeIsolated {
            makeWindowPayloadOnMain(document: document)
        }
        model = payload.model
        platformView = payload.platformView
        semaphore.signal()
    }
    semaphore.wait()

    guard let model, let platformView else { return -1 }
    let windowID = MicroOSWM.openWindow(
        title: title,
        platformView: platformView,
        width: width > 0 ? width : 560,
        height: height > 0 ? height : 360
    )

    if windowID >= 0 {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                model.windowID = windowID
                modelsByWindowID[windowID] = model
            }
        }
    }
    return windowID
}

@_cdecl("micro_os_gui_host_update_window")
public func micro_os_gui_host_update_window(_ windowID: Int32, _ document: UnsafePointer<CChar>?) -> Int32 {
    let resolvedDocument = document.map { String(cString: $0) } ?? "v1\n"

    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            updateWindowOnMain(windowID: windowID, document: resolvedDocument)
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Int32 = -1
    DispatchQueue.main.async {
        result = MainActor.assumeIsolated {
            updateWindowOnMain(windowID: windowID, document: resolvedDocument)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

@_cdecl("micro_os_gui_host_close_window")
public func micro_os_gui_host_close_window(_ windowID: Int32) -> Int32 {
    DispatchQueue.main.async {
        _ = MainActor.assumeIsolated {
            modelsByWindowID.removeValue(forKey: windowID)
        }
    }
    return 0
}

@MainActor
private func makeWindowPayloadOnMain(document: String) -> (model: MacGUIWindowModel, platformView: PlatformOverlayView) {
    let model = MacGUIWindowModel(document: document)
    let platformView = makePlatformView(rootView: MacGUIWindowView(model: model))
    return (model, platformView)
}

@MainActor
private func updateWindowOnMain(windowID: Int32, document: String) -> Int32 {
    guard let model = modelsByWindowID[windowID] else { return -1 }
    model.update(document: document)
    return 0
}

@MainActor
private func makePlatformView<Content: View>(rootView: Content) -> PlatformOverlayView {
    #if os(macOS)
    return NSHostingView(rootView: rootView)
    #else
    let controller = UIHostingController(rootView: rootView)
    controller.view.backgroundColor = .clear
    let view = controller.view!
    objc_setAssociatedObject(view, &hostingControllerAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return view
    #endif
}

private func sendEvent(windowID: Int32, controlID: String, eventName: String) {
    controlID.withCString { controlPointer in
        eventName.withCString { eventPointer in
            micro_os_gui_deliver_event(windowID, controlPointer, eventPointer)
        }
    }
}

private func parseDocument(_ document: String) -> [MacGUIElement] {
    var elements: [MacGUIElement] = []
    var nextID = 0

    for rawLine in document.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.isEmpty || line == "v1" {
            continue
        }

        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { decodeField(String($0)) }
        guard let kind = parts.first else { continue }
        let first = parts.count > 1 ? parts[1] : ""
        let second = parts.count > 2 ? parts[2] : ""
        elements.append(MacGUIElement(id: nextID, kind: kind, first: first, second: second))
        nextID += 1
    }

    return elements
}

private func decodeField(_ value: String) -> String {
    var bytes: [UInt8] = []
    let scalars = Array(value.utf8)
    var index = 0

    while index < scalars.count {
        if scalars[index] == UInt8(ascii: "%"), index + 2 < scalars.count {
            let hex = String(bytes: scalars[(index + 1)...(index + 2)], encoding: .utf8) ?? ""
            if let byte = UInt8(hex, radix: 16) {
                bytes.append(byte)
                index += 3
                continue
            }
        }

        bytes.append(scalars[index])
        index += 1
    }

    return String(decoding: bytes, as: UTF8.self)
}
