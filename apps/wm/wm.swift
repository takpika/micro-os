import SwiftUI
import SwiftUIWindow
import UIKit
import ObjectiveC

private var hostingControllerAssociationKey: UInt8 = 0
private let desktopController = WindowDesktopController()
private var wmServiceTable = MicroOSWMServiceTable(
    openWindow: wmOpenWindow, setTitle: wmSetTitle, setPermission: wmSetPermission,
    setCloseHandler: wmSetCloseHandler, setFullscreen: wmSetFullscreen,
    addChromeView: wmAddChromeView)

// Move a subview to exactly fill its new parent (used to move the one surface view
// between its window holder and a fullscreen container). Auto Layout pins to the
// edges so it fills regardless of when the parent itself gets sized — autoresizing
// from a zero-size container would otherwise leave it collapsed (black).
@MainActor
private func pinToFill(_ sub: UIView, in parent: UIView) {
    sub.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(sub)   // removing from the old parent drops its old constraints
    NSLayoutConstraint.activate([
        sub.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        sub.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        sub.topAnchor.constraint(equalTo: parent.topAnchor),
        sub.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}
private var wmWindowsByOwner: [Int32: [Int32]] = [:]
private var pendingWindows: [PendingWindowRequest] = []
private var isFlushScheduled = false
// wm's own pid, captured on the process thread at entry. Fullscreen overlays are
// mounted from the main thread (where the per-thread pid isn't wm's), so we pass
// this explicitly.
private var wmOwnPID: Int32 = 0

// Per-window setting closures (SetKey environment values) captured from the
// window's content, so an app can change its title / resizability after it is
// shown. Calls that arrive before the content registers are queued and applied
// on registration.
@MainActor
private final class WindowControls {
    var titleSet: ((String) -> Void)?
    var permSet: ((String, Bool) -> Void)?
    var pendingTitle: String?
    var pendingPerms: [(String, Bool)] = []
    // Set by the owning app (via the wm service) so the close (X) button defers
    // to the app's own close path instead of just removing the window.
    var closeHandler: MicroOSWMCloseHandler?
    var closeHandlerCtx: UnsafeMutableRawPointer?
    // Fullscreen state. The single surface view lives in `holder` (in the window)
    // or, while fullscreen, in `fsContainer` (a layer stacked on top via overlay).
    var surfaceView: UIView?
    var holder: UIView?
    var fsContainer: UIView?
    var fsHosting: UIViewController?   // retains the hosting controller while fullscreen
    var fsOverlayID: Int32?
    // Chrome action-bar (beside the traffic lights). The owning app adds buttons via
    // the wm service; requests arriving before the bar is captured are queued.
    var actionBarAdd: ((AnyView) -> String)?
    var pendingActionButtons: [AnyView] = []
}

@MainActor private var wmControlsByID: [Int32: WindowControls] = [:]

@MainActor
private func registerWindowControls(id: Int32,
                                    titleSet: ((String) -> Void)?,
                                    permSet: ((String, Bool) -> Void)?,
                                    actionBarAdd: ((AnyView) -> String)?) {
    let controls = wmControlsByID[id] ?? WindowControls()
    controls.titleSet = titleSet
    controls.permSet = permSet
    controls.actionBarAdd = actionBarAdd
    if let title = controls.pendingTitle { titleSet?(title); controls.pendingTitle = nil }
    for (key, value) in controls.pendingPerms { permSet?(key, value) }
    controls.pendingPerms = []
    if let add = actionBarAdd {
        for view in controls.pendingActionButtons { _ = add(view) }
        controls.pendingActionButtons = []
    }
    wmControlsByID[id] = controls
}

// Generic chrome items: the app hands wm a SwiftUI view (built in SwiftUI, so it
// aligns/taps exactly like the traffic lights, and owns its own behavior); wm just
// slots it into the action bar. The keyboard toggle is one such view.
@MainActor private var nextChromeItemID: Int32 = 1

@MainActor
private func addChromeViewNow(windowID: Int32, view: AnyView) -> Int32 {
    let id = nextChromeItemID
    nextChromeItemID += 1
    let controls = wmControlsByID[windowID] ?? WindowControls()
    if let add = controls.actionBarAdd { _ = add(view) }
    else { controls.pendingActionButtons.append(view) }
    wmControlsByID[windowID] = controls
    return id
}

private let wmAddChromeView: MicroOSWMAddChromeViewCallback = { windowID, viewPtr in
    guard let viewPtr else { return -1 }
    let view = Unmanaged<MicroOSChromeViewBox>.fromOpaque(viewPtr).takeRetainedValue().view
    if Thread.isMainThread {
        return MainActor.assumeIsolated { addChromeViewNow(windowID: windowID, view: view) }
    }
    let sem = DispatchSemaphore(value: 0)
    var result: Int32 = -1
    DispatchQueue.main.async {
        MainActor.assumeIsolated { result = addChromeViewNow(windowID: windowID, view: view); sem.signal() }
    }
    sem.wait()
    return result
}

private let wmSetTitle: MicroOSWMSetTitleCallback = { windowID, titleC in
    let title = titleC.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let controls = wmControlsByID[windowID] ?? WindowControls()
            if let setter = controls.titleSet { setter(title) } else { controls.pendingTitle = title }
            wmControlsByID[windowID] = controls
        }
    }
}

