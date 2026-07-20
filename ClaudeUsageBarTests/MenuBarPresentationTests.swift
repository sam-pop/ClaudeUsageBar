import Testing
import Foundation

@Suite("MenuBarPresentation")
struct MenuBarPresentationTests {

    private func account(_ label: String, shortCode: String? = nil) -> Account {
        Account(label: label, accountUUID: nil, shortCode: shortCode)
    }

    private func snapshot(five: Int, seven: Int, fiveReset: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: five, sevenDayPercent: seven,
                      fiveHourResetsAt: fiveReset, sevenDayResetsAt: nil, fetchedAt: Date())
    }

    @Test("No accounts shows a placeholder")
    func none() {
        let result = MenuBarPresentation.compute(accounts: [], snapshots: [:], mode: .auto)
        #expect(result.text == "--%")
        #expect(result.worstPercent == nil)
    }

    @Test("Single account reproduces today's percent-only format (no countdown when reset unknown)")
    func singleNoCountdown() {
        let a = account("Personal")
        let result = MenuBarPresentation.compute(
            accounts: [a],
            snapshots: [a.id: snapshot(five: 47, seven: 30)],
            mode: .fiveHour
        )
        // Matches UsageViewModel.menuBarText: "47%" with no countdown suffix when resetsAt is nil.
        #expect(result.text == "47%")
        #expect(result.worstPercent == 47)
    }

    @Test("Single account in auto mode picks the higher window")
    func singleAuto() {
        let a = account("Personal")
        let result = MenuBarPresentation.compute(
            accounts: [a],
            snapshots: [a.id: snapshot(five: 20, seven: 80)],
            mode: .auto
        )
        #expect(result.text == "80%")
        #expect(result.worstPercent == 80)
    }

    @Test("Two accounts compose compactly with worst-case percent")
    func twoAccounts() {
        let p = account("Personal")
        let w = account("Work")
        let result = MenuBarPresentation.compute(
            accounts: [p, w],
            snapshots: [
                p.id: snapshot(five: 45, seven: 10),
                w.id: snapshot(five: 82, seven: 12),
            ],
            mode: .fiveHour
        )
        #expect(result.text == "P 45% · W 82%")
        #expect(result.worstPercent == 82)
    }

    @Test("Two accounts honor a user shortCode override")
    func twoAccountsShortCode() {
        let p = account("Personal", shortCode: "🏠")
        let w = account("Work")
        let result = MenuBarPresentation.compute(
            accounts: [p, w],
            snapshots: [
                p.id: snapshot(five: 45, seven: 10),
                w.id: snapshot(five: 82, seven: 12),
            ],
            mode: .fiveHour
        )
        #expect(result.text == "🏠 45% · W 82%")
    }

    @Test("An account still loading shows -- for its slot")
    func loadingSlot() {
        let p = account("Personal")
        let w = account("Work")
        let result = MenuBarPresentation.compute(
            accounts: [p, w],
            snapshots: [p.id: snapshot(five: 45, seven: 10)],   // w has no snapshot yet
            mode: .fiveHour
        )
        #expect(result.text == "P 45% · W --%")
        #expect(result.worstPercent == 45)
    }
}
