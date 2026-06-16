import SwiftUI
import Darwin

@main
struct MicroOSApp: App {
    @StateObject private var kernel = MicroKernel()
    @State private var didBoot = false

    init() {
        Darwin.signal(SIGPIPE, SIG_IGN)
        MicroOSApp.ensureStandardFDs()
    }

    /// Programs run via the host's PID-routed I/O, not the app's real fd 0/1/2.
    /// A GUI app often launches with those closed, so a program's libc-internal
    /// write to them (e.g. toybox's exit-time `fflush(NULL)`) fails EBADF and
    /// gets misreported as a command error. Point any closed standard fd at
    /// /dev/null so those writes are harmless. (All processes share one fd table,
    /// so this is done once.)
    private static func ensureStandardFDs() {
        let devnull = open("/dev/null", O_RDWR)
        guard devnull >= 0 else { return }
        for fd in Int32(0)...2 where fcntl(fd, F_GETFD) == -1 {
            dup2(devnull, fd)
        }
        if devnull > 2 { close(devnull) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(kernel)
                .onAppear {
                    guard !didBoot else { return }
                    didBoot = true
                    HostABI.shared.attach(kernel: kernel)
                    kernel.boot()
                    launchInit()
                }
        }
    }

    /// The kernel's only boot duty is to start init (PID 1). Everything else —
    /// provisioning userspace, registering commands, launching a shell — is the
    /// init program's job, not the kernel's.
    ///
    /// Defaults to launching the `init` program. A different initial process can
    /// be supplied via launch arguments (like `init=` on a kernel command line),
    /// e.g. `busybox sh -i`, which is useful before a real init exists.
    private func launchInit() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let dylib = arguments.first ?? "init"
        let argv = Array(arguments.dropFirst())
        let pid = kernel.launch(dylib: dylib, argv: argv)
        guard pid > 0 else {
            kernel.triggerPanic("init launch failed dylib=\(dylib)")
            return
        }
        kernel.monitorInitialProcess(pid: pid)
    }
}
