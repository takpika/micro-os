import Foundation
import Darwin

@_cdecl("micro_os_pid")
public func micro_os_pid() -> Int32 {
    HostABI.shared.currentPID()
}

@_cdecl("micro_os_stdout")
public func micro_os_stdout(_ text: UnsafePointer<CChar>?) {
    HostABI.shared.write(stream: .stdout, text: string(from: text))
}

@_cdecl("micro_os_stderr")
public func micro_os_stderr(_ text: UnsafePointer<CChar>?) {
    HostABI.shared.write(stream: .stderr, text: string(from: text))
}

@_cdecl("micro_os_stdin")
public func micro_os_stdin(_ buffer: UnsafeMutablePointer<CChar>?, _ maxBytes: Int32) -> Int32 {
    guard let buffer, maxBytes > 0 else { return 0 }
    let text = HostABI.shared.readStdin(maxBytes: Int(maxBytes))
    let bytes = Array(text.utf8.prefix(Int(maxBytes)))
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    if bytes.count < Int(maxBytes) {
        buffer[bytes.count] = 0
    }
    return Int32(bytes.count)
}

@_cdecl("micro_os_overlay_platform_view_fullscreen")
public func micro_os_overlay_platform_view_fullscreen(_ retainedPlatformView: UnsafeMutableRawPointer?) -> Int32 {
    HostABI.shared.fullscreenOverlay(platformViewPointer: retainedPlatformView)
}

@_cdecl("micro_os_overlay_platform_view")
public func micro_os_overlay_platform_view(
    _ retainedPlatformView: UnsafeMutableRawPointer?,
    _ x: Double,
    _ y: Double,
    _ width: Double,
    _ height: Double
) -> Int32 {
    HostABI.shared.overlay(platformViewPointer: retainedPlatformView, x: x, y: y, width: width, height: height)
}

@_cdecl("micro_os_overlay_remove")
public func micro_os_overlay_remove(_ overlayID: Int32) {
    HostABI.shared.removeOverlay(overlayID: overlayID)
}

// Variants that name the owning pid explicitly, for a display server mounting an
// overlay on behalf of itself from the main thread (where currentPID isn't it).
@_cdecl("micro_os_overlay_platform_view_fullscreen_for_pid")
public func micro_os_overlay_platform_view_fullscreen_for_pid(_ retainedPlatformView: UnsafeMutableRawPointer?, _ pid: Int32) -> Int32 {
    HostABI.shared.fullscreenOverlay(platformViewPointer: retainedPlatformView, ownerPID: pid)
}

@_cdecl("micro_os_overlay_remove_for_pid")
public func micro_os_overlay_remove_for_pid(_ overlayID: Int32, _ pid: Int32) {
    HostABI.shared.removeOverlay(overlayID: overlayID, ownerPID: pid)
}

@_cdecl("micro_os_kernel_panic")
public func micro_os_kernel_panic(_ text: UnsafePointer<CChar>?) {
    HostABI.shared.panic(string(from: text))
}

@_cdecl("micro_os_service_register")
public func micro_os_service_register(_ name: UnsafePointer<CChar>?, _ serviceTable: UnsafeMutableRawPointer?) {
    HostABI.shared.registerService(name: string(from: name), pointer: serviceTable)
}

@_cdecl("micro_os_service_lookup")
public func micro_os_service_lookup(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    HostABI.shared.lookupService(name: string(from: name))
}

