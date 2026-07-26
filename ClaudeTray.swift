import SwiftUI
import Security
import UserNotifications

// MARK: - Model

struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?
    }
    let fiveHour: Window?
    let sevenDay: Window?
}

let fiveHourWindow: TimeInterval = 5 * 3600
let sevenDayWindow: TimeInterval = 7 * 24 * 3600
let weeklyPctPerSession = 11.0   // burn-all model: one maxed 5h session ≈ 11% of the week
let epsilon = 0.01               // below a hundredth of a percent, treat budget as spent

/// One 5h slot in the burn-all plan. Only slots that actually spend budget are
/// listed, which caps a plan at ceil(100 / 11) + 1 rows — short enough to show whole.
struct BurnSession: Identifiable {
    let id: Int
    let start: Date
    let isCurrent: Bool          // the window in progress, which starts part-spent
    let burn: Double             // weekly % this session consumes
    let remainingAfter: Double
}

struct BurnForecast {
    let weeklyRemaining: Double
    let sessionsLeft: Int        // 5h windows that fit before the weekly reset
    let unburnable: Double       // budget expiring because too few windows fit
    let finishesAt: Date?        // nil when the budget can't be spent in time
    let plan: [BurnSession]

    var canExhaust: Bool { finishesAt != nil }
    var sessionsNeeded: Int { plan.count + Int(ceil(unburnable / weeklyPctPerSession)) }
}

// MARK: - Monitor

@MainActor
final class ClaudeMonitor: ObservableObject {
    @Published var fiveHour = 0.0
    @Published var sevenDay = 0.0
    @Published var fiveHourReset: Date?
    @Published var sevenDayReset: Date?
    @Published var lastUpdated: Date?
    @Published var fatalError: String?      // credential failure — hides the usage rows
    @Published var transientError: String?  // recoverable — old values stay on screen
    @Published var isLoading = false

    /// Advanced by the ticker so time-based values stay live between fetches.
    @Published private var now = Date()

    private var timer: Timer?
    private var tickTimer: Timer?
    private var lastFetchAttempt: Date?
    private var cachedToken: String?
    private var tokenExpiresAt: Date?

    /// Recoverable states carry the message telling the user what to do about them.
    private enum TokenState {
        case ok(String)
        case unavailable(String)
        case missing
    }

    // MARK: Derived values

    private var resetDates: [Date] { [fiveHourReset, sevenDayReset].compactMap { $0 } }

    /// % above/below linear pace (+ = burning faster than time is passing).
    private func pace(_ used: Double, reset: Date?, window: TimeInterval) -> Double? {
        guard let reset else { return nil }
        let elapsed = max(0, now.timeIntervalSince(reset.addingTimeInterval(-window)))
        return used - min(elapsed / window, 1) * 100
    }

    var fiveHourPace: Double? { pace(fiveHour, reset: fiveHourReset, window: fiveHourWindow) }
    var sevenDayPace: Double? { pace(sevenDay, reset: sevenDayReset, window: sevenDayWindow) }

    /// Can I exhaust the weekly limit before it resets? Walks the 5h slots that fit,
    /// spending budget as it goes — every figure comes from that one walk, so the
    /// summary and the expanded plan can't disagree.
    var burnForecast: BurnForecast? {
        guard let weekReset = sevenDayReset, weekReset > now else { return nil }
        let remaining = max(0, 100 - sevenDay)
        guard remaining > epsilon else { return nil }

        // A window in progress only contributes its unused share, and only counts as
        // a slot if any is left; full-value sessions begin once it resets.
        let active = fiveHourReset.flatMap { $0 > now ? $0 : nil }
        let currentShare = active == nil ? 0 : max(0, 100 - fiveHour) / 100 * weeklyPctPerSession
        let usesCurrent = currentShare > epsilon
        let freshStart = active ?? now
        let slots = Int(weekReset.timeIntervalSince(freshStart) / fiveHourWindow) + (usesCurrent ? 1 : 0)

        var plan: [BurnSession] = []
        var left = remaining
        var start = usesCurrent ? now : freshStart
        var finishesAt: Date?
        while left > epsilon, plan.count < slots {
            let isCurrent = plan.isEmpty && usesCurrent
            let end = isCurrent ? (active ?? start) : start.addingTimeInterval(fiveHourWindow)
            let burn = min(isCurrent ? currentShare : weeklyPctPerSession, left)
            left -= burn
            plan.append(BurnSession(id: plan.count, start: start, isCurrent: isCurrent,
                                    burn: burn, remainingAfter: max(0, left)))
            // The final session ends when the budget runs out, not a full 5h in.
            if left <= epsilon {
                finishesAt = min(start.addingTimeInterval(burn / weeklyPctPerSession * fiveHourWindow), end)
            }
            start = end
        }
        return BurnForecast(weeklyRemaining: remaining, sessionsLeft: slots,
                            unburnable: left > epsilon ? left : 0,
                            finishesAt: finishesAt, plan: plan)
    }

