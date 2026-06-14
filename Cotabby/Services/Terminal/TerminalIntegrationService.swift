import Foundation
import Logging

/// File overview:
/// Owns a Unix domain socket server that shell hooks connect to in order to report command buffer
/// state. Each connected shell session is tracked by PID, and the latest snapshot is published so
/// the suggestion pipeline can consume terminal focus data through the same `FocusedInputSnapshot`
/// shape used for Accessibility-based fields.
///
/// The socket lives at `~/Library/Application Support/Cotabby/terminal.sock` with owner-only
/// permissions (0600) so other users on the system cannot inject fake shell state.
///
/// **Wire format / transport.** The hooks in `scripts/shell-integration/` connect with
/// `/usr/bin/nc -U <socket>` (BSD netcat — present on every macOS install, no `brew install
/// socat` required) and write one JSON object per line. The server reads newline-delimited
/// records and decodes each one as `TerminalIpcMessage`. If you change the framing, the
/// transport line in `cotabby.zsh` / `cotabby.bash` / `cotabby.fish` must change in lockstep.
@MainActor
final class TerminalIntegrationService {
    /// Called on the main actor whenever a terminal session publishes a new focus snapshot.
    var onSnapshotUpdate: ((TerminalFocusSnapshot) -> Void)?
    /// Called when a session connects or disconnects, so the availability evaluator can re-check.
    var onSessionChange: (() -> Void)?
    /// Called when an `.accept` IPC message arrives. The environment gates this on
    /// `CotabbyDebugOptions.isEnabled` — see `TerminalIpcMessage.MessageType.accept`.
    var onAcceptRequest: (() -> Void)?

    private(set) var sessions: [Int32: TerminalSession] = [:]

    private let logger = Logger(label: "com.cotabby.terminal-integration")
    private var serverFileDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var readBuffers: [Int32: Data] = [:]

