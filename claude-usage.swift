#!/usr/bin/env swift

import Foundation

// MARK: - Models

struct ClaudeUsageDay: Codable {
  let date: String
  let inputTokens: Int
  let cacheReadTokens: Int
  let cacheCreationTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  let costUSD: Double?
  let models: [String: ModelUsage]

  struct ModelUsage: Codable {
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let outputTokens: Int
    let costUSD: Double?
  }
}

struct ClaudeUsageSummary {
  let days: [ClaudeUsageDay]
  let totalInputTokens: Int
  let totalCacheReadTokens: Int
  let totalCacheCreationTokens: Int
  let totalOutputTokens: Int
  let totalTokens: Int
  let totalCostUSD: Double?
}

enum ProviderFilter {
  case all
  case vertexOnly
  case excludeVertex
}

// MARK: - Pricing

enum ClaudePricing {
  static func costUSD(
    model: String,
    inputTokens: Int,
    cacheReadTokens: Int,
    cacheCreationTokens: Int,
    outputTokens: Int
  ) -> Double? {
    let normalized = normalizeModel(model)
    guard let pricing = prices[normalized] else { return nil }

    let inputCost = Double(inputTokens) * pricing.input / 1_000_000
    let cacheReadCost = Double(cacheReadTokens) * pricing.cacheRead / 1_000_000
    let cacheCreateCost = Double(cacheCreationTokens) * pricing.cacheCreate / 1_000_000
    let outputCost = Double(outputTokens) * pricing.output / 1_000_000

    return inputCost + cacheReadCost + cacheCreateCost + outputCost
  }

  static func normalizeModel(_ model: String) -> String {
    // Remove @ version suffix (Vertex AI format)
    let withoutVersion = model.split(separator: "@").first.map(String.init) ?? model
    // Common normalizations
    return withoutVersion
      .replacingOccurrences(of: "anthropic.", with: "")
  }

  private struct Pricing {
    let input: Double
    let cacheRead: Double
    let cacheCreate: Double
    let output: Double
  }

  private static let prices: [String: Pricing] = [
    "claude-opus-4-5": Pricing(input: 15.00, cacheRead: 1.50, cacheCreate: 18.75, output: 75.00),
    "claude-sonnet-4-5": Pricing(input: 3.00, cacheRead: 0.30, cacheCreate: 3.75, output: 15.00),
    "claude-3-7-sonnet": Pricing(input: 3.00, cacheRead: 0.30, cacheCreate: 3.75, output: 15.00),
    "claude-3-5-sonnet": Pricing(input: 3.00, cacheRead: 0.30, cacheCreate: 3.75, output: 15.00),
    "claude-3-5-haiku": Pricing(input: 1.00, cacheRead: 0.10, cacheCreate: 1.25, output: 5.00),
    "claude-3-haiku": Pricing(input: 0.25, cacheRead: 0.03, cacheCreate: 0.30, output: 1.25),
    "claude-3-opus": Pricing(input: 15.00, cacheRead: 1.50, cacheCreate: 18.75, output: 75.00),
    "claude-3-sonnet": Pricing(input: 3.00, cacheRead: 0.30, cacheCreate: 3.75, output: 15.00),
  ]
}

// MARK: - Scanner

final class ClaudeUsageScanner {
  private let projectsRoots: [URL]
  private let providerFilter: ProviderFilter
  private let daysSince: Int

  init(projectsRoots: [URL]? = nil, providerFilter: ProviderFilter = .all, daysSince: Int = 30) {
    self.projectsRoots = projectsRoots ?? Self.defaultProjectsRoots()
    self.providerFilter = providerFilter
    self.daysSince = daysSince
  }

  func scan() -> ClaudeUsageSummary {
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysSince, to: Date()) ?? Date()
    let cutoffKey = Self.dayKey(from: cutoffDate)

    var daysByKey: [String: [String: [Int]]] = [:]
    var seenKeys: Set<String> = []

    for root in projectsRoots {
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      scanRoot(root, into: &daysByKey, seen: &seenKeys, cutoffKey: cutoffKey)
    }

