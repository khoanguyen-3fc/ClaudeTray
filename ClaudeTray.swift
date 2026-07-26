import SwiftUI
import Security
import UserNotifications

// MARK: - Data

struct UsageResponse: Decodable {
    struct Window: Decodable {
        var utilization: Double
        var resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    let fiveHour: Window?
    let sevenDay: Window?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

let fiveHourWindow: TimeInterval = 5 * 3600
let sevenDayWindow: TimeInterval = 7 * 24 * 3600
// Burn-all model: 1 full 5h session ≈ 11% of weekly budget
let weeklyPctPerSession = 11.0

// One 5h slot in the burn-all plan. `burn` is 0 for slots that fit before the
// weekly reset but aren't needed — the budget already ran out earlier.
struct BurnSession: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    let isCurrent: Bool         // the window already in progress
    let burn: Double            // weekly % this session would consume
    let remainingAfter: Double
}

struct BurnForecast {
    let weeklyRemaining: Double     // 100 - sevenDay
    let sessionsLeft: Int           // 5h windows that fit before the weekly reset
    let sessionsNeeded: Int         // minimum maxed sessions to burn the remaining budget
    let maxBurnable: Double         // total the plan can actually consume
    let canExhaustLimit: Bool
    let estimatedExhaustionDate: Date?  // when 100% weekly is hit at max burn rate
    let plan: [BurnSession]         // the schedule the numbers above are derived from
}

// MARK: - Monitor

@MainActor
final class ClaudeMonitor: ObservableObject {
    @Published var fiveHour: Double = 0
    @Published var sevenDay: Double = 0
    @Published var fiveHourReset: Date?
    @Published var sevenDayReset: Date?
    @Published var lastUpdated: Date?
    @Published var fatalError: String?    // auth/credential failure — hides usage rows
    @Published var transientError: String? // 429/5xx/network — keeps old values, shown in footer
    @Published var isLoading = false

    // Advanced by a lightweight ticker so time-based values (pace, forecast) stay
    // live between fetches — including while the 5h window is maxed and we don't poll.
    @Published private var now = Date()

    private var timer: Timer?
    private var tickTimer: Timer?
    private var lastFetchAttempt: Date?
    private var cachedToken: String?
    private var tokenExpiresAt: Date?

    // Outcome of a Keychain read — distinguishes "no credentials" (fatal) from
    // recoverable states (expired token, or access denied/not-yet-granted).
    private enum TokenState {
        case ok(String)
        case expired   // item present but past expiresAt — Claude Code will refresh it
        case denied    // read blocked: user cancelled, auth failed, or UI not allowed
        case missing   // no credential item at all
    }

    // % above/below linear pace within a window (+ = burning faster than time is passing)
    private func pace(_ utilization: Double, reset: Date?, window: TimeInterval) -> Double? {
        guard let reset else { return nil }
        let elapsed = max(0, now.timeIntervalSince(reset.addingTimeInterval(-window)))
        return utilization - min(elapsed / window, 1) * 100
    }

    var fiveHourPace: Double? { pace(fiveHour, reset: fiveHourReset, window: fiveHourWindow) }
    var sevenDayPace: Double? { pace(sevenDay, reset: sevenDayReset, window: sevenDayWindow) }

    private var resetDates: [Date] { [fiveHourReset, sevenDayReset].compactMap { $0 } }

