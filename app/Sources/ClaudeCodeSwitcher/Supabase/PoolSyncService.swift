import CryptoKit
import Foundation
import Supabase

/// Everything that talks to the pool tables directly (accounts, account_tokens, usage_current,
/// claims): fetches, pushes, and the claim RPCs. Realtime subscriptions live here too, so
/// `AppState` can consume them without knowing about `RealtimeChannelV2`/`AnyAction`.
///
/// Usage reaches `usage_current` two ways, by design. A client holding local credentials for an
/// account publishes what it already read (`AppState.refreshUsage`), and the elected poll leader
/// (`PollLeaderController`) sweeps the accounts nobody is driving. Both write the same row, so an
/// occasional redundant push is harmless.
struct PoolSyncService {
    private let client = SupabaseClientProvider.shared

    // MARK: - Accounts

    private struct NewPoolAccount: Encodable {
        let team_id: UUID
        let owner_user_id: UUID
        let email: String
        let organization_uuid: String?
        let anthropic_account_uuid: String
        let share_mode: String
    }

    /// Upserts on `(team_id, anthropic_account_uuid)`. Capturing the same underlying Anthropic
    /// account twice, by you then a teammate, updates the existing row rather than duplicating it.
    @discardableResult
    func pushAccount(
        teamId: UUID,
        ownerUserId: UUID,
        identity: AccountIdentity,
        shareMode: ShareMode
    ) async throws -> PoolAccount {
        let payload = NewPoolAccount(
            team_id: teamId,
            owner_user_id: ownerUserId,
            email: identity.email,
            organization_uuid: identity.organizationUuid,
            anthropic_account_uuid: identity.accountUuid,
            share_mode: shareMode.rawValue
        )
        return try await client
            .from("accounts")
            .upsert(payload, onConflict: "team_id,anthropic_account_uuid")
            .select()
            .single()
            .execute()
            .value
    }

    private struct ShareModeUpdate: Encodable { let share_mode: String }

    /// Upgrading or downgrading share mode. The `accounts_update` RLS policy already restricts
    /// this to the account's owner, so no separate ownership check is needed here. The caller
    /// handles the token side; this call is just the `accounts` row.
    func updateShareMode(accountId: UUID, shareMode: ShareMode) async throws {
        try await client
            .from("accounts")
            .update(ShareModeUpdate(share_mode: shareMode.rawValue))
            .eq("id", value: accountId)
            .execute()
    }

    /// Removes an account from the pool (owner-only via the `accounts_delete` RLS policy),
    /// cascading its token, usage and claim rows. Distinct from downgrading to visibility-only:
    /// this forgets the account from the team altogether.
    func removeAccountFromPool(accountId: UUID) async throws {
        try await client
            .from("accounts")
            .delete()
            .eq("id", value: accountId)
            .execute()
    }

    /// Hands an account to another team member (Settings → My Accounts). Owner-only and
    /// same-team-only, both enforced inside the `transfer_account_ownership` RPC.
    func transferOwnership(accountId: UUID, to newOwner: UUID) async throws {
        try await client
            .rpc("transfer_account_ownership", params: TransferOwnershipParams(p_account: accountId, p_new_owner: newOwner))
            .execute()
    }

    func fetchAccounts(teamId: UUID) async throws -> [PoolAccount] {
        try await client
            .from("accounts")
            .select()
            .eq("team_id", value: teamId)
            .execute()
            .value
    }

    // MARK: - Account tokens (encrypted)

    private struct PushTokenParams: Encodable {
        let p_account: UUID
        let p_ciphertext: String
        let p_nonce: String
    }

    /// Encrypts `token` with the team key and upserts the team-key row via the
    /// `push_account_token` RPC, which accepts the write from the account's owner *or* whoever
    /// holds a live claim on it. That second path is what keeps a shared account alive: refresh
    /// tokens are single-use, so whoever last drove the account holds the only live lineage, and
    /// before this RPC a non-owner had no way to put it back. Direct `account_tokens` writes stay
    /// owner-only under RLS; this is the one sanctioned non-owner path. Never called for
    /// `.visibilityOnly` accounts — the caller checks first, and the server refuses anyway.
    func pushToken(accountId: UUID, plaintextToken: String, teamKey: SymmetricKey) async throws {
        let (ciphertext, nonce) = try TeamCrypto.encrypt(plaintextToken, key: teamKey)
        try await client
            .rpc("push_account_token", params: PushTokenParams(
                p_account: accountId, p_ciphertext: ciphertext, p_nonce: nonce
            ))
            .execute()
    }

