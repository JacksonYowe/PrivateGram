import AppKit
import SwiftUI


/// Follower analytics for the Mac app: followers, following, recent followers, people who
/// unfollowed you, and "not following back" — with CSV export and a safety-gated one-tap unfollow.
///
/// Everything reads Instagram's own web endpoints from the logged-in page (the same ones the
/// website uses), paced to stay inside normal browser behaviour. Reads are low risk; the unfollow
/// is the dangerous part, so it is forced through a hard rate limit + daily cap and auto-stops if
/// Instagram flags the account. See the ban-risk review this was built to.

struct IGUser: Codable, Identifiable, Hashable {
    let pk: String
    let username: String
    let fullName: String
    var id: String { pk }
}

enum InsightsTab: String, CaseIterable, Identifiable {
    case notFollowingBack = "Not following back"
    case recent = "Recent followers"
    case unfollowed = "Unfollowed you"
    case followers = "Followers"
    case following = "Following"
    var id: String { rawValue }
}

@MainActor
final class Insights {
    static let shared = Insights()
    private var windowController: NSWindowController?
    let model = InsightsModel()

    func present(host: NSWindow?, runner: @escaping (String) async -> String?) {
        model.runner = runner
        if windowController == nil {
            let hosting = NSHostingController(rootView: InsightsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Follower Insights"
            window.setContentSize(NSSize(width: 460, height: 620))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            windowController = NSWindowController(window: window)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        model.loadSnapshot()
    }
}

// MARK: - Model

@MainActor
final class InsightsModel: ObservableObject {
    @Published var followers: [IGUser] = []
    @Published var following: [IGUser] = []
    @Published var recent: [IGUser] = []        // new followers since last refresh
    @Published var unfollowed: [IGUser] = []     // followers lost since last refresh
    @Published var tab: InsightsTab = .notFollowingBack
    @Published var status = "Press Refresh to load your data."
    @Published var loading = false
    @Published var progress = ""
    @Published var lastRefresh: Date?
    @Published var unfollowedToday = 0
    @Published var halted = false                // set when Instagram flags us; blocks unfollows
    @Published var nextUnfollowReady = Date.distantPast

    var runner: ((String) async -> String?)?

    // Conservative because this account was recently soft-locked. Not user-editable.
    private let dailyUnfollowCap = 10
    private let minUnfollowGap: TimeInterval = 45   // plus jitter

    var notFollowingBack: [IGUser] {
        let f = Set(followers.map(\.pk))
        return following.filter { !f.contains($0.pk) }
    }

    var rows: [IGUser] {
        switch tab {
        case .notFollowingBack: return notFollowingBack
        case .recent: return recent
        case .unfollowed: return unfollowed
        case .followers: return followers
        case .following: return following
        }
    }

    var canUnfollowTab: Bool { tab == .notFollowingBack || tab == .following }


    // MARK: Snapshot persistence

    private struct Snapshot: Codable { var date: Date; var followers: [IGUser]; var following: [IGUser] }

    private var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("insights.json")
    }

    func loadSnapshot() {
        guard followers.isEmpty, following.isEmpty,
              let data = try? Data(contentsOf: snapshotURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        followers = snap.followers
        following = snap.following
        lastRefresh = snap.date
        status = "Loaded your last saved data. Press Refresh to update."
        resetDailyCountIfNeeded()
    }

    private func saveSnapshot() {
        let snap = Snapshot(date: Date(), followers: followers, following: following)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: snapshotURL) }
    }

    // MARK: Refresh (paced reads)

    func refresh() {
        guard !loading, let runner else { return }
        loading = true; halted = false; progress = ""
        status = "Loading…"
        Task {
            defer { loading = false; progress = "" }
            guard let pk = await currentUserID(runner) else { status = "Couldn't read your account — are you logged in?"; return }
            let oldFollowers = followers

            status = "Loading followers…"
            guard let newFollowers = await fetchList(pk: pk, kind: "followers", runner: runner) else {
                status = haltedMessage(); return
            }
            status = "Loading following…"
            guard let newFollowing = await fetchList(pk: pk, kind: "following", runner: runner) else {
                status = haltedMessage(); return
            }

            // Diff against the previous snapshot.
            if !oldFollowers.isEmpty {
                let oldSet = Set(oldFollowers.map(\.pk)), newSet = Set(newFollowers.map(\.pk))
                recent = newFollowers.filter { !oldSet.contains($0.pk) }
                unfollowed = oldFollowers.filter { !newSet.contains($0.pk) }
            }
            followers = newFollowers
            following = newFollowing
            lastRefresh = Date()
            saveSnapshot()
            status = "\(newFollowers.count) followers · \(newFollowing.count) following"
                + (oldFollowers.isEmpty ? " · recent/unfollowed will show after your next refresh"
                                        : " · +\(recent.count) new, −\(unfollowed.count) left")
        }
    }