    // Can I exhaust the weekly limit before it resets? Walks the 5h slots that fit
    // before the weekly reset, spending budget as it goes — every figure below is
    // derived from that one walk, so the summary and the detail can't disagree.
    var burnForecast: BurnForecast? {
        guard let weekReset = sevenDayReset else { return nil }
        let remaining = max(0, 100 - sevenDay)
        guard remaining > 0, weekReset > now else { return nil }

        // The active 5h window is already partly spent, so it can only contribute its
        // unused share; full-value sessions only begin once it resets.
        let activeReset = fiveHourReset.flatMap { $0 > now ? $0 : nil }
        let currentCap = activeReset == nil ? 0
            : max(0, 100 - fiveHour) / 100 * weeklyPctPerSession

        var plan: [BurnSession] = []
        var left = remaining
        var cursor = now
        if let activeReset {
            left -= min(currentCap, left)
            plan.append(BurnSession(id: 0, start: now, end: activeReset, isCurrent: true,
                                    burn: min(currentCap, remaining), remainingAfter: left))
            cursor = activeReset
        }
        while cursor.addingTimeInterval(fiveHourWindow) <= weekReset, plan.count < 40 {
            let end = cursor.addingTimeInterval(fiveHourWindow)
            let burn = min(weeklyPctPerSession, left)
            left -= burn
            plan.append(BurnSession(id: plan.count, start: cursor, end: end, isCurrent: false,
                                    burn: burn, remainingAfter: left))
            cursor = end
        }

        let canExhaust = left <= 0.0001
        // Slots that fit can't cover it — count how many more would have been needed.
        let sessionsNeeded = canExhaust
            ? plan.filter { $0.burn > 0 }.count
            : plan.count + Int(ceil(left / weeklyPctPerSession))
        // The final session only burns what's left of the budget, so it ends early.
        var exhaustDate: Date? = nil
        if canExhaust, let last = plan.last(where: { $0.burn > 0 }) {
            let span = last.burn / weeklyPctPerSession * fiveHourWindow
            exhaustDate = min(last.start.addingTimeInterval(span), last.end)
        }
        return BurnForecast(
            weeklyRemaining: remaining,
            sessionsLeft: plan.count,
            sessionsNeeded: sessionsNeeded,
            maxBurnable: remaining - left,
            canExhaustLimit: canExhaust,
            estimatedExhaustionDate: exhaustDate,
            plan: plan
        )
    }

