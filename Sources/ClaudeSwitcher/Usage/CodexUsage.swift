import Foundation

enum CodexUsage {
    static let usageURLs = [
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/backend-api/api/codex/usage",
    ]

    static func fetchCodexUsageOnce(creds: String) -> [String: Any]? {
        guard let (token, accountID) = extractToken(from: creds) else { return nil }

        for urlString in usageURLs {
            var request = URLRequest(url: URL(string: urlString)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("claude-switcher/0.4.3", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            var result: [String: Any]?
            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, resp, _ in
                defer { sema.signal() }
                if let resp = resp as? HTTPURLResponse, resp.statusCode >= 400 { return }
                if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result = json
                }
            }.resume()
            sema.wait()
            if let result { return result }
        }
        return nil
    }

    static func fetchCodexUsageWithRefresh(creds: String) -> (usage: [String: Any]?, refreshed: String?) {
        let normalized = CodexCore.normalizeCredentialsBlob(creds) ?? creds
        if let usage = fetchCodexUsageOnce(creds: normalized) {
            return (usage, nil)
        }

        do {
            guard let refreshed = try CodexCore.refreshCredentials(normalized) else { return (nil, nil) }
            return (fetchCodexUsageOnce(creds: refreshed), refreshed)
        } catch is CodexCredentialsExpiredError {
            return (["error": ["code": "login_required"]], nil)
        } catch {
            return (nil, nil)
        }
    }

    static func fetchCodexUsageForAccount(email: String) -> [String: Any]? {
        let service = "codex-switcher:\(email)"
        guard let creds = KeychainManager.readCredentials(service: service) else { return nil }
        let (usage, refreshed) = fetchCodexUsageWithRefresh(creds: creds)
        if let refreshed {
            KeychainManager.writeCredentials(service: service, account: email, password: refreshed)
        }
        return usage
    }

    static func fetchActiveCodexUsage() -> [String: Any]? {
        guard let creds = CodexCore.readCodexCredentials() else { return nil }
        let (usage, refreshed) = fetchCodexUsageWithRefresh(creds: creds)
        if let refreshed {
            try? CodexCore.writeCodexCredentials(refreshed)
            _ = CodexCore.backupCredentials(refreshed)
        }
        return usage
    }

    static func codexUsageState(_ usage: [String: Any]?) -> UsageState {
        guard let usage else {
            return UsageState(available: false, display: "Usage unavailable")
        }
        if let error = usage["error"] as? [String: Any],
           (error["code"] as? String) == "login_required" {
            return UsageState(available: false, display: "Login required")
        }
        guard let rateLimit = usage["rate_limit"] as? [String: Any] else {
            return UsageState(available: false, display: "Usage unavailable")
        }

        var parts: [String] = []
        var windows: [UsageWindow] = []

        for (label, key) in [("1h", "primary_window"), ("7d", "secondary_window")] {
            guard let window = rateLimit[key] as? [String: Any],
                  let rawPercent = window["used_percent"],
                  let percent = Double("\(rawPercent)") else { continue }

            let reset = (window["reset_at"] as? Double).map { formatResetDelta(timestamp: $0) }
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

    private static func extractToken(from creds: String) -> (token: String, accountID: String)? {
        let normalized = CodexCore.normalizeCredentialsBlob(creds) ?? creds
        guard let data = normalized.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let token = tokens["access_token"] as? String ?? json["access_token"] as? String
        var accountID = tokens["account_id"] as? String ?? json["account_id"] as? String

        if accountID == nil, let idToken = tokens["id_token"] as? String,
           let payload = CodexCore.decodeJWTPayload(idToken),
           let authInfo = payload["https://api.openai.com/auth"] as? [String: Any] {
            accountID = authInfo["chatgpt_account_id"] as? String
        }

        guard let t = token, let a = accountID else { return nil }
        return (t, a)
    }

    private static func formatResetDelta(timestamp: Double) -> String {
        let diff = Int(timestamp - Date().timeIntervalSince1970)
        guard diff > 0 else { return "now" }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let minutes = (diff % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

extension CodexCore {
    static func backupCredentials(_ creds: String) -> String? {
        let normalized = normalizeCredentialsBlob(creds) ?? ""
        guard let email = emailFromCredentials(normalized) else { return nil }
        guard (try? ClaudeCore.validateEmail(email)) != nil else { return nil }
        KeychainManager.writeCredentials(service: "\(keychainPrefix)\(email)", account: email, password: normalized)
        return email
    }
}
