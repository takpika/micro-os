import Foundation
import Darwin

// Implemented in micro_os_image_refresh.c (same target): resets a reused pool
// image's writable data segments to their pristine post-load state, so each
// process on a recycled device slot starts with fresh globals.
@_silgen_name("micro_os_image_refresh")
func micro_os_image_refresh(_ header: UnsafeRawPointer?)

/// On a real device, per-process dylib copies are impossible (code signing only
/// trusts images signed inside the app bundle), so a multicall program that
/// spawns instances of itself — the toybox shell forks children that are also
/// toybox — would load ONE shared image and let those instances clobber each
/// other's globals (toys/this/toybuf). copy-payload.sh ships extra signed copies
/// of such frameworks as `<stem>-pool-<i>.framework`; this hands out a distinct
/// copy per live instance so each gets independent __DATA, keyed by pid so the
/// slot can be returned when the process exits.
///
/// The slot is released from the process-exit path (HostABI.exit), NOT the
/// loader's normal return: programs almost always terminate via exit() ->
/// micro_os_process_exit -> pthread_exit, which unwinds past the loader without
/// running its cleanup, so a `defer` there would leak every slot.
///
/// A reused slot must come back with FRESH globals: programs keep mutable state in
/// __DATA (toybox's toys/this/toybuf, the CRT/libc shim's per-image state), and a
/// stale value from the previous tenant corrupts the next one. We can't reload the
/// image for that — iOS dyld keeps it mapped across dlclose — so the loader instead
/// restores the image's pristine post-load __DATA on each reuse (see
/// micro_os_image_refresh). Always compiled — on the simulator the loader uses
/// private temp-dir copies instead and never acquires here, so this stays inert.
final class FrameworkPool {
    static let shared = FrameworkPool()
    private let lock = NSLock()
    private var free: [String: [String]] = [:]              // stem -> free copy binary paths
    private var probed: Set<String> = []
    private var assigned: [Int32: (stem: String, path: String)] = [:]  // pid -> checked-out slot

    /// A free pool-copy binary path for `stem` (checked out to `pid`), or nil when
    /// the program has no pool (single-instance) or every copy is currently in use.
    func acquire(stem: String, frameworksPath: String, pid: Int32) -> String? {
        lock.lock(); defer { lock.unlock() }
        if !probed.contains(stem) {
            probed.insert(stem)
            var paths: [String] = []
            var i = 1
            while true {
                let p = "\(frameworksPath)/\(stem)-pool-\(i).framework/\(stem)"
                guard FileManager.default.fileExists(atPath: p) else { break }
                paths.append(p)
                i += 1
            }
            free[stem] = paths
        }
        guard var list = free[stem], !list.isEmpty else { return nil }
        let path = list.removeLast()
        free[stem] = list
        assigned[pid] = (stem, path)
        return path
    }

    /// Return the slot held by `pid` (if any) to its free list. Idempotent and
    /// safe for pids that never acquired (single-instance programs, simulator).
    func release(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard let slot = assigned.removeValue(forKey: pid) else { return }
        free[slot.stem, default: []].append(slot.path)
    }
}