    init() {
        // Only quit when there are genuinely no credentials. An expired token or a
        // denied/not-yet-granted read is recoverable — start up and let fetch() retry.
        if case .missing = keychainToken() {
            let alert = NSAlert()
            alert.messageText = "Claude credentials not found"
            alert.informativeText = "Sign in to Claude Code first, then relaunch ClaudeTray.\n\nIf you already signed in, relaunch and choose \"Always Allow\" when macOS prompts for Keychain access."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // Re-render time-based values (pace, forecast) from the last fetched
        // utilization — no network. 3 min = 1% of the 5h window, the granularity at
        // which the displayed integer pace actually moves.
        let ticker = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        ticker.tolerance = 5
        // .common mode so ticks keep firing while the popover/menu is tracking
        RunLoop.main.add(ticker, forMode: .common)
        tickTimer = ticker
        Task { await fetch() }
    }

    private func tick() async {
        now = Date()
        // Safety net: App Nap or system sleep can delay the one-shot fetch timer past
        // a window reset — the "limit reset" notification fires on time (it's
        // system-delivered) but the tray would keep stale values. If a reset passed
        // and we haven't fetched since, fetch now (at most one attempt per 60s).
        let lastFetch = lastUpdated ?? .distantPast
        let resetPassed = resetDates.contains { $0 <= now && lastFetch < $0 }
        let attemptedRecently = lastFetchAttempt.map { now.timeIntervalSince($0) < 60 } ?? false
        if resetPassed, !attemptedRecently {
            await fetch()
        }
    }

    func fetchIfStale(olderThan seconds: TimeInterval = 120) async {
        let stale = lastUpdated.map { Date().timeIntervalSince($0) > seconds } ?? true
        if stale { await fetch() }
    }

    private func scheduleNextFetch() {
        timer?.invalidate()
        let current = Date()
        // Default 10-min poll, but if a window resets sooner, wake up right then so
        // the freshly-reset values show up on their own. Small buffer lets the server
        // reflect the reset before we read.
        var delay: TimeInterval = 600
        for reset in resetDates where reset > current {
            delay = min(delay, reset.timeIntervalSince(current) + 20)
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { await self?.fetch() }
        }
        t.tolerance = 5   // default tolerance is ~10% of interval — 60s late on a 10-min poll
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func fetch() async {
        // Timer, ticker, popover-open, and the refresh button can all trigger a fetch;
        // don't stack them. The in-flight fetch will reschedule when it finishes.
        if isLoading { return }
        // Reschedule on EVERY exit path — early returns (429/5xx/fatal) previously
        // skipped the trailing call and silently killed polling.
        defer { scheduleNextFetch() }
        // No point hitting the server while the 5h window is maxed — nothing changes
        // until it resets. The reschedule wakes us the moment it does.
        if fiveHour >= 100, let reset = fiveHourReset, reset > Date() {
            return
        }
        lastFetchAttempt = Date()
        isLoading = true
        defer { isLoading = false }
        let token: String
        switch keychainToken() {
        case .ok(let t):
            token = t
        case .expired:
            // Don't fetch with a known-bad token — Claude Code refreshes it on its own.
            transientError = "Token expired — reopen Claude Code to refresh"
            return
        case .denied:
            // ACL was reset (e.g. after Claude Code refreshed the token). Keep old
            // values, retry on schedule / next popover open — no need to restart.
            transientError = "Keychain access needed — allow when prompted"
            return
        case .missing:
            fatalError = "Credentials not found.\nRun Claude Code first, then allow\nKeychain access when prompted."
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            var (data, resp) = try await URLSession.shared.data(for: req)
            // On 401, bust the cache and retry once with a fresh keychain read
            if (resp as? HTTPURLResponse)?.statusCode == 401 {
                cachedToken = nil
                tokenExpiresAt = nil
                if case .ok(let freshToken) = keychainToken() {
                    req.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")
                    (data, resp) = try await URLSession.shared.data(for: req)
                }
            }
            if let http = resp as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                print("[ClaudeTray] HTTP \(http.statusCode) — \(body)")
                switch http.statusCode {
                case 200:
                    break
                case 401:
                    fatalError = "Authentication failed — restart Claude Code to re-authenticate."
                    return
                case 429:
                    transientError = "Rate limited"
                    return
                default:
                    transientError = "Server error (\(http.statusCode))"
                    return
                }
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            fiveHour = usage.fiveHour?.utilization ?? 0
            sevenDay = usage.sevenDay?.utilization ?? 0
            let newFiveHourReset = usage.fiveHour?.resetsAt.flatMap(parseISO8601)
            let newSevenDayReset = usage.sevenDay?.resetsAt.flatMap(parseISO8601)
            if newFiveHourReset != fiveHourReset {
                scheduleResetNotification(id: "5h", at: newFiveHourReset,
                                          title: "5-hour session reset",
                                          body: "Your 5-hour Claude window has reset — ready to go.")
            }
            if newSevenDayReset != sevenDayReset {
                scheduleResetNotification(id: "7d", at: newSevenDayReset,
                                          title: "Weekly limit reset",
                                          body: "Your 7-day Claude budget has reset — full capacity restored.")
            }
            fiveHourReset = newFiveHourReset
            sevenDayReset = newSevenDayReset
            lastUpdated = Date()
            fatalError = nil
            transientError = nil
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func scheduleResetNotification(id: String, at date: Date?, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["claudetray.\(id)"])
        guard let date, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: "claudetray.\(id)", content: content, trigger: trigger))
    }

    // macOS prompts for Keychain access on first launch — choose "Always Allow".
    // Subsequent calls use the in-memory cache until the token expires. Note: when
    // Claude Code refreshes the token it rewrites the Keychain item, which resets the
    // item's access list — so macOS may prompt again on the next read. That surfaces
    // here as .denied if the prompt is dismissed / can't be shown; we recover rather
    // than treating it as missing credentials.
    private func keychainToken() -> TokenState {
        if let token = cachedToken, let expiry = tokenExpiresAt, expiry > Date() {
            return .ok(token)
        }
        cachedToken = nil
        tokenExpiresAt = nil
        let locations: [(service: String, account: String?)] = [
            ("Claude Code-credentials", nil),
            ("Claude Code", "credentials")
        ]
        var denied = false
        for (service, account) in locations {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let account { q[kSecAttrAccount as String] = account }
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            switch status {
            case errSecSuccess:
                guard let data = out as? Data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = json["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String
                else { continue }
                if let ms = oauth["expiresAt"] as? Double {
                    let expiry = Date(timeIntervalSince1970: ms / 1000)
                    if expiry <= Date() { return .expired }
                    tokenExpiresAt = expiry
                }
                cachedToken = token
                return .ok(token)
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                denied = true          // access blocked, not absent — recoverable
            default:
                break                  // errSecItemNotFound and friends → try next query
            }
        }
        return denied ? .denied : .missing
    }
}

// MARK: - Helpers

func parseISO8601(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
}

func statusColor(_ pct: Double) -> Color {
    switch pct {
    case ..<50: return .green
    case ..<80: return .yellow
    case ..<95: return .orange
    default:    return .red
    }
}

func paceColor(_ pace: Double) -> Color {
    switch pace {
    case ...0:   return .green   // under pace — headroom remaining
    case ..<15:  return .yellow
    case ..<30:  return .orange
    default:     return .red     // burning far ahead of schedule
    }
}

// Formatters are expensive to build and these run on every render, so they're
// shared. One 24-hour convention everywhere — the reset line, the forecast and the
// session plan all name the same instants.
enum TimeFormat {
    static let clock = pattern("HH:mm")                    // 08:10
    static let dayClock = pattern("EEE HH:mm")             // Tue 04:09
    static let tomorrowClock = pattern("'tomorrow' HH:mm")
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static func pattern(_ p: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = p
        return f
    }
}

// Rounding in one place, so the same instant can't render as 08:09 here and 08:10
// there. `verbose` spells out "tomorrow" for prose; table rows just get the weekday.
func timeLabel(_ date: Date, verbose: Bool = false) -> String {
    let cal = Calendar.current
    let fmt: DateFormatter
    if cal.isDateInToday(date) {
        fmt = TimeFormat.clock
    } else if verbose, cal.isDateInTomorrow(date) {
        fmt = TimeFormat.tomorrowClock
    } else {
        fmt = TimeFormat.dayClock
    }
    return fmt.string(from: Date(timeIntervalSince1970:
        (date.timeIntervalSince1970 / 60).rounded() * 60))
}

func resetLabel(for date: Date?) -> String {
    guard let date else { return "no active window" }
    if Calendar.current.isDateInToday(date) {
        return "resets at \(timeLabel(date))"
    }
    return "resets \(TimeFormat.relative.localizedString(for: date, relativeTo: .now))"
}

func pctLabel(_ v: Double) -> String {
    v > 0 && v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
}

// Signed pace, e.g. "+17%" / "-8%" — the tray label and the popover badge agree.
func paceLabel(_ p: Double) -> String {
    "\(p >= 0 ? "+" : "")\(Int(p.rounded()))%"
}

// MARK: - Views

struct UsageRow: View {
    let label: String
    let pct: Double
    let resetDate: Date?
    var pace: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                ProgressView(value: min(pct / 100, 1))
                    .progressViewStyle(.linear)
                    .tint(statusColor(pct))
                Text("\(Int(pct.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor(pct))
                    .frame(width: 34, alignment: .trailing)
                if let p = pace {
                    Text(paceLabel(p))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(paceColor(p))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                }
            }
            Text(resetLabel(for: resetDate))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
        }
    }
}

// A plain VStack for short plans — a ScrollView with no parent height to resolve
// against collapses to nothing inside a MenuBarExtra window, so it only wraps the
// list once there are more rows than fit, and then with an explicit height.
struct SessionPlanList: View {
    let plan: [BurnSession]