@_cdecl("micro_os_process_observe_exit")
public func micro_os_process_observe_exit(
    _ callback: (@convention(c) (Int32, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let callback else { return }
    HostABI.shared.observeProcessExit(callback: callback, context: context)
}

@_cdecl("micro_os_ptty_create")
public func micro_os_ptty_create(_ name: UnsafePointer<CChar>?) -> Int32 {
    HostABI.shared.createPseudoTTY(name: string(from: name))
}

@_cdecl("micro_os_ptty_write")
public func micro_os_ptty_write(_ id: Int32, _ text: UnsafePointer<CChar>?) {
    HostABI.shared.writePseudoTTY(id: id, text: string(from: text))
}

@_cdecl("micro_os_ptty_input")
public func micro_os_ptty_input(_ id: Int32, _ text: UnsafePointer<CChar>?) {
    HostABI.shared.enqueuePseudoTTYInput(id: id, text: string(from: text))
}

@_cdecl("micro_os_ptty_key_input")
public func micro_os_ptty_key_input(
    _ id: Int32,
    _ key: Int32,
    _ modifiers: UInt32,
    _ text: UnsafePointer<CChar>?
) {
    HostABI.shared.enqueuePseudoTTYKeyboardInput(id: id, key: key, modifiers: modifiers, text: string(from: text))
}

@_cdecl("micro_os_ptty_read")
public func micro_os_ptty_read(_ id: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ maxBytes: Int32) -> Int32 {
    guard let buffer, maxBytes > 0 else { return 0 }
    let text = HostABI.shared.readPseudoTTY(id: id, maxBytes: Int(maxBytes))
    let bytes = Array(text.utf8.prefix(Int(maxBytes)))
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    if bytes.count < Int(maxBytes) {
        buffer[bytes.count] = 0
    }
    return Int32(bytes.count)
}

@_cdecl("micro_os_keyboard_sink_register")
public func micro_os_keyboard_sink_register(
    _ callback: MicroOSKeyboardSinkCallback?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let callback else { return -1 }
    return HostABI.shared.registerKeyboardSink(callback: callback, context: context)
}

@_cdecl("micro_os_keyboard_sink_unregister")
public func micro_os_keyboard_sink_unregister(_ sinkID: Int32) {
    HostABI.shared.unregisterKeyboardSink(id: sinkID)
}

@_cdecl("micro_os_keyboard_dispatch")
public func micro_os_keyboard_dispatch(
    _ sinkID: Int32,
    _ phase: Int32,
    _ key: Int32,
    _ modifiers: UInt32,
    _ text: UnsafePointer<CChar>?
) {
    HostABI.shared.dispatchKeyboardEvent(
        sinkID: sinkID,
        phase: phase,
        key: key,
        modifiers: modifiers,
        text: string(from: text)
    )
}

@_cdecl("micro_os_ptty_observe_output")
public func micro_os_ptty_observe_output(
    _ id: Int32,
    _ callback: (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let callback else { return }
    HostABI.shared.observePseudoTTYOutput(id: id, callback: callback, context: context)
}

@_cdecl("micro_os_tty_get_lflag")
public func micro_os_tty_get_lflag() -> UInt32 {
    HostABI.shared.ttyLocalFlags()
}

@_cdecl("micro_os_tty_set_lflag")
public func micro_os_tty_set_lflag(_ lflag: UInt32) {
    HostABI.shared.setTTYLocalFlags(lflag)
}

@_cdecl("micro_os_process_keep_alive")
public func micro_os_process_keep_alive() {
    HostABI.shared.keepAliveUntilTerminationRequested()
}

@_cdecl("micro_os_process_termination_requested")
public func micro_os_process_termination_requested() -> Int32 {
    HostABI.shared.isTerminationRequestedForCurrentProcess() ? 1 : 0
}

@_cdecl("micro_os_process_exit")
public func micro_os_process_exit(_ code: Int32) {
    let pid = HostABI.shared.currentPID()
    if pid > 0 {
        HostABI.shared.exit(pid: pid, code: code)
    }
    pthread_exit(nil)
}

@_cdecl("micro_os_process_signal")
public func micro_os_process_signal(_ pid: Int32, _ signal: Int32) -> Int32 {
    HostABI.shared.signal(pid: pid, signal: signal) ? 0 : -1
}

@_cdecl("micro_os_process_snapshot")
public func micro_os_process_snapshot(_ buffer: UnsafeMutableRawPointer?, _ maxEntries: Int32) -> Int32 {
    let snapshot = HostABI.shared.processSnapshot()
    guard let buffer, maxEntries > 0 else {
        return Int32(snapshot.count)
    }

    let entrySize = 344
    let count = min(snapshot.count, Int(maxEntries))
    for (index, process) in snapshot.prefix(count).enumerated() {
        let base = buffer.advanced(by: index * entrySize)
        base.storeBytes(of: process.pid, toByteOffset: 0, as: Int32.self)
        base.storeBytes(of: process.parentPID, toByteOffset: 4, as: Int32.self)
        base.storeBytes(of: process.ttyID, toByteOffset: 8, as: Int32.self)
        base.storeBytes(of: Int32(2), toByteOffset: 12, as: Int32.self)
        let startMS = UInt64(max(0, process.startTime.timeIntervalSince1970 * 1000))
        base.storeBytes(of: startMS, toByteOffset: 16, as: UInt64.self)
        writeCString(process.command, to: base.advanced(by: 24), capacity: 64)
        writeArgv(process.argv, to: base.advanced(by: 88), capacity: 256)
    }
    return Int32(snapshot.count)
}

@_cdecl("micro_os_spawn")
public func micro_os_spawn(
    _ dylib: UnsafePointer<CChar>?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let dylib else { return -1 }
    let dylibName = String(cString: dylib)
    return HostABI.shared.spawn(dylib: dylibName, argv: normalizedSpawnArguments(dylib: dylibName, argc: argc, argv: argv))
}

@_cdecl("micro_os_spawn_with_tty")
public func micro_os_spawn_with_tty(
    _ dylib: UnsafePointer<CChar>?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ ttyID: Int32
) -> Int32 {
    guard let dylib else { return -1 }
    let dylibName = String(cString: dylib)
    return HostABI.shared.spawn(
        dylib: dylibName,
        argv: normalizedSpawnArguments(dylib: dylibName, argc: argc, argv: argv),
        ttyID: ttyID
    )
}

private func normalizedSpawnArguments(
    dylib: String,
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> [String] {
    var args: [String] = []
    if let argv, argc > 0 {
        for index in 0..<Int(argc) {
            if let item = argv[index] {
                args.append(String(cString: item))
            }
        }
    }

    guard let first = args.first else { return args }
    let dylibBaseName = (dylib as NSString).lastPathComponent
    let dylibCommandName = (dylibBaseName as NSString).deletingPathExtension

    // Drop a caller-supplied argv[0] that just repeats the command, since the
    // kernel re-derives argv[0] from the launch name. Matches exec("ls", ["ls",…])
    // as well as exec("foo.dylib", ["foo.dylib",…]); the kernel keeps argv[0]="ls".
    let firstBaseName = (first as NSString).lastPathComponent
    let firstCommandName = (firstBaseName as NSString).deletingPathExtension
    if first == dylib || firstBaseName == dylibBaseName || firstBaseName == dylibCommandName
        || firstCommandName == dylibCommandName {
        return Array(args.dropFirst())
    }
    return args
}

@_cdecl("micro_os_fork")
public func micro_os_fork() -> Int32 {
    HostABI.shared.fork()
}

@_cdecl("micro_os_exec_forked_child")
public func micro_os_exec_forked_child(
    _ pid: Int32,
    _ dylib: UnsafePointer<CChar>?,
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    guard let dylib else { return -1 }
    let dylibName = String(cString: dylib)
    return HostABI.shared.execForkedChild(
        pid: pid,
        dylib: dylibName,
        argv: normalizedSpawnArguments(dylib: dylibName, argc: argc, argv: argv)
    )
}

@_cdecl("micro_os_exit_forked_child")
public func micro_os_exit_forked_child(_ pid: Int32, _ code: Int32) {
    HostABI.shared.exitForkedChild(pid: pid, code: code)
}

// The emulated-fork child side runs on the parent's thread until it execs/exits.
// These bracket that window so the host routes its fd ops to the child pid.
@_cdecl("micro_os_fork_child_begin")
public func micro_os_fork_child_begin(_ childPID: Int32) {
    HostABI.shared.beginForkChild(childPID)
}

@_cdecl("micro_os_fork_child_end")
public func micro_os_fork_child_end() {
    HostABI.shared.endForkChild()
}

// access() routed through the host. A bundled program is a code-signed ".dylib"
// that the read-only app bundle leaves without a +x bit, so a shell's
// access(X_OK) on a command link (-> the bundle .dylib) would refuse to run it.
// We treat a .dylib as an executable program: best-effort chmod +x (for copies
// on writable storage) and report it runnable even when the bundle itself can't
// be made +x. Everything else falls through to the real access().
@_cdecl("micro_os_access")
public func micro_os_access(_ pathC: UnsafePointer<CChar>?, _ mode: Int32) -> Int32 {
    guard let pathC else { errno = EFAULT; return -1 }
    let path = String(cString: pathC)
    let xOK: Int32 = 1  // X_OK
    if (mode & xOK) != 0 {
        let resolved = (path as NSString).resolvingSymlinksInPath
        // A program ships either as a bare .dylib (legacy) or, in the app bundle,
        // as the binary inside a framework: Frameworks/<name>.framework/<name>.
        // Either way the read-only bundle leaves it without +x, so treat both as
        // runnable (dlopen doesn't need +x; this just gets past a shell's X_OK).
        let parent = ((resolved as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let base = (resolved as NSString).lastPathComponent
        let isFrameworkBinary = parent == "\(base).framework"
        if (resolved.hasSuffix(".dylib") || isFrameworkBinary) && FileManager.default.fileExists(atPath: resolved) {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: resolved)
            return 0
        }
    }
    return path.withCString { Darwin.access($0, mode) }
}

@_cdecl("micro_os_waitpid")
public func micro_os_waitpid(_ pid: Int32, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32) -> Int32 {
    let result = HostABI.shared.waitpid(pid, options: options)
    status?.pointee = result.status
    return result.pid
}

@_cdecl("micro_os_fd_kind")
public func micro_os_fd_kind(_ fd: Int32) -> Int32 {
    HostABI.shared.fdKind(fd)
}

@_cdecl("micro_os_fd_open")
public func micro_os_fd_open(_ kind: Int32, _ bytes: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    HostABI.shared.fdOpen(kind: kind, bytes: bytes, count: count)
}

@_cdecl("micro_os_fd_dup")
public func micro_os_fd_dup(_ fd: Int32) -> Int32 {
    HostABI.shared.fdDup(fd)
}

@_cdecl("micro_os_fd_dup2")
public func micro_os_fd_dup2(_ fd: Int32, _ fd2: Int32) -> Int32 {
    HostABI.shared.fdDup2(fd, fd2)
}

@_cdecl("micro_os_fd_close")
public func micro_os_fd_close(_ fd: Int32) -> Int32 {
    HostABI.shared.fdClose(fd)
}

@_cdecl("micro_os_fd_pipe")
public func micro_os_fd_pipe(_ fds: UnsafeMutablePointer<Int32>?) -> Int32 {
    HostABI.shared.fdPipe(fds)
}

@_cdecl("micro_os_fd_read")
public func micro_os_fd_read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int32) -> Int32 {
    HostABI.shared.fdRead(fd, buffer: buffer, count: count)
}

@_cdecl("micro_os_fd_write")
public func micro_os_fd_write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int32) -> Int32 {
    HostABI.shared.fdWrite(fd, buffer: buffer, count: count)
}

@_cdecl("micro_os_fd_lseek")
public func micro_os_fd_lseek(_ fd: Int32, _ offset: Int64, _ whence: Int32) -> Int64 {
    HostABI.shared.fdLseek(fd, offset: offset, whence: whence)
}

func string(from pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

private func writeCString(_ value: String, to pointer: UnsafeMutableRawPointer, capacity: Int) {
    guard capacity > 0 else { return }
    memset(pointer, 0, capacity)
    let bytes = Array(value.utf8.prefix(capacity - 1))
    for (index, byte) in bytes.enumerated() {
        pointer.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
    }
}

private func writeArgv(_ argv: [String], to pointer: UnsafeMutableRawPointer, capacity: Int) {
    guard capacity > 0 else { return }
    memset(pointer, 0, capacity)
    var offset = 0
    for argument in argv {
        if offset >= capacity - 1 {
            break
        }
        let bytes = Array(argument.utf8.prefix(capacity - offset - 1))
        for (index, byte) in bytes.enumerated() {
            pointer.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self)
        }
        offset += bytes.count
        pointer.storeBytes(of: UInt8(0), toByteOffset: offset, as: UInt8.self)
        offset += 1
    }
}