    return buildSummary(from: daysByKey, cutoffKey: cutoffKey)
  }

  private func scanRoot(
    _ root: URL,
    into daysByKey: inout [String: [String: [Int]]],
    seen: inout Set<String>,
    cutoffKey: String
  ) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return }

    for case let url as URL in enumerator {
      guard url.pathExtension.lowercased() == "jsonl" else { continue }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      guard values.isRegularFile == true else { continue }
      let size = Int64(values.fileSize ?? 0)
      guard size > 0 else { continue }

      parseFile(url, into: &daysByKey, seen: &seen, cutoffKey: cutoffKey)
    }
  }

  private func parseFile(
    _ url: URL,
    into daysByKey: inout [String: [String: [Int]]],
    seen: inout Set<String>,
    cutoffKey: String
  ) {
    guard let data = try? Data(contentsOf: url) else { return }
    let lines = data.split(separator: UInt8(ascii: "\n"))

    for lineData in lines {
      guard !lineData.isEmpty else { continue }
      guard lineData.contains(UInt8(ascii: "\"")) else { continue }

      guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
            let type = obj["type"] as? String,
            type == "assistant"
      else { continue }

      guard matchesProviderFilter(obj) else { continue }

      guard let tsText = obj["timestamp"] as? String,
            let dayKey = Self.dayKeyFromTimestamp(tsText)
      else { continue }

      guard dayKey >= cutoffKey else { continue }

      guard let message = obj["message"] as? [String: Any],
            let model = message["model"] as? String,
            let usage = message["usage"] as? [String: Any]
      else { continue }

      // Deduplicate by message ID + request ID
      let messageId = message["id"] as? String
      let requestId = obj["requestId"] as? String
      if let messageId, let requestId {
        let key = "\(messageId):\(requestId)"
        guard !seen.contains(key) else { continue }
        seen.insert(key)
      }

      let input = max(0, toInt(usage["input_tokens"]))
      let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
      let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
      let output = max(0, toInt(usage["output_tokens"]))

      guard input > 0 || cacheCreate > 0 || cacheRead > 0 || output > 0 else { continue }

      addUsage(
        dayKey: dayKey,
        model: model,
        input: input,
        cacheRead: cacheRead,
        cacheCreate: cacheCreate,
        output: output,
        to: &daysByKey
      )
    }
  }

  private func addUsage(
    dayKey: String,
    model: String,
    input: Int,
    cacheRead: Int,
    cacheCreate: Int,
    output: Int,
    to daysByKey: inout [String: [String: [Int]]]
  ) {
    let normalized = ClaudePricing.normalizeModel(model)
    var dayModels = daysByKey[dayKey] ?? [:]
    var packed = dayModels[normalized] ?? [0, 0, 0, 0]
    packed[0] += input
    packed[1] += cacheRead
    packed[2] += cacheCreate
    packed[3] += output
    dayModels[normalized] = packed
    daysByKey[dayKey] = dayModels
  }

  private func buildSummary(from daysByKey: [String: [String: [Int]]], cutoffKey: String) -> ClaudeUsageSummary {
    var days: [ClaudeUsageDay] = []
    var totalInput = 0
    var totalCacheRead = 0
    var totalCacheCreate = 0
    var totalOutput = 0
    var totalCost = 0.0
    var hasCost = false

    let sortedKeys = daysByKey.keys.sorted()

    for dayKey in sortedKeys where dayKey >= cutoffKey {
      guard let models = daysByKey[dayKey] else { continue }

      var dayInput = 0
      var dayCacheRead = 0
      var dayCacheCreate = 0
      var dayOutput = 0
      var dayCost = 0.0
      var dayHasCost = false
      var modelUsages: [String: ClaudeUsageDay.ModelUsage] = [:]

      for (model, packed) in models {
        let input = packed[safe: 0] ?? 0
        let cacheRead = packed[safe: 1] ?? 0
        let cacheCreate = packed[safe: 2] ?? 0
        let output = packed[safe: 3] ?? 0

        dayInput += input
        dayCacheRead += cacheRead
        dayCacheCreate += cacheCreate
        dayOutput += output

        if let cost = ClaudePricing.costUSD(
          model: model,
          inputTokens: input,
          cacheReadTokens: cacheRead,
          cacheCreationTokens: cacheCreate,
          outputTokens: output
        ) {
          dayCost += cost
          dayHasCost = true
          modelUsages[model] = ClaudeUsageDay.ModelUsage(
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            outputTokens: output,
            costUSD: cost
          )
        } else {
          modelUsages[model] = ClaudeUsageDay.ModelUsage(
            inputTokens: input,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            outputTokens: output,
            costUSD: nil
          )
        }
      }

      let dayTotal = dayInput + dayCacheRead + dayCacheCreate + dayOutput
      days.append(ClaudeUsageDay(
        date: dayKey,
        inputTokens: dayInput,
        cacheReadTokens: dayCacheRead,
        cacheCreationTokens: dayCacheCreate,
        outputTokens: dayOutput,
        totalTokens: dayTotal,
        costUSD: dayHasCost ? dayCost : nil,
        models: modelUsages
      ))

      totalInput += dayInput
      totalCacheRead += dayCacheRead
      totalCacheCreate += dayCacheCreate
      totalOutput += dayOutput
      if dayHasCost {
        totalCost += dayCost
        hasCost = true
      }
    }

    let totalTokens = totalInput + totalCacheRead + totalCacheCreate + totalOutput

    return ClaudeUsageSummary(
      days: days,
      totalInputTokens: totalInput,
      totalCacheReadTokens: totalCacheRead,
      totalCacheCreationTokens: totalCacheCreate,
      totalOutputTokens: totalOutput,
      totalTokens: totalTokens,
      totalCostUSD: hasCost ? totalCost : nil
    )
  }

  private func matchesProviderFilter(_ obj: [String: Any]) -> Bool {
    switch providerFilter {
    case .all:
      return true
    case .vertexOnly:
      return isVertexAI(obj)
    case .excludeVertex:
      return !isVertexAI(obj)
    }
  }

  private func isVertexAI(_ obj: [String: Any]) -> Bool {
    // Check message/request IDs for vrtx prefix
    if let message = obj["message"] as? [String: Any],
       let messageId = message["id"] as? String,
       messageId.contains("_vrtx_") {
      return true
    }
    if let requestId = obj["requestId"] as? String,
       requestId.contains("_vrtx_") {
      return true
    }

    // Check model format (Vertex uses @ separator)
    if let message = obj["message"] as? [String: Any],
       let model = message["model"] as? String,
       model.hasPrefix("claude-"), model.contains("@") {
      return true
    }

    return false
  }

  private func toInt(_ value: Any?) -> Int {
    if let n = value as? NSNumber { return n.intValue }
    return 0
  }

  private static func defaultProjectsRoots() -> [URL] {
    var roots: [URL] = []
    let home = FileManager.default.homeDirectoryForCurrentUser

    if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
       !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      for part in env.split(separator: ",") {
        let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        let url = URL(fileURLWithPath: raw)
        if url.lastPathComponent == "projects" {
          roots.append(url)
        } else {
          roots.append(url.appendingPathComponent("projects", isDirectory: true))
        }
      }
    } else {
      roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
      roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
    }

    return roots
  }

  private static func dayKey(from date: Date) -> String {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
  }

  private static func dayKeyFromTimestamp(_ ts: String) -> String? {
    // Parse ISO 8601 timestamp: 2026-01-27T10:30:45.123Z
    let parts = ts.split(separator: "T")
    guard parts.count >= 1 else { return nil }
    let datePart = String(parts[0])
    let components = datePart.split(separator: "-")
    guard components.count == 3 else { return nil }
    return datePart
  }
}

