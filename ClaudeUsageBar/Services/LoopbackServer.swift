import Foundation
import Network

/// Catches the browser's OAuth redirect on a local port.
///
/// Serves until satisfied or timed out — never single-shot. Browsers speculatively open
/// connections and ask for `/favicon.ico`, and the authorization code is single-use, so a
/// listener that consumed the first connection and exited could lose the real callback and
/// strand the login. Anything that is not `GET /callback` carrying a non-empty `code` and a
/// `state` equal to `expectedState` gets a `404`, and the listener keeps accepting.
///
/// Binds `127.0.0.1` only (never all interfaces) on an OS-assigned port. Every response
/// body is a fixed string: no request-derived content — path, query, `code`, `state` — is
/// ever written back, so nothing from the redirect can be reflected into the page.
///
/// Lifecycle: `start()` → `waitForCallback(expectedState:timeout:)` → `stop()`. Shutdown is
/// the caller's job: the server does not tear itself down on success, so the browser tab
/// finishes loading the success page. `stop()` is idempotent, requests cancellation before
/// it returns (the port has been immediately re-bindable in practice — see the
/// `Ports are released between logins` test), and is safe to call while a wait is in flight
/// (the waiter is then resumed with `nil`).
///
/// Start the wait BEFORE opening the browser: until `waitForCallback` arms the listener, a
/// callback would be answered `404` like any other stray request.
actor LoopbackServer {
    enum StartError: Error { case bindFailed }

    /// Cap on how long `start()` waits for the listener to report ready or failed. A bind
    /// that has not resolved by then is reported as `.bindFailed` so the login can fall
    /// back to paste mode instead of hanging.
    private static let bindTimeout: TimeInterval = 5

    private let engine: LoopbackEngine
    private let requestedPort: UInt16
    private let gracePeriod: TimeInterval

    private var port: UInt16?
    private var waiter: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var isStopped = false
    /// Set once this instance's single login has been settled — delivered or expired. A
    /// spent server can never be re-armed, so a later wait returns `nil` at once.
    private var isSpent = false

    /// - Parameters:
    ///   - gracePeriod: how long the "login expired" page keeps being served after a
    ///     timeout, so a late browser redirect lands on a page instead of
    ///     connection-refused. The listener shuts itself down when it elapses.
    ///   - requestedPort: a fixed port instead of an OS-assigned one. Test seam only —
    ///     production uses the default `0` (ephemeral); a fixed port is what lets a test
    ///     force a real bind conflict.
    init(gracePeriod: TimeInterval = 600, requestedPort: UInt16 = 0) {
        self.gracePeriod = gracePeriod
        self.requestedPort = requestedPort
        self.engine = LoopbackEngine()
    }

    /// Binds the loopback port and returns the OS-assigned port number.
    /// - Throws: `StartError.bindFailed` if the listener cannot bind or does not become
    ///   ready within `bindTimeout`. The login flow's paste-mode fallback is driven by this
    ///   error, so a bind failure is a handled condition, never a crash.
    func start() throws -> UInt16 {
        guard !isStopped else { throw StartError.bindFailed }
        if let port { return port }
        // The engine blocks until the listener reports ready or failed. The signal comes
        // from the engine's own dispatch queue — never from this actor — so the wait cannot
        // deadlock on itself, and it is capped by `bindTimeout`.
        let bound = try engine.start(requestedPort: requestedPort, readyTimeout: Self.bindTimeout)
        port = bound
        return bound
    }

    /// Waits for `GET /callback?code=…&state=…` with `state == expectedState` and returns
    /// the code, or `nil` on timeout, on `stop()`, or if the server was never started.
    ///
    /// `timeout` bounds how long this waits for a callback to be *accepted*, not the total
    /// call duration: a callback accepted right at the boundary is always delivered, so a
    /// successful return can legitimately arrive slightly after `timeout` has elapsed. A
    /// caller must not treat "took longer than `timeout`" as a failure — read the result.
    ///
    /// One login per instance: a second call — concurrent, or after this login was already
    /// settled by delivery or timeout — returns `nil` immediately rather than displacing the
    /// first waiter or waiting out a full timeout against a listener that can no longer be
    /// armed. The continuation is resumed exactly once: by delivery, timeout, or `stop()`,
    /// whichever reaches the actor first.
    func waitForCallback(expectedState: String, timeout: TimeInterval) async -> String? {
        guard port != nil, !isStopped, !isSpent, waiter == nil else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            waiter = continuation
            engine.arm(expectedState: expectedState) { [weak self] code in
                Task { await self?.deliver(code) }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expire()
            }
        }
    }

    /// Cancels the listener and every open connection, and resumes a waiter (if any) with
    /// `nil`. Idempotent.
    func stop() {
        isStopped = true
        graceTask?.cancel()
        graceTask = nil
        engine.stop()
        finish(with: nil)
    }

    private func deliver(_ code: String) {
        isSpent = true
        finish(with: code)
    }

    /// Timeout reached: the engine stops completing logins and switches to the static
    /// "expired" page for `gracePeriod`, then the server shuts down.
    private func expire() {
        // No waiter left means delivery or `stop()` already resumed it.
        guard waiter != nil else { return }
        // A live waiter does NOT mean no code is in flight: between the engine accepting a
        // callback and its `deliver` hop landing here, the waiter is still set. Only the
        // engine can settle that, so ask it synchronously — and if it says a code was
        // already accepted, do nothing at all: resuming `nil` here would silently drop a
        // single-use code while the browser reads "Logged in". That delivery is expected to
        // arrive: `respond` calls its completion synchronously when the connection is
        // already gone, and otherwise relies on `send` completing (including with an error).
        // If that ever failed to fire, the wait would outlast its timeout until the caller
        // calls `stop()`.
        guard engine.expire() else { return }
        isSpent = true
        finish(with: nil)
        graceTask = Task { [weak self, gracePeriod] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, gracePeriod) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    /// The one place the continuation is resumed. Actor isolation serializes every caller
    /// (delivery, timeout, `stop()`), and the waiter is cleared before resuming, so a
    /// second arrival is dropped instead of resuming twice.
    private func finish(with code: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(returning: code)
    }
}