    private let rowHeight: CGFloat = 16
    private let maxRows = 8

    private var rows: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(plan) { SessionPlanRow(session: $0) }
        }
    }

    var body: some View {
        if plan.count > maxRows {
            ScrollView { rows }
                .frame(height: rowHeight * CGFloat(maxRows))
        } else {
            rows
        }
    }
}

struct SessionPlanRow: View {
    let session: BurnSession

    var body: some View {
        let spare = session.burn <= 0
        HStack(spacing: 0) {
            Text("\(session.id + 1)")
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .trailing)
            Text(session.isCurrent ? "now" : timeLabel(session.start))
                .frame(width: 62, alignment: .leading)
                .padding(.leading, 6)
            Text(spare ? "spare" : "−\(pctLabel(session.burn))%")
                .foregroundStyle(spare ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.purple))
            Spacer(minLength: 4)
            Text("\(pctLabel(session.remainingAfter))% left")
                .foregroundStyle(session.remainingAfter <= 0.0001 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        }
        .font(.caption2.monospacedDigit())
        .opacity(spare ? 0.55 : 1)
    }
}

struct BurnForecastView: View {
    let forecast: BurnForecast
    @State private var expanded = false

    private var sessionLine: String {
        forecast.canExhaustLimit
            ? "Needs \(forecast.sessionsNeeded) of \(forecast.sessionsLeft) maxed sessions"
            : "Needs \(forecast.sessionsNeeded) sessions, only \(forecast.sessionsLeft) fit"
    }

