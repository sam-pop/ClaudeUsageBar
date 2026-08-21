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

        init(
            fetchUsage: @escaping (String) async throws -> UsageResponse,
            refreshToken: @escaping (CachedCredentials) async throws -> CachedCredentials,
            now: @escaping () -> Date,
            onThresholdCrossing: ((ThresholdTracker.Crossing) -> Void)? = nil
        ) {
            self.fetchUsage = fetchUsage
            self.refreshToken = refreshToken
            self.now = now
            self.onThresholdCrossing = onThresholdCrossing
        }
    }

    let id: UUID
    private(set) var state: LoadingState = .idle
    private(set) var snapshot: UsageSnapshot?
    private(set) var history: [UsageDataPoint] = []
    private(set) var needsReAuth = false

    private let credentials: AccountCredentialManager
    private let persistence: AccountPersistence
    private let deps: Dependencies
    private let onChange: () -> Void
    private var breaker: RefreshCircuitBreaker
    private var thresholdTracker: ThresholdTracker
    private var refreshTask: Task<Void, Never>?

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
        if snapshot == nil { state = .loading }
        do {
            let snap = try await fetchWithRetry()
            snapshot = snap
            state = .loaded(snap)
            needsReAuth = false
            persistence.saveSnapshot(snap)
            recordHistory(snap)
            checkThresholds(snap)
        } catch let error as UsageAPIError {
            state = .error(error.localizedDescription)
            needsReAuth = error.needsKeychainRefresh
        } catch {
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
    /// credentials are known-good — clears `needsReAuth`, and re-fetches.
    func credentialsReplaced() async {
        breaker = RefreshCircuitBreaker()
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
            // "expiry unknown" — carry forward the prior value so the rolling ~28-day
            // refresh-token expiry (and its pre-expiry warning) survive a response that
            // simply didn't repeat the field.
            if refreshed.refreshTokenExpiresAt == nil {
                refreshed.refreshTokenExpiresAt = creds.refreshTokenExpiresAt
            }
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
}
