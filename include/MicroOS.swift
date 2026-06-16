import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

@_silgen_name("micro_os_pid")
private func micro_os_pid() -> Int32

@_silgen_name("micro_os_stdout")
private func micro_os_stdout(_ text: UnsafePointer<CChar>?)

@_silgen_name("micro_os_stderr")
private func micro_os_stderr(_ text: UnsafePointer<CChar>?)

@_silgen_name("micro_os_stdin")
private func micro_os_stdin(_ buffer: UnsafeMutablePointer<CChar>?, _ maxBytes: Int32) -> Int32

@_silgen_name("micro_os_overlay_platform_view_fullscreen")
private func micro_os_overlay_platform_view_fullscreen(_ retainedPlatformView: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("micro_os_overlay_platform_view")
private func micro_os_overlay_platform_view(
    _ retainedPlatformView: UnsafeMutableRawPointer?,
    _ x: Double,
    _ y: Double,
    _ width: Double,
    _ height: Double
) -> Int32

@_silgen_name("micro_os_overlay_remove")
private func micro_os_overlay_remove(_ overlayID: Int32)

@_silgen_name("micro_os_overlay_platform_view_fullscreen_for_pid")
private func micro_os_overlay_platform_view_fullscreen_for_pid(_ retainedPlatformView: UnsafeMutableRawPointer?, _ pid: Int32) -> Int32

@_silgen_name("micro_os_overlay_remove_for_pid")
private func micro_os_overlay_remove_for_pid(_ overlayID: Int32, _ pid: Int32)

@_silgen_name("micro_os_kernel_panic")
private func micro_os_kernel_panic(_ text: UnsafePointer<CChar>?)

@_silgen_name("micro_os_service_register")
private func micro_os_service_register(_ name: UnsafePointer<CChar>?, _ serviceTable: UnsafeMutableRawPointer?)

@_silgen_name("micro_os_service_lookup")
private func micro_os_service_lookup(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("micro_os_process_observe_exit")
private func micro_os_process_observe_exit(
    _ callback: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
)

@_silgen_name("micro_os_ptty_create")
private func micro_os_ptty_create(_ name: UnsafePointer<CChar>?) -> Int32

@_silgen_name("micro_os_ptty_write")
private func micro_os_ptty_write(_ id: Int32, _ text: UnsafePointer<CChar>?)

@_silgen_name("micro_os_ptty_input")
private func micro_os_ptty_input(_ id: Int32, _ text: UnsafePointer<CChar>?)

@_silgen_name("micro_os_ptty_read")
private func micro_os_ptty_read(_ id: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ maxBytes: Int32) -> Int32

@_silgen_name("micro_os_ptty_observe_output")
private func micro_os_ptty_observe_output(
    _ id: Int32,
    _ callback: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
)

@_silgen_name("micro_os_process_keep_alive")
private func micro_os_process_keep_alive()

@_silgen_name("micro_os_process_exit")
private func micro_os_process_exit(_ code: Int32) -> Never

@_silgen_name("micro_os_spawn")
private func micro_os_spawn(
    _ dylib: UnsafePointer<CChar>?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("micro_os_spawn_with_tty")
private func micro_os_spawn_with_tty(
    _ dylib: UnsafePointer<CChar>?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ ttyID: Int32
) -> Int32

public enum MicroOS {
    public static var pid: Int32 {
        micro_os_pid()
    }

    public static func stdout(_ text: String) {
        text.withCString { micro_os_stdout($0) }
    }

    public static func stderr(_ text: String) {
        text.withCString { micro_os_stderr($0) }
    }

    public static func stdin(maxBytes: Int = 4096) -> String {
        let capacity = max(1, maxBytes)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let count = micro_os_stdin(buffer, Int32(capacity))
        guard count > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Mount a platform view as a full-console overlay. Returns an overlay id that
    /// can be passed to `overlayRemove` to take just this overlay down later.
    @discardableResult
    public static func overlayFullscreen(_ platformView: PlatformOverlayView) -> Int32 {
        let retained = Unmanaged.passRetained(platformView).toOpaque()
        return micro_os_overlay_platform_view_fullscreen(retained)
    }

    @discardableResult
    public static func overlay(
        _ platformView: PlatformOverlayView,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> Int32 {
        let retained = Unmanaged.passRetained(platformView).toOpaque()
        return micro_os_overlay_platform_view(retained, x, y, width, height)
    }

    /// Remove one overlay this process previously added, by the id it returned.
    public static func overlayRemove(_ overlayID: Int32) {
        micro_os_overlay_remove(overlayID)
    }

    /// Mount/remove an overlay owned by an explicit pid. Used by a display server
    /// (wm) that adds an overlay from the main thread on its own behalf, where the
    /// per-thread pid would otherwise be wrong.
    @discardableResult
    public static func overlayFullscreen(_ platformView: PlatformOverlayView, ownerPID: Int32) -> Int32 {
        let retained = Unmanaged.passRetained(platformView).toOpaque()
        return micro_os_overlay_platform_view_fullscreen_for_pid(retained, ownerPID)
    }

    public static func overlayRemove(_ overlayID: Int32, ownerPID: Int32) {
        micro_os_overlay_remove_for_pid(overlayID, ownerPID)
    }

    public static func kernelPanic(_ text: String) {
        text.withCString { micro_os_kernel_panic($0) }
    }

    public static func registerService(name: String, table: UnsafeMutableRawPointer) {
        name.withCString { micro_os_service_register($0, table) }
    }

    public static func lookupService(name: String) -> UnsafeMutableRawPointer? {
        name.withCString { micro_os_service_lookup($0) }
    }

    public static func observeProcessExit(
        _ callback: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?,
        context: UnsafeMutableRawPointer?
    ) {
        micro_os_process_observe_exit(callback, context)
    }

    public static func createPseudoTTY(name: String) -> Int32 {
        name.withCString { micro_os_ptty_create($0) }
    }

    public static func writePseudoTTY(_ id: Int32, _ text: String) {
        text.withCString { micro_os_ptty_write(id, $0) }
    }

    public static func inputPseudoTTY(_ id: Int32, _ text: String) {
        text.withCString { micro_os_ptty_input(id, $0) }
    }

    public static func readPseudoTTY(_ id: Int32, maxBytes: Int = 4096) -> String {
        let capacity = max(1, maxBytes)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        let count = micro_os_ptty_read(id, buffer, Int32(capacity))
        guard count > 0 else { return "" }
        return String(cString: buffer)
    }

    public static func observePseudoTTYOutput(
        _ id: Int32,
        callback: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
        context: UnsafeMutableRawPointer?
    ) {
        micro_os_ptty_observe_output(id, callback, context)
    }

    public static func keepAlive() {
        micro_os_process_keep_alive()
    }

    public static func exit(_ code: Int32) -> Never {
        micro_os_process_exit(code)
    }

    public static func spawn(dylib: String, arguments: [String] = []) -> Int32 {
        var cStrings = arguments.map { strdup($0) }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }

        return dylib.withCString { dylibPointer in
            cStrings.withUnsafeMutableBufferPointer { buffer in
                micro_os_spawn(dylibPointer, Int32(buffer.count), buffer.baseAddress)
            }
        }
    }

    public static func spawn(dylib: String, arguments: [String] = [], ttyID: Int32) -> Int32 {
        var cStrings = arguments.map { strdup($0) }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }

        return dylib.withCString { dylibPointer in
            cStrings.withUnsafeMutableBufferPointer { buffer in
                micro_os_spawn_with_tty(dylibPointer, Int32(buffer.count), buffer.baseAddress, ttyID)
            }
        }
    }
}

#if os(macOS)
public typealias PlatformOverlayView = NSView
#elseif os(iOS) || os(tvOS) || os(visionOS)
public typealias PlatformOverlayView = UIView
#endif

public typealias MicroOSWMOpenWindowCallback = @convention(c) (
    Int32,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?,
    Double,
    Double
) -> Int32

// v2: change a shown window's settings after the fact (title; permissions such
// as "Resize"/"Close"/"Minimum"). windowID is the value openWindow returned.
public typealias MicroOSWMSetTitleCallback = @convention(c) (
    Int32, UnsafePointer<CChar>?
) -> Void

public typealias MicroOSWMSetPermissionCallback = @convention(c) (
    Int32, UnsafePointer<CChar>?, Int32
) -> Void

// v3: register a close-request handler. wm invokes it when the user activates the
// window's close (X) button, so the owning app can run its own close path (e.g.
// AppKit -performClose: -> windowShouldClose: confirm) instead of the window
// vanishing while the process keeps running. windowID is openWindow's return.
public typealias MicroOSWMCloseHandler = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void
public typealias MicroOSWMSetCloseHandlerCallback = @convention(c) (
    Int32, MicroOSWMCloseHandler?, UnsafeMutableRawPointer?
) -> Void

// v4: full-screen a window. The owning surface stays the same view; wm moves it
// from its window into a full-screen layer stacked on top of the desktop (and back
// out on off=0), so the app's -toggleFullScreen: just flips this.
public typealias MicroOSWMSetFullscreenCallback = @convention(c) (Int32, Int32) -> Void

// v5: add an arbitrary SwiftUI view to a window's chrome action bar, beside the
// traffic lights — mirroring SwiftUIWindow's action bar, which takes a view. The
// app builds the view in SwiftUI (so it aligns and taps exactly like the traffic
// lights) and owns its behavior; wm only slots it in. The keyboard toggle is just
// one such view. The boxed view is consumed; returns a chrome-item id.
public typealias MicroOSWMAddChromeViewCallback = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32

// Box used to hand a SwiftUI AnyView across the C-ABI service boundary (single
// address space — the pointer is a retained box the receiver unwraps).
public final class MicroOSChromeViewBox {
    public let view: AnyView
    public init(_ view: AnyView) { self.view = view }
}

public struct MicroOSWMServiceTable {
    public var version: Int32
    public var openWindow: MicroOSWMOpenWindowCallback?
    public var setTitle: MicroOSWMSetTitleCallback?
    public var setPermission: MicroOSWMSetPermissionCallback?
    public var setCloseHandler: MicroOSWMSetCloseHandlerCallback?
    public var setFullscreen: MicroOSWMSetFullscreenCallback?
    public var addChromeView: MicroOSWMAddChromeViewCallback?

    public init(version: Int32 = 5,
                openWindow: MicroOSWMOpenWindowCallback?,
                setTitle: MicroOSWMSetTitleCallback? = nil,
                setPermission: MicroOSWMSetPermissionCallback? = nil,
                setCloseHandler: MicroOSWMSetCloseHandlerCallback? = nil,
                setFullscreen: MicroOSWMSetFullscreenCallback? = nil,
                addChromeView: MicroOSWMAddChromeViewCallback? = nil) {
        self.version = version
        self.openWindow = openWindow
        self.setTitle = setTitle
        self.setPermission = setPermission
        self.setCloseHandler = setCloseHandler
        self.setFullscreen = setFullscreen
        self.addChromeView = addChromeView
    }
}

public enum MicroOSWM {
    public static let serviceName = "micro-os.wm.v1"

    public static func register(_ table: UnsafeMutablePointer<MicroOSWMServiceTable>) {
        MicroOS.registerService(name: serviceName, table: UnsafeMutableRawPointer(table))
    }

    public static func lookup() -> UnsafeMutablePointer<MicroOSWMServiceTable>? {
        guard let raw = MicroOS.lookupService(name: serviceName) else { return nil }
        return raw.assumingMemoryBound(to: MicroOSWMServiceTable.self)
    }

    @discardableResult
    public static func openWindow(
        title: String,
        platformView: PlatformOverlayView,
        width: Double = 560,
        height: Double = 360
    ) -> Int32 {
        guard let service = lookup(), service.pointee.version >= 1, let openWindow = service.pointee.openWindow else {
            return -1
        }

        let retained = Unmanaged.passRetained(platformView).toOpaque()
        let ownerPID = MicroOS.pid
        let callOpenWindow = {
            title.withCString { titlePointer in
                openWindow(ownerPID, titlePointer, retained, width, height)
            }
        }

        guard Thread.isMainThread else {
            return callOpenWindow()
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Int32 = -1
        DispatchQueue.global(qos: .userInitiated).async {
            result = callOpenWindow()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    public static func setTitle(windowID: Int32, title: String) {
        guard let service = lookup(), service.pointee.version >= 2,
              let setTitle = service.pointee.setTitle else { return }
        title.withCString { setTitle(windowID, $0) }
    }

    public static func setPermission(windowID: Int32, key: String, enabled: Bool) {
        guard let service = lookup(), service.pointee.version >= 2,
              let setPermission = service.pointee.setPermission else { return }
        key.withCString { setPermission(windowID, $0, enabled ? 1 : 0) }
    }

    public static func setCloseHandler(windowID: Int32,
                                       handler: MicroOSWMCloseHandler?,
                                       context: UnsafeMutableRawPointer? = nil) {
        guard let service = lookup(), service.pointee.version >= 3,
              let setCloseHandler = service.pointee.setCloseHandler else { return }
        setCloseHandler(windowID, handler, context)
    }

    public static func setFullscreen(windowID: Int32, on: Bool) {
        guard let service = lookup(), service.pointee.version >= 4,
              let setFullscreen = service.pointee.setFullscreen else { return }
        setFullscreen(windowID, on ? 1 : 0)
    }

    /// Add a SwiftUI view to a window's chrome action bar (beside the traffic
    /// lights). Returns a chrome-item id, or -1 if wm is too old / not running.
    @discardableResult
    public static func addChromeView(windowID: Int32, view: AnyView) -> Int32 {
        guard let service = lookup(), service.pointee.version >= 5,
              let addChromeView = service.pointee.addChromeView else { return -1 }
        let box = MicroOSChromeViewBox(view)
        return addChromeView(windowID, Unmanaged.passRetained(box).toOpaque())
    }
}