// MARK: - Formatting

enum UsageFormatter {
  static func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
      return String(format: "%.1fK", Double(count) / 1_000)
    } else {
      return "\(count)"
    }
  }

  static func formatCost(_ cost: Double) -> String {
    return String(format: "$%.4f", cost)
  }

  static func formatPercent(_ value: Double, total: Double) -> String {
    guard total > 0 else { return "0%" }
    let percent = (value / total) * 100
    return String(format: "%.1f%%", percent)
  }
}

// MARK: - CLI

struct CLI {
  enum OutputFormat {
    case text
    case json
  }

  struct Options {
    var days: Int = 30
    var format: OutputFormat = .text
    var providerFilter: ProviderFilter = .all
    var showDaily: Bool = false
    var showModels: Bool = false
  }

  static func run() {
    let options = parseArguments()
    let scanner = ClaudeUsageScanner(
      providerFilter: options.providerFilter,
      daysSince: options.days
    )
    let summary = scanner.scan()

    switch options.format {
    case .text:
      printText(summary, options: options)
    case .json:
      printJSON(summary)
    }
  }

  private static func parseArguments() -> Options {
    var options = Options()
    let args = CommandLine.arguments.dropFirst()

    var i = args.startIndex
    while i < args.endIndex {
      let arg = args[i]
      switch arg {
      case "--days", "-d":
        i = args.index(after: i)
        if i < args.endIndex, let days = Int(args[i]) {
          options.days = days
        }
      case "--json":
        options.format = .json
      case "--daily":
        options.showDaily = true
      case "--models":
        options.showModels = true
      case "--vertex-only":
        options.providerFilter = .vertexOnly
      case "--exclude-vertex":
        options.providerFilter = .excludeVertex
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
    Claude Usage Tracker

    Usage: claude-usage [options]

    Options:
      --days, -d N        Show usage for last N days (default: 30)
      --json              Output in JSON format
      --daily             Show daily breakdown
      --models            Show per-model breakdown
      --vertex-only       Only show Vertex AI usage
      --exclude-vertex    Exclude Vertex AI usage
      --help, -h          Show this help

    Examples:
      claude-usage                    # Show 30-day summary
      claude-usage --days 7 --daily   # Show daily breakdown for last 7 days
      claude-usage --json             # Output JSON
    """)
  }

  private static func printText(_ summary: ClaudeUsageSummary, options: Options) {
    let filterLabel: String = switch options.providerFilter {
    case .all: ""
    case .vertexOnly: " (Vertex AI only)"
    case .excludeVertex: " (excluding Vertex AI)"
    }

    print("Claude Usage Summary (\(options.days) days)\(filterLabel)")
    print(String(repeating: "=", count: 50))
    print()

    if summary.days.isEmpty {
      print("No usage found.")
      return
    }

    print("Total Tokens: \(UsageFormatter.formatTokens(summary.totalTokens))")
    print("  Input:          \(UsageFormatter.formatTokens(summary.totalInputTokens))")
    print("  Cache Read:     \(UsageFormatter.formatTokens(summary.totalCacheReadTokens))")
    print("  Cache Create:   \(UsageFormatter.formatTokens(summary.totalCacheCreationTokens))")
    print("  Output:         \(UsageFormatter.formatTokens(summary.totalOutputTokens))")

    if let cost = summary.totalCostUSD {
      print()
      print("Total Cost: \(UsageFormatter.formatCost(cost))")
    }

    if options.showDaily {
      print()
      print("Daily Breakdown:")
      print(String(repeating: "-", count: 50))

      for day in summary.days.sorted(by: { $0.date > $1.date }) {
        print()
        print("\(day.date):")
        print("  Tokens: \(UsageFormatter.formatTokens(day.totalTokens))")
        if let cost = day.costUSD {
          print("  Cost: \(UsageFormatter.formatCost(cost))")
        }

        if options.showModels {
          let sortedModels = day.models.sorted { $0.value.outputTokens > $1.value.outputTokens }
          for (model, usage) in sortedModels {
            print("    \(model):")
            print("      Input: \(UsageFormatter.formatTokens(usage.inputTokens))")
            if usage.cacheReadTokens > 0 {
              print("      Cache Read: \(UsageFormatter.formatTokens(usage.cacheReadTokens))")
            }
            if usage.cacheCreationTokens > 0 {
              print("      Cache Create: \(UsageFormatter.formatTokens(usage.cacheCreationTokens))")
            }
            print("      Output: \(UsageFormatter.formatTokens(usage.outputTokens))")
            if let cost = usage.costUSD {
              print("      Cost: \(UsageFormatter.formatCost(cost))")
            }
          }
        }
      }
    }
  }

  private static func printJSON(_ summary: ClaudeUsageSummary) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let output: [String: Any] = [
      "days": summary.days.map { day -> [String: Any] in
        var dict: [String: Any] = [
          "date": day.date,
          "totalTokens": day.totalTokens,
          "inputTokens": day.inputTokens,
          "cacheReadTokens": day.cacheReadTokens,
          "cacheCreationTokens": day.cacheCreationTokens,
          "outputTokens": day.outputTokens,
        ]
        if let cost = day.costUSD {
          dict["costUSD"] = cost
        }
        dict["models"] = day.models.mapValues { usage -> [String: Any] in
          var modelDict: [String: Any] = [
            "inputTokens": usage.inputTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "outputTokens": usage.outputTokens,
          ]
          if let cost = usage.costUSD {
            modelDict["costUSD"] = cost
          }
          return modelDict
        }
        return dict
      },
      "summary": [
        "totalTokens": summary.totalTokens,
        "totalInputTokens": summary.totalInputTokens,
        "totalCacheReadTokens": summary.totalCacheReadTokens,
        "totalCacheCreationTokens": summary.totalCacheCreationTokens,
        "totalOutputTokens": summary.totalOutputTokens,
        "totalCostUSD": summary.totalCostUSD as Any,
      ],
    ]

    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
      print(json)
    }
  }
}

// MARK: - Array Extension

extension Array {
  subscript(safe index: Int) -> Element? {
    return indices.contains(index) ? self[index] : nil
  }
}

// MARK: - Main

CLI.run()
