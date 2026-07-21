import Foundation
import Supabase

/// Team creation/membership/invites — thin wrappers over the RPCs in
/// supabase/migrations/20260720000008_team_invites.sql. Deliberately RPC-only for every mutation
/// here (never a raw `.from("members").insert(...)`): the RPCs are security definer and encode
/// the actual join/create rules (owner-only invites, single-use codes, no self-inviting twice),
/// so a raw insert from the client would either be rejected by RLS or — worse — would need to
/// duplicate those rules client-side where they could drift from the server's.
struct TeamService {
    private let client = SupabaseClientProvider.shared

    /// Every team this user belongs to (multi-team). Empty means "needs onboarding." RLS's
    /// `members_select` returns a row for each team the caller is in, so this naturally spans all
    /// of them without a special query.
    func myMemberships(userId: UUID) async throws -> [Member] {
        try await client
            .from("members")
            .select()
            .eq("user_id", value: userId)
            .execute()
            .value
    }

    func teams(ids: [UUID]) async throws -> [Team] {
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("teams")
            .select()
            .in("id", values: ids)
            .execute()
            .value
    }

    func team(id: UUID) async throws -> Team {
        try await client
            .from("teams")
            .select()
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    @discardableResult
    func createTeam(name: String) async throws -> Team {
        try await client
            .rpc("create_team", params: CreateTeamParams(p_name: name))
            .single()
            .execute()
            .value
    }

    /// Returns the invite code to share with a teammate out-of-band (text/Slack/etc — this app
    /// has no notification/DM channel of its own). Owner-only; the RPC itself enforces that.
    func createInvite(teamId: UUID, expiresHours: Int = 24 * 7, maxUses: Int = 1) async throws -> String {
        try await client
            .rpc(
                "create_team_invite",
                params: CreateTeamInviteParams(p_team: teamId, p_expires_hours: expiresHours, p_max_uses: maxUses)
            )
            .execute()
            .value
    }

    @discardableResult
    func joinTeam(code: String) async throws -> Member {
        try await client
            .rpc("join_team", params: JoinTeamParams(p_code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
            .single()
            .execute()
            .value
    }

    /// Removes the caller from their team (and their owned accounts) via the `leave_team` RPC —
    /// which blocks the team owner from leaving while other members remain, so the error surfaces
    /// to the UI rather than orphaning the team. No return value; the caller re-derives its state
    /// from `myMembership` afterward (it'll come back nil).
    func leaveTeam() async throws {
        try await client
            .rpc("leave_team")
            .execute()
    }
}
