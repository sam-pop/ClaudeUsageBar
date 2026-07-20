import Testing
import Foundation

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
}
