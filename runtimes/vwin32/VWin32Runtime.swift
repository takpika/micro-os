import Foundation
import SwiftUI
import ObjectiveC

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@_silgen_name("micro_os_win32_user_main")
private func micro_os_win32_user_main(
    _ instance: UnsafeMutableRawPointer?,
    _ previousInstance: UnsafeMutableRawPointer?,
    _ commandLine: UnsafeMutablePointer<CChar>?,
    _ commandShow: Int32
) -> Int32

@_silgen_name("micro_os_gui_deliver_event")
private func micro_os_gui_deliver_event(
    _ windowID: Int32,
    _ controlID: UnsafePointer<CChar>?,
    _ eventName: UnsafePointer<CChar>?
)

private var hostingControllerAssociationKey: UInt8 = 0

@MainActor
private var modelsByWindowID: [Int32: Win32WindowModel] = [:]

private struct Win32Element: Identifiable {
    let id: Int
    let kind: String
    let first: String
    let second: String
}

@MainActor
private final class Win32WindowModel: ObservableObject {
    @Published var elements: [Win32Element]
    var windowID: Int32 = -1

    init(document: String) {
        self.elements = parseDocument(document)
    }

    func update(document: String) {
        elements = parseDocument(document)
    }
}

private struct Win32WindowView: View {
    @ObservedObject var model: Win32WindowModel

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
    var commandLine = makeCommandLine(argc: argc, argv: argv)
    return commandLine.withUnsafeMutableBufferPointer { buffer in
        micro_os_win32_user_main(nil, nil, buffer.baseAddress, 10)
    }
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
    var model: Win32WindowModel?
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
private func makeWindowPayloadOnMain(document: String) -> (model: Win32WindowModel, platformView: PlatformOverlayView) {
    let model = Win32WindowModel(document: document)
    let platformView = makePlatformView(rootView: Win32WindowView(model: model))
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

private func parseDocument(_ document: String) -> [Win32Element] {
    var elements: [Win32Element] = []
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
        elements.append(Win32Element(id: nextID, kind: kind, first: first, second: second))
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

private func makeCommandLine(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [CChar] {
    guard let argv, argc > 1 else { return [0] }
    var parts: [String] = []
    for index in 1..<Int(argc) {
        guard let item = argv[index] else { continue }
        parts.append(String(cString: item))
    }
    return Array(parts.joined(separator: " ").utf8CString)
}
