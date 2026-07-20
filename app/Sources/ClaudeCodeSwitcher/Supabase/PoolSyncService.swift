import CryptoKit
import Foundation
import Supabase

/// Everything that talks to the pool tables directly (accounts, account_tokens, usage_current,
/// claims) — fetches, pushes, and the claim RPCs. Realtime subscriptions live here too, exposed
/// as `AsyncStream`s so `AppState` can consume them without knowing anything about
/// `RealtimeChannelV2`/`AnyAction` itself.
///
/// v1 usage-push note: every client that reads an account's usage locally pushes it to
/// `usage_current` (see `AppState.refreshUsage`). That is deliberately *not* the poll-leader
/// election BUILD_PLAN.md section 3a describes — this is the honest v1 stepping stone (multiple
/// online clients can occasionally push the same shared account's usage redundantly), and the
/// election engine is still Phase 3 work, not silently pretended-done here.
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

    /// Upserts on `(team_id, anthropic_account_uuid)` — the identity dedup BUILD_PLAN.md
    /// invariant 4 requires. Capturing the same underlying Anthropic account twice (you, then a
    /// teammate) updates the existing pool row rather than creating a duplicate.
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

    /// Upgrading/downgrading share mode (BUILD_PLAN.md section 5) — the RLS `accounts_update`
    /// policy already restricts this to the account's owner, so there's no separate ownership
    /// check needed here. The caller (`AppState.setShareMode`) handles the token side: pushing a
    /// fresh ciphertext on upgrade, deleting it on downgrade (`deleteToken` below) — this call is
    /// just the `accounts` row itself.
    func updateShareMode(accountId: UUID, shareMode: ShareMode) async throws {
        try await client
            .from("accounts")
            .update(ShareModeUpdate(share_mode: shareMode.rawValue))
            .eq("id", value: accountId)
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

    private struct NewAccountToken: Encodable {
        let account_id: UUID
        let recipient_user_id: UUID?
        let ciphertext: String
        let nonce: String
    }

    /// Encrypts `token` with the team key and upserts the v1 (team-key, `recipient_user_id ==
    /// nil`) row. Never called for `.visibilityOnly` accounts — the caller checks that first, so
    /// a token for a visibility-only account is never even read out of local storage.
    func pushToken(accountId: UUID, plaintextToken: String, teamKey: SymmetricKey) async throws {
        let (ciphertext, nonce) = try TeamCrypto.encrypt(plaintextToken, key: teamKey)
        let payload = NewAccountToken(
            account_id: accountId, recipient_user_id: nil, ciphertext: ciphertext, nonce: nonce
        )
        try await client
            .from("account_tokens")
            .upsert(payload, onConflict: "account_id,recipient_key")
            .execute()
    }

    /// The v1 team-key row for an account, or nil for a visibility-only account (no row exists).
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

    /// Downgrading to visibility-only (BUILD_PLAN.md section 5) deletes the ciphertext outright
    /// rather than leaving an unused row — a visibility-only account should have zero token rows
    /// in Supabase, same as one that was never shared in the first place.
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

    /// Nil means someone else holds a live lease — the caller falls back to the next-best
    /// candidate (BUILD_PLAN.md section 5's "Switch account" flow) rather than treating it as an error.
    ///
    /// `claim_account` is declared `RETURNS claims` (a single composite row, nullable when the
    /// lease is held by someone else), so PostgREST returns a single JSON object or `null` — NOT
    /// an array. Decoding into `[ClaimRow]` threw "data couldn't be read" on every call, which
    /// silently aborted the switch *after* the server-side claim had already been taken, leaving
    /// orphaned claims and making switching appear completely broken. `.single()` can't be used
    /// here (it errors on the legitimate null-lease case), so decode straight into `ClaimRow?`.
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

    /// Called on a repeating timer while a claim is held (BUILD_PLAN.md section 5) — extends the
    /// 5-minute lease so an account genuinely still in use doesn't silently free itself and show
    /// as available to a teammate mid-session.
    func heartbeatClaim(accountId: UUID) async throws {
        try await client
            .rpc("heartbeat_claim", params: HeartbeatClaimParams(p_account: accountId))
            .execute()
    }

    // MARK: - Poll-leader election (BUILD_PLAN.md section 3a)

    /// Nil means another client already holds a live leader lease — the caller stays a
    /// follower and relies on Realtime for `usage_current` updates instead of polling itself.
    ///
    /// Same single-composite/`RETURNS poll_leader` shape as `claim` above — decode into a single
    /// optional, never an array, or the response fails to decode (see `claim`'s header comment).
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

    // MARK: - Attribution (BUILD_PLAN.md section 8)

    /// Turn rows are written by the hook script directly (via the `log_turn` RPC over `curl`, not
    /// through this Swift client — see `AttributionHookService`'s header comment for why); this is
    /// only the read side, for `TeamUsageView`'s digest. `since` bounds the window client-side
    /// rather than the server aggregating, since a team of up to ~10 people's weekly turn volume
    /// is small enough that fetching raw rows and counting in Swift is simpler than a second RPC.
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

    /// Plain insert, not an RPC — `switch_log` is an append-only audit row with a policy-level
    /// check (`user_id = auth.uid()`), not a lease, so there's no race to make atomic (see
    /// `0005_attribution.sql`'s header comment).
    func logSwitch(teamId: UUID, userId: UUID, from: UUID?, to: UUID?, reason: String) async throws {
        let payload = NewSwitchLog(team_id: teamId, user_id: userId, account_from: from, account_to: to, reason: reason)
        try await client.from("switch_log").insert(payload).execute()
    }

    // MARK: - Realtime

    /// One `AnyAction` stream per table, decoded to the caller's model type. The caller is
    /// expected to `for await` each stream in its own `Task` and apply updates on the main actor
    /// — see `AppState.startPoolRealtime()`.
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
                break  // deletes are rare here (removal goes through explicit app actions,
                       // which already update local state directly) — not worth a second callback shape
            }
        }
    }
}
