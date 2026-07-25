import Foundation
import Supabase

/// Team creation, membership and invites: thin wrappers over the RPCs in supabase/migrations.
/// Deliberately RPC-only for every mutation, never a raw `.from("members").insert(...)`. The RPCs
/// are security definer and encode the real rules (owner-only invites, single-use codes, no
/// joining twice), so a raw insert would either be rejected by RLS or, worse, need those rules
/// duplicated client-side where they could drift.
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

    /// This identity's online-access flag, read directly rather than only inferred from a failed
    /// create_team/join_team call, so onboarding can show "pending approval" up front instead of
    /// only after a doomed attempt. A row always exists once the account-gate migration's trigger
    /// has run, so `nil` here means "couldn't tell" (network hiccup), not "no access" — the caller
    /// should fail open and let the RPC-level check be the real backstop.
    func myProfile(userId: UUID) async throws -> Profile? {
        try await client
            .from("profiles")
            .select()
            .eq("user_id", value: userId)
            .single()
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

    @discardableResult
    func createTeam(name: String) async throws -> Team {
        try await client
            .rpc("create_team", params: CreateTeamParams(p_name: name))
            .single()
            .execute()
            .value
    }

    /// Returns the invite code to share with a teammate over text or Slack, since this app has no
    /// messaging channel of its own. Owner-only, enforced by the RPC.
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

    /// Removes the caller from `teamId`, along with the accounts they own in it. The RPC blocks a
    /// team's owner from leaving while other members remain, so that error surfaces to the UI
    /// rather than orphaning the team. The team is passed explicitly because a user can belong to
    /// several: the old no-argument RPC resolved it with a query that matched every membership and
    /// silently kept whichever row came back first.
    func leaveTeam(teamId: UUID) async throws {
        try await client
            .rpc("leave_team", params: TeamIdParam(p_team: teamId))
            .execute()
    }
}