    /// The team-key row for an account, or nil for a visibility-only account, which has no row.
    func fetchTeamKeyToken(accountId: UUID) async throws -> AccountToken? {
        let rows: [AccountToken] = try await client
            .from("account_tokens")
            .select()
            .eq("account_id", value: accountId)
            .is("recipient_user_id", value: nil)
            .execute()
            .value
        return rows.first
    }

    /// Downgrading to visibility-only deletes the ciphertext rather than leaving an unused row: a
    /// visibility-only account should have zero token rows, same as one never shared at all.
    func deleteToken(accountId: UUID) async throws {
        try await client
            .from("account_tokens")
            .delete()
            .eq("account_id", value: accountId)
            .execute()
    }

    // MARK: - Usage

    private struct NewUsageCurrent: Encodable {
        let account_id: UUID
        let fetched_at: String
        let fetched_by: UUID
        let five_hour_pct: Double?
        let seven_day_pct: Double?
        let five_hour_resets_at: String?
        let seven_day_resets_at: String?
        let scoped: [ScopedUsageRow]?
    }

    func pushUsage(accountId: UUID, usage: Usage, fetchedBy: UUID) async throws {
        let payload = NewUsageCurrent(
            account_id: accountId,
            fetched_at: ISO8601DateFormatter().string(from: Date()),
            fetched_by: fetchedBy,
            five_hour_pct: usage.fiveHour?.pct,
            seven_day_pct: usage.sevenDay?.pct,
            five_hour_resets_at: usage.fiveHour?.resetsAt,
            seven_day_resets_at: usage.sevenDay?.resetsAt,
            scoped: usage.scoped?.map { ScopedUsageRow(name: $0.name, pct: $0.pct, resetsAt: $0.resetsAt) }
        )
        try await client
            .from("usage_current")
            .upsert(payload, onConflict: "account_id")
            .execute()
    }

    func fetchUsage(teamAccountIds: [UUID]) async throws -> [UsageCurrentRow] {
        guard !teamAccountIds.isEmpty else { return [] }
        return try await client
            .from("usage_current")
            .select()
            .in("account_id", values: teamAccountIds)
            .execute()
            .value
    }

    // MARK: - Claims

    func fetchClaims(teamAccountIds: [UUID]) async throws -> [ClaimRow] {
        guard !teamAccountIds.isEmpty else { return [] }
        return try await client
            .from("claims")
            .select()
            .in("account_id", values: teamAccountIds)
            .execute()
            .value
    }

    /// Nil means someone else holds a live lease; the caller falls back to the next-best candidate
    /// rather than treating it as an error.
    ///
    /// `claim_account` is declared `RETURNS claims`: a single composite row, nullable when someone
    /// else holds the lease, so PostgREST returns one JSON object or `null`, never an array.
    /// Decoding into `[ClaimRow]` fails on every call, which aborts the switch *after* the
    /// server-side claim was already taken and leaves orphaned claims. `.single()` can't be used
    /// either, since it errors on the legitimate null-lease case. Decode into `ClaimRow?`.
    func claim(accountId: UUID, purpose: String = "active_use") async throws -> ClaimRow? {
        try await client
            .rpc("claim_account", params: ClaimAccountParams(p_account: accountId, p_purpose: purpose))
            .execute()
            .value
    }

    func releaseClaim(accountId: UUID) async throws {
        try await client
            .rpc("release_claim", params: ReleaseClaimParams(p_account: accountId))
            .execute()
    }

    /// Called on a repeating timer while a claim is held. Extends the 5-minute lease so an account
    /// still in use doesn't free itself and show as available to a teammate mid-session.
    func heartbeatClaim(accountId: UUID) async throws {
        try await client
            .rpc("heartbeat_claim", params: HeartbeatClaimParams(p_account: accountId))
            .execute()
    }