private let wmSetPermission: MicroOSWMSetPermissionCallback = { windowID, keyC, enabled in
    let key = keyC.map { String(cString: $0) } ?? ""
    let on = enabled != 0
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let controls = wmControlsByID[windowID] ?? WindowControls()
            if let setter = controls.permSet { setter(key, on) } else { controls.pendingPerms.append((key, on)) }
            wmControlsByID[windowID] = controls
        }
    }
}

// The app registers a close handler so the X button routes back to it (e.g. to
// show a quit-confirm and tear down cleanly) instead of the window just vanishing.
private let wmSetCloseHandler: MicroOSWMSetCloseHandlerCallback = { windowID, handler, ctx in
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let controls = wmControlsByID[windowID] ?? WindowControls()
            controls.closeHandler = handler
            controls.closeHandlerCtx = ctx
            wmControlsByID[windowID] = controls
        }
    }
}

// Called by SwiftUIWindow when the user taps a window's close (X) button. If the
// owning app registered a close handler, defer to it (it decides whether/when to
// actually close); otherwise fall back to removing the window locally.
@MainActor
private func handleWindowClose(id: Int) -> Bool {
    if let controls = wmControlsByID[Int32(id)], let handler = controls.closeHandler {
        handler(Int32(id), controls.closeHandlerCtx)
        return false   // app drives the real close (on its exit -> processExitObserver)
    }
    return true        // no handler: let SwiftUIWindow close it
}

// The app's -toggleFullScreen: ends up here. wm keeps the desktop window in place
// and moves the one surface view to a full-screen layer stacked on top (on), or
// back into its window holder (off). Nothing is recreated; only the parent changes.
private let wmSetFullscreen: MicroOSWMSetFullscreenCallback = { windowID, on in
    let enable = on != 0
    DispatchQueue.main.async {
        MainActor.assumeIsolated { setWindowFullscreen(windowID: windowID, on: enable) }
    }
}

@MainActor
private func setWindowFullscreen(windowID: Int32, on: Bool) {
    guard let controls = wmControlsByID[windowID],
          let surface = controls.surfaceView, let holder = controls.holder else { return }
    if on {
        guard controls.fsOverlayID == nil else { return }   // already fullscreen
        // Mirror how wm shows its own desktop: a UIHostingController-backed SwiftUI
        // view, mounted as a fullscreen overlay. SwiftUI sizes it edge-to-edge; the
        // one surface view just moves into the container it hosts.
        let container = UIView()
        container.backgroundColor = .black
        pinToFill(surface, in: container)                    // holder -> container
        let hosting = UIHostingController(rootView: FullscreenSurfaceView(container: container))
        hosting.view.backgroundColor = .black
        controls.fsHosting = hosting
        controls.fsContainer = container
        controls.fsOverlayID = MicroOS.overlayFullscreen(hosting.view, ownerPID: wmOwnPID)
    } else {
        guard let id = controls.fsOverlayID else { return }  // already windowed
        pinToFill(surface, in: holder)                       // container -> holder
        MicroOS.overlayRemove(id, ownerPID: wmOwnPID)
        controls.fsOverlayID = nil
        controls.fsContainer = nil
        controls.fsHosting = nil
    }
}

