import Foundation

/// Per-account usage runtime: owns one account's credential access, refresh loop, snapshot,
/// history, and threshold notifications. Plain (non-`ObservableObject`) — the coordinator
/// owns the published state and passes an `onChange` closure that this fires after any
/// state mutation, so SwiftUI re-renders without the nested-observation freeze.
///
/// Network operations are injected via `Dependencies` so the refresh orchestration is
/// testable without live calls. `@MainActor` so the load→mutate→save credential discipline
/// runs uninterrupted.
@MainActor
final class AccountRuntime {

    enum LoadingState: Equatable {
        case idle
        case loading
        case loaded(UsageSnapshot)
        case error(String)

        static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case let (.loaded(a), .loaded(b)): return a.fetchedAt == b.fetchedAt
            case let (.error(a), .error(b)): return a == b
            default: return false
            }
        }
    }

    /// Injected network + clock seam.
    struct Dependencies {
        var fetchUsage: (String) async throws -> UsageResponse
        var refreshToken: (CachedCredentials) async throws -> CachedCredentials
        var now: () -> Date
        /// Fired for each newly-crossed usage threshold, so the coordinator can post a
        /// per-account notification. Optional so tests can omit it.
        var onThresholdCrossing: ((ThresholdTracker.Crossing) -> Void)?
        /// Fired for each newly-crossed login-expiry day-threshold (3, 1), so the
        /// coordinator can post a per-account pre-expiry notification. Optional so tests
        /// can omit it.
        var onLoginExpiryCrossing: ((Int) -> Void)?

        init(
            fetchUsage: @escaping (String) async throws -> UsageResponse,
            refreshToken: @escaping (CachedCredentials) async throws -> CachedCredentials,
            now: @escaping () -> Date,
            onThresholdCrossing: ((ThresholdTracker.Crossing) -> Void)? = nil,
            onLoginExpiryCrossing: ((Int) -> Void)? = nil
        ) {
            self.fetchUsage = fetchUsage
            self.refreshToken = refreshToken
            self.now = now
            self.onThresholdCrossing = onThresholdCrossing
            self.onLoginExpiryCrossing = onLoginExpiryCrossing
        }
    }

    let id: UUID
    private(set) var state: LoadingState = .idle
    private(set) var snapshot: UsageSnapshot?
    private(set) var history: [UsageDataPoint] = []
    private(set) var needsReAuth = false
    /// The stored credentials' refresh-token expiry, refreshed alongside every fetch —
    /// never read from the keychain on its own, so the coordinator can mirror it into a
    /// `@Published` property without per-render I/O.
    private(set) var refreshTokenExpiresAt: Date?

    private let credentials: AccountCredentialManager
    private let persistence: AccountPersistence
    private let deps: Dependencies
    private let onChange: () -> Void
    private var breaker: RefreshCircuitBreaker
    private var thresholdTracker: ThresholdTracker
    private var loginExpiryNotifier = LoginExpiry.Notifier()
    private var refreshTask: Task<Void, Never>?
    /// Bumped by `credentialsReplaced()`. A `refresh()` call captures this at entry and
    /// checks it again after its awaited fetch returns; if it no longer matches, a newer
    /// `refresh()` (from `credentialsReplaced()`) has already run to completion, so this
    /// call's result is stale and must not overwrite `state`/`needsReAuth`/`snapshot`.
    private var epoch = 0

    private static let maxHistoryPoints = 288      // 24 hours at 5-min sampling
    private static let historySampleInterval: TimeInterval = 300

    init(
        id: UUID,
        credentials: AccountCredentialManager,
        persistence: AccountPersistence,
        deps: Dependencies,
        breaker: RefreshCircuitBreaker = RefreshCircuitBreaker(),
        thresholdTracker: ThresholdTracker = ThresholdTracker(),
        onChange: @escaping () -> Void = {}
    ) {
        self.id = id
        self.credentials = credentials
        self.persistence = persistence
        self.deps = deps
        self.breaker = breaker
        self.thresholdTracker = thresholdTracker
        self.onChange = onChange
        self.snapshot = persistence.loadSnapshot()
        self.history = persistence.loadHistory()
        if let snapshot { self.state = .loaded(snapshot) }
    }

    func refresh() async {
        let startEpoch = epoch
        if snapshot == nil { state = .loading }
        do {
            let snap = try await fetchWithRetry()
            guard startEpoch == epoch else { return }
            snapshot = snap
            state = .loaded(snap)
            needsReAuth = false
            persistence.saveSnapshot(snap)
            recordHistory(snap)
            checkThresholds(snap)
        } catch let error as UsageAPIError {
            guard startEpoch == epoch else { return }
            state = .error(error.localizedDescription)
            needsReAuth = error.needsReLogin
        } catch {
            guard startEpoch == epoch else { return }
            state = .error(error.localizedDescription)
        }
        onChange()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Called after new credentials have been stored for this account (e.g. a fresh
    /// browser login). Resets the circuit breaker to a fresh un-tripped state — the prior
    /// breaker may still be tripped from the dead-token era and would otherwise keep
    /// blocking refresh attempts for up to its re-arm window even though the new
    /// credentials are known-good — clears `needsReAuth`, bumps `epoch` so a `refresh()`
    /// already in flight (e.g. a timer tick that started against the old credentials)
    /// cannot clobber this call's result when it later resumes, and re-fetches.
    func credentialsReplaced() async {
        epoch += 1
        breaker.reset()
        needsReAuth = false
        await refresh()
    }

    // MARK: - Fetch with retry + OAuth refresh

    private func fetchWithRetry() async throws -> UsageSnapshot {
        guard var creds = try? credentials.credentials(for: id) else {
            throw UsageAPIError.noToken
        }

        // Proactive refresh when the token is near expiry, gated by the breaker so a dead
        // refresh token doesn't hammer the endpoint. On failure, fall through to the fetch;
        // the reactive 401/403 path is the safety net.
        if creds.needsRefresh(), breaker.allowsAttempt(now: deps.now()) {
            if let refreshed = await tryTokenRefresh(creds) { creds = refreshed }
        }

        // Checked after the proactive-refresh attempt above (not before) so an account that
        // just re-armed its ~28-day window is read at its new expiry, not the stale one that
        // prompted the refresh.
        refreshTokenExpiresAt = creds.refreshTokenExpiresAt
        checkLoginExpiry(creds.refreshTokenExpiresAt)

        let policy = RetryPolicy()
        var rng = SystemRandomNumberGenerator()
        var lastError: UsageAPIError?

        for attempt in 1...policy.maxAttempts {
            do {
                return UsageSnapshot(from: try await deps.fetchUsage(creds.accessToken))
            } catch let error as UsageAPIError where error.isAuthError {
                if breaker.allowsAttempt(now: deps.now()), let refreshed = await tryTokenRefresh(creds) {
                    return UsageSnapshot(from: try await deps.fetchUsage(refreshed.accessToken))
                }
                throw UsageAPIError.tokenExpired
            } catch let error as UsageAPIError where error.isTransient {
                lastError = error
                if attempt < policy.maxAttempts {
                    try? await Task.sleep(for: .seconds(policy.delay(forAttempt: attempt, using: &rng)))
                }
            }
        }
        throw lastError ?? UsageAPIError.invalidResponse(-1)
    }

    /// Attempts an OAuth token refresh, updating the breaker and the stored credentials.
    /// Returns the new credentials on success, `nil` on failure.
    private func tryTokenRefresh(_ creds: CachedCredentials) async -> CachedCredentials? {
        do {
            var refreshed = try await deps.refreshToken(creds)
            // A refresh response that omits refresh_token_expires_in must not be read as
            // "expiry unknown" — carry forward the prior value as a conservative floor:
            // under token rotation the true expiry can only be later, and nil would
            // silently disable the expiry warning entirely.
            if refreshed.refreshTokenExpiresAt == nil {
                refreshed.refreshTokenExpiresAt = creds.refreshTokenExpiresAt
            }
            refreshTokenExpiresAt = refreshed.refreshTokenExpiresAt
            breaker.recordSuccess()
            try? credentials.update(id: id, credentials: refreshed)
            return refreshed
        } catch {
            breaker.record(OAuthRefreshOutcome.classify(error), now: deps.now())
            return nil
        }
    }

    // MARK: - History + thresholds

    private func recordHistory(_ snapshot: UsageSnapshot) {
        let point = UsageDataPoint(
            timestamp: snapshot.fetchedAt,
            fiveHourPercent: snapshot.fiveHourPercent,
            sevenDayPercent: snapshot.sevenDayPercent
        )
        let updated = HistoryBuffer.appending(
            point, to: history,
            maxPoints: Self.maxHistoryPoints,
            minInterval: Self.historySampleInterval
        )
        guard updated.last?.timestamp != history.last?.timestamp else { return }
        history = updated
        persistence.saveHistory(history)
    }

    private func checkThresholds(_ snapshot: UsageSnapshot) {
        let crossings = thresholdTracker.record(
            fiveHour: snapshot.fiveHourPercent,
            sevenDay: snapshot.sevenDayPercent
        )
        for crossing in crossings { deps.onThresholdCrossing?(crossing) }
    }

    /// Run on every `refresh()` regardless of whether the usage fetch itself succeeds — the
    /// refresh token's expiry comes from the already-loaded credentials, not the network.
    private func checkLoginExpiry(_ expiresAt: Date?) {
        let crossings = loginExpiryNotifier.check(refreshTokenExpiresAt: expiresAt, now: deps.now())
        for days in crossings { deps.onLoginExpiryCrossing?(days) }
    }
}
