import Foundation

/// Mirrors of the Postgres tables/RPC shapes from supabase/migrations/*.sql. Timestamps are kept
/// as raw ISO8601 strings rather than `Date` — avoids any risk of this decoder's date strategy
/// silently disagreeing with PostgREST's `timestamptz` serialization; parsed to `Date` only where
/// the UI actually needs one.

struct Team: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdBy: UUID
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

struct Member: Codable, Identifiable, Equatable {
    let userId: UUID
    let teamId: UUID
    let displayName: String
    let role: String
    let joinedAt: String

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case teamId = "team_id"
        case displayName = "display_name"
        case role
        case joinedAt = "joined_at"
    }
}

enum ShareMode: String, Codable {
    case shared
    case visibilityOnly = "visibility_only"
}

enum AccountStatus: String, Codable {
    case active
    case disabled
    case quarantined
}

/// A row in the pool — the shared-team analog of `KnownAccount` (CoreBridge/Models.swift), which
/// is this same account as seen locally by ccswitch-core. Deliberately not merged into one type:
/// this one exists only once Supabase sync is live, and its identity (Supabase `id`) is different
/// from the account's Anthropic identity (`anthropicAccountUuid`), which is the join key between
/// the two.
struct PoolAccount: Codable, Identifiable, Equatable {
    let id: UUID
    let teamId: UUID
    let ownerUserId: UUID
    let label: String?
    let email: String
    let organizationUuid: String?
    let anthropicAccountUuid: String
    let shareMode: ShareMode
    let status: AccountStatus
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case teamId = "team_id"
        case ownerUserId = "owner_user_id"
        case label, email
        case organizationUuid = "organization_uuid"
        case anthropicAccountUuid = "anthropic_account_uuid"
        case shareMode = "share_mode"
        case status
        case createdAt = "created_at"
    }
}

/// One row per (account, recipient) — see 0002_accounts.sql's header comment. `recipientUserId ==
/// nil` is the v1 team-key-encrypted row; a non-nil value is a v2 per-member sealed-box row (not
/// produced yet — Crypto/TeamKey.swift only writes the v1 shape for now).
struct AccountToken: Codable, Equatable {
    let accountId: UUID
    let recipientUserId: UUID?
    let ciphertext: String
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case recipientUserId = "recipient_user_id"
        case ciphertext, nonce
    }
}

struct ScopedUsageRow: Codable, Equatable {
    let name: String
    let pct: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case name, pct
        case resetsAt = "resets_at"
    }
}

struct UsageCurrentRow: Codable, Identifiable, Equatable {
    let accountId: UUID
    let fetchedAt: String
    let fetchedBy: UUID?
    let fiveHourPct: Double?
    let sevenDayPct: Double?
    let fiveHourResetsAt: String?
    let sevenDayResetsAt: String?
    let scoped: [ScopedUsageRow]?

    var id: UUID { accountId }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case fetchedAt = "fetched_at"
        case fetchedBy = "fetched_by"
        case fiveHourPct = "five_hour_pct"
        case sevenDayPct = "seven_day_pct"
        case fiveHourResetsAt = "five_hour_resets_at"
        case sevenDayResetsAt = "seven_day_resets_at"
        case scoped
    }

    /// Same "tighter window wins" rule as the local `Usage.tightestPct` (CoreBridge/Models.swift)
    /// — kept in sync deliberately, since both drive the same claimed-by/switch-scoring logic.
    var tightestPct: Double? {
        switch (fiveHourPct, sevenDayPct) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

struct ClaimRow: Codable, Identifiable, Equatable {
    let accountId: UUID
    let heldBy: UUID?
    let claimedAt: String?
    let leaseExpiresAt: String?
    let heartbeatAt: String?
    let purpose: String?

    var id: UUID { accountId }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case heldBy = "held_by"
        case claimedAt = "claimed_at"
        case leaseExpiresAt = "lease_expires_at"
        case heartbeatAt = "heartbeat_at"
        case purpose
    }
}

/// One `turn_log` row (BUILD_PLAN.md section 8) — written by the attribution hook script via the
/// `log_turn` RPC, read back here for the Team-usage digest. Only the two columns the digest
/// actually aggregates on; `id`/`ts` aren't needed once the query has already filtered by window.
struct TurnLogRow: Codable {
    let userId: UUID
    let accountId: UUID?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
    }
}

struct PollLeaderRow: Codable, Equatable {
    let teamId: UUID
    let leaderUserId: UUID?
    let leaseExpiresAt: String?
    let heartbeatAt: String?

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case leaderUserId = "leader_user_id"
        case leaseExpiresAt = "lease_expires_at"
        case heartbeatAt = "heartbeat_at"
    }
}

/// One "please re-login" event (0004_reauth_requests.sql) — an append-only audit trail, same
/// shape as switch_log/turn_log. The owner's `AppState` subscribes to inserts targeting accounts
/// it owns to fire the actual system notification; everyone else can read it for context (whose
/// idea was it), but only the RPC that created it and the owner's own recovery check ever act on it.
struct ReauthRequest: Codable, Identifiable {
    let id: UUID
    let accountId: UUID
    let requestedBy: UUID
    let requestedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case accountId = "account_id"
        case requestedBy = "requested_by"
        case requestedAt = "requested_at"
    }
}

// MARK: - RPC parameter payloads (Encodable; match the SQL functions' argument names exactly)

struct CreateTeamParams: Encodable { let p_name: String }
struct CreateTeamInviteParams: Encodable { let p_team: UUID; let p_expires_hours: Int; let p_max_uses: Int }
struct JoinTeamParams: Encodable { let p_code: String }
struct ClaimAccountParams: Encodable { let p_account: UUID; let p_purpose: String }
struct HeartbeatClaimParams: Encodable { let p_account: UUID }
struct ReleaseClaimParams: Encodable { let p_account: UUID }
struct LogTurnParams: Encodable { let p_team: UUID; let p_account: UUID?; let p_event: String }
struct TeamIdParam: Encodable { let p_team: UUID }
struct TransferOwnershipParams: Encodable { let p_account: UUID; let p_new_owner: UUID }
