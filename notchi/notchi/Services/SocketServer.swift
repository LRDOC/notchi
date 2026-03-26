import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SocketServer")

typealias HookEventHandler = @Sendable (HookEvent) -> Void

final class SocketServer {
    static let socketPath = "/tmp/notchi.sock"
    static let shared = SocketServer(socketPath: socketPath, clientReadTimeout: 0.5)

    private let socketPath: String
    private let clientReadTimeout: TimeInterval
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private let serverQueue = DispatchQueue(label: "com.ruban.notchi.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ruban.notchi.socket.client", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = SocketServer.socketPath, clientReadTimeout: TimeInterval = 0.5) {
        self.socketPath = socketPath
        self.clientReadTimeout = clientReadTimeout
    }

    func start(onEvent: @escaping HookEventHandler) {
        serverQueue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent

        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: serverQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    func stop() {
        serverQueue.async { [weak self] in
            self?.stopServer()
        }
    }

    private func stopServer() {
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        unlink(socketPath)
    }

    private func acceptConnections() {
        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                let acceptError = errno

                if acceptError == EINTR {
                    continue
                }

                if acceptError == EAGAIN || acceptError == EWOULDBLOCK {
                    return
                }

                logger.error("Failed to accept connection: \(acceptError)")
                return
            }

            configureClientSocket(clientSocket)
            let eventHandler = self.eventHandler
            clientQueue.async { [weak self] in
                guard let self else {
                    close(clientSocket)
                    return
                }

                self.handleClient(clientSocket, eventHandler: eventHandler)
            }
        }
    }

    private func configureClientSocket(_ clientSocket: Int32) {
        let clientFlags = fcntl(clientSocket, F_GETFL)
        if clientFlags >= 0, fcntl(clientSocket, F_SETFL, clientFlags & ~O_NONBLOCK) != 0 {
            logger.warning("Failed to clear O_NONBLOCK on client socket: \(errno)")
        }

        var nosigpipe: Int32 = 1
        if setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &nosigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) != 0 {
            logger.warning("Failed to set SO_NOSIGPIPE: \(errno)")
        }

        var timeout = makeTimeval(for: clientReadTimeout)
        if setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) != 0 {
            logger.warning("Failed to set SO_RCVTIMEO: \(errno)")
        }
    }

    private func handleClient(_ clientSocket: Int32, eventHandler: HookEventHandler?) {
        defer { close(clientSocket) }

        guard let allData = readClientPayload(from: clientSocket), !allData.isEmpty else { return }

        if let event = decodeEvent(from: allData) {
            dispatch(event)
            return
        }

        guard let payload = String(data: allData, encoding: .utf8) else {
            logger.warning("Failed to parse event (non-UTF8 payload)")
            return
        }

        var parsedAny = false
        for line in payload.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty,
                  let event = decodeEvent(from: Data(line.utf8)) else { continue }
            parsedAny = true
            dispatch(event)
        }

        if !parsedAny {
            let preview = payload
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(200)
            logger.warning("Failed to parse event payload: \(String(preview), privacy: .private)")
        }
    }

    private func decodeEvent(from data: Data) -> HookEvent? {
        try? JSONDecoder().decode(HookEvent.self, from: data)
    }

    private func dispatch(_ event: HookEvent) {
        logEvent(event)
        eventHandler?(event)
    }

    private func readClientPayload(from clientSocket: Int32) -> Data? {
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)

            if bytesRead > 0 {
                allData.append(contentsOf: buffer[0..<bytesRead])
                continue
            }

            if bytesRead == 0 {
                return allData
            }

            let readError = errno
            if readError == EINTR {
                continue
            }

            if readError == EAGAIN || readError == EWOULDBLOCK {
                logger.warning("Dropped idle client connection after read timeout")
                return nil
            }

            logger.warning("Failed to read client socket: \(readError)")
            return nil
        }
    }

    private func makeTimeval(for timeout: TimeInterval) -> timeval {
        let clampedTimeout = max(timeout, 0)
        let seconds = floor(clampedTimeout)
        let microseconds = (clampedTimeout - seconds) * 1_000_000
        return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
    }

    private func logEvent(_ event: HookEvent) {
        switch event.event {
        case "SessionStart":
            logger.info("Session started")
        case "SessionEnd":
            logger.info("Session ended")
        case "PreToolUse":
            let tool = event.tool ?? "unknown"
            logger.info("Tool: \(tool, privacy: .public)")
        case "PostToolUse":
            let tool = event.tool ?? "unknown"
            let success = event.status != "error"
            logger.info("Result: \(success ? "✓" : "✗", privacy: .public) \(tool, privacy: .public)")
        case "Stop", "SubagentStop":
            logger.info("Done")
        default:
            break
        }
    }
}
