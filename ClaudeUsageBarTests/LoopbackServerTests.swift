import Testing
import Foundation

/// Real-socket tests: every case binds a live loopback port, so the suite is serialized
/// and every wait is bounded (a hung listener must fail the run, not stall CI).
@Suite("LoopbackServer", .serialized)
struct LoopbackServerTests {
    @Test("Delivers the code from GET /callback with matching state")
    func roundTrip() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)

        // favicon + wrong-state noise first — neither may complete the flow, and the
        // listener must still be up for the real callback that follows.
        #expect(try await get(port: port, path: "/favicon.ico").status == 404)
        #expect(try await get(port: port, path: "/callback?code=x&state=WRONG").status == 404)
        let good = try await get(port: port, path: "/callback?code=good-code&state=st8")
        #expect(good.status == 200)

        let code = await captured
        #expect(code == "good-code")
        await server.stop()
    }

    @Test("The success page echoes no request content")
    func successPageIsStatic() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)
        let page = try await get(port: port, path: "/callback?code=secret-code&state=st8")
        _ = await captured
        #expect(!page.body.contains("secret-code"))
        #expect(!page.body.contains("st8"))
        #expect(!page.body.contains("callback"))
        #expect(page.headers["Cache-Control"] == "no-store")
        await server.stop()
    }

    @Test("Rejects non-GET, wrong path, and missing code")
    func rejectsInvalidRequests() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)

        #expect(try await raw(port: port, request: "POST /callback?code=c&state=st8 HTTP/1.1\r\nHost: x\r\n\r\n").contains("404"))
        #expect(try await get(port: port, path: "/callback").status == 404)
        #expect(try await get(port: port, path: "/callback?state=st8").status == 404)
        #expect(try await get(port: port, path: "/callback?code=&state=st8").status == 404)
        #expect(try await get(port: port, path: "/other?code=c&state=st8").status == 404)

        // Still listening: the real callback lands after all of it.
        #expect(try await get(port: port, path: "/callback?code=late-but-good&state=st8").status == 200)
        #expect(await captured == "late-but-good")
        await server.stop()
    }

    @Test("Reassembles a request split across TCP segments")
    func partialReads() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)
        let reply = try await raw(
            port: port,
            chunks: ["GET /callb", "ack?code=split-code&st", "ate=st8 HTTP/1.1\r\nHost: localhost\r\n", "\r\n"])
        #expect(reply.contains("200 OK"))
        #expect(await captured == "split-code")
        await server.stop()
    }

    @Test("start() throws bindFailed when the port is already taken")
    func bindFailure() async throws {
        let hog = try PortHog()
        defer { hog.close() }
        let server = LoopbackServer(requestedPort: hog.port)
        await #expect(throws: LoopbackServer.StartError.self) {
            _ = try await server.start()
        }
        await server.stop()
    }

    @Test("waitForCallback returns nil on timeout")
    func timesOut() async throws {
        let server = LoopbackServer(gracePeriod: 0.2)
        _ = try await server.start()
        let code = await server.waitForCallback(expectedState: "st8", timeout: 0.2)
        #expect(code == nil)
        await server.stop()
    }

    @Test("After timeout a late callback gets the expired page, not connection-refused")
    func expiredPageDuringGracePeriod() async throws {
        let server = LoopbackServer(gracePeriod: 30)
        let port = try await server.start()
        #expect(await server.waitForCallback(expectedState: "st8", timeout: 0.2) == nil)
        let late = try await get(port: port, path: "/callback?code=too-late&state=st8")
        #expect(late.status == 200)
        #expect(late.body.lowercased().contains("expired"))
        #expect(!late.body.contains("too-late"))
        await server.stop()
    }

    @Test("Two valid callbacks at once complete the login exactly once")
    func simultaneousCallbacks() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 5)
        async let first = get(port: port, path: "/callback?code=first&state=st8")
        async let second = get(port: port, path: "/callback?code=second&state=st8")
        let statuses = try await [first.status, second.status].sorted()
        // Exactly one is accepted; the other is refused rather than resuming the waiter
        // a second time (a double resume would crash this test process).
        #expect(statuses == [200, 404])
        let code = await captured
        #expect(code == "first" || code == "second")
        // A wait after the login is spent returns nil instead of re-arming the listener.
        #expect(await server.waitForCallback(expectedState: "st8", timeout: 5) == nil)
        await server.stop()
    }

    /// The dangerous interleaving: a valid callback accepted at almost exactly the instant
    /// the timeout fires. However it lands, the two sides must agree — a browser told
    /// "Logged in" means the caller MUST get the code, and the expired page means the caller
    /// MUST see `nil`. Dropping an accepted code is unrecoverable (it is single-use) and does
    /// not reproduce on demand, so the arrival instant is swept across the deadline: the
    /// request sits complete-but-for-its-terminator in the server's buffer, and the final two
    /// bytes decide which side of the deadline it lands on.
    @Test("A callback landing on the timeout instant is never silently dropped")
    func callbackAtTheTimeoutInstant() async throws {
        let timeout: TimeInterval = 0.03
        for offsetMicroseconds in stride(from: -2500, through: 600, by: 100) {
            // 5 s of grace, not 1: the only way this test can false-fail is a `try` throwing
            // because a stall between the sleep and the write outlasted the grace period and
            // the server cancelled the connection underneath it.
            let server = LoopbackServer(gracePeriod: 5)
            let port = try await server.start()
            let client = try PortHog.connect(to: port)
            defer { client.close() }

            let armed = DispatchTime.now()
            async let captured = server.waitForCallback(expectedState: "st8", timeout: timeout)
            try client.write("GET /callback?code=race&state=st8 HTTP/1.1\r\nHost: localhost\r\n")
            let deadline = armed + timeout + Double(offsetMicroseconds) / 1_000_000
            try await Task.sleep(nanoseconds: deadline.nanosecondsFromNow)
            try client.write("\r\n")

            let reply = try client.readAll(timeout: 5)
            let code = await captured
            if reply.contains("Logged in") {
                #expect(code == "race", "the browser was told the login succeeded but the code was dropped")
            } else {
                #expect(code == nil, "the caller got a code the browser was never told about")
            }
            await server.stop()
        }
    }

    @Test("A wait after a timeout returns nil at once instead of timing out again")
    func waitAfterTimeoutReturnsImmediately() async throws {
        let server = LoopbackServer(gracePeriod: 0.2)
        _ = try await server.start()
        #expect(await server.waitForCallback(expectedState: "st8", timeout: 0.1) == nil)
        // A 30 s timeout that returns instantly can only be the spent-login guard.
        let elapsed = await ContinuousClock().measure {
            _ = await server.waitForCallback(expectedState: "st8", timeout: 30)
        }
        #expect(elapsed < .seconds(1))
        await server.stop()
    }

    @Test("start() after stop() fails instead of handing back a dead port")
    func startAfterStop() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        await server.stop()
        await #expect(throws: LoopbackServer.StartError.self) {
            _ = try await server.start()
        }
        #expect(port != 0)
    }

    @Test("Percent-encoded query values are decoded before the state check")
    func percentEncodedValues() async throws {
        let server = LoopbackServer()
        let port = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st 8", timeout: 5)
        #expect(try await get(port: port, path: "/callback?code=a%2Fb%20c&state=st%208").status == 200)
        #expect(await captured == "a/b c")
        await server.stop()
    }

    @Test("stop() while waiting resumes the waiter exactly once")
    func stopWhileWaiting() async throws {
        let server = LoopbackServer()
        _ = try await server.start()
        async let captured = server.waitForCallback(expectedState: "st8", timeout: 30)
        await server.stop()
        #expect(await captured == nil)
        await server.stop()   // idempotent
    }

    @Test("Ports are released between logins")
    func portsAreReleased() async throws {
        var ports: [UInt16] = []
        for _ in 0..<3 {
            let server = LoopbackServer()
            ports.append(try await server.start())
            await server.stop()
        }
        #expect(ports.allSatisfy { $0 != 0 })
        // Rebinding one of the released ports proves the previous listener let go of it.
        let reused = LoopbackServer(requestedPort: ports[0])
        #expect(try await reused.start() == ports[0])
        await reused.stop()
    }

    // MARK: - HTTP helpers

    private struct Reply {
        let status: Int
        let body: String
        let headers: [String: String]
    }

    private func get(port: UInt16, path: String) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = Dictionary(uniqueKeysWithValues: (http?.allHeaderFields ?? [:]).compactMap {
            key, value -> (String, String)? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return (key, value)
        })
        return Reply(status: http?.statusCode ?? -1, body: String(decoding: data, as: UTF8.self), headers: headers)
    }

    /// Sends bytes verbatim (URLSession can't express a malformed or split request) and
    /// returns whatever the server wrote back.
    private func raw(port: UInt16, request: String) async throws -> String {
        try await raw(port: port, chunks: [request])
    }

    private func raw(port: UInt16, chunks: [String]) async throws -> String {
        let client = try PortHog.connect(to: port)
        defer { client.close() }
        for chunk in chunks {
            try client.write(chunk)
            try await Task.sleep(nanoseconds: 20_000_000)   // force separate TCP segments
        }
        return try client.readAll(timeout: 5)
    }
}