    // MARK: - Poll-leader election

    /// Nil means another client holds a live leader lease; the caller stays a follower and relies
    /// on Realtime for `usage_current` updates instead of polling itself.
    ///
    /// Same `RETURNS poll_leader` single-composite shape as `claim` above, so decode into a single
    /// optional rather than an array.
    func tryBecomePollLeader(teamId: UUID) async throws -> PollLeaderRow? {
        try await client
            .rpc("try_become_poll_leader", params: TeamIdParam(p_team: teamId))
            .execute()
            .value
    }

    func heartbeatPollLeader(teamId: UUID) async throws {
        try await client
            .rpc("heartbeat_poll_leader", params: TeamIdParam(p_team: teamId))
            .execute()
    }

    func releasePollLeader(teamId: UUID) async throws {
        try await client
            .rpc("release_poll_leader", params: TeamIdParam(p_team: teamId))
            .execute()
    }

    func fetchMembers(teamId: UUID) async throws -> [Member] {
        try await client
            .from("members")
            .select()
            .eq("team_id", value: teamId)
            .execute()
            .value
    }

    // MARK: - Attribution

    /// Turn rows are written by the hook script over `curl`, not through this client, so this is
    /// only the read side for `TeamUsageView`'s digest. Counting happens in Swift rather than via
    /// a server-side aggregate because a ~10-person team's weekly volume is small enough that
    /// fetching raw rows is simpler than a second RPC.
    func fetchTurnLog(teamId: UUID, since: Date) async throws -> [TurnLogRow] {
        try await client
            .from("turn_log")
            .select("user_id,account_id")
            .eq("team_id", value: teamId)
            .gte("ts", value: ISO8601DateFormatter().string(from: since))
            .execute()
            .value
    }

    private struct NewSwitchLog: Encodable {
        let team_id: UUID
        let user_id: UUID
        let account_from: UUID?
        let account_to: UUID?
        let reason: String
    }

    /// Plain insert, not an RPC: `switch_log` is an append-only audit row with a policy-level
    /// check (`user_id = auth.uid()`), not a lease, so there's no race to make atomic.
    func logSwitch(teamId: UUID, userId: UUID, from: UUID?, to: UUID?, reason: String) async throws {
        let payload = NewSwitchLog(team_id: teamId, user_id: userId, account_from: from, account_to: to, reason: reason)
        try await client.from("switch_log").insert(payload).execute()
    }

    // MARK: - Re-login requests

    /// Flags an account as needing re-login and records who asked. Open to any team member, not
    /// just the owner, since whoever hits the failure usually isn't the owner. Sets
    /// `accounts.status = 'quarantined'`, visible to everyone over the `accounts` subscription.
    @discardableResult
    func requestReauth(accountId: UUID) async throws -> ReauthRequest {
        try await client
            .rpc("request_reauth", params: ReleaseClaimParams(p_account: accountId))
            .single()
            .execute()
            .value
    }

    /// Owner-only; flips the account back to `active`. Called automatically once a post-re-login
    /// usage read succeeds, not from a manual "mark resolved" button.
    func clearAccountReauth(accountId: UUID) async throws {
        try await client
            .rpc("clear_account_reauth", params: ReleaseClaimParams(p_account: accountId))
            .execute()
    }

    // MARK: - Realtime

    /// One `AnyAction` stream per table, decoded to the caller's model type. The caller `for
    /// await`s each stream in its own `Task` and applies updates on the main actor.
    func subscribeChanges<T: Decodable>(
        table: String,
        as type: T.Type,
        onChange: @escaping @Sendable (T) -> Void
    ) async {
        let channel = client.channel("pool-\(table)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: table)
        try? await channel.subscribeWithError()

        for await action in changes {
            let decoder = JSONDecoder()
            switch action {
            case .insert(let insert):
                if let record = try? insert.decodeRecord(as: T.self, decoder: decoder) {
                    onChange(record)
                }
            case .update(let update):
                if let record = try? update.decodeRecord(as: T.self, decoder: decoder) {
                    onChange(record)
                }
            case .delete:
                break  // removal goes through explicit app actions that already update local
                       // state, so there's nothing a second callback shape would add here
            }
        }
    }
}