    private var outcomeIcon: String {
        forecast.canExhaustLimit ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var outcomeColor: Color {
        forecast.canExhaustLimit ? .green : .secondary
    }

    private var outcomeLine: String {
        if forecast.canExhaustLimit, let date = forecast.estimatedExhaustionDate {
            return "\(pctLabel(forecast.weeklyRemaining))% left · limit hit ~\(timeLabel(date, verbose: true))"
        }
        let unused = forecast.weeklyRemaining - forecast.maxBurnable
        return "\(pctLabel(unused))% of \(pctLabel(forecast.weeklyRemaining))% expires unused"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Burn-all forecast")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: outcomeIcon)
                    .foregroundStyle(outcomeColor)
                    .font(.caption)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionLine)
                            .font(.caption)
                        Text(outcomeLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)   // wrap, don't truncate
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                            Text(expanded ? "Hide plan" : "Show plan")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        SessionPlanList(plan: forecast.plan)
                    }
                }
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: ClaudeMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.purple)
                Text("Claude Limits")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.isLoading {
                    ProgressView().scaleEffect(0.65)
                }
            }

            Divider()

            if let err = monitor.fatalError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                UsageRow(label: "5h", pct: monitor.fiveHour, resetDate: monitor.fiveHourReset, pace: monitor.fiveHourPace)
                UsageRow(label: "7d", pct: monitor.sevenDay, resetDate: monitor.sevenDayReset, pace: monitor.sevenDayPace)
                if let forecast = monitor.burnForecast {
                    Divider()
                    BurnForecastView(forecast: forecast)
                }
            }

            Divider()

            HStack {
                Group {
                    if let warn = monitor.transientError {
                        if let d = monitor.lastUpdated {
                            Text("Updated \(d, style: .relative) ago · \(warn)")
                        } else {
                            Text(warn)
                        }
                    } else if let d = monitor.lastUpdated {
                        Text("Updated \(d, style: .relative) ago")
                    } else if monitor.fatalError == nil {
                        Text("Loading…")
                    }
                }
                .font(.caption2)
                .foregroundStyle(monitor.transientError != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                Spacer()
                Button {
                    Task { await monitor.fetch() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Divider().frame(height: 12)

                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            Task { await monitor.fetchIfStale() }
        }
    }
}

// MARK: - AppDelegate (hide from Dock)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[ClaudeTray] Notification auth error: \(error.localizedDescription)")
            } else {
                print("[ClaudeTray] Notification permission: \(granted ? "granted" : "denied")")
            }
        }
    }
}

// MARK: - Entry Point

@main
struct ClaudeTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = ClaudeMonitor()

    // 5h pace when a window is active, raw utilization otherwise
    private var trayStatus: (Color, String) {
        if let p = monitor.fiveHourPace {
            return (paceColor(p), paceLabel(p))
        }
        return (statusColor(monitor.fiveHour), "\(Int(monitor.fiveHour.rounded()))%")
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                if monitor.fatalError != nil, monitor.lastUpdated == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                } else {
                    let (color, text) = trayStatus
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(text)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
            .padding(.horizontal, 2)
        }
        .menuBarExtraStyle(.window)
    }
}