let processMain: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { raw in
    let boot = Unmanaged<ProcessBootInfo>.fromOpaque(raw).takeRetainedValue()
    let pcb = boot.pcb
    HostABI.shared.setCurrentPID(pcb.pid)
    HostABI.shared.registerProcess(pid: pcb.pid)
    setenv("HOME", pcb.home, 1)
    setenv("PATH", "\(pcb.home)/.local/bin:/bin:/usr/bin", 1)
    if let resources = Bundle.main.resourceURL {
        setenv("BUNDLE", resources.appendingPathComponent("BundledDylibs", isDirectory: true).path, 1)
    }
    // Program code ships as .frameworks in the app's Frameworks/ (bare dylibs are
    // rejected by App Store). $FW points there so setup-path can link the per-
    // program command names to Frameworks/<name>.framework/<name>.
    if let frameworks = Bundle.main.privateFrameworksPath {
        setenv("FW", frameworks, 1)
    }
    setenv("BIN", "\(pcb.home)/.local/bin", 1)
    if chdir(pcb.home) != 0 {
        HostABI.shared.write(stream: .stderr, text: "loader: chdir(\(pcb.home)) failed errno=\(errno)\n")
    }

    // Resolve through any symlink (e.g. a $BIN command link -> toybox.dylib) to
    // the real file: on the simulator the per-process copy below must copy a real
    // image, not a symlink aliasing one; on device this gives the canonical
    // realpath that dyld caches the loaded image under.
    let dylibPath = (resolveDylibPath(pcb.dylib) as NSString).resolvingSymlinksInPath
    let loadedStem = (((dylibPath as NSString).deletingLastPathComponent as NSString)
        .lastPathComponent as NSString).deletingPathExtension

    let dependencyFrameworks: [String: [String]] = [
        "dig": ["libcrypto", "libssl", "libuv", "libisc", "libdns", "libisccfg", "libirs"],
        "nslookup": ["libcrypto", "libssl", "libuv", "libisc", "libdns", "libisccfg", "libirs"],
        "bzip2": ["libbz2"],
        "xz": ["liblzma"],
    ]

    let handle: UnsafeMutableRawPointer?
    var simulatorPreloadHandles: [UnsafeMutableRawPointer] = []
#if targetEnvironment(simulator)
    // Per-process isolation: dlopen a PRIVATE COPY of the dylib so each process
    // gets its own copy of the image's globals. Real programs keep mutable state
    // in globals (toybox: toys/this/toybuf); since every process here shares one
    // address space (pthreads), loading the same file would alias that state and
    // let concurrent/sequential processes corrupt each other. A distinct on-disk
    // path defeats dyld's by-realpath image caching, giving fresh __DATA. The
    // simulator does not enforce code signing, so a copy in a writable dir runs.
    let isolatedDeps = dependencyFrameworks[loadedStem] ?? []
    let needsIsolatedDeps = !isolatedDeps.isEmpty
    var simulatorLoadError: String?
    let isolatedPath: String
    let isolated: Bool
    let isolatedRemovalPath: String

    if needsIsolatedDeps {
        let frameworkDir = (dylibPath as NSString).deletingLastPathComponent
        let frameworksDir = (frameworkDir as NSString).deletingLastPathComponent
        let tempRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("micro-os-pid\(pcb.pid)-\(loadedStem)-frameworks")
        try? FileManager.default.removeItem(atPath: tempRoot)
        try? FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        for stem in isolatedDeps + [loadedStem] {
            let src = "\(frameworksDir)/\(stem).framework"
            let dst = "\(tempRoot)/\(stem).framework"
            do {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
            } catch {
                simulatorLoadError = "copy \(stem).framework failed: \(error)"
                break
            }
        }

        if simulatorLoadError == nil {
            for stem in isolatedDeps {
                let depPath = "\(tempRoot)/\(stem).framework/\(stem)"
                guard let depHandle = dlopen(depPath, RTLD_NOW | RTLD_LOCAL) else {
                    simulatorLoadError = "dlopen \(stem) failed: \(String(cString: dlerror()))"
                    break
                }
                simulatorPreloadHandles.append(depHandle)
            }
        }

        isolatedPath = "\(tempRoot)/\(loadedStem).framework/\(loadedStem)"
        isolatedRemovalPath = tempRoot
        isolated = simulatorLoadError == nil && FileManager.default.fileExists(atPath: isolatedPath)
    } else {
        isolatedPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("micro-os-pid\(pcb.pid)-\((dylibPath as NSString).lastPathComponent)")
        try? FileManager.default.removeItem(atPath: isolatedPath)
        isolated = (try? FileManager.default.copyItem(atPath: dylibPath, toPath: isolatedPath)) != nil
        isolatedRemovalPath = isolatedPath
    }
    defer {
        if isolated { try? FileManager.default.removeItem(atPath: isolatedRemovalPath) }
    }
    if simulatorLoadError == nil {
        handle = dlopen(isolated ? isolatedPath : dylibPath, RTLD_NOW | RTLD_LOCAL)
    } else {
        handle = nil
    }
#else
    // On a real device the per-process-copy trick is impossible: iOS code signing
    // (AMFI) only lets a process execute code from images signed inside the app
    // bundle. A copy in a writable dir (NSTemporaryDirectory) dlopen()s without
    // error, but its code pages fail validation and the kernel SIGKILLs the
    // process the moment it executes them (EXC_BAD_ACCESS, CODESIGNING "Invalid
    // Page"). So load an in-bundle, build-time-signed image. For a program that
    // can run concurrently with itself (the toybox shell), check out a distinct
    // signed pool copy so it gets independent globals; otherwise (single-instance
    // programs, or the pool exhausted) load the base framework directly. dyld
    // returns one image per realpath, so without a pool copy multiple instances
    // of the same program would share __DATA.
    let frameworks = Bundle.main.privateFrameworksPath ?? ""
    let stem = (((dylibPath as NSString).deletingLastPathComponent as NSString)
        .lastPathComponent as NSString).deletingPathExtension
    // The slot is returned in HostABI.exit (keyed by pid), not here: programs
    // exit via pthread_exit and never unwind back to this loader.
    let poolPath = FrameworkPool.shared.acquire(stem: stem, frameworksPath: frameworks, pid: pcb.pid)
    handle = dlopen(poolPath ?? dylibPath, RTLD_NOW | RTLD_LOCAL)
#endif
    guard let handle else {
        let error: String
#if targetEnvironment(simulator)
        error = simulatorLoadError ?? String(cString: dlerror())
#else
        error = String(cString: dlerror())
#endif
        HostABI.shared.write(stream: .stderr, text: "loader: dlopen failed: \(error)\n")
        for depHandle in simulatorPreloadHandles.reversed() {
            dlclose(depHandle)
        }
        HostABI.shared.exit(pid: pcb.pid, code: 127)
        return nil
    }

    // A pool image is kept loaded for reuse (iOS dyld won't unload it anyway), so
    // the loader must NOT dlclose it. Other images (tmp copy, or the shared base)
    // are dlclose'd as usual.
    let poolOwned: Bool
#if targetEnvironment(simulator)
    poolOwned = false
#else
    poolOwned = poolPath != nil
#endif
    let keepLoadedAfterExit = poolOwned
#if targetEnvironment(simulator)
    // BIND dns tools spin up libisc/libuv worker threads during startup. Give
    // those threads a short grace period before dlclose() so dyld does not
    // unload libisc while a trampoline is still attaching.
    let delayBeforeClose = loadedStem == "dig" || loadedStem == "nslookup"
#else
    let delayBeforeClose = false
#endif

    HostABI.shared.setCurrentDylibHandle(handle)

    guard let symbol = dlsym(handle, "entry") else {
        HostABI.shared.write(stream: .stderr, text: "loader: dlsym(\"entry\") failed\n")
        HostABI.shared.clearCurrentDylibHandle()
        if !poolOwned { dlclose(handle) }
        for depHandle in simulatorPreloadHandles.reversed() {
            dlclose(depHandle)
        }
        HostABI.shared.exit(pid: pcb.pid, code: 126)
        return nil
    }

    // iOS dyld keeps images mapped across dlclose, so every re-run of the same
    // program (or its dependencies) inherits stale globals. Restore each image's
    // pristine post-load __DATA before the new process runs.
#if !targetEnvironment(simulator)
    do {
        var dlinfo = Dl_info()
        if dladdr(symbol, &dlinfo) != 0 {
            micro_os_image_refresh(dlinfo.dli_fbase)
        }
        if let deps = dependencyFrameworks[stem] {
            let depSet = Set(deps)
            let imageCount = _dyld_image_count()
            for i in 0..<imageCount {
                guard let name = _dyld_get_image_name(i) else { continue }
                let path = String(cString: name)
                let imageStem = (((path as NSString).deletingLastPathComponent as NSString)
                    .lastPathComponent as NSString).deletingPathExtension
                if depSet.contains(imageStem), let hdr = _dyld_get_image_header(i) {
                    micro_os_image_refresh(hdr)
                }
            }
        }
    }
#endif

    typealias Entry = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    let entry = unsafeBitCast(symbol, to: Entry.self)
    resetLibcProcessGlobals()
    let code = withCArgv(pcb.argv) { argc, argv in
        entry(argc, argv)
    }
    HostABI.shared.clearCurrentDylibHandle()
    if delayBeforeClose {
        usleep(200_000)
    }
    if !keepLoadedAfterExit { dlclose(handle) }
    for depHandle in simulatorPreloadHandles.reversed() {
        dlclose(depHandle)
    }
    HostABI.shared.exit(pid: pcb.pid, code: code)
    return nil
}

