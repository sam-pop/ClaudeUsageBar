import Foundation

/// Applies a freshly-fetched identity to an account (the backfill for a migrated account
/// that started with no `accountUUID`), and reports whether that identity already belongs
/// to another tracked account — i.e. a duplicate. Pure so the decision is unit-tested;
/// the coordinator does the network fetch and the (non-destructive) duplicate handling.
enum AccountIdentityResolver {
    struct Result: Equatable {
        let accounts: [Account]
        /// The label of a *different* account that already has this identity, if any.
        let duplicateOfLabel: String?
    }

    static func backfill(_ accounts: [Account], id: UUID, uuid: String, email: String?) -> Result {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            return Result(accounts: accounts, duplicateOfLabel: nil)
        }

        // A different account already carrying this identity is a duplicate.
        let duplicate = accounts.first { $0.id != id && $0.accountUUID == uuid }

        var updated = accounts
        updated[index].accountUUID = uuid
        if let email { updated[index].email = email }

        return Result(accounts: updated, duplicateOfLabel: duplicate?.label)
    }
}