/// The `Network` plumbing behind `LoopbackServer`, kept out of the actor: `NWListener` and
/// `NWConnection` deliver their callbacks on a `DispatchQueue`, and no `Network` type ever
/// crosses into the actor — only `String`/`UInt16` do.
///
/// All mutable state below is confined to `queue`. The entry points called from the actor
/// (`start`, `arm`, `expire`, `stop`) hop onto it explicitly; every other method runs from a
/// `Network` callback, which is delivered on the queue passed to `start(queue:)`.
/// `assertOnQueue()` turns a violation of that into a DEBUG test failure rather than a
/// silent data race.
private final class LoopbackEngine: @unchecked Sendable {
    private enum Phase {
        case idle           // bound, not yet waiting for a callback
        case awaiting       // a login is in flight; a matching callback completes it
        case satisfied      // the code was delivered; no further completions
        case expired        // timed out; serving the static "expired" page
        case stopped
    }

    /// Header bytes accepted per connection before the request is abandoned. The real
    /// callback is a single short GET; anything larger is noise or an attack.
    private static let maxRequestBytes = 16 * 1024
    /// Concurrent connections held open. Browser preconnects add a handful. This bounds the
    /// buffer space stray connections can occupy; it is not a defence against a local process
    /// that deliberately fills every slot (out of scope — a same-user attacker has far better
    /// levers than this listener).
    private static let maxConnections = 64

    private let queue = DispatchQueue(label: "com.sam.ClaudeUsageBar.loopback")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var phase: Phase = .idle
    private var expectedState = ""
    private var onCode: (@Sendable (String) -> Void)?

    // MARK: - Lifecycle (called from the actor)