private extension DispatchTime {
    /// Nanoseconds still to run, or 0 if the instant has already passed. (Dispatch's own
    /// `DispatchTime + Double` does the arithmetic, and handles the sweep's negative
    /// offsets.)
    var nanosecondsFromNow: UInt64 {
        // One read of the clock, not two: comparing against one `now` and subtracting a
        // second one lets the deadline pass in between, and the unsigned subtraction would
        // then trap and take the whole test process down with it.
        let now = DispatchTime.now().uptimeNanoseconds
        return uptimeNanoseconds > now ? uptimeNanoseconds - now : 0
    }
}

/// A plain POSIX socket: holds a port hostage for the bind-failure test, and doubles as
/// the raw client the framing tests need.
private final class PortHog {
    let fd: Int32
    private(set) var port: UInt16 = 0

    enum Failure: Error { case syscall(String) }

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket") }
        var addr = PortHog.loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw Failure.syscall("bind/listen")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: assigned.sin_port)
    }

    private init(connectedTo fd: Int32) {
        self.fd = fd
    }

    static func connect(to port: UInt16) throws -> PortHog {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.syscall("socket") }
        var addr = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw Failure.syscall("connect")
        }
        return PortHog(connectedTo: fd)
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return addr
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw Failure.syscall("write") }
    }

    /// Reads until the peer closes (the server always sends `Connection: close`) or the
    /// bound elapses, so a silent server fails the test instead of hanging it.
    func readAll(timeout: TimeInterval) throws -> String {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }

    func close() {
        Darwin.close(fd)
    }
}