    // MARK: Lifecycle

    init() {
        // Only missing credentials are fatal; an expired or blocked read recovers.
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
        // 3 min = 1% of the 5h window, the granularity at which the integer pace moves.
        let ticker = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)   // keep firing while the menu tracks
        tickTimer = ticker
        Task { await fetch() }
    }

    /// Re-renders time-based values from the last fetch — no network. Also a safety
    /// net: App Nap or sleep can delay the fetch timer past a reset, and the reset
    /// notification is system-delivered, so it arrives while the tray looks stale.
    private func tick() async {
        now = Date()
        let lastFetch = lastUpdated ?? .distantPast
        let attemptedRecently = lastFetchAttempt.map { now.timeIntervalSince($0) < 60 } ?? false
        if resetDates.contains(where: { $0 <= now && lastFetch < $0 }), !attemptedRecently {
            await fetch()
        }
    }

    func fetchIfStale(olderThan seconds: TimeInterval = 120) async {
        if lastUpdated.map({ Date().timeIntervalSince($0) > seconds }) ?? true { await fetch() }
    }

    /// 10-minute poll, or the next window reset if sooner (+20s so the server has
    /// caught up) — freshly reset values then appear on their own.
    private func scheduleNextFetch() {
        timer?.invalidate()
        let current = Date()
        var delay: TimeInterval = 600
        for reset in resetDates where reset > current {
            delay = min(delay, reset.timeIntervalSince(current) + 20)
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { await self?.fetch() }
        }
        t.tolerance = 5   // the ~10% default would land 60s late on a 10-min poll
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Fetching

    func fetch() async {
        // Four callers can trigger this; the in-flight one reschedules when it ends.
        if isLoading { return }
        // Must cover every exit path — polling is a one-shot timer, so returning
        // without rescheduling stops updates entirely.
        defer { scheduleNextFetch() }
        // Nothing changes while the 5h window is maxed; the reschedule wakes us
        // the moment it resets.
        if fiveHour >= 100, let reset = fiveHourReset, reset > Date() { return }

        lastFetchAttempt = Date()
        isLoading = true
        defer { isLoading = false }

        let token: String
        switch keychainToken() {
        case .ok(let t):
            token = t
        case .unavailable(let why):
            transientError = why      // keep old values, retry on schedule
            return
        case .missing:
            fatalError = "Credentials not found.\nRun Claude Code first, then allow\nKeychain access when prompted."
            return
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            var (data, resp) = try await URLSession.shared.data(for: req)
            // On 401 the cached token is stale — re-read the Keychain and retry once.
            if (resp as? HTTPURLResponse)?.statusCode == 401 {
                cachedToken = nil
                tokenExpiresAt = nil
                if case .ok(let fresh) = keychainToken() {
                    req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                    (data, resp) = try await URLSession.shared.data(for: req)
                }
            }
            if let http = resp as? HTTPURLResponse {
                print("[ClaudeTray] HTTP \(http.statusCode) — \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
                switch http.statusCode {
                case 200: break
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
            let usage = try usageDecoder.decode(UsageResponse.self, from: data)
            let newFiveHour = usage.fiveHour?.resetsAt.flatMap(parseISO8601)
            let newSevenDay = usage.sevenDay?.resetsAt.flatMap(parseISO8601)
            if newFiveHour != fiveHourReset {
                notifyReset("5h", at: newFiveHour, title: "5-hour session reset",
                            body: "Your 5-hour Claude window has reset — ready to go.")
            }
            if newSevenDay != sevenDayReset {
                notifyReset("7d", at: newSevenDay, title: "Weekly limit reset",
                            body: "Your 7-day Claude budget has reset — full capacity restored.")
            }
            fiveHour = usage.fiveHour?.utilization ?? 0
            sevenDay = usage.sevenDay?.utilization ?? 0
            fiveHourReset = newFiveHour
            sevenDayReset = newSevenDay
            lastUpdated = Date()
            fatalError = nil
            transientError = nil
        } catch {
            transientError = error.localizedDescription
        }
    }

    private func notifyReset(_ id: String, at date: Date?, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current(), key = "claudetray.\(id)"
        center.removePendingNotificationRequests(withIdentifiers: [key])
        guard let date, date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let at = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        center.add(UNNotificationRequest(identifier: key, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false)))
    }

    /// Choose "Always Allow" at the macOS prompt. Claude Code rewrites the Keychain
    /// item whenever it refreshes the token, which resets that grant — so a later
    /// read can be blocked again. That's recoverable, not missing credentials.
    private func keychainToken() -> TokenState {
        if let token = cachedToken, let expiry = tokenExpiresAt, expiry > Date() {
            return .ok(token)
        }
        cachedToken = nil
        tokenExpiresAt = nil
        var denied = false
        for (service, account) in [("Claude Code-credentials", nil), ("Claude Code", "credentials")]
            as [(String, String?)] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let account { query[kSecAttrAccount as String] = account }
            var out: AnyObject?
            switch SecItemCopyMatching(query as CFDictionary, &out) {
            case errSecSuccess:
                guard let data = out as? Data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = json["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String
                else { continue }
                if let ms = oauth["expiresAt"] as? Double {
                    // Claude Code refreshes it on its own; don't spend the request.
                    guard case let expiry = Date(timeIntervalSince1970: ms / 1000), expiry > Date() else {
                        return .unavailable("Token expired — reopen Claude Code to refresh")
                    }
                    tokenExpiresAt = expiry
                }
                cachedToken = token
                return .ok(token)
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                denied = true        // blocked, not absent
            default:
                break                // errSecItemNotFound and friends → try next location
            }
        }
        return denied ? .unavailable("Keychain access needed — allow when prompted") : .missing
    }
}

// MARK: - Formatting

/// Converts snake_case, so `UsageResponse` needs no CodingKeys.
let usageDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

/// Shared: DateFormatter is costly to build and these run on every render.
func dateFmt(_ pattern: String) -> DateFormatter {
    let f = DateFormatter(); f.dateFormat = pattern; return f
}
let clockFmt = dateFmt("HH:mm"), dayFmt = dateFmt("EEE HH:mm"), tomorrowFmt = dateFmt("'tomorrow' HH:mm")
let relativeFmt: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
}()

func parseISO8601(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
}

/// One 24-hour convention, rounded in one place, so the same instant can't render as
/// 08:09 here and 08:10 there. `verbose` spells out "tomorrow" for prose lines.
func timeLabel(_ date: Date, verbose: Bool = false) -> String {
    let cal = Calendar.current
    let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    if cal.isDateInToday(date) { return clockFmt.string(from: rounded) }
    if verbose, cal.isDateInTomorrow(date) { return tomorrowFmt.string(from: rounded) }
    return dayFmt.string(from: rounded)
}

func resetLabel(for date: Date?) -> String {
    guard let date else { return "no active window" }
    return Calendar.current.isDateInToday(date)
        ? "resets at \(timeLabel(date))"
        : "resets \(relativeFmt.localizedString(for: date, relativeTo: .now))"
}

func pctLabel(_ v: Double) -> String {
    v > 0 && v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
}

/// Signed pace, e.g. "+17%" — the tray label and the popover badge agree.
func paceLabel(_ p: Double) -> String { "\(p >= 0 ? "+" : "")\(Int(p.rounded()))%" }

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
    case ...0:  return .green    // under pace — headroom remaining
    case ..<15: return .yellow
    case ..<30: return .orange
    default:    return .red      // burning far ahead of schedule
    }
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
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                ProgressView(value: min(pct / 100, 1))
                    .progressViewStyle(.linear).tint(statusColor(pct))
                Text("\(Int(pct.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor(pct))
                    .frame(width: 34, alignment: .trailing)
                if let pace {
                    Text(paceLabel(pace))
                        .font(.caption2.weight(.medium)).foregroundStyle(paceColor(pace))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                }
            }
            Text(resetLabel(for: resetDate))
                .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 28)
        }
    }
}