// Hosts the surface container as a full-bleed SwiftUI view (same shape as the wm
// desktop root), so a UIHostingController sizes it edge-to-edge.
private struct SurfaceHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct FullscreenSurfaceView: View {
    let container: UIView
    var body: some View {
        SurfaceHost(view: container).ignoresSafeArea()
    }
}

private final class PendingWindowRequest {
    let ownerPID: Int32
    let title: String
    var view: UIView?
    let width: Double
    let height: Double
    let semaphore: DispatchSemaphore
    var result: Int32 = -1

    init(ownerPID: Int32, title: String, width: Double, height: Double) {
        self.ownerPID = ownerPID
        self.title = title
        self.width = width
        self.height = height
        self.semaphore = DispatchSemaphore(value: 0)
    }
}

private let wmOpenWindow: MicroOSWMOpenWindowCallback = { ownerPID, title, retainedPlatformView, width, height in
    guard let retainedPlatformView else { return -1 }
    let resolvedTitle = title.map { String(cString: $0) } ?? "Untitled"
    let request = PendingWindowRequest(
        ownerPID: ownerPID,
        title: resolvedTitle,
        width: width,
        height: height
    )

    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let object = Unmanaged<AnyObject>.fromOpaque(retainedPlatformView).takeRetainedValue()
            guard let view = object as? UIView else {
                request.semaphore.signal()
                return
            }

            request.view = view
            if desktopController.isAttached {
                openWindowNow(request)
            } else {
                pendingWindows.append(request)
                scheduleFlushPendingWindows()
            }
        }
    }

    request.semaphore.wait()
    return request.result
}

private let processExitObserver: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { pid, _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let windowIDs = wmWindowsByOwner.removeValue(forKey: pid) else { return }
            for windowID in windowIDs {
                if let id = wmControlsByID[windowID]?.fsOverlayID {
                    MicroOS.overlayRemove(id, ownerPID: wmOwnPID)   // drop any fullscreen layer it left up
                }
                wmControlsByID.removeValue(forKey: windowID)
                desktopController.closeWindow(id: Int(windowID))
            }
        }
    }
}

private struct HostedPlatformView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The window injects its setting closures into the content's environment;
        // capture them (keyed by this window's id) so the app can drive them.
        if let idGet = context.environment.windowIDGetKey {
            let id = Int32(idGet())
            let titleSet = context.environment.titleSetKey
            let permSet = context.environment.permission_SetKey
            let actionBarAdd = context.environment.actionBarAddKey
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    registerWindowControls(id: id, titleSet: titleSet, permSet: permSet,
                                           actionBarAdd: actionBarAdd)
                }
            }
        }
    }
}

struct WindowManagerRoot: View {
    var body: some View {
        WindowDesktop(controller: desktopController) {
        } background: {
            Color.black
        }
        .ignoresSafeArea()
        .onAppear {
            scheduleFlushPendingWindows()
        }
        // Keyboard focus follows the active window: make its surface first responder
        // so iOS delivers hardware keys (and the soft keyboard, when toggled) there.
        // The previously focused surface resigns automatically.
        .onReceive(desktopController.$activeWindowID) { newID in
            MainActor.assumeIsolated {
                if let id = newID {
                    wmControlsByID[Int32(id)]?.surfaceView?.becomeFirstResponder()
                }
            }
        }
    }
}

@_cdecl("entry")
public func entry(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    wmOwnPID = MicroOS.pid   // captured here on wm's process thread (correct pid)
    let initialApp = parseInitialApp(argc: argc, argv: argv)
    let platformView = makeWindowManagerPlatformView()

    MicroOS.overlayFullscreen(platformView)
    MicroOSWM.register(&wmServiceTable)
    MicroOS.observeProcessExit(processExitObserver, context: nil)

    if let initialApp {
        let pid = MicroOS.spawn(dylib: initialApp.dylib, arguments: initialApp.arguments)
        if pid < 0 {
            MicroOS.stderr("wm: failed to launch initial app: \(initialApp.dylib)\n")
        }
    }

    MicroOS.keepAlive()
    return 0
}

