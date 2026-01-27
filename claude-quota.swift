#!/usr/bin/env swift

import Foundation

// MARK: - Models

struct ClaudeQuota {
  struct Window {
    let percentUsed: Double
    let percentRemaining: Double
    let resetAt: Date?
    let resetText: String?
  }

  let session: Window?  // 5-hour window
  let weekly: Window?   // 7-day window
  let weeklyOpus: Window?  // 7-day Opus
  let weeklySonnet: Window?  // 7-day Sonnet
  let accountEmail: String?
  let plan: String?
  let extraUsage: ExtraUsage?

  struct ExtraUsage {
    let spendUSD: Double
    let limitUSD: Double
    let percentUsed: Double
  }
}

// MARK: - OAuth Fetcher

final class ClaudeOAuthFetcher {
  enum FetchError: Error, LocalizedError {
    case noCredentials
    case invalidCredentials
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .noCredentials: "No Claude credentials found"
      case .invalidCredentials: "Invalid credentials format"
      case let .requestFailed(msg): "Request failed: \(msg)"
      case .invalidResponse: "Invalid API response"
      }
    }
  }

  func fetch() async throws -> ClaudeQuota {
    let token = try loadAccessToken()
    let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw FetchError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw FetchError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FetchError.invalidResponse
    }

    return parseOAuthResponse(json)
  }

  private func loadAccessToken() throws -> String {
    // Try Keychain first (macOS)
    if let token = try? loadFromKeychain() {
      return token
    }

    // Fallback to file
    let home = FileManager.default.homeDirectoryForCurrentUser
    let credPath = home.appendingPathComponent(".claude/.credentials.json")

    guard let data = try? Data(contentsOf: credPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw FetchError.noCredentials
    }

    // Try new format: claudeAiOauth.accessToken
    if let oauth = json["claudeAiOauth"] as? [String: Any],
       let token = oauth["accessToken"] as? String {
      return token
    }

    // Fallback: old format with access_token
    if let token = json["access_token"] as? String {
      return token
    }

    throw FetchError.invalidCredentials
  }

  private func loadFromKeychain() throws -> String? {
    var result: CFTypeRef?
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]

    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    // Try new format: claudeAiOauth.accessToken
    if let oauth = json["claudeAiOauth"] as? [String: Any],
       let token = oauth["accessToken"] as? String {
      return token
    }

    // Fallback: old format with access_token
    if let token = json["access_token"] as? String {
      return token
    }

    return nil
  }

  private func parseOAuthResponse(_ json: [String: Any]) -> ClaudeQuota {
    func parseWindow(_ key: String) -> ClaudeQuota.Window? {
      guard let data = json[key] as? [String: Any] else { return nil }

      // API returns "utilization" as percentage (0-100)
      guard let utilization = (data["utilization"] as? NSNumber)?.doubleValue else { return nil }

      let percentUsed = utilization
      let percentRemaining = 100 - percentUsed

      var resetAt: Date?
      var resetText: String?
      if let resetStr = data["resets_at"] as? String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetStr) {
          resetAt = date
          resetText = formatReset(date)
        }
      }

      return ClaudeQuota.Window(
        percentUsed: percentUsed,
        percentRemaining: percentRemaining,
        resetAt: resetAt,
        resetText: resetText
      )
    }

    let session = parseWindow("five_hour")
    let weekly = parseWindow("seven_day")
    let weeklyOpus = parseWindow("seven_day_opus")
    let weeklySonnet = parseWindow("seven_day_sonnet")

    var extraUsage: ClaudeQuota.ExtraUsage?
    if let extra = json["extra_usage"] as? [String: Any],
       let spend = (extra["spend"] as? NSNumber)?.doubleValue,
       let limit = (extra["limit"] as? NSNumber)?.doubleValue,
       limit > 0 {
      // OAuth returns cents, convert to dollars
      let spendUSD = spend / 100
      let limitUSD = limit / 100
      let percentUsed = (spendUSD / limitUSD) * 100
      extraUsage = ClaudeQuota.ExtraUsage(
        spendUSD: spendUSD,
        limitUSD: limitUSD,
        percentUsed: percentUsed
      )
    }

    return ClaudeQuota(
      session: session,
      weekly: weekly,
      weeklyOpus: weeklyOpus,
      weeklySonnet: weeklySonnet,
      accountEmail: nil,
      plan: nil,
      extraUsage: extraUsage
    )
  }

  private func formatReset(_ date: Date) -> String {
    let now = Date()
    let interval = date.timeIntervalSince(now)
    guard interval > 0 else { return "now" }

    let days = Int(interval / 86400)
    let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
    let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

    if days > 0 {
      return "\(days)d \(hours)h"
    } else if hours > 0 {
      return "\(hours)h \(minutes)m"
    } else {
      return "\(minutes)m"
    }
  }
}

// MARK: - Formatter

enum QuotaFormatter {
  static func formatWindow(_ window: ClaudeQuota.Window?, label: String, showUsed: Bool) -> String {
    guard let window else { return "\(label): N/A" }

    let percent = showUsed ? window.percentUsed : window.percentRemaining
    let percentLabel = showUsed ? "used" : "remaining"
    let resetPart = window.resetText.map { " (resets in \($0))" } ?? ""

    return String(format: "\(label): %.1f%% \(percentLabel)\(resetPart)", percent)
  }