    /// One page at a time, paced in Swift with jitter and periodic longer pauses.
    private func fetchList(pk: String, kind: String, runner: (String) async -> String?) async -> [IGUser]? {
        var out: [IGUser] = []
        var cursor: String?
        var page = 0
        repeat {
            page += 1
            progress = "\(kind.capitalized): \(out.count)"
            let js = """
            const h = { 'x-ig-app-id':'936619743392459',
              'x-csrftoken': (document.cookie.match(/csrftoken=([^;]+)/)||[])[1]||'',
              'x-requested-with':'XMLHttpRequest' };
            const max = \(cursor.map { "'\($0.jsEscaped)'" } ?? "null");
            const url = '/api/v1/friendships/\(pk)/\(kind)/?count=30' + (max ? '&max_id=' + encodeURIComponent(max) : '');
            try {
              const r = await fetch(url, { headers: h, credentials: 'include' });
              let j = {}; try { j = await r.json(); } catch(_) {}
              return JSON.stringify({ status: r.status,
                next: j.next_max_id || null,
                blocked: ((j.message && /feedback_required|checkpoint_required|challenge_required|login_required/.test(j.message)) || j.spam === true) ? (j.message || 'spam') : null,
                users: (j.users||[]).map(u => ({ pk: String(u.pk), un: u.username || '', fn: u.full_name || '' })) });
            } catch (e) { return JSON.stringify({ status: 0, err: String(e) }); }
            """
            guard let text = await runner(js), let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                halted = true; return nil
            }
            let httpStatus = obj["status"] as? Int ?? 0
            if httpStatus == 429 || (obj["blocked"] as? String) != nil || httpStatus == 401 {
                halted = true; return nil
            }
            if let users = obj["users"] as? [[String: Any]] {
                for u in users {
                    if let pk = u["pk"] as? String, !pk.isEmpty {
                        out.append(IGUser(pk: pk, username: u["un"] as? String ?? "", fullName: u["fn"] as? String ?? ""))
                    }
                }
            }
            cursor = obj["next"] as? String
            if cursor != nil {
                // Human-paced: 2–4 s between pages, and a longer breather every ~10 pages.
                let base = page % 10 == 0 ? Double.random(in: 8...15) : Double.random(in: 2...4)
                try? await Task.sleep(nanoseconds: UInt64(base * 1_000_000_000))
            }
        } while cursor != nil && page < 400
        return out
    }

    private func currentUserID(_ runner: (String) async -> String?) async -> String? {
        let js = "return (document.cookie.match(/ds_user_id=(\\d+)/) || [])[1] || null;"
        guard let text = await runner(js) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.range(of: #"^\d+$"#, options: .regularExpression) != nil ? id : nil
    }

    private func haltedMessage() -> String {
        "Stopped — Instagram asked to slow down or verify. Use the real app, then try again tomorrow."
    }

    // MARK: Unfollow (safety-gated, one tap, no dialog)

    func unfollow(_ user: IGUser) {
        resetDailyCountIfNeeded()
        guard let runner else { return }
        if halted { status = haltedMessage(); return }
        if unfollowedToday >= dailyUnfollowCap {
            status = "Daily unfollow limit reached (\(dailyUnfollowCap)). This protects your account — try again tomorrow."
            return
        }
        let wait = nextUnfollowReady.timeIntervalSinceNow
        if wait > 0 {
            status = "Pacing to stay safe — wait \(Int(ceil(wait)))s before the next unfollow."
            return
        }
        // Reserve the slot immediately so rapid taps can't burst past the limiter.
        nextUnfollowReady = Date().addingTimeInterval(minUnfollowGap + Double.random(in: 0...45))
        status = "Unfollowing @\(user.username)…"
        Task {
            let js = """
            const h = { 'x-ig-app-id':'936619743392459',
              'x-csrftoken': (document.cookie.match(/csrftoken=([^;]+)/)||[])[1]||'',
              'x-requested-with':'XMLHttpRequest',
              'content-type':'application/x-www-form-urlencoded' };
            try {
              const r = await fetch('/api/v1/friendships/destroy/\(user.pk)/', { method:'POST', headers:h, credentials:'include', body:'' });
              let j = {}; try { j = await r.json(); } catch(_) {}
              return JSON.stringify({ status: r.status, ok: j.status === 'ok',
                blocked: ((j.message && /feedback_required|checkpoint_required|challenge_required/.test(j.message)) || j.spam === true) ? (j.message || 'spam') : null });
            } catch (e) { return JSON.stringify({ status: 0, err: String(e) }); }
            """
            guard let text = await runner(js), let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                nextUnfollowReady = .distantPast
                status = "Couldn't reach Instagram. Nothing changed."
                return
            }
            if (obj["blocked"] as? String) != nil || (obj["status"] as? Int) == 429 {
                halted = true
                status = "Instagram flagged this as too fast. Unfollowing is paused — open the real app and check your account."
                return
            }
            if obj["ok"] as? Bool == true {
                following.removeAll { $0.pk == user.pk }
                unfollowedToday += 1
                persistDailyCount()
                status = "Unfollowed @\(user.username)  ·  \(unfollowedToday)/\(dailyUnfollowCap) today"
            } else {
                nextUnfollowReady = .distantPast
                status = "Couldn't unfollow @\(user.username)."
            }
        }
    }

    var capLabel: String { "\(unfollowedToday)/\(dailyUnfollowCap) today" }

    // Daily counter, stored per calendar day.
    private func resetDailyCountIfNeeded() {
        let today = Self.dayKey()
        if UserDefaults.standard.string(forKey: "insightsUnfollowDay") != today {
            UserDefaults.standard.set(today, forKey: "insightsUnfollowDay")
            UserDefaults.standard.set(0, forKey: "insightsUnfollowCount")
        }
        unfollowedToday = UserDefaults.standard.integer(forKey: "insightsUnfollowCount")
    }
    private func persistDailyCount() {
        UserDefaults.standard.set(Self.dayKey(), forKey: "insightsUnfollowDay")
        UserDefaults.standard.set(unfollowedToday, forKey: "insightsUnfollowCount")
    }
    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: CSV export

    func exportCSV() {
        let rows = self.rows
        guard !rows.isEmpty else { status = "Nothing to export in this list."; return }
        let header = "username,full_name,profile_url,list,exported\n"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = rows.map { u in
            [u.username, u.fullName, "https://instagram.com/\(u.username)/", tab.rawValue, stamp]
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
        }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "instagram-\(tab.rawValue.replacingOccurrences(of: " ", with: "-")).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? (header + body + "\n").data(using: .utf8)?.write(to: url)
        }
    }
}

