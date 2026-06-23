import SwiftUI
import Security

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

// Burn-all model: 1 full 5h session ≈ 11% of weekly budget
struct BurnForecast {
    let weeklyRemaining: Double     // 100 - sevenDay
    let sessionsLeft: Int           // full 5h windows before weekly reset
    let maxBurnable: Double         // min(sessionsLeft × 11, weeklyRemaining)
    let canExhaustLimit: Bool
    let estimatedExhaustionDate: Date?  // when 100% weekly is hit at max burn rate
}

// MARK: - Monitor

@MainActor
final class ClaudeMonitor: ObservableObject {
    @Published var fiveHour: Double = 0
    @Published var sevenDay: Double = 0
    @Published var fiveHourReset: Date?
    @Published var sevenDayReset: Date?
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var isLoading = false

    private var timer: Timer?
    private var cachedToken: String?
    private var tokenExpiresAt: Date?

    // % above/below linear pace within each window (+ = burning faster than time is passing)
    var fiveHourPace: Double? {
        guard let resetDate = fiveHourReset else { return nil }
        let windowStart = resetDate.addingTimeInterval(-5 * 3600)
        let elapsed = max(0, Date().timeIntervalSince(windowStart))
        let fraction = min(elapsed / (5 * 3600), 1)
        return fiveHour - fraction * 100
    }

    var sevenDayPace: Double? {
        guard let resetDate = sevenDayReset else { return nil }
        let windowStart = resetDate.addingTimeInterval(-7 * 24 * 3600)
        let elapsed = max(0, Date().timeIntervalSince(windowStart))
        let fraction = min(elapsed / (7 * 24 * 3600), 1)
        return sevenDay - fraction * 100
    }

    // Can I exhaust the weekly limit before it resets?
    var burnForecast: BurnForecast? {
        guard let resetDate = sevenDayReset else { return nil }
        let remaining = max(0, 100 - sevenDay)
        guard remaining > 0 else { return nil }
        let hoursLeft = resetDate.timeIntervalSinceNow / 3600
        guard hoursLeft > 0 else { return nil }
        let sessionsLeft = Int(hoursLeft / 5)
        let maxBurnable = min(Double(sessionsLeft) * 11, remaining)
        let canExhaust = Double(sessionsLeft) * 11 >= remaining
        var exhaustDate: Date? = nil
        if canExhaust {
            exhaustDate = Date().addingTimeInterval(ceil(remaining / 11) * 5 * 3600)
        }
        return BurnForecast(
            weeklyRemaining: remaining,
            sessionsLeft: sessionsLeft,
            maxBurnable: maxBurnable,
            canExhaustLimit: canExhaust,
            estimatedExhaustionDate: exhaustDate
        )
    }

    init() {
        Task { await fetch() }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
        }
    }

    func fetch() async {
        // No point hitting the server while the 5h window is maxed — nothing will change
        if fiveHour >= 100, let reset = fiveHourReset, reset > Date() {
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let token = keychainToken() else {
            error = "Credentials not found.\nRun Claude Code first, then allow\nKeychain access when prompted."
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                error = "HTTP \(http.statusCode) — token may need refresh.\nRestart Claude Code to re-authenticate."
                return
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            fiveHour = usage.fiveHour?.utilization ?? 0
            sevenDay = usage.sevenDay?.utilization ?? 0
            fiveHourReset = usage.fiveHour?.resetsAt.flatMap(parseISO8601)
            sevenDayReset = usage.sevenDay?.resetsAt.flatMap(parseISO8601)
            lastUpdated = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // macOS prompts for Keychain access on first launch — choose "Always Allow"
    // Subsequent calls use the in-memory cache until the token expires.
    private func keychainToken() -> String? {
        if let token = cachedToken, let expiry = tokenExpiresAt, expiry > Date() {
            return token
        }
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "Claude Code-credentials",
             kSecReturnData as String: true,
             kSecMatchLimit as String: kSecMatchLimitOne],
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "Claude Code",
             kSecAttrAccount as String: "credentials",
             kSecReturnData as String: true,
             kSecMatchLimit as String: kSecMatchLimitOne]
        ]
        for q in queries {
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String
            else { continue }
            if let ms = oauth["expiresAt"] as? Double {
                tokenExpiresAt = Date(timeIntervalSince1970: ms / 1000)
            }
            cachedToken = token
            return token
        }
        return nil
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

func resetLabel(for date: Date?) -> String {
    guard let date else { return "no active window" }
    if Calendar.current.isDateInToday(date) {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "resets at \(fmt.string(from: rounded))"
    }
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .short
    return "resets \(fmt.localizedString(for: date, relativeTo: .now))"
}

func shortDateTime(_ date: Date) -> String {
    let h = date.timeIntervalSinceNow / 3600
    let fmt = DateFormatter()
    if h < 14 {
        fmt.dateFormat = "h:mma"          // 3:30PM (today)
    } else if h < 38 {
        fmt.dateFormat = "'tomorrow' h:mma"
    } else {
        fmt.dateFormat = "EEE h:mma"      // Mon 3:30PM
    }
    return fmt.string(from: date)
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
                    let sign = p >= 0 ? "+" : ""
                    Text("\(sign)\(Int(p.rounded()))%")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(p > 15 ? .red : p > 0 ? .orange : .teal)
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

struct BurnForecastView: View {
    let forecast: BurnForecast

    private var sessionLine: String {
        "\(forecast.sessionsLeft) sessions × 11% = \(Int(forecast.maxBurnable.rounded()))% max"
    }

    private var outcomeIcon: String {
        forecast.canExhaustLimit ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var outcomeColor: Color {
        forecast.canExhaustLimit ? .green : .secondary
    }

    private var outcomeLine: String {
        if forecast.canExhaustLimit, let date = forecast.estimatedExhaustionDate {
            return "Limit hit ~\(shortDateTime(date))"
        } else {
            let unused = forecast.weeklyRemaining - forecast.maxBurnable
            return "\(Int(unused.rounded()))% expires unused at reset"
        }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionLine)
                        .font(.caption)
                    Text(outcomeLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

            if let err = monitor.error {
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
                if let d = monitor.lastUpdated {
                    Text("Updated \(d, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
    }
}

// MARK: - AppDelegate (hide from Dock)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Entry Point

@main
struct ClaudeTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = ClaudeMonitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            HStack(spacing: 4) {
                if monitor.error != nil, monitor.lastUpdated == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                } else if let p = monitor.fiveHourPace {
                    let sign = p >= 0 ? "+" : ""
                    Circle()
                        .fill(paceColor(p))
                        .frame(width: 7, height: 7)
                    Text("\(sign)\(Int(p.rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                } else {
                    // No active 5h window — show raw utilization
                    Circle()
                        .fill(statusColor(monitor.fiveHour))
                        .frame(width: 7, height: 7)
                    Text("\(Int(monitor.fiveHour.rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
            .padding(.horizontal, 2)
        }
        .menuBarExtraStyle(.window)
    }
}
