import Testing
import Foundation

@Suite("AccountIdentityResolver.backfill")
struct AccountIdentityResolverTests {

    @Test("Backfills uuid and email onto the target account")
    func backfills() {
        let a = Account(label: "Account 1")   // migrated, no identity
        let result = AccountIdentityResolver.backfill([a], id: a.id, uuid: "uuid-x", email: "x@e.com")
        #expect(result.accounts.count == 1)
        #expect(result.accounts[0].accountUUID == "uuid-x")
        #expect(result.accounts[0].email == "x@e.com")
        #expect(result.duplicateOfLabel == nil)
    }

    @Test("Detects a duplicate when another account already has that identity")
    func detectsDuplicate() {
        let migrated = Account(label: "Account 1")                       // nil uuid
        let existing = Account(label: "Sam", accountUUID: "uuid-x", email: "x@e.com")
        let result = AccountIdentityResolver.backfill([migrated, existing],
                                                      id: migrated.id, uuid: "uuid-x", email: "x@e.com")
        // The migrated account is still identified…
        #expect(result.accounts.first { $0.id == migrated.id }?.accountUUID == "uuid-x")
        // …and flagged as a duplicate of the existing one.
        #expect(result.duplicateOfLabel == "Sam")
    }

    @Test("No false duplicate for a distinct identity")
    func distinctIdentity() {
        let migrated = Account(label: "Account 1")
        let other = Account(label: "Work", accountUUID: "uuid-other")
        let result = AccountIdentityResolver.backfill([migrated, other],
                                                      id: migrated.id, uuid: "uuid-x", email: nil)
        #expect(result.duplicateOfLabel == nil)
        #expect(result.accounts.first { $0.id == migrated.id }?.accountUUID == "uuid-x")
    }

    @Test("Unknown id leaves the list unchanged")
    func unknownID() {
        let a = Account(label: "Account 1")
        let result = AccountIdentityResolver.backfill([a], id: UUID(), uuid: "uuid-x", email: nil)
        #expect(result.accounts == [a])
        #expect(result.duplicateOfLabel == nil)
    }
}