    private var socketPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Cotabby")
        return appSupport.appendingPathComponent("terminal.sock").path
    }

    // MARK: - Lifecycle

    func start() {
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: socketDir,
            withIntermediateDirectories: true
        )

        // Remove stale socket file from a previous run.
        unlink(socketPath)

        serverFileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFileDescriptor >= 0 else {
            logger.error("Failed to create Unix domain socket: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            logger.error("Socket path too long: \(socketPath)")
            close(serverFileDescriptor)
            serverFileDescriptor = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(
            MemoryLayout<sa_family_t>.size + strlen(socketPath) + 1
        )
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFileDescriptor, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            logger.error("Failed to bind socket at \(socketPath): \(errno)")
            close(serverFileDescriptor)
            serverFileDescriptor = -1
            return
        }

        // Owner-only permissions.
        chmod(socketPath, 0o600)

        guard listen(serverFileDescriptor, 8) == 0 else {
            logger.error("Failed to listen on socket: \(errno)")
            close(serverFileDescriptor)
            serverFileDescriptor = -1
            return
        }

        logger.info("Terminal integration socket listening at \(socketPath)")

        let source = DispatchSource.makeReadSource(
            fileDescriptor: serverFileDescriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.serverFileDescriptor)
            self.serverFileDescriptor = -1
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        for (fd, source) in clientSources {
            source.cancel()
            close(fd)
        }
        clientSources.removeAll()
        readBuffers.removeAll()
        sessions.removeAll()

        if serverFileDescriptor >= 0 {
            close(serverFileDescriptor)
            serverFileDescriptor = -1
        }

        unlink(socketPath)
        onSessionChange?()
    }

    // MARK: - Session queries

    /// Whether any terminal with the given bundle identifier has an active shell integration session.
    func hasActiveSession(forBundleIdentifier bundleIdentifier: String) -> Bool {
        sessions.values.contains { $0.terminalBundleIdentifier == bundleIdentifier }
    }

    /// Whether any terminal with the given PID has an active shell integration session.
    func hasActiveSession(forPid pid: Int32) -> Bool {
        sessions[pid] != nil
    }

    /// Returns the latest snapshot for the terminal with the given bundle identifier, if any.
    func latestSnapshot(forBundleIdentifier bundleIdentifier: String) -> TerminalFocusSnapshot? {
        sessions.values
            .filter { $0.terminalBundleIdentifier == bundleIdentifier }
            .compactMap(\.latestSnapshot)
            .max { $0.timestamp < $1.timestamp }
    }

    /// Returns the latest snapshot for the shell running under the given PID.
    func latestSnapshot(forPid pid: Int32) -> TerminalFocusSnapshot? {
        sessions[pid]?.latestSnapshot
    }

    /// Applies an optimistic local echo for text Cotabby itself just pasted into the shell.
    /// Bracketed paste never reaches the per-keystroke hooks, so without this the session's
    /// snapshot stays pre-paste until the user's next REAL keystroke — long enough for the
    /// acceptance whitespace reconciler and the ghost position to act on stale text. The
    /// updated snapshot flows through `onSnapshotUpdate` exactly like a hook report; the
    /// shell's next real report replaces it with ground truth.
    func applyOptimisticInsertion(shellPid: Int32, insertedText: String) {
        guard !insertedText.isEmpty,
              var session = sessions[shellPid],
              let snapshot = session.latestSnapshot else { return }
        let echoed = snapshot.appendingInsertedText(insertedText)
        session.latestSnapshot = echoed
        session.lastMessageAt = Date()
        sessions[shellPid] = session
        onSnapshotUpdate?(echoed)
    }

    // MARK: - Connection handling

    private func acceptConnection() {
        let clientFd = accept(serverFileDescriptor, nil, nil)
        guard clientFd >= 0 else { return }

        // Set non-blocking.
        let flags = fcntl(clientFd, F_GETFL)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)

        readBuffers[clientFd] = Data()

        let source = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFd)
        }
        source.setCancelHandler { [weak self] in
            self?.cleanupClient(fd: clientFd)
        }
        source.resume()
        clientSources[clientFd] = source

        logger.debug("Accepted terminal integration client (fd=\(clientFd))")
    }

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buf, buf.count)

        if bytesRead <= 0 {
            // EOF or error — client disconnected.
            clientSources[fd]?.cancel()
            return
        }

        readBuffers[fd, default: Data()].append(contentsOf: buf[0..<bytesRead])

        // Process complete lines (newline-delimited JSON).
        while let buffer = readBuffers[fd],
              let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            readBuffers[fd] = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }
            processMessage(lineData, fromFd: fd)
        }
    }

    private func processMessage(_ data: Data, fromFd fd: Int32) {
        let decoder = JSONDecoder()
        guard let message = try? decoder.decode(TerminalIpcMessage.self, from: data) else {
            logger.warning("Failed to decode terminal IPC message")
            return
        }

        switch message.type {
        case .buffer:
            handleBufferMessage(message, fromFd: fd)
        case .disconnect:
            handleDisconnectMessage(message, fromFd: fd)
        case .accept:
            logger.debug("Accept request received over terminal IPC")
            onAcceptRequest?()
        }
    }

    private func handleBufferMessage(_ message: TerminalIpcMessage, fromFd fd: Int32) {
        guard let text = message.text,
              let cursor = message.cursor,
              let shell = message.shell,
              let terminal = message.terminal,
              let pid = message.pid
        else {
            logger.warning("Incomplete buffer message from terminal hook")
            return
        }

        let now = Date()
        let snapshot = TerminalFocusSnapshot(
            commandBuffer: text,
            cursorOffset: cursor,
            shellType: shell,
            terminalBundleIdentifier: terminal,
            shellPid: pid,
            terminalWindowFrame: nil, // Resolved later by TerminalGeometryResolver.
            estimatedCursorPosition: nil,
            cursorRow: message.row,
            cursorColumn: message.col,
            timestamp: now
        )

        if sessions[pid] == nil {
            sessions[pid] = TerminalSession(
                shellPid: pid,
                shellType: shell,
                terminalBundleIdentifier: terminal,
                connectedAt: now,
                lastMessageAt: now,
                latestSnapshot: snapshot
            )
            logger.info("New terminal session: pid=\(pid), shell=\(shell.rawValue), terminal=\(terminal)")
            onSessionChange?()
        } else {
            sessions[pid]?.lastMessageAt = now
            sessions[pid]?.latestSnapshot = snapshot
            // `exec <other-shell>` keeps the PID, so a same-pid report can legitimately arrive
            // from a different shell. Follow it — a stale shellType mislabels every downstream
            // prompt and hides the switch from diagnostics.
            if let previous = sessions[pid]?.shellType, previous != shell {
                sessions[pid]?.shellType = shell
                logger.info("Terminal session switched shell: pid=\(pid), \(previous.rawValue) → \(shell.rawValue)")
            }
        }

        onSnapshotUpdate?(snapshot)
    }

    private func handleDisconnectMessage(_ message: TerminalIpcMessage, fromFd fd: Int32) {
        if let pid = message.pid {
            sessions.removeValue(forKey: pid)
            logger.info("Terminal session disconnected: pid=\(pid)")
            onSessionChange?()
        }
    }

    private func cleanupClient(fd: Int32) {
        close(fd)
        clientSources.removeValue(forKey: fd)
        readBuffers.removeValue(forKey: fd)

        // Remove any sessions that were associated with this fd.
        // Since we don't track fd→pid mapping directly, stale sessions are cleaned up by timeout.
        logger.debug("Terminal integration client disconnected (fd=\(fd))")
    }

    // MARK: - Stale session cleanup

    /// Removes sessions whose shell process no longer exists.
    /// Called periodically from the app's main polling loop.
    ///
    /// Liveness, not message recency: a shell suspended under a full-screen TUI (Claude Code
    /// owning the tty) goes silent for arbitrarily long while remaining the session the user
    /// will return to — and "this app has a live shell session" now drives shell-surface
    /// behavior (terminal accept key, inline rendering) in embedded-terminal hosts like
    /// VS Code, so silence-based pruning would flip those behaviors off after 30 quiet
    /// seconds. `kill(pid, 0)` probes existence without signaling; EPERM still means alive.
    func pruneStaleSessionsIfNeeded() {
        let dead = sessions.filter { kill($0.value.shellPid, 0) != 0 && errno == ESRCH }

        guard !dead.isEmpty else { return }

        for (pid, _) in dead {
            sessions.removeValue(forKey: pid)
            logger.info("Pruned dead terminal session: pid=\(pid)")
        }
        onSessionChange?()
    }
}
