import Foundation
import Darwin

final class ExternalTTYBridge {
    let ttyID: Int32
    let socketPath: String

    private let clientLock = NSLock()
    private var clients: Set<Int32> = []
    private var backlog = Data()
    private var serverFD: Int32 = -1
    private var isRunning = false
    private var onInput: ((String) -> Void)?

    init(ttyID: Int32) {
        self.ttyID = ttyID
        socketPath = "/tmp/micro-os-\(getpid())-tty\(ttyID).sock"
    }

    func start(onInput: @escaping (String) -> Void) {
        self.onInput = onInput
        guard !isRunning else { return }
        isRunning = true

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        guard bindSocket(fd: fd, path: socketPath) == 0 else {
            close(fd)
            return
        }

        guard listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        serverFD = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(serverFD: fd)
        }
    }

    func appendOutput(_ text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        clientLock.lock()
        backlog.append(data)
        if backlog.count > 64 * 1024 {
            backlog.removeFirst(backlog.count - 64 * 1024)
        }
        let currentClients = clients
        clientLock.unlock()

        for client in currentClients {
            data.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                let written = Darwin.write(client, baseAddress, data.count)
                if written < 0 {
                    removeClient(client)
                }
            }
        }
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { continue }
            disableSIGPIPE(client)
            addClient(client)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.readLoop(clientFD: client)
            }
        }
    }

    private func readLoop(clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(clientFD, raw.baseAddress, raw.count)
            }
            guard count > 0 else {
                removeClient(clientFD)
                close(clientFD)
                return
            }

            let data = Data(buffer.prefix(count))
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            Task { @MainActor [weak self] in
                self?.onInput?(text)
            }
        }
    }

    private func addClient(_ fd: Int32) {
        disableSIGPIPE(fd)
        clientLock.lock()
        clients.insert(fd)
        let initialBacklog = backlog
        clientLock.unlock()
        guard !initialBacklog.isEmpty else { return }
        initialBacklog.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            let written = Darwin.write(fd, baseAddress, initialBacklog.count)
            if written < 0 {
                removeClient(fd)
            }
        }
    }

    private func removeClient(_ fd: Int32) {
        clientLock.lock()
        clients.remove(fd)
        clientLock.unlock()
    }

    private func bindSocket(fd: Int32, path: String) -> Int32 {
        guard var address = sockaddrUNIX(path: path) else { return -1 }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func disableSIGPIPE(_ fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

private func sockaddrUNIX(path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)

    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }

    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for index in 0..<raw.count {
            raw[index] = 0
        }
        for index in bytes.indices {
            raw[index] = bytes[index]
        }
    }
    return address
}
