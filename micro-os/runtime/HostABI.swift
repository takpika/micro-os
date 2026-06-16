import Foundation
import Darwin

final class HostABI {
    static let shared = HostABI()

    private let lock = NSLock()
    private weak var kernel: MicroKernel?
    private var tlsKey = pthread_key_t()
    private var dylibHandleKey = pthread_key_t()
    private var forkChildKey = pthread_key_t()
    private var tlsReady = false
    private var terminationSignals: [Int32: DispatchSemaphore] = [:]
    private var terminationRequests: Set<Int32> = []
    private var processParents: [Int32: Int32] = [:]
    private var exitedProcesses: [Int32: Int32] = [:]
    private let processExitCondition = NSCondition()
    private var services: [String: ServiceEntry] = [:]
    private var exitObservers: [ProcessExitObserver] = []
    private var fdTables: [Int32: [Int32: KernelFD]] = [:]
    private var nextFDByPID: [Int32: Int32] = [:]
    private var pipes: [Int32: KernelPipe] = [:]
    private var nextPipeID: Int32 = 1
    private var nextOverlayID: Int32 = 1

    private init() {}

    // Overlay ids are handed out synchronously so add returns an id the process
    // can later pass to remove, even though the kernel mutation runs async on main.
    private func allocateOverlayID() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextOverlayID
        nextOverlayID += 1
        return id
    }

    func attach(kernel: MicroKernel) {
        lock.lock()
        self.kernel = kernel
        if !tlsReady {
            pthread_key_create(&tlsKey, nil)
            pthread_key_create(&forkChildKey, nil)
            pthread_key_create(&dylibHandleKey) { raw in
                dlclose(raw)
            }
            tlsReady = true
        }
        lock.unlock()
    }

    func setCurrentPID(_ pid: Int32) {
        ensureTLS()
        pthread_setspecific(tlsKey, UnsafeMutableRawPointer(bitPattern: Int(pid)))
    }

    func registerProcess(pid: Int32) {
        lock.lock()
        if terminationSignals[pid] == nil {
            terminationSignals[pid] = DispatchSemaphore(value: 0)
        }
        if fdTables[pid] == nil {
            fdTables[pid] = [
                0: KernelFD(kind: .stdin),
                1: KernelFD(kind: .stdout),
                2: KernelFD(kind: .stderr)
            ]
            nextFDByPID[pid] = 256
        }
        terminationRequests.remove(pid)
        lock.unlock()
    }

    func registerProcessParent(pid: Int32, parentPID: Int32) {
        guard pid > 0 else { return }
        lock.lock()
        processParents[pid] = parentPID
        lock.unlock()
    }

    func currentPID() -> Int32 {
        ensureTLS()
        // During the child side of an emulated fork (see micro_os_crt_fork), this
        // thread is still the parent's pthread but is acting as the child: its fd
        // setup (dup2/close/pipe) and exec must target the reserved child pid, not
        // the parent's. The override is set between fork()-returns-0 and exec/exit.
        let child = pthread_getspecific(forkChildKey)
        if child != nil {
            return Int32(Int(bitPattern: child))
        }
        let raw = pthread_getspecific(tlsKey)
        return Int32(Int(bitPattern: raw))
    }

    /// Begin acting as the reserved fork child on the current (parent) thread.
    func beginForkChild(_ childPID: Int32) {
        ensureTLS()
        pthread_setspecific(forkChildKey, UnsafeMutableRawPointer(bitPattern: Int(childPID)))
    }

    /// Stop acting as the fork child; the thread is the parent again.
    func endForkChild() {
        ensureTLS()
        pthread_setspecific(forkChildKey, nil)
    }

    func setCurrentDylibHandle(_ handle: UnsafeMutableRawPointer) {
        ensureTLS()
        pthread_setspecific(dylibHandleKey, handle)
    }

    func clearCurrentDylibHandle() {
        ensureTLS()
        pthread_setspecific(dylibHandleKey, nil)
    }

    func write(stream: TTYStream, text: String) {
        let pid = currentPID()
        if Thread.isMainThread {
            kernel?.write(pid: pid, stream: stream, text: text)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.kernel?.write(pid: pid, stream: stream, text: text)
        }
    }

    func readStdin(maxBytes: Int) -> String {
        let pid = currentPID()
        if Thread.isMainThread {
            return kernel?.readStdin(pid: pid, maxBytes: maxBytes) ?? ""
        }

        return pollInput(pid: pid) { [weak self] in
            self?.kernel?.readStdin(pid: pid, maxBytes: maxBytes) ?? ""
        }
    }

    func createPseudoTTY(name: String) -> Int32 {
        if Thread.isMainThread {
            return kernel?.createPseudoTTY(name: name) ?? -1
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Int32 = -1
        DispatchQueue.main.async { [weak self] in
            result = self?.kernel?.createPseudoTTY(name: name) ?? -1
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    func writePseudoTTY(id: Int32, text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.writePseudoTTY(id: id, text: text)
        }
    }

    func enqueuePseudoTTYInput(id: Int32, text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.enqueuePseudoTTYInput(id: id, text: text)
        }
    }

    func readPseudoTTY(id: Int32, maxBytes: Int) -> String {
        let pid = currentPID()
        if Thread.isMainThread {
            return kernel?.readPseudoTTY(id: id, maxBytes: maxBytes) ?? ""
        }

        return pollInput(pid: pid) { [weak self] in
            self?.kernel?.readPseudoTTY(id: id, maxBytes: maxBytes) ?? ""
        }
    }

    func observePseudoTTYOutput(
        id: Int32,
        callback: @escaping PseudoTTYOutputObserverCallback,
        context: UnsafeMutableRawPointer?
    ) {
        let pid = currentPID()
        if Thread.isMainThread {
            kernel?.observePseudoTTYOutput(pid: pid, id: id, callback: callback, context: context)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.kernel?.observePseudoTTYOutput(pid: pid, id: id, callback: callback, context: context)
        }
    }

    func ttyLocalFlags() -> UInt32 {
        let pid = currentPID()
        if Thread.isMainThread {
            return kernel?.ttyLocalFlags(pid: pid) ?? 0
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: UInt32 = 0
        DispatchQueue.main.async { [weak self] in
            result = self?.kernel?.ttyLocalFlags(pid: pid) ?? 0
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    func setTTYLocalFlags(_ flags: UInt32) {
        let pid = currentPID()
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.setTTYLocalFlags(pid: pid, flags: flags)
        }
    }

    @discardableResult
    func overlay(platformViewPointer: UnsafeMutableRawPointer?, x: Double, y: Double, width: Double, height: Double) -> Int32 {
        guard let platformViewPointer else { return -1 }
        let pid = currentPID()
        let overlayID = allocateOverlayID()
        let object = Unmanaged<AnyObject>.fromOpaque(platformViewPointer).takeRetainedValue()
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.addPlatformOverlay(pid: pid, overlayID: overlayID, object: object, x: x, y: y, width: width, height: height)
        }
        return overlayID
    }

    // ownerPID is given explicitly when the caller can't rely on currentPID() —
    // e.g. a display server (wm) mounting an overlay from the MAIN thread, where
    // the per-thread pid is not its own. nil falls back to the calling process.
    @discardableResult
    func fullscreenOverlay(platformViewPointer: UnsafeMutableRawPointer?, ownerPID: Int32? = nil) -> Int32 {
        guard let platformViewPointer else { return -1 }
        let pid = ownerPID ?? currentPID()
        let overlayID = allocateOverlayID()
        let object = Unmanaged<AnyObject>.fromOpaque(platformViewPointer).takeRetainedValue()
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.addFullscreenPlatformOverlay(pid: pid, overlayID: overlayID, object: object)
        }
        return overlayID
    }

    // Remove one overlay previously added (by its id). A process can hold several
    // overlays (e.g. a window plus a fullscreen layer on top) and tear them down
    // individually; process exit still removes them all.
    func removeOverlay(overlayID: Int32, ownerPID: Int32? = nil) {
        let pid = ownerPID ?? currentPID()
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.removeOverlay(pid: pid, overlayID: overlayID)
        }
    }

    func keepAliveUntilTerminationRequested() {
        let pid = currentPID()
        lock.lock()
        let signal = terminationSignals[pid] ?? DispatchSemaphore(value: 0)
        terminationSignals[pid] = signal
        lock.unlock()
        signal.wait()
    }

    func requestTermination(pid: Int32) {
        lock.lock()
        terminationRequests.insert(pid)
        let signal = terminationSignals[pid]
        lock.unlock()
        signal?.signal()
    }

    func registerService(name: String, pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        let pid = currentPID()
        lock.lock()
        services[name] = ServiceEntry(ownerPID: pid, pointer: pointer)
        lock.unlock()
    }

    func lookupService(name: String) -> UnsafeMutableRawPointer? {
        lock.lock()
        let pointer = services[name]?.pointer
        lock.unlock()
        return pointer
    }

    func observeProcessExit(callback: @escaping ProcessExitObserverCallback, context: UnsafeMutableRawPointer?) {
        let pid = currentPID()
        lock.lock()
        exitObservers.append(ProcessExitObserver(pid: pid, callback: callback, context: context))
        lock.unlock()
    }

    func notifyProcessExit(pid: Int32) {
        lock.lock()
        let observers = exitObservers.filter { $0.pid != pid }
        services = services.filter { $0.value.ownerPID != pid }
        exitObservers.removeAll { $0.pid == pid }
        lock.unlock()

        for observer in observers {
            observer.callback(pid, observer.context)
        }
    }

    func exit(pid: Int32, code: Int32) {
        lock.lock()
        exitedProcesses[pid] = code
        lock.unlock()
        processExitCondition.lock()
        processExitCondition.broadcast()
        processExitCondition.unlock()

        unregisterProcess(pid: pid)
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.markExit(pid: pid, code: code)
        }
    }

    func spawn(dylib: String, argv: [String], ttyID: Int32 = 0) -> Int32 {
        let parentPID = currentPID()
        let normalizedTTYID = ttyID == 0 ? currentTTYID(for: parentPID) : ttyID
        let launchedPID: Int32
        if Thread.isMainThread {
            launchedPID = kernel?.launch(dylib: dylib, argv: argv, ttyID: normalizedTTYID, parentPID: parentPID) ?? -1
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var pid: Int32 = -1
            DispatchQueue.main.async { [weak self] in
                pid = self?.kernel?.launch(dylib: dylib, argv: argv, ttyID: normalizedTTYID, parentPID: parentPID) ?? -1
                semaphore.signal()
            }
            semaphore.wait()
            launchedPID = pid
        }
        return launchedPID
    }

    func fork() -> Int32 {
        let parentPID = currentPID()
        guard parentPID > 0 else { return -1 }
        let childPID: Int32
        if Thread.isMainThread {
            childPID = kernel?.allocateForkPID() ?? -1
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var pid: Int32 = -1
            DispatchQueue.main.async { [weak self] in
                pid = self?.kernel?.allocateForkPID() ?? -1
                semaphore.signal()
            }
            semaphore.wait()
            childPID = pid
        }
        guard childPID > 0 else { return -1 }
        registerProcessParent(pid: childPID, parentPID: parentPID)
        // A real fork inherits the WHOLE fd table, not just stdio. The child side
        // (running on this parent thread, impersonating the child) then rewires its
        // own copy — dup2'ing a pipe end onto stdout, closing the others — without
        // touching the parent's fds. Pipelines depend on this.
        cloneFDTableForFork(parentPID: parentPID, childPID: childPID)
        return childPID
    }

    func execForkedChild(pid childPID: Int32, dylib: String, argv: [String]) -> Int32 {
        let registeredParentPID: Int32?
        lock.lock()
        registeredParentPID = processParents[childPID]
        lock.unlock()
        let parentPID = registeredParentPID ?? currentPID()
        let normalizedTTYID = currentTTYID(for: parentPID)
        if Thread.isMainThread {
            return kernel?.launch(
                dylib: dylib,
                argv: argv,
                ttyID: normalizedTTYID,
                parentPID: parentPID,
                reservedPID: childPID,
                inheritFDs: false
            ) ?? -1
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Int32 = -1
        DispatchQueue.main.async { [weak self] in
            result = self?.kernel?.launch(
                dylib: dylib,
                argv: argv,
                ttyID: normalizedTTYID,
                parentPID: parentPID,
                reservedPID: childPID,
                inheritFDs: false
            ) ?? -1
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    func exitForkedChild(pid childPID: Int32, code: Int32) {
        lock.lock()
        exitedProcesses[childPID] = code
        lock.unlock()
        processExitCondition.lock()
        processExitCondition.broadcast()
        processExitCondition.unlock()
    }

    func prepareProcessFDs(pid: Int32, parentPID: Int32) {
        inheritStandardFDs(parentPID: parentPID, childPID: pid)
    }

    /// fork() inherits every open fd, with each shared pipe end refcounted so the
    /// pipe stays open until both the parent's and the child's copies are closed.
    private func cloneFDTableForFork(parentPID: Int32, childPID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let parent = fdTables[parentPID] else {
            fdTables[childPID] = [
                0: KernelFD(kind: .stdin),
                1: KernelFD(kind: .stdout),
                2: KernelFD(kind: .stderr)
            ]
            nextFDByPID[childPID] = 256
            return
        }
        var child: [Int32: KernelFD] = [:]
        for (fd, entry) in parent {
            child[fd] = entry
            retainPipeLocked(entry)
        }
        fdTables[childPID] = child
        nextFDByPID[childPID] = nextFDByPID[parentPID] ?? 256
    }

    func fdKind(_ fd: Int32) -> Int32 {
        let pid = currentPID()
        lock.lock()
        let kind = fdTables[pid]?[fd]?.kind.rawValue ?? 0
        lock.unlock()
        return kind
    }

    func fdOpen(kind rawKind: Int32, bytes: UnsafeRawPointer?, count: Int32) -> Int32 {
        guard let kind = KernelFDKind(rawValue: rawKind) else { return -1 }
        let pid = currentPID()
        let payload: [UInt8]
        if let bytes, count > 0 {
            payload = Array(UnsafeRawBufferPointer(start: bytes, count: Int(count)))
        } else {
            payload = []
        }
        lock.lock()
        defer { lock.unlock() }
        let fd = allocateFDLocked(pid: pid)
        guard fd >= 0 else { return -1 }
        fdTables[pid, default: [:]][fd] = KernelFD(kind: kind, memory: payload)
        return fd
    }

    func fdDup(_ fd: Int32) -> Int32 {
        let pid = currentPID()
        lock.lock()
        defer { lock.unlock() }
        guard let source = fdTables[pid]?[fd] else { return -1 }
        let target = allocateFDLocked(pid: pid)
        guard target >= 0 else { return -1 }
        fdTables[pid, default: [:]][target] = source
        retainPipeLocked(source)
        return target
    }

    func fdDup2(_ fd: Int32, _ fd2: Int32) -> Int32 {
        let pid = currentPID()
        lock.lock()
        defer { lock.unlock() }
        guard fd2 >= 0, let source = fdTables[pid]?[fd] else { return -1 }
        if fd == fd2 { return fd2 }
        releaseFDLocked(pid: pid, fd: fd2)
        fdTables[pid, default: [:]][fd2] = source
        retainPipeLocked(source)
        return fd2
    }

    func fdClose(_ fd: Int32) -> Int32 {
        let pid = currentPID()
        lock.lock()
        defer { lock.unlock() }
        releaseFDLocked(pid: pid, fd: fd)
        return 0
    }

    func fdPipe(_ fds: UnsafeMutablePointer<Int32>?) -> Int32 {
        guard let fds else { return -1 }
        let pid = currentPID()
        lock.lock()
        defer { lock.unlock() }
        let readFD = allocateFDLocked(pid: pid)
        let writeFD = allocateFDLocked(pid: pid)
        guard readFD >= 0, writeFD >= 0 else { return -1 }
        let pipeID = nextPipeID
        nextPipeID += 1
        pipes[pipeID] = KernelPipe()
        fdTables[pid, default: [:]][readFD] = KernelFD(kind: .pipeRead, pipeID: pipeID)
        fdTables[pid, default: [:]][writeFD] = KernelFD(kind: .pipeWrite, pipeID: pipeID)
        fds[0] = readFD
        fds[1] = writeFD
        return 0
    }

    func fdRead(_ fd: Int32, buffer: UnsafeMutableRawPointer?, count: Int32) -> Int32 {
        guard let buffer, count > 0 else { return 0 }
        let pid = currentPID()
        while !isTerminationRequested(pid: pid) {
            lock.lock()
            guard var entry = fdTables[pid]?[fd] else {
                lock.unlock()
                return -1
            }
            switch entry.kind {
            case .stdin:
                lock.unlock()
                let text = readStdin(maxBytes: Int(count))
                let bytes = Array(text.utf8.prefix(Int(count)))
                for (index, byte) in bytes.enumerated() {
                    buffer.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
                }
                return Int32(bytes.count)
            case .null, .pipeWrite:
                lock.unlock()
                return 0
            case .zero:
                lock.unlock()
                memset(buffer, 0, Int(count))
                return count
            case .random:
                lock.unlock()
                arc4random_buf(buffer, Int(count))
                return count
            case .memory:
                let available = max(0, entry.memory.count - entry.offset)
                let amount = min(Int(count), available)
                if amount > 0 {
                    _ = entry.memory.withUnsafeBytes { source in
                        memcpy(buffer, source.baseAddress!.advanced(by: entry.offset), amount)
                    }
                    entry.offset += amount
                    fdTables[pid]?[fd] = entry
                }
                lock.unlock()
                return Int32(amount)
            case .pipeRead:
                guard let pipeID = entry.pipeID, let pipe = pipes[pipeID] else {
                    lock.unlock()
                    return 0
                }
                let available = max(0, pipe.buffer.count - pipe.offset)
                if available == 0 {
                    let writers = pipe.writeRefs
                    lock.unlock()
                    if writers == 0 {
                        return 0
                    }
                    pipe.condition.lock()
                    pipe.condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                    pipe.condition.unlock()
                    continue
                }
                let amount = min(Int(count), available)
                if amount > 0 {
                    _ = pipe.buffer.withUnsafeBytes { source in
                        memcpy(buffer, source.baseAddress!.advanced(by: pipe.offset), amount)
                    }
                    pipe.offset += amount
                    if pipe.offset == pipe.buffer.count {
                        pipe.offset = 0
                        pipe.buffer.removeAll(keepingCapacity: true)
                    }
                    lock.unlock()
                    return Int32(amount)
                }
            default:
                lock.unlock()
                return -1
            }
        }
        return 0
    }

    func fdWrite(_ fd: Int32, buffer: UnsafeRawPointer?, count: Int32) -> Int32 {
        guard count >= 0 else { return -1 }
        let pid = currentPID()
        lock.lock()
        guard let entry = fdTables[pid]?[fd] else {
            lock.unlock()
            return -1
        }
        switch entry.kind {
        case .stdout, .stderr:
            guard let buffer else {
                lock.unlock()
                return -1
            }
            let bytes = UnsafeRawBufferPointer(start: buffer, count: Int(count))
            let text = String(decoding: bytes, as: UTF8.self)
            let stream: TTYStream = entry.kind == .stderr ? .stderr : .stdout
            lock.unlock()
            write(stream: stream, text: text)
            return count
        case .null, .zero, .random:
            lock.unlock()
            return count
        case .pipeWrite:
            guard let buffer, let pipeID = entry.pipeID, let pipe = pipes[pipeID] else {
                lock.unlock()
                return -1
            }
            let bytes = Array(UnsafeRawBufferPointer(start: buffer, count: Int(count)))
            pipe.buffer.append(contentsOf: bytes)
            let condition = pipe.condition
            lock.unlock()
            condition.lock()
            condition.broadcast()
            condition.unlock()
            return count
        default:
            lock.unlock()
            return -1
        }
    }

    func fdLseek(_ fd: Int32, offset: Int64, whence: Int32) -> Int64 {
        let pid = currentPID()
        lock.lock()
        defer { lock.unlock() }
        guard var entry = fdTables[pid]?[fd], entry.kind == .memory else { return -1 }
        let base: Int
        switch whence {
        case 0: base = 0
        case 1: base = entry.offset
        case 2: base = entry.memory.count
        default: return -1
        }
        let next = max(0, min(entry.memory.count, base + Int(offset)))
        entry.offset = next
        fdTables[pid]?[fd] = entry
        return Int64(next)
    }

    func waitpid(_ requestedPID: Int32, options: Int32) -> (pid: Int32, status: Int32) {
        let parentPID = currentPID()
        let noHang = (options & 1) != 0

        while !isTerminationRequested(pid: parentPID) {
            if let result = consumeExitedChild(parentPID: parentPID, requestedPID: requestedPID) {
                return result
            }
            if !hasWaitableChild(parentPID: parentPID, requestedPID: requestedPID) {
                return (-1, 0)
            }
            if noHang {
                return (0, 0)
            }
            processExitCondition.lock()
            processExitCondition.wait(until: Date(timeIntervalSinceNow: 0.1))
            processExitCondition.unlock()
        }
        return (-1, 0)
    }

    func panic(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.kernel?.triggerPanic(message)
        }
    }

    private func ensureTLS() {
        lock.lock()
        if !tlsReady {
            pthread_key_create(&tlsKey, nil)
            pthread_key_create(&dylibHandleKey) { raw in
                dlclose(raw)
            }
            tlsReady = true
        }
        lock.unlock()
    }

    private func unregisterProcess(pid: Int32) {
        lock.lock()
        terminationRequests.remove(pid)
        let signal = terminationSignals.removeValue(forKey: pid)
        if let table = fdTables[pid] {
            for fd in table.keys {
                releaseFDLocked(pid: pid, fd: fd)
            }
        }
        fdTables.removeValue(forKey: pid)
        nextFDByPID.removeValue(forKey: pid)
        lock.unlock()
        signal?.signal()
    }

    private func inheritStandardFDs(parentPID: Int32, childPID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var child = fdTables[childPID] ?? [
            0: KernelFD(kind: .stdin),
            1: KernelFD(kind: .stdout),
            2: KernelFD(kind: .stderr)
        ]
        for fd in 0...2 {
            if let inherited = fdTables[parentPID]?[Int32(fd)] {
                child[Int32(fd)] = inherited
                retainPipeLocked(inherited)
            } else if parentPID > 0 {
                child.removeValue(forKey: Int32(fd))
            }
        }
        fdTables[childPID] = child
        if nextFDByPID[childPID] == nil {
            nextFDByPID[childPID] = 256
        }
    }

    private func allocateFDLocked(pid: Int32) -> Int32 {
        var fd = nextFDByPID[pid] ?? 256
        while fd < 1024 {
            if fdTables[pid]?[fd] == nil {
                nextFDByPID[pid] = fd + 1
                return fd
            }
            fd += 1
        }
        return -1
    }

    private func releaseFDLocked(pid: Int32, fd: Int32) {
        guard let entry = fdTables[pid]?[fd] else { return }
        fdTables[pid]?.removeValue(forKey: fd)
        guard let pipeID = entry.pipeID, let pipe = pipes[pipeID] else { return }
        var shouldBroadcast = false
        if entry.kind == .pipeRead {
            pipe.readRefs -= 1
        } else if entry.kind == .pipeWrite {
            pipe.writeRefs -= 1
            shouldBroadcast = true
        }
        if pipe.readRefs <= 0 && pipe.writeRefs <= 0 {
            pipes.removeValue(forKey: pipeID)
        }
        if shouldBroadcast {
            pipe.condition.lock()
            pipe.condition.broadcast()
            pipe.condition.unlock()
        }
    }

    private func retainPipeLocked(_ entry: KernelFD) {
        guard let pipeID = entry.pipeID, let pipe = pipes[pipeID] else { return }
        if entry.kind == .pipeRead {
            pipe.readRefs += 1
        } else if entry.kind == .pipeWrite {
            pipe.writeRefs += 1
        }
        pipes[pipeID] = pipe
    }

    private func isTerminationRequested(pid: Int32) -> Bool {
        lock.lock()
        let requested = terminationRequests.contains(pid)
        lock.unlock()
        return requested
    }

    /// Non-blocking: has termination been requested for the calling process?
    /// A GUI runtime's frame loop polls this so a `kill` can break the loop and
    /// let the app's own `main` run its cleanup (close window, stop audio, …).
    func isTerminationRequestedForCurrentProcess() -> Bool {
        isTerminationRequested(pid: currentPID())
    }

    private func currentTTYID(for pid: Int32) -> Int32 {
        if Thread.isMainThread {
            return kernel?.ttyID(pid: pid) ?? 0
        }

        let semaphore = DispatchSemaphore(value: 0)
        var ttyID: Int32 = 0
        DispatchQueue.main.async { [weak self] in
            ttyID = self?.kernel?.ttyID(pid: pid) ?? 0
            semaphore.signal()
        }
        semaphore.wait()
        return ttyID
    }

    private func consumeExitedChild(parentPID: Int32, requestedPID: Int32) -> (pid: Int32, status: Int32)? {
        lock.lock()
        defer { lock.unlock() }

        let childPID = exitedProcesses.keys.sorted().first { pid in
            guard requestedPID <= 0 || pid == requestedPID else { return false }
            return processParents[pid] == parentPID
        }
        guard let childPID, let code = exitedProcesses.removeValue(forKey: childPID) else {
            return nil
        }
        processParents.removeValue(forKey: childPID)
        return (childPID, (code & 0xff) << 8)
    }

    private func hasWaitableChild(parentPID: Int32, requestedPID: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return processParents.contains { pid, parent in
            parent == parentPID && (requestedPID <= 0 || pid == requestedPID)
        }
    }

    private func pollInput(pid: Int32, read: @escaping @MainActor () -> String) -> String {
        while !isTerminationRequested(pid: pid) {
            let semaphore = DispatchSemaphore(value: 0)
            var result = ""
            DispatchQueue.main.async {
                result = read()
                semaphore.signal()
            }
            semaphore.wait()

            if !result.isEmpty {
                return result
            }
            usleep(10_000)
        }
        return ""
    }
}

typealias ProcessExitObserverCallback = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void

struct ProcessExitObserver {
    let pid: Int32
    let callback: ProcessExitObserverCallback
    let context: UnsafeMutableRawPointer?
}

struct ServiceEntry {
    let ownerPID: Int32
    let pointer: UnsafeMutableRawPointer
}

enum KernelFDKind: Int32 {
    case none = 0
    case stdin = 1
    case stdout = 2
    case stderr = 3
    case null = 4
    case zero = 5
    case random = 6
    case memory = 7
    case pipeRead = 8
    case pipeWrite = 9
}

struct KernelFD {
    var kind: KernelFDKind
    var pipeID: Int32?
    var memory: [UInt8]
    var offset: Int

    init(kind: KernelFDKind, pipeID: Int32? = nil, memory: [UInt8] = [], offset: Int = 0) {
        self.kind = kind
        self.pipeID = pipeID
        self.memory = memory
        self.offset = offset
    }
}

final class KernelPipe {
    var buffer: [UInt8] = []
    var offset: Int = 0
    var readRefs: Int = 1
    var writeRefs: Int = 1
    let condition = NSCondition()
}