    /// Starts the listener and blocks until it reports ready (returning the bound port) or
    /// fails. Called from the actor; the semaphore is signalled from `queue`, so the two
    /// never wait on each other.
    func start(requestedPort: UInt16, readyTimeout: TimeInterval) throws -> UInt16 {
        let endpointPort = requestedPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedPort)
        guard let endpointPort else { throw LoopbackServer.StartError.bindFailed }
        let parameters = NWParameters.tcp
        // Loopback only: `requiredLocalEndpoint` pins the bind to 127.0.0.1 — verified with
        // `lsof`, which shows `TCP 127.0.0.1:<port> (LISTEN)` and no wildcard socket. Port 0
        // means OS-assigned. Endpoint reuse stays off; an already-taken port was then observed
        // to fail with EADDRINUSE rather than bind alongside.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackServer.StartError.bindFailed
        }

        let outcome = BindOutcome()
        let resolved = DispatchSemaphore(value: 0)
        queue.sync {
            self.listener = listener
            self.phase = .idle
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state, outcome: outcome, resolved: resolved)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: self.queue)
        }

        guard resolved.wait(timeout: .now() + readyTimeout) == .success, let bound = outcome.port else {
            stop()
            throw LoopbackServer.StartError.bindFailed
        }
        return bound
    }

    func arm(expectedState: String, onCode: @escaping @Sendable (String) -> Void) {
        queue.async {
            guard self.phase == .idle else { return }
            self.expectedState = expectedState
            self.onCode = onCode
            self.phase = .awaiting
        }
    }

    /// Closes the window for completing this login.
    ///
    /// Synchronous, and its answer is what the caller's timeout decision hangs on: anything
    /// already queued — including the final chunk of a callback that is mid-parse — runs
    /// before this block, so the phase read here accounts for it.
    ///
    /// - Returns: `false` only when a callback has already been accepted and its code is on
    ///   its way to the actor (`.satisfied`); the caller must NOT report a timeout then, or
    ///   a single-use code would be dropped while the browser shows "Logged in". Every other
    ///   phase returns `true`: either nothing has been accepted, or `stop()` has already
    ///   settled the login and resumed the waiter itself — in neither case can reporting a
    ///   timeout strand the caller.
    func expire() -> Bool {
        queue.sync {
            guard phase != .satisfied else { return false }
            if phase == .awaiting {
                phase = .expired
                expectedState = ""
                onCode = nil
            }
            return true
        }
    }

    /// Synchronous on purpose: when this returns, `cancel()` has been called on the listener
    /// and on every open connection, so teardown is ordered ahead of whatever the caller does
    /// next. `NWListener.cancel()` itself completes asynchronously, so this orders the request
    /// rather than proving the socket is closed; in practice the port has been re-bindable
    /// immediately. (`queue` only runs non-blocking work and nothing on it waits on the actor,
    /// so this cannot deadlock.)
    func stop() {
        queue.sync {
            self.phase = .stopped
            self.expectedState = ""
            self.onCode = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            self.connections.removeAll()
            self.buffers.removeAll()
        }
    }

    // MARK: - Listener callbacks (on `queue`)

    private func handleListenerState(_ state: NWListener.State, outcome: BindOutcome, resolved: DispatchSemaphore) {
        assertOnQueue()
        switch state {
        case .ready:
            // A ready listener without a port is anomalous; report it as a bind failure
            // rather than hand the login a redirect URI that cannot be built.
            if outcome.resolve(port: listener?.port?.rawValue) { resolved.signal() }
        case .failed, .waiting:
            // A taken port was observed to arrive here as `.failed(EADDRINUSE)`. `.waiting`
            // is treated the same way rather than waited out: a listener that is not
            // accepting is no use to a login that is about to open a browser, and the
            // caller has a paste-mode fallback ready.
            if outcome.resolve(port: nil) { resolved.signal() }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        assertOnQueue()
        guard phase != .stopped, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        buffers[id] = Data()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id: id)
    }

    // MARK: - Request handling (on `queue`)

    private func receive(id: ObjectIdentifier) {
        assertOnQueue()
        guard let connection = connections[id] else { return }
        // Only `id` is captured — never the connection — so no `Network` type is captured
        // in an escaping closure.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            self?.handleChunk(id: id, data: data, isComplete: isComplete, failed: error != nil)
        }
    }

    /// Accumulates until the `\r\n\r\n` header terminator: a request can arrive across
    /// several TCP segments, so one `receive` is not assumed to hold a whole request.
    private func handleChunk(id: ObjectIdentifier, data: Data?, isComplete: Bool, failed: Bool) {
        assertOnQueue()
        guard connections[id] != nil else { return }

        if let data, !data.isEmpty {
            var buffer = buffers[id] ?? Data()
            buffer.append(data)
            guard buffer.count <= Self.maxRequestBytes else {
                buffers[id] = nil
                respond(id: id, with: HTTPReply.notFound)
                return
            }
            buffers[id] = buffer
            if let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                buffers[id] = nil
                handleRequest(head: buffer[..<terminator.lowerBound], id: id)
                return
            }
        }
        guard !isComplete, !failed else {
            closeConnection(id)
            return
        }
        receive(id: id)
    }

    private func handleRequest(head: Data, id: ObjectIdentifier) {
        assertOnQueue()
        let request = LoopbackRequest(head: head)
        switch phase {
        case .awaiting:
            guard let code = request.callbackCode(matchingState: expectedState) else {
                respond(id: id, with: HTTPReply.notFound)
                return
            }
            phase = .satisfied
            let deliver = onCode
            onCode = nil
            expectedState = ""
            // The code is handed over only once the success page has been written, so a
            // caller that stops the server the moment it has the code cannot cut the
            // browser's page off mid-flight.
            respond(id: id, with: HTTPReply.success) { deliver?(code) }
        case .expired:
            // A late redirect must not land on connection-refused: serve the static
            // "expired" page for any well-formed callback GET, without completing anything.
            respond(id: id, with: request.isCallbackGET ? HTTPReply.expired : HTTPReply.notFound)
        case .idle, .satisfied, .stopped:
            respond(id: id, with: HTTPReply.notFound)
        }
    }

    /// Writes one fixed reply and closes. `finished` runs after the write — and still runs
    /// if the connection has already gone, so a lost socket can never swallow a code that
    /// was accepted.
    private func respond(id: ObjectIdentifier, with reply: Data, then finished: (@Sendable () -> Void)? = nil) {
        assertOnQueue()
        guard let connection = connections[id] else {
            finished?()
            return
        }
        connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection(id)
            finished?()
        })
    }

    private func closeConnection(_ id: ObjectIdentifier) {
        queue.async {
            guard let connection = self.connections[id] else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.forget(id)
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        queue.async {
            self.connections[id] = nil
            self.buffers[id] = nil
        }
    }

    /// Everything in this class assumes `Network` callbacks arrive on `queue` (the queue
    /// handed to `start(queue:)`), which is what makes the unsynchronized state above safe.
    /// The DEBUG check turns a violation into a test failure instead of a silent data race,
    /// and is compiled out of the shipped build.
    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }
}

