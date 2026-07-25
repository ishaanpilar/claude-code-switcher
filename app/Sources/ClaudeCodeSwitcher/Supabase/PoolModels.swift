import Foundation

/// Mirrors of the Postgres table and RPC shapes in supabase/migrations. Timestamps stay raw
/// ISO8601 strings rather than `Date`, so this decoder's date strategy can't silently disagree
/// with PostgREST's `timestamptz` serialization. Parsed to `Date` only where the UI needs one.

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

/// A row in the pool: the shared-team analog of `KnownAccount`, which is the same account as seen
/// locally by ccswitch-core. Deliberately not merged into one type, since this exists only once
/// Supabase sync is live, and its identity (Supabase `id`) differs from the account's Anthropic
/// identity (`anthropicAccountUuid`), which is the join key between the two.
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

/// One row per (account, recipient). A nil `recipientUserId` is the team-key-encrypted row; a
/// non-nil value would be a per-member sealed box, which nothing writes yet.
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

    /// Same "tighter window wins" rule as the local `Usage.tightestPct`, kept in sync deliberately
    /// since both drive the same switch-scoring logic.
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

    /// Whether this reservation should still be believed. `held_by` alone is not enough: it stays
    /// set in the row until something clears it, and the only thing that clears an abandoned one is
    /// the pg_cron reaper. If the holder quit, slept, or lost the network, or if pg_cron isn't
    /// running on the project at all, `held_by` stays populated indefinitely and the "held by"
    /// badge becomes permanent.
    ///
    /// A lease is the actual contract: `claim_account` sets `lease_expires_at` 5 minutes out and
    /// the holder heartbeats every 60s. Past that timestamp the claim is void, which is exactly how
    /// `claim_account`'s own WHERE clause treats it (`or lease_expires_at < now()`). Judging expiry
    /// client-side keeps the UI honest without depending on the reaper being healthy.
    var isLive: Bool {
        guard heldBy != nil else { return false }
        guard let leaseExpiresAt else { return true }  // no lease recorded: treat as held
        guard let expiry = ISO8601Timestamp.parse(leaseExpiresAt) else { return true }
        return expiry > Date()
    }
}

/// Shared parser for the raw ISO8601 strings every row in this file stores. Handles both the
/// fractional-seconds and whole-second shapes PostgREST can emit for a `timestamptz`.
enum ISO8601Timestamp {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// One `turn_log` row, written by the attribution hook script via the `log_turn` RPC and read back
/// here for the Team usage digest. Only the two columns the digest aggregates on: `id` and `ts`
/// aren't needed once the query has filtered by window.
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

/// One "please re-login" event: an append-only audit trail, same shape as switch_log and turn_log.
/// The owner's `AppState` subscribes to inserts for accounts it owns and fires the notification.
/// Everyone else can read it for context, but only the owner's recovery check acts on it.
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
struct TeamIdParam: Encodable { let p_team: UUID }
struct TransferOwnershipParams: Encodable { let p_account: UUID; let p_new_owner: UUID }