private func resetLibcProcessGlobals() {
    if let optindPointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "optind") {
        optindPointer.assumingMemoryBound(to: Int32.self).pointee = 1
    }
    if let optresetPointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "optreset") {
        optresetPointer.assumingMemoryBound(to: Int32.self).pointee = 1
    }
}

func resolveDylibPath(_ name: String) -> String {
    if name.hasPrefix("/") {
        return name
    }

    let cwdPath = FileManager.default.currentDirectoryPath + "/" + name
    if FileManager.default.fileExists(atPath: cwdPath) {
        return cwdPath
    }

    // A program ships as Frameworks/<name>.framework/<name> (a real bundle —
    // App Store rejects bare dylibs). Strip any directory and legacy .dylib
    // suffix to get the framework name.
    let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    if let binary = frameworkBinaryPath(stem) {
        return binary
    }

    // Unknown command -> fall back to the bundled toybox multicall, if present.
    // A bare name like "ls" has no ls.framework; toybox dispatches on argv[0]
    // (kept as "ls" by the kernel), so this runs the matching applet. This is how
    // the shell's exec("ls") resolves without per-applet frameworks.
    if let toybox = frameworkBinaryPath("toybox") {
        return toybox
    }

    return name
}

// The executable inside an embedded program framework
// (Frameworks/<name>.framework/<name>), or nil if there is no such framework.
func frameworkBinaryPath(_ name: String) -> String? {
    guard !name.isEmpty, let frameworks = Bundle.main.privateFrameworksPath else { return nil }
    let binary = "\(frameworks)/\(name).framework/\(name)"
    return FileManager.default.fileExists(atPath: binary) ? binary : nil
}

func withCArgv<R>(_ args: [String], body: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
    let cStrings = args.map { strdup($0) }
    let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count + 1)
    for index in cStrings.indices {
        argv[index] = cStrings[index]
    }
    argv[cStrings.count] = nil
    defer {
        for pointer in cStrings {
            free(pointer)
        }
        argv.deallocate()
    }
    return body(Int32(cStrings.count), argv)
}