/// First-wins box for the bind outcome, written from the listener's queue and read by the
/// blocked caller once the semaphore is signalled.
private final class BindOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var boundPort: UInt16?

    /// - Returns: `true` only for the first call, so the semaphore is signalled once.
    func resolve(port: UInt16?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return false }
        isResolved = true
        boundPort = port
        return true
    }

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }
}

/// The parsed request line. Only the pieces the callback check needs are read; the body and
/// every other header are ignored, and nothing parsed here is ever written back to the
/// browser.
private struct LoopbackRequest {
    let isGET: Bool
    let path: String
    let queryItems: [URLQueryItem]

    init(head: Data) {
        // Invalid UTF-8 decodes to replacement characters, which simply fail the checks
        // below — a malformed request is a 404, not a crash.
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let fields = requestLine.split(separator: " ")
        isGET = fields.first == "GET"
        // Browsers send an origin-form target (`/callback?…`); parsing it against a dummy
        // authority yields percent-decoded query values (covered by a test). Any other target
        // shape simply fails the `/callback` path check below.
        let components = fields.count > 1 ? URLComponents(string: "http://127.0.0.1" + fields[1]) : nil
        path = components?.path ?? ""
        queryItems = components?.queryItems ?? []
    }

    var isCallbackGET: Bool { isGET && path == "/callback" }

    /// The authorization code, only if this is a `GET /callback` carrying a non-empty
    /// `code` and a `state` equal to `expected`. The state check is the flow's anti-CSRF
    /// control: without it the listener would accept a code injected by any local process
    /// or hostile page that guessed the port.
    func callbackCode(matchingState expected: String) -> String? {
        guard isCallbackGET else { return nil }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        guard let state = queryItems.first(where: { $0.name == "state" })?.value, !state.isEmpty else { return nil }
        guard LoopbackRequest.statesMatch(state, expected) else { return nil }
        return code
    }

    /// Byte-wise comparison with no early exit on the first difference. Lengths are still
    /// distinguishable; the contents are not.
    private static func statesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

/// The three fixed responses. Bodies are constants — no request content is ever echoed —
/// and `no-store` keeps the page (and the URL that produced it) out of the browser cache.
private enum HTTPReply {
    static let success = response(status: "200 OK", body: page(
        title: "Logged in",
        heading: "Logged in",
        message: "You can close this tab and go back to ClaudeUsageBar."))

    static let expired = response(status: "200 OK", body: page(
        title: "Login expired",
        heading: "Login expired",
        message: "Close this tab and start a new login from the app."))

    static let notFound = response(status: "404 Not Found", body: page(
        title: "Not found",
        heading: "Not found",
        message: "Nothing here."))

    private static func page(title: String, heading: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title)</title></head>
        <body style="font: 16px -apple-system, system-ui, sans-serif; margin: 4rem auto; max-width: 30rem; text-align: center">
        <h1 style="font-size: 1.25rem">\(heading)</h1>
        <p>\(message)</p>
        </body>
        </html>
        """
    }

    private static func response(status: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        let head = headers.map { $0 + "\r\n" }.joined() + "\r\n"
        return Data(head.utf8) + bodyData
    }
}