private extension String {
    var jsEscaped: String { replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
}

// MARK: - View

struct InsightsView: View {
    @ObservedObject var model: InsightsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: model.refresh) {
                    Label(model.loading ? "Loading…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading)
                if model.loading, !model.progress.isEmpty {
                    ProgressView().controlSize(.small)
                    Text(model.progress).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.exportCSV) { Label("Export CSV", systemImage: "square.and.arrow.down") }
                    .disabled(model.rows.isEmpty)
            }
            .padding(12)

            Picker("", selection: $model.tab) {
                ForEach(InsightsTab.allCases) { Text(countLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider().padding(.top, 8)

            if model.rows.isEmpty {
                Spacer()
                Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                List(model.rows) { user in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(user.username)").fontWeight(.medium)
                            if !user.fullName.isEmpty {
                                Text(user.fullName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.canUnfollowTab {
                            // Red = this person is not a mutual (opposite of "follow back").
                            // One tap, no dialog — but the model's rate limit + daily cap gate it.
                            Button {
                                model.unfollow(user)
                            } label: {
                                Text("Unfollow").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(model.status).font(.caption).foregroundStyle(model.halted ? .red : .secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.canUnfollowTab {
                    Text(model.capLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private func countLabel(_ tab: InsightsTab) -> String {
        let n: Int
        switch tab {
        case .notFollowingBack: n = model.notFollowingBack.count
        case .recent: n = model.recent.count
        case .unfollowed: n = model.unfollowed.count
        case .followers: n = model.followers.count
        case .following: n = model.following.count
        }
        let short = ["Not following back": "Non-mutual", "Recent followers": "Recent",
                     "Unfollowed you": "Unfollowed", "Followers": "Followers", "Following": "Following"][tab.rawValue] ?? tab.rawValue
        return model.followers.isEmpty && model.following.isEmpty ? short : "\(short) \(n)"
    }

    private var emptyText: String {
        switch model.tab {
        case .recent, .unfollowed:
            return "This compares your followers between two refreshes.\nRefresh now, then again later to see changes."
        default:
            return "Press Refresh to load your followers and following."
        }
    }
}