private func parseInitialApp(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> (dylib: String, arguments: [String])? {
    guard let argv, argc > 1, let first = argv[1] else { return nil }

    let value = String(cString: first)
    let dylib = value.hasSuffix(".dylib") ? value : "\(value).dylib"
    var arguments: [String] = []

    if argc > 2 {
        for index in 2..<Int(argc) {
            guard let item = argv[index] else { continue }
            arguments.append(String(cString: item))
        }
    }

    return (dylib, arguments)
}

private func makeWindowManagerPlatformView() -> UIView {
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            makeWindowManagerPlatformViewOnMain()
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: UIView?
    DispatchQueue.main.async {
        result = MainActor.assumeIsolated {
            makeWindowManagerPlatformViewOnMain()
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

@MainActor
private func makeWindowManagerPlatformViewOnMain() -> UIView {
    let controller = UIHostingController(rootView: WindowManagerRoot())
    controller.view.backgroundColor = .clear

    let platformView = controller.view!
    objc_setAssociatedObject(platformView, &hostingControllerAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return platformView
}

@MainActor
private func flushPendingWindows() {
    isFlushScheduled = false
    guard desktopController.isAttached else {
        scheduleFlushPendingWindows()
        return
    }

    let requests = pendingWindows
    pendingWindows.removeAll()
    for request in requests {
        openWindowNow(request)
    }
}

@MainActor
private func scheduleFlushPendingWindows() {
    guard !pendingWindows.isEmpty, !isFlushScheduled else { return }
    isFlushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        MainActor.assumeIsolated {
            flushPendingWindows()
        }
    }
}

// An app's requested size is its CONTENT (client) area in its own units — e.g. a
// macOS app's -initWithContentRect: of 800x600 render pixels. WindowConfig.size
// is the content area too (SwiftUIWindow adds the title bar on top), so just fit
// the content to the desktop preserving the requested aspect; the renderer keeps
// its own pixel resolution and scales to fill it.
@MainActor
private func fitWindowSize(_ requested: CGSize) -> CGSize {
    let screen = UIScreen.main.bounds.size
    guard requested.width > 0, requested.height > 0, screen.width > 0, screen.height > 0 else {
        return requested
    }
    let aspect = requested.width / requested.height
    let maxWidth = screen.width * 0.98
    let maxHeight = screen.height * 0.62   // leaves room for the toolbar + title bar + margins
    var width = maxWidth
    var height = width / aspect
    if height > maxHeight {
        height = maxHeight
        width = height * aspect
    }
    return CGSize(width: width, height: height)
}

@MainActor
private func openWindowNow(_ request: PendingWindowRequest) {
    guard let view = request.view else {
        request.semaphore.signal()
        return
    }

    // The window hosts a stable `holder`; the actual surface view lives inside it.
    // Fullscreen later moves the surface out to an on-top layer and back, without
    // SwiftUIWindow ever losing its hosted view.
    let holder = UIView()
    holder.backgroundColor = .black
    pinToFill(view, in: holder)
    let hosted = HostedPlatformView(view: holder)
    let requested = CGSize(
        width: request.width > 0 ? request.width : 560,
        height: request.height > 0 ? request.height : 360
    )
    var config = WindowConfig(
        title: request.title,
        size: fitWindowSize(requested),
        startPos: .center
    )
    // Route the X button back to the owning app (if it registered a handler) so it
    // can confirm/clean up; returning false keeps the window until the app exits.
    config.onClose = { id in handleWindowClose(id: id) }

    if let windowID = desktopController.addWindow(config: config, content: { hosted }) {
        request.result = Int32(windowID)
        let controls = wmControlsByID[Int32(windowID)] ?? WindowControls()
        controls.surfaceView = view
        controls.holder = holder
        wmControlsByID[Int32(windowID)] = controls
        var ownerWindows = wmWindowsByOwner[request.ownerPID] ?? []
        ownerWindows.append(request.result)
        wmWindowsByOwner[request.ownerPID] = ownerWindows
    }
    request.semaphore.signal()
}
