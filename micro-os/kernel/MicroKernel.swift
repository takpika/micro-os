import SwiftUI
import Foundation
import Combine
import Darwin

@MainActor
final class MicroKernel: ObservableObject {
    @Published private(set) var consoleLines: [ConsoleLine] = []
    @Published private(set) var overlays: [UIOverlay] = []

    private var nextPID: Int32 = 100
    private var nextTTYID: Int32 = 0
    private var processes: [Int32: ProcessControlBlock] = [:]
    private var pttys: [Int32: PseudoTTY] = [:]
    private var initialProcessPID: Int32?
    private let ansiParser = ANSIConsoleParser()
    private let defaultTTY = PseudoTTY(id: 0, name: "console0")
    private let homeDirectory: String
    private var externalTTYBridges: [Int32: ExternalTTYBridge] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        homeDirectory = support?.appendingPathComponent("micro-os-home", isDirectory: true).path ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
        externalTTYBridges[defaultTTY.id] = ExternalTTYBridge(ttyID: defaultTTY.id)
        pttys[defaultTTY.id] = defaultTTY
    }

    func boot() {
        externalTTYBridges[defaultTTY.id]?.start { [weak self] text in
            self?.enqueueStdin(text)
        }
        log(.system, "boot: pthread kernel online")
        log(.system, "boot: default tty = \(defaultTTY.name) (SwiftUI console ptty)")
        log(.system, "boot: HOME=\(homeDirectory)")
        if let bridge = externalTTYBridges[defaultTTY.id] {
            log(.system, "boot: host tty socket=\(bridge.socketPath)")
        }
        log(.stdout, "ready. launch a dylib exporting: int entry(int argc, char **argv)")
    }

    @discardableResult
    func launch(
        dylib: String,
        argv: [String],
        ttyID: Int32 = 0,
        parentPID: Int32 = 0,
        reservedPID: Int32? = nil,
        inheritFDs: Bool = true
    ) -> Int32 {
        guard let resolvedDylib = resolveLaunchDylib(dylib) else {
            return -1
        }
        let pid = reservedPID ?? allocatePID()
        guard processes[pid] == nil else {
            log(.stderr, "exec: pid=\(pid) already running")
            return -1
        }
        // argv[0] is the command name (basename, no ".dylib"), not the resolved
        // dylib path — multicall binaries like toybox dispatch on basename(argv[0]),
        // so "toybox.dylib" would be an unknown applet. normalizedSpawnArguments
        // already de-dups a redundant caller-supplied argv[0].
        let commandName = ((resolvedDylib as NSString).lastPathComponent as NSString).deletingPathExtension
        var processArgv = [commandName.isEmpty ? resolvedDylib : commandName]
        processArgv.append(contentsOf: argv)
        let pcb = ProcessControlBlock(
            pid: pid,
            dylib: resolvedDylib,
            argv: processArgv,
            home: homeDirectory,
            ttyID: pttys[ttyID] == nil ? defaultTTY.id : ttyID,
            parentPID: parentPID
        )
        processes[pid] = pcb
        HostABI.shared.registerProcessParent(pid: pid, parentPID: parentPID)
        if inheritFDs {
            HostABI.shared.prepareProcessFDs(pid: pid, parentPID: parentPID)
        }

        let boot = ProcessBootInfo(pcb: pcb)
        var thread = pthread_t(bitPattern: 0)
        let result = pthread_create(&thread, nil, processMain, Unmanaged.passRetained(boot).toOpaque())
        if result == 0 {
            pcb.thread = thread
            pthread_detach(thread!)
            return pid
        } else {
            processes.removeValue(forKey: pid)
            log(.stderr, "exec: pthread_create failed errno=\(result)")
            return -1
        }
    }

    func allocateForkPID() -> Int32 {
        allocatePID()
    }

    private func resolveLaunchDylib(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }

        if name.contains("/") {
            let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
                .path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        // Bare command name: normalize to a dylib filename and let the loader
        // resolve it against the bundle (with the toybox multicall fallback).
        return (name as NSString).pathExtension.isEmpty ? "\(name).dylib" : name
    }

    func monitorInitialProcess(pid: Int32) {
        guard pid > 0 else { return }
        initialProcessPID = pid
    }

    func write(pid: Int32, stream: TTYStream, text: String) {
        if let ttyID = processes[pid]?.ttyID, ttyID != defaultTTY.id, stream == .stdout || stream == .stderr {
            pttys[ttyID]?.write(text)
            externalTTYBridges[ttyID]?.appendOutput(text)
            return
        }
        append(stream, text)
    }

    func readStdin(pid: Int32, maxBytes: Int) -> String {
        if let ttyID = processes[pid]?.ttyID, ttyID != defaultTTY.id {
            return pttys[ttyID]?.read(maxBytes: maxBytes) ?? ""
        }
        return defaultTTY.read(maxBytes: maxBytes)
    }

    func ttyID(pid: Int32) -> Int32 {
        processes[pid]?.ttyID ?? defaultTTY.id
    }

    func enqueueStdin(_ text: String) {
        let echo = defaultTTY.enqueueInput(text)
        if defaultTTY.shouldEchoInput(), !echo.isEmpty {
            write(pid: 0, stream: .stdout, text: echo)
        }
    }

    func createPseudoTTY(name: String) -> Int32 {
        nextTTYID += 1
        let tty = PseudoTTY(id: nextTTYID, name: name.isEmpty ? "ptty\(nextTTYID)" : name)
        pttys[tty.id] = tty
        let bridge = ExternalTTYBridge(ttyID: tty.id)
        externalTTYBridges[tty.id] = bridge
        bridge.start { [weak self] text in
            self?.enqueuePseudoTTYInput(id: tty.id, text: text)
        }
        log(.system, "ptty: created \(tty.name) id=\(tty.id)")
        log(.system, "ptty: \(tty.name) host socket=\(bridge.socketPath)")
        return tty.id
    }

    func writePseudoTTY(id: Int32, text: String) {
        pttys[id]?.write(text)
    }

    func enqueuePseudoTTYInput(id: Int32, text: String) {
        guard let tty = pttys[id] else { return }
        let echo = tty.enqueueInput(text)
        if tty.shouldEchoInput(), !echo.isEmpty {
            tty.write(echo)
        }
    }

    func ttyLocalFlags(pid: Int32) -> UInt32 {
        let id = ttyID(pid: pid)
        return pttys[id]?.getLocalFlags() ?? defaultTTY.getLocalFlags()
    }

    func setTTYLocalFlags(pid: Int32, flags: UInt32) {
        let id = ttyID(pid: pid)
        (pttys[id] ?? defaultTTY).setLocalFlags(flags)
    }

    func readPseudoTTY(id: Int32, maxBytes: Int) -> String {
        pttys[id]?.read(maxBytes: maxBytes) ?? ""
    }

    func observePseudoTTYOutput(
        pid: Int32,
        id: Int32,
        callback: @escaping PseudoTTYOutputObserverCallback,
        context: UnsafeMutableRawPointer?
    ) {
        pttys[id]?.addOutputObserver(pid: pid, callback: callback, context: context)
    }

    func addPlatformOverlay(pid: Int32, overlayID: Int32, object: AnyObject, x: Double, y: Double, width: Double, height: Double) {
        guard processes[pid] != nil else { return }
        let overlay = UIOverlay(
            pid: pid,
            overlayID: overlayID,
            object: object,
            frame: UIOverlayFrame(
                x: x,
                y: y,
                width: width > 0 ? width : nil,
                height: height > 0 ? height : nil,
                isFullscreen: false
            )
        )
        overlays.append(overlay)
        log(.system, "[pid \(pid)] ui: overlay mounted")
    }

    func addFullscreenPlatformOverlay(pid: Int32, overlayID: Int32, object: AnyObject) {
        guard processes[pid] != nil else { return }
        let overlay = UIOverlay(
            pid: pid,
            overlayID: overlayID,
            object: object,
            frame: UIOverlayFrame(x: 0, y: 0, width: nil, height: nil, isFullscreen: true)
        )
        overlays.append(overlay)
        log(.system, "[pid \(pid)] ui: overlay mounted")
    }

    // Remove a single overlay the process added (matched by its id). Scoped to the
    // owning pid so a process can only drop its own overlays.
    func removeOverlay(pid: Int32, overlayID: Int32) {
        overlays.removeAll { $0.pid == pid && $0.overlayID == overlayID }
    }

    func markExit(pid: Int32, code: Int32) {
        guard let process = processes.removeValue(forKey: pid) else { return }
        process.exitCode = code
        overlays.removeAll { $0.pid == pid }
        for tty in pttys.values {
            tty.removeObservers(pid: pid)
        }
        HostABI.shared.notifyProcessExit(pid: pid)
        if initialProcessPID == pid {
            initialProcessPID = nil
            triggerPanic("initial process exited pid=\(pid) status=\(code)")
        }
    }

    func terminateLatestProcess() {
        guard let pid = processes.keys.sorted().last else {
            log(.system, "kill: no running process")
            return
        }
        terminate(pid: pid)
    }

    func terminateAllProcesses() {
        let pids = processes.keys.sorted(by: >)
        guard !pids.isEmpty else {
            log(.system, "kill: no running process")
            return
        }

        for pid in pids {
            terminate(pid: pid)
        }
    }

    func terminate(pid: Int32) {
        guard processes[pid] != nil else {
            log(.stderr, "kill: pid=\(pid) not found")
            return
        }
        log(.system, "kill: pid=\(pid) requested")
        HostABI.shared.requestTermination(pid: pid)
    }

    func triggerPanic(_ message: String) {
        log(.panic, "panic: \(message)")
    }

    private func allocatePID() -> Int32 {
        nextPID += 1
        return nextPID
    }

    private func append(_ stream: TTYStream, _ text: String) {
        externalTTYBridges[defaultTTY.id]?.appendOutput(text)

        let color: Color
        switch stream {
        case .stdout: color = .white
        case .stderr: color = .red
        case .system: color = .green
        case .panic: color = .red
        }

        consoleLines = ansiParser.write(text, defaultColor: color)
    }

    private func log(_ stream: TTYStream, _ text: String) {
        append(stream, text.hasSuffix("\n") ? text : "\(text)\n")
    }

}
