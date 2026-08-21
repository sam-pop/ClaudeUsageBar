import Testing
import Foundation

/// Test-only rendezvous: lets a concurrently-running call (e.g. a stale `refresh()`) signal
/// that it has reached a specific suspension point, and lets the test block until that
/// signal arrives before proceeding — then release it deterministically later. Avoids
/// relying on `Task.yield()` timing assumptions to force a specific interleaving.
private actor AsyncGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the code under test: signals arrival, then suspends until `release()`.
    func arriveAndWait() async {
        arrived = true
        let pending = arrivalWaiters
        arrivalWaiters.removeAll()
        pending.forEach { $0.resume() }

        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    /// Called by the test: blocks until `arriveAndWait()` has been called at least once.
    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Called by the test: lets a suspended `arriveAndWait()` call resume.
    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@Suite("AccountRuntime")
@MainActor
struct AccountRuntimeTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "AccountRuntimeTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func response(five: Double, seven: Double) -> UsageResponse {
        UsageResponse(
            fiveHour: UsagePeriod(utilization: five, resetsAt: "2026-07-09T18:30:00Z"),
            sevenDay: UsagePeriod(utilization: seven, resetsAt: "2026-07-16T00:00:00Z")
        )
    }

    /// Builds a runtime whose credential store already holds a token, with injected deps.
    private func makeRuntime(
        id: UUID = UUID(),
        defaults: UserDefaults,
        fetchUsage: @escaping (String) async throws -> UsageResponse,
        onChange: @escaping () -> Void = {}
    ) throws -> AccountRuntime {
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-tok", refreshToken: "r", expiresAt: nil)
        ])
        let manager = AccountCredentialManager(store: store)
        let persistence = AccountPersistence(defaults: defaults, accountID: id)
        let deps = AccountRuntime.Dependencies(
            fetchUsage: fetchUsage,
            refreshToken: { $0 },
            now: { self.t0 }
        )
        return AccountRuntime(id: id, credentials: manager, persistence: persistence,
                              deps: deps, onChange: onChange)
    }

    @Test("Successful refresh stores the snapshot, records history, and fires onChange")
    func refreshSuccess() async throws {
        let defaults = ephemeralDefaults()
        var changeCount = 0
        let runtime = try makeRuntime(defaults: defaults,
                                      fetchUsage: { _ in self.response(five: 30, seven: 60) },
                                      onChange: { changeCount += 1 })

        await runtime.refresh()

        #expect(runtime.snapshot?.fiveHourPercent == 30)
        #expect(runtime.snapshot?.sevenDayPercent == 60)
        #expect(runtime.state == .loaded(try #require(runtime.snapshot)))
        #expect(runtime.history.count == 1)
        #expect(changeCount >= 1)
        // Persisted so a fresh runtime on the same account reloads it.
        #expect(defaults.data(forKey: "lastSnapshot-\(runtime.id.uuidString)") != nil)
    }

    @Test("A 401 triggers an OAuth refresh and the retried fetch succeeds")
    func recoversViaOAuthRefresh() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-old", refreshToken: "r", expiresAt: nil)
        ])
        let manager = AccountCredentialManager(store: store)

        var fetchCalls = 0
        var refreshCalls = 0
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { token in
                fetchCalls += 1
                if token == "sk-ant-oat01-old" { throw UsageAPIError.invalidResponse(401) }
                return self.response(five: 15, seven: 25)   // succeeds with the refreshed token
            },
            refreshToken: { old in
                refreshCalls += 1
                return CachedCredentials(accessToken: "sk-ant-oat01-new",
                                         refreshToken: old.refreshToken, expiresAt: nil)
            },
            now: { self.t0 }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()

        #expect(refreshCalls == 1)
        #expect(fetchCalls == 2)                       // 401, then success
        #expect(runtime.snapshot?.fiveHourPercent == 15)
        // The refreshed token was persisted back into the account's slot.
        #expect(try manager.credentials(for: id)?.accessToken == "sk-ant-oat01-new")
    }

    @Test("A failed fetch surfaces an error without a prior snapshot")
    func refreshErrorNoSnapshot() async throws {
        let defaults = ephemeralDefaults()
        let runtime = try makeRuntime(defaults: defaults,
                                      fetchUsage: { _ in throw UsageAPIError.invalidResponse(500) })

        await runtime.refresh()

        if case .error = runtime.state {} else {
            Issue.record("expected .error state, got \(runtime.state)")
        }
        #expect(runtime.snapshot == nil)
    }

    @Test("credentialsReplaced resets a tripped breaker, clears needsReAuth, and refreshes")
    func credentialsReplacedResetsBreakerAndRefreshes() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-dead", refreshToken: "r-old", expiresAt: nil)
        ])
        let manager = AccountCredentialManager(store: store)

        // Three consecutive rejections trip the breaker at t0; its 600s re-arm window
        // means `allowsAttempt` stays false for a long time unless something resets it.
        var trippedBreaker = RefreshCircuitBreaker()
        trippedBreaker.record(.rejected, now: t0)
        trippedBreaker.record(.rejected, now: t0)
        trippedBreaker.record(.rejected, now: t0)

        var refreshCalls = 0
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { token in
                // The dead token always 401s; the fresh one (post credentialsReplaced) succeeds.
                if token == "sk-ant-oat01-dead" { throw UsageAPIError.invalidResponse(401) }
                return self.response(five: 10, seven: 20)
            },
            refreshToken: { old in
                refreshCalls += 1
                return CachedCredentials(accessToken: "sk-ant-oat01-fresh",
                                         refreshToken: old.refreshToken, expiresAt: nil)
            },
            now: { self.t0 }   // fixed at t0 — still inside the tripped breaker's re-arm window
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps, breaker: trippedBreaker)

        // While tripped, the breaker blocks the refresh attempt entirely.
        await runtime.refresh()
        #expect(runtime.needsReAuth == true)
        #expect(refreshCalls == 0)

        await runtime.credentialsReplaced()

        #expect(runtime.needsReAuth == false)
        #expect(refreshCalls == 1)
        #expect(runtime.snapshot?.fiveHourPercent == 10)
    }

    @Test("tryTokenRefresh preserves the previous refreshTokenExpiresAt when the response omits it")
    func carriesForwardRefreshTokenExpiresAt() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let oldExpiry = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-old", refreshToken: "r",
                                  expiresAt: nil, refreshTokenExpiresAt: oldExpiry)
        ])
        let manager = AccountCredentialManager(store: store)

        let deps = AccountRuntime.Dependencies(
            fetchUsage: { token in
                if token == "sk-ant-oat01-old" { throw UsageAPIError.invalidResponse(401) }
                return self.response(five: 5, seven: 5)
            },
            refreshToken: { old in
                // Simulates a refresh response that omits refresh_token_expires_in.
                CachedCredentials(accessToken: "sk-ant-oat01-new", refreshToken: old.refreshToken,
                                  expiresAt: nil, refreshTokenExpiresAt: nil)
            },
            now: { self.t0 }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()

        let saved = try manager.credentials(for: id)
        #expect(saved?.accessToken == "sk-ant-oat01-new")
        #expect(saved?.refreshTokenExpiresAt == oldExpiry)
    }

    @Test("tryTokenRefresh uses the new refreshTokenExpiresAt when the response provides one")
    func carryForwardDoesNotOverwriteAFresherExpiry() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let oldExpiry = Date(timeIntervalSince1970: 2_000_000)
        let newExpiry = Date(timeIntervalSince1970: 3_000_000)
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-old", refreshToken: "r",
                                  expiresAt: nil, refreshTokenExpiresAt: oldExpiry)
        ])
        let manager = AccountCredentialManager(store: store)

        let deps = AccountRuntime.Dependencies(
            fetchUsage: { token in
                if token == "sk-ant-oat01-old" { throw UsageAPIError.invalidResponse(401) }
                return self.response(five: 5, seven: 5)
            },
            refreshToken: { old in
                // A response that DOES rotate the refresh-token expiry must win over the
                // stale value — the carry-forward guard exists only for the omitted case.
                CachedCredentials(accessToken: "sk-ant-oat01-new", refreshToken: old.refreshToken,
                                  expiresAt: nil, refreshTokenExpiresAt: newExpiry)
            },
            now: { self.t0 }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()

        let saved = try manager.credentials(for: id)
        #expect(saved?.refreshTokenExpiresAt == newExpiry)
    }

    @Test("refresh() mirrors the stored refreshTokenExpiresAt without a second keychain read")
    func mirrorsRefreshTokenExpiresAt() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let expiry = Date(timeIntervalSince1970: 2_000_000)
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-tok", refreshToken: "r",
                                  expiresAt: nil, refreshTokenExpiresAt: expiry)
        ])
        let manager = AccountCredentialManager(store: store)
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { _ in self.response(five: 10, seven: 10) },
            refreshToken: { $0 },
            now: { self.t0 }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        #expect(runtime.refreshTokenExpiresAt == nil)   // nothing read yet — no I/O at init
        await runtime.refresh()
        #expect(runtime.refreshTokenExpiresAt == expiry)
    }

    @Test("Login-expiry thresholds fire once per crossing across repeated 60-second refreshes, body carrying the true days")
    func loginExpiryFiresOncePerThreshold() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        // Fixed 2 days remaining at every refresh — exactly the repeated tick a naive
        // implementation would re-notify on every time.
        let expiry = t0.addingTimeInterval(2 * 86400)
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-tok", refreshToken: "r",
                                  expiresAt: nil, refreshTokenExpiresAt: expiry)
        ])
        let manager = AccountCredentialManager(store: store)
        var crossings: [(threshold: Int, daysRemaining: Int)] = []
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { _ in self.response(five: 10, seven: 10) },
            refreshToken: { $0 },
            now: { self.t0 },
            onLoginExpiryCrossing: { threshold, daysRemaining in
                crossings.append((threshold, daysRemaining))
            }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()
        await runtime.refresh()
        await runtime.refresh()

        // Three 60-second-apart refreshes at the same remaining-days count fire the 3-day
        // threshold exactly once, not three times — and the body value is the TRUE 2 days
        // remaining, not the 3-day threshold's own label.
        #expect(crossings.count == 1)
        #expect(crossings.first?.threshold == 3)
        #expect(crossings.first?.daysRemaining == 2)
    }

    @Test("A relaunch at 2 days remaining fires only the 3-day threshold, never the 1-day one it hasn't reached")
    func doesNotFireLowerThresholdPrematurely() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let expiry = t0.addingTimeInterval(2 * 86400)
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-tok", refreshToken: "r",
                                  expiresAt: nil, refreshTokenExpiresAt: expiry)
        ])
        let manager = AccountCredentialManager(store: store)
        var crossings: [(threshold: Int, daysRemaining: Int)] = []
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { _ in self.response(five: 10, seven: 10) },
            refreshToken: { $0 },
            now: { self.t0 },
            onLoginExpiryCrossing: { threshold, daysRemaining in
                crossings.append((threshold, daysRemaining))
            }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()

        #expect(crossings.map(\.threshold) == [3])
    }

    @Test("Login-expiry is checked against the post-refresh expiry, not the stale value that triggered the refresh")
    func loginExpiryCheckedAfterProactiveRefresh() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        // The ACCESS token is already expired, forcing the proactive-refresh attempt below;
        // the refresh token itself is 2 days from its own expiry beforehand — within the
        // 3-day threshold, if it were ever checked at that stale value.
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-old", refreshToken: "r",
                                  expiresAt: t0.addingTimeInterval(-60),
                                  refreshTokenExpiresAt: t0.addingTimeInterval(2 * 86400))
        ])
        let manager = AccountCredentialManager(store: store)
        var crossings: [Int] = []
        let newExpiry = t0.addingTimeInterval(28 * 86400)
        let deps = AccountRuntime.Dependencies(
            fetchUsage: { _ in self.response(five: 10, seven: 10) },
            refreshToken: { old in
                CachedCredentials(accessToken: "sk-ant-oat01-new", refreshToken: old.refreshToken,
                                  expiresAt: self.t0.addingTimeInterval(3600), refreshTokenExpiresAt: newExpiry)
            },
            now: { self.t0 },
            onLoginExpiryCrossing: { threshold, _ in crossings.append(threshold) }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        await runtime.refresh()

        // No false alarm posted for the stale 2-day value: by the time checkLoginExpiry
        // runs, the proactive refresh above has already re-armed the ~28-day window.
        #expect(crossings == [])
        #expect(runtime.refreshTokenExpiresAt == newExpiry)
    }

    @Test("A stale refresh in flight when credentialsReplaced runs does not clobber the fresh state")
    func staleRefreshDoesNotClobberFreshState() async throws {
        let defaults = ephemeralDefaults()
        let id = UUID()
        let store = InMemoryAccountCredentialStore([
            id: CachedCredentials(accessToken: "sk-ant-oat01-old", refreshToken: "r-old", expiresAt: nil)
        ])
        let manager = AccountCredentialManager(store: store)

        // Blocks the "stale tick"'s fetchUsage call on the dead token until the test
        // explicitly releases it — well after credentialsReplaced() has already completed.
        let gate = AsyncGate()

        let deps = AccountRuntime.Dependencies(
            fetchUsage: { token in
                if token == "sk-ant-oat01-old" {
                    await gate.arriveAndWait()
                    throw UsageAPIError.invalidResponse(401)   // resumes late, now irrelevant
                }
                return self.response(five: 42, seven: 42)
            },
            refreshToken: { _ in throw KeychainServiceError.noRefreshToken },   // the stale refresh token is dead too
            now: { self.t0 }
        )
        let runtime = AccountRuntime(id: id, credentials: manager,
                                     persistence: AccountPersistence(defaults: defaults, accountID: id),
                                     deps: deps)

        // Simulates a 60s-timer tick already in flight when a browser login lands.
        let staleTick = Task { await runtime.refresh() }
        await gate.waitUntilArrived()

        // Simulates the credential-store write a fresh browser login performs before
        // calling credentialsReplaced() (owned by the login flow, not this runtime).
        try manager.update(id: id, credentials: CachedCredentials(
            accessToken: "sk-ant-oat01-new", refreshToken: "r-new", expiresAt: nil))
        await runtime.credentialsReplaced()

        #expect(runtime.needsReAuth == false)
        #expect(runtime.snapshot?.fiveHourPercent == 42)

        // Let the stale tick's fetchUsage finally return its now-irrelevant 401.
        await gate.release()
        await staleTick.value

        // The stale completion must not have clobbered the fresh state set above.
        #expect(runtime.needsReAuth == false)
        #expect(runtime.snapshot?.fiveHourPercent == 42)
    }
}
