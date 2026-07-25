import Charts
import SwiftUI

/// Per-user weekly digest: prompt count, share of the pool, top accounts. Prompt counts are a
/// better proxy for "who used how much" than claim wall-clock time. Neither the Anthropic usage
/// API (per-account, never per-user) nor claim duration captures real interaction volume.
@MainActor
final class TeamUsageStats: ObservableObject {
    struct TopAccount: Identifiable {
        let email: String
        let count: Int
        var id: String { email }
    }

    struct MemberDigest: Identifiable {
        let id: UUID
        let displayName: String
        let turnCount: Int
        let sharePct: Double
        let topAccounts: [TopAccount]
    }

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var totalTurns = 0
    @Published private(set) var members: [MemberDigest] = []

    private let poolSync = PoolSyncService()

    /// `accountsById` keys pool accounts by Supabase row id, which is what `turn_log.account_id`
    /// points at. That's a different key from the `anthropicAccountUuid` used everywhere else, so
    /// the caller builds it fresh rather than this class reaching into AppState.
    func load(teamId: UUID, membersById: [UUID: Member], accountsById: [UUID: PoolAccount]) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-7 * 86400)
            let rows = try await poolSync.fetchTurnLog(teamId: teamId, since: since)
            totalTurns = rows.count

            var byUser: [UUID: [TurnLogRow]] = [:]
            for row in rows { byUser[row.userId, default: []].append(row) }

            members = byUser.map { userId, userRows in
                var accountCounts: [UUID: Int] = [:]
                for row in userRows {
                    guard let accountId = row.accountId else { continue }
                    accountCounts[accountId, default: 0] += 1
                }
                let top = accountCounts
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { TopAccount(email: accountsById[$0.key]?.email ?? "unpooled account", count: $0.value) }
                let share = totalTurns > 0 ? Double(userRows.count) / Double(totalTurns) * 100 : 0
                return MemberDigest(
                    id: userId,
                    displayName: membersById[userId]?.displayName ?? "Unknown member",
                    turnCount: userRows.count,
                    sharePct: share,
                    topAccounts: Array(top)
                )
            }.sorted { $0.turnCount > $1.turnCount }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The Team usage pane inside the Settings sidebar. Two halves: live per-account usage bars,
