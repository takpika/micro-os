import Foundation
import Darwin

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
    // the real file, so the per-process copy below is a genuinely independent
    // image rather than a symlink aliasing one shared copy.
    let dylibPath = (resolveDylibPath(pcb.dylib) as NSString).resolvingSymlinksInPath

    // Per-process isolation: dlopen a PRIVATE COPY of the dylib so each process
    // gets its own copy of the image's globals. Real programs keep mutable state
    // in globals (toybox: toys/this/toybuf); since every process here shares one
    // address space (pthreads), loading the same file would alias that state and
    // let concurrent/sequential processes corrupt each other. A distinct on-disk
    // path defeats dyld's by-realpath image caching, giving fresh __DATA.
    let isolatedPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("micro-os-pid\(pcb.pid)-\((dylibPath as NSString).lastPathComponent)")
    try? FileManager.default.removeItem(atPath: isolatedPath)
    var isolated = (try? FileManager.default.copyItem(atPath: dylibPath, toPath: isolatedPath)) != nil
    defer {
        if isolated { try? FileManager.default.removeItem(atPath: isolatedPath) }
    }

    var handle = dlopen(isolated ? isolatedPath : dylibPath, RTLD_NOW | RTLD_LOCAL)
    if handle == nil && isolated {
        // The private copy wouldn't load — most likely iOS device code signing,
        // which only trusts dylibs shipped+signed inside the app bundle. Fall
        // back to the bundle dylib: this loses per-process isolation (globals are
        // then shared) but lets the program run instead of failing outright.
        try? FileManager.default.removeItem(atPath: isolatedPath)
        isolated = false
        handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL)
    }
    guard let handle else {
        let error = String(cString: dlerror())
        HostABI.shared.write(stream: .stderr, text: "loader: dlopen failed: \(error)\n")
        HostABI.shared.exit(pid: pcb.pid, code: 127)
        return nil
    }
    HostABI.shared.setCurrentDylibHandle(handle)

    guard let symbol = dlsym(handle, "entry") else {
        HostABI.shared.write(stream: .stderr, text: "loader: dlsym(\"entry\") failed\n")
        HostABI.shared.clearCurrentDylibHandle()
        dlclose(handle)
        HostABI.shared.exit(pid: pcb.pid, code: 126)
        return nil
    }

    typealias Entry = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    let entry = unsafeBitCast(symbol, to: Entry.self)
    let code = withCArgv(pcb.argv) { argc, argv in
        entry(argc, argv)
    }
    HostABI.shared.clearCurrentDylibHandle()
    dlclose(handle)
    HostABI.shared.exit(pid: pcb.pid, code: code)
    return nil
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
