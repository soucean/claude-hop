import Foundation

enum ClaudeUsage {
    static let usageURL = "https://api.anthropic.com/oauth/usage"

    static func fetchUsage(service: String) -> [String: Any]? {
        NSLog("[ClaudeHop] fetchUsage — service: %@", service)

        guard let creds = KeychainManager.readCredentials(service: service) else {
            NSLog("[ClaudeHop] fetchUsage — FAIL: cannot read credentials from Keychain")
            return nil
        }
        NSLog("[ClaudeHop] fetchUsage — credentials read OK (%d bytes)", creds.count)

        guard let token = extractToken(from: creds) else {
            // Log the top-level keys to understand the actual structure
            if let data = creds.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                NSLog("[ClaudeHop] fetchUsage — FAIL: token extract failed. Top-level keys: %@", json.keys.joined(separator: ", "))
            } else {
                NSLog("[ClaudeHop] fetchUsage — FAIL: credentials not valid JSON. First 100 chars: %@", String(creds.prefix(100)))
            }
            return nil
        }
        NSLog("[ClaudeHop] fetchUsage — token extracted OK (first 12 chars: %@...)", String(token.prefix(12)))

        var request = URLRequest(url: URL(string: usageURL)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-code/2.1.11", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        var result: [String: Any]?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, resp, error in
            defer { sema.signal() }
            if let error {
                NSLog("[ClaudeHop] fetchUsage — network error: %@", error.localizedDescription)
                return
            }
            if let http = resp as? HTTPURLResponse {
                NSLog("[ClaudeHop] fetchUsage — HTTP %d", http.statusCode)
                if http.statusCode == 401 {
                    result = ["error": "token_expired"]
                    return
                }
                guard http.statusCode < 400 else {
                    if let data, let body = String(data: data, encoding: .utf8) {
                        NSLog("[ClaudeHop] fetchUsage — error body: %@", String(body.prefix(300)))
                    }
                    return
                }
            }
            if let data {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    NSLog("[ClaudeHop] fetchUsage — response keys: %@", json.keys.joined(separator: ", "))
                    result = json
                } else {
                    NSLog("[ClaudeHop] fetchUsage — response not JSON: %@", String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
                }
            }
        }.resume()
        sema.wait()
        return result
    }

    static func fetchUsageForAccount(email: String) -> [String: Any]? {
        let usage = fetchUsage(service: "claude-switcher:\(email)")
        if usage?["error"] as? String == "token_expired" {
            return ["error": "session_expired"]
        }
        return usage
    }

    static func fetchActiveUsage() -> [String: Any]? {
        fetchUsage(service: KeychainManager.claudeService)
    }

    // Fetch usage for the active account, refreshing the token via Claude CLI if expired.
    // If CLI refresh fails, recover from ClaudeHop's stored backup for activeEmail.
    static func fetchActiveUsageWithRefresh(activeEmail: String? = nil) -> [String: Any]? {
        var usage = fetchUsage(service: KeychainManager.claudeService)
        guard usage?["error"] as? String == "token_expired" else { return usage }

        // Round 1: ask Claude CLI to self-refresh
        _ = ClaudeCore.getAuthStatus()
        KeychainManager.invalidateClaudeServiceCache()
        usage = fetchUsage(service: KeychainManager.claudeService)
        guard usage?["error"] as? String == "token_expired" else { return usage }

        // Round 2: still 401 — recover from ClaudeHop's stored backup
        guard let email = activeEmail else { return usage }
        NSLog("[ClaudeHop] fetchActiveUsageWithRefresh — recovering from stored backup for %@", email)
        return recoverFromStoredCredentials(email: email)
    }

    // Try claude-switcher:<email>; if valid, copy credentials back to the active Keychain slot.
    private static func recoverFromStoredCredentials(email: String) -> [String: Any]? {
        let storedService = "claude-switcher:\(email)"
        let usage = fetchUsage(service: storedService)
        guard usage != nil, usage?["error"] as? String != "token_expired" else {
            NSLog("[ClaudeHop] recoverFromStoredCredentials — stored token also expired or missing")
            return usage
        }

        // Restore the fresh token into the active Claude CLI slot
        if let creds = KeychainManager.readCredentials(service: storedService) {
            let account = KeychainManager.readAccountAttribute(service: storedService) ?? email
            let activeService = KeychainManager.claudeService
            if KeychainManager.writeCredentials(service: activeService, account: account, password: creds) {
                NSLog("[ClaudeHop] recoverFromStoredCredentials — restored credentials to active slot (%@)", activeService)
            }
        }
        return usage
    }

    static func claudeUsageState(_ usage: [String: Any]?) -> UsageState {
        guard let usage else {
            return UsageState(available: false, display: "Usage unavailable")
        }
        if usage["error"] != nil {
            return UsageState(available: false, display: "Session expired")
        }

        var parts: [String] = []
        var windows: [UsageWindow] = []

        for (label, key) in [("5h", "five_hour"), ("7d", "seven_day")] {
            guard let window = usage[key] as? [String: Any],
                  let utilization = window["utilization"],
                  let percent = Double("\(utilization)") else { continue }

            let reset = (window["resets_at"] as? String).map { formatResetDelta(iso: $0) }
            let suffix = reset.map { " (\($0))" } ?? ""
            parts.append("\(label) \(Int(percent))%\(suffix)")
            windows.append(UsageWindow(label: label, percent: percent, resetsIn: reset))
        }

        if parts.isEmpty {
            return UsageState(available: false, display: "Usage unavailable")
        }
        return UsageState(available: true, display: parts.joined(separator: " | "), windows: windows)
    }

    // MARK: - Helpers

    private static func extractToken(from creds: String) -> String? {
        guard let data = creds.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    private static func formatResetDelta(iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "?" }

        let diff = Int(date.timeIntervalSinceNow)
        guard diff > 0 else { return "now" }

        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let minutes = (diff % 3600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