/// which work regardless of attribution, and, when prompt logging is on, charts of who has been
/// driving the pool over the last 7 days.
struct TeamUsagePane: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @StateObject private var stats = TeamUsageStats()
    @State private var window: UsageWindow = .sevenDay
    @State private var expanded: UUID?

    enum UsageWindow: String, CaseIterable, Identifiable {
        case fiveHour = "5-hour"
        case sevenDay = "7-day"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountUsageSection
                Divider()
                activitySection
            }
            .padding(20)
        }
        .task(id: teamId) { await reload() }
    }

    private var teamId: UUID? {
        if case .ready(let team, _) = pool.step { return team.id }
        return nil
    }

    // MARK: - Live account usage

    private struct AccountBar: Identifiable {
        let id: String
        let email: String
        let pct: Double?
        let resetsInLabel: String?
    }

    private var accountBars: [AccountBar] {
        state.displayAccounts.map { acct in
            let usageWindow = window == .fiveHour ? acct.usage?.fiveHour : acct.usage?.sevenDay
            return AccountBar(
                id: acct.accountUuid,
                email: acct.email,
                pct: usageWindow?.pct,
                resetsInLabel: usageWindow?.resetsInLabel
            )
        }
        .sorted { ($0.pct ?? -1) > ($1.pct ?? -1) }
    }

    private var accountUsageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Account usage").font(.title3).fontWeight(.semibold).foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: $window) {
                    ForEach(UsageWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }

            if accountBars.isEmpty {
                Text("No accounts in the pool yet.").font(.callout).foregroundStyle(Theme.textDim)
            } else {
                ForEach(accountBars) { bar in
                    HStack(spacing: 10) {
                        Text(bar.email)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        UsageMeter(pct: bar.pct)
                        Text(bar.pct.map { "\(Int($0))%" } ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(bar.pct.map { Theme.usageColor(forPct: $0) } ?? Theme.textDim)
                            .frame(width: 44, alignment: .trailing)
                        Text(bar.resetsInLabel ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
                Text("Bars show the \(window.rawValue) window. Green has room, red is near the limit.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: - Activity (attribution)

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Team activity").font(.title3).fontWeight(.semibold).foregroundStyle(Theme.text)
                Spacer()
                if state.attributionEnabled {
                    Text("Last 7 days · \(stats.totalTurns) prompts").font(.caption).foregroundStyle(Theme.textDim)
                }
            }

            if !state.attributionEnabled {
                attributionPrompt
            } else if let error = stats.lastError {
                Text(error).font(.callout).foregroundStyle(Theme.crit)
            } else if stats.isLoading && stats.members.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if stats.members.isEmpty {
                Text("No prompts logged in the last 7 days. Activity shows up here once you and your teammates use Claude Code.")
                    .font(.callout).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                charts
                memberList
            }
        }
    }

    private var attributionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt logging is off. Turn it on to see who's driving the pool. Each prompt logs a timestamp and the active account, never its contents.")
                .font(.callout).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Button("Turn on prompt logging") { state.setAttributionEnabled(true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
    }

    private var charts: some View {
        HStack(alignment: .top, spacing: 20) {
            // Share of the pool, as a donut.
            VStack(spacing: 6) {
                Chart(stats.members) { m in
                    SectorMark(
                        angle: .value("Prompts", m.turnCount),
                        innerRadius: .ratio(0.62),
                        angularInset: 2
                    )
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Member", m.displayName))
                }
                .chartLegend(.hidden)
                .frame(width: 150, height: 150)
                Text("Share of prompts").font(.caption2).foregroundStyle(Theme.textDim)
            }

            // Prompt counts, as horizontal bars.
            VStack(alignment: .leading, spacing: 6) {
                Chart(stats.members) { m in
                    BarMark(
                        x: .value("Prompts", m.turnCount),
                        y: .value("Member", m.displayName)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Member", m.displayName))
                    .annotation(position: .trailing) {
                        Text("\(m.turnCount)").font(.caption2).foregroundStyle(Theme.textDim)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks(position: .bottom) }
                .frame(height: max(90, CGFloat(stats.members.count) * 34))
                Text("Prompts per person").font(.caption2).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memberList: some View {
        VStack(spacing: 6) {
            ForEach(stats.members) { member in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expanded = expanded == member.id ? nil : member.id
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(member.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(member.turnCount)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                            Text(String(format: "%.0f%%", member.sharePct))
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 44, alignment: .trailing)
                            Image(systemName: expanded == member.id ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(Theme.textDim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    UsageMeter(pct: member.sharePct, tint: Theme.accent)

                    if expanded == member.id, !member.topAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(member.topAccounts) { acct in
                                HStack {
                                    Text(acct.email).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                    Spacer()
                                    Text("\(acct.count) prompts").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                }
                            }
                        }
                        .padding(.leading, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
            }
        }
    }

    private func reload() async {
        guard let teamId else { return }
        let accountsById = Dictionary(uniqueKeysWithValues: state.poolAccountsByUuid.values.map { ($0.id, $0) })
        await stats.load(teamId: teamId, membersById: state.membersById, accountsById: accountsById)
    }
}

/// A rounded horizontal meter: fill proportion coloured by usage, or a fixed tint for shares.
/// Animates on value change, which is what makes flipping the 5-hour/7-day control feel live.
private struct UsageMeter: View {
    let pct: Double?
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                Capsule()
                    .fill(tint ?? (pct.map { Theme.usageColor(forPct: $0) } ?? Theme.textDim))
                    .frame(width: max(4, geo.size.width * (pct ?? 0) / 100))
            }
        }
        .frame(height: 10)
        .animation(.easeInOut(duration: 0.3), value: pct)
    }
}