struct BurnForecastView: View {
    let forecast: BurnForecast
    @State private var expanded = false

    private var sessionLine: String {
        forecast.canExhaust
            ? "Needs \(forecast.sessionsNeeded) of \(forecast.sessionsLeft) maxed sessions"
            : "Needs \(forecast.sessionsNeeded) sessions, only \(forecast.sessionsLeft) fit"
    }

    private var outcomeLine: String {
        guard let finish = forecast.finishesAt else {
            return "\(pctLabel(forecast.unburnable))% of \(pctLabel(forecast.weeklyRemaining))% expires unused"
        }
        return "\(pctLabel(forecast.weeklyRemaining))% left · limit hit ~\(timeLabel(finish, verbose: true))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Burn-all forecast")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: forecast.canExhaust ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption).padding(.top, 1)
                    .foregroundStyle(forecast.canExhaust ? Color.green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionLine).font(.caption)
                        Text(outcomeLine).font(.caption2).foregroundStyle(.secondary)
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
                        .font(.caption2).foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(forecast.plan) { session in
                                HStack(spacing: 0) {
                                    Text("\(session.id + 1)")
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 14, alignment: .trailing)
                                    Text(session.isCurrent ? "now" : timeLabel(session.start))
                                        .frame(width: 62, alignment: .leading).padding(.leading, 6)
                                    Text("−\(pctLabel(session.burn))%").foregroundStyle(.purple)
                                    Spacer(minLength: 4)
                                    Text("\(pctLabel(session.remainingAfter))% left")
                                        .foregroundStyle(session.remainingAfter <= 0 ? Color.green : .secondary)
                                }
                            }
                        }
                        .font(.caption2.monospacedDigit())
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
                Image(systemName: "waveform").foregroundStyle(.purple)
                Text("Claude Limits").font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.isLoading { ProgressView().scaleEffect(0.65) }
            }

            Divider()

            if let err = monitor.fatalError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                UsageRow(label: "5h", pct: monitor.fiveHour,
                         resetDate: monitor.fiveHourReset, pace: monitor.fiveHourPace)
                UsageRow(label: "7d", pct: monitor.sevenDay,
                         resetDate: monitor.sevenDayReset, pace: monitor.sevenDayPace)
                if let forecast = monitor.burnForecast {
                    Divider()
                    BurnForecastView(forecast: forecast)
                }
            }

            Divider()

            HStack {
                Group {
                    if let d = monitor.lastUpdated, let warn = monitor.transientError {
                        Text("Updated \(d, style: .relative) ago · \(warn)").foregroundStyle(Color.orange)
                    } else if let warn = monitor.transientError {
                        Text(warn).foregroundStyle(Color.orange)
                    } else if let d = monitor.lastUpdated {
                        Text("Updated \(d, style: .relative) ago")
                    } else if monitor.fatalError == nil {
                        Text("Loading…")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { Task { await monitor.fetch() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Divider().frame(height: 12)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { Task { await monitor.fetchIfStale() } }
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)        // no Dock icon
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
            print("[ClaudeTray] Notifications: "
                + (error.map { "error — \($0.localizedDescription)" } ?? (ok ? "granted" : "denied")))
        }
    }
}

@main
struct ClaudeTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = ClaudeMonitor()

    /// 5h pace while a window is active, raw utilization otherwise.
    private var trayStatus: (Color, String) {
        if let p = monitor.fiveHourPace { return (paceColor(p), paceLabel(p)) }
        return (statusColor(monitor.fiveHour), "\(Int(monitor.fiveHour.rounded()))%")
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                if monitor.fatalError != nil, monitor.lastUpdated == nil {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                } else {
                    let (color, text) = trayStatus
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(text).font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
            .padding(.horizontal, 2)
        }
        .menuBarExtraStyle(.window)
    }
}