  static func formatProgressBar(percent: Double, width: Int = 40) -> String {
    let clamped = max(0, min(100, percent))
    let filled = Int((clamped / 100) * Double(width))
    let empty = width - filled

    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    return String(format: "[\(bar)] %.1f%%", clamped)
  }
}

// MARK: - CLI

struct CLI {
  enum OutputFormat {
    case text
    case json
  }

  struct Options {
    var format: OutputFormat = .text
    var showUsed: Bool = false
    var noBars: Bool = false
  }

  static func run() async {
    let options = parseArguments()

    do {
      let quota = try await ClaudeOAuthFetcher().fetch()

      switch options.format {
      case .text:
        printText(quota, options: options)
      case .json:
        printJSON(quota)
      }
      exit(0)
    } catch {
      print("Error: \(error.localizedDescription)")
      exit(1)
    }
  }

  private static func parseArguments() -> Options {
    var options = Options()
    let args = CommandLine.arguments.dropFirst()

    var i = args.startIndex
    while i < args.endIndex {
      let arg = args[i]
      switch arg {
      case "--json":
        options.format = .json
      case "--used":
        options.showUsed = true
      case "--no-bars":
        options.noBars = true
      case "--help", "-h":
        printHelp()
        exit(0)
      default:
        if arg.hasPrefix("-") {
          print("Unknown option: \(arg)")
          printHelp()
          exit(1)
        }
      }
      i = args.index(after: i)
    }

    return options
  }

  private static func printHelp() {
    print("""
    Claude Quota Tracker

    Usage: claude-quota [options]

    Options:
      --json          Output in JSON format
      --used          Show percent used instead of remaining
      --no-bars       Hide progress bars
      --help, -h      Show this help

    Examples:
      claude-quota                  # Show quota summary
      claude-quota --used           # Show percent used
      claude-quota --json           # Output JSON
    """)
  }

  private static func printText(_ quota: ClaudeQuota, options: Options) {
    print("Claude Quota Summary")
    print(String(repeating: "=", count: 50))
    print()

    if let email = quota.accountEmail {
      print("Account: \(email)")
    }
    if let plan = quota.plan {
      print("Plan: \(plan)")
    }
    if quota.accountEmail != nil || quota.plan != nil {
      print()
    }

    let showUsed = options.showUsed

    if let session = quota.session {
      print(QuotaFormatter.formatWindow(session, label: "Session (5h)", showUsed: showUsed))
      if !options.noBars {
        let percent = showUsed ? session.percentUsed : session.percentRemaining
        print("  \(QuotaFormatter.formatProgressBar(percent: percent))")
      }
      print()
    }

    if let weekly = quota.weekly {
      print(QuotaFormatter.formatWindow(weekly, label: "Weekly (7d)", showUsed: showUsed))
      if !options.noBars {
        let percent = showUsed ? weekly.percentUsed : weekly.percentRemaining
        print("  \(QuotaFormatter.formatProgressBar(percent: percent))")
      }
      print()
    }

    if let opus = quota.weeklyOpus {
      print(QuotaFormatter.formatWindow(opus, label: "Weekly Opus", showUsed: showUsed))
      if !options.noBars {
        let percent = showUsed ? opus.percentUsed : opus.percentRemaining
        print("  \(QuotaFormatter.formatProgressBar(percent: percent))")
      }
      print()
    }

    if let sonnet = quota.weeklySonnet {
      print(QuotaFormatter.formatWindow(sonnet, label: "Weekly Sonnet", showUsed: showUsed))
      if !options.noBars {
        let percent = showUsed ? sonnet.percentUsed : sonnet.percentRemaining
        print("  \(QuotaFormatter.formatProgressBar(percent: percent))")
      }
      print()
    }

    if let extra = quota.extraUsage {
      print("Extra Usage:")
      print(String(format: "  Spend: $%.2f / $%.2f", extra.spendUSD, extra.limitUSD))
      if !options.noBars {
        print("  \(QuotaFormatter.formatProgressBar(percent: extra.percentUsed))")
      }
      print()
    }
  }

  private static func printJSON(_ quota: ClaudeQuota) {
    func windowDict(_ window: ClaudeQuota.Window?) -> [String: Any]? {
      guard let window else { return nil }
      var dict: [String: Any] = [
        "percentUsed": window.percentUsed,
        "percentRemaining": window.percentRemaining,
      ]
      if let resetAt = window.resetAt {
        dict["resetAt"] = ISO8601DateFormatter().string(from: resetAt)
      }
      if let resetText = window.resetText {
        dict["resetText"] = resetText
      }
      return dict
    }

    var output: [String: Any] = [:]

    if let session = quota.session {
      output["session"] = windowDict(session)
    }
    if let weekly = quota.weekly {
      output["weekly"] = windowDict(weekly)
    }
    if let opus = quota.weeklyOpus {
      output["weeklyOpus"] = windowDict(opus)
    }
    if let sonnet = quota.weeklySonnet {
      output["weeklySonnet"] = windowDict(sonnet)
    }
    if let email = quota.accountEmail {
      output["accountEmail"] = email
    }
    if let plan = quota.plan {
      output["plan"] = plan
    }
    if let extra = quota.extraUsage {
      output["extraUsage"] = [
        "spendUSD": extra.spendUSD,
        "limitUSD": extra.limitUSD,
        "percentUsed": extra.percentUsed,
      ]
    }

    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
      print(json)
    }
  }
}

// MARK: - Main

Task {
  await CLI.run()
}

dispatchMain()
