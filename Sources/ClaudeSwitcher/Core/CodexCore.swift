import Foundation

private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

private let codexExtraPaths = [
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
    "/usr/local/bin/codex",
    "/opt/homebrew/bin/codex",
]

enum CodexCore {
    static let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    static let codexAuthFile = codexHome.appendingPathComponent("auth.json")
    static let codexConfigFile = codexHome.appendingPathComponent("config.toml")
    static let keychainPrefix = "codex-switcher:"
    static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let oauthTokenURL = "https://auth.openai.com/oauth/token"
    static let loginTimeout: TimeInterval = 300

    // MARK: - Binary discovery

    static func findCodex() -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let full = "\(dir)/codex"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return codexExtraPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func checkCodexCLI() -> Bool { findCodex() != nil }
    private static func codexCmd() -> String { findCodex() ?? "codex" }

    // MARK: - Credentials file

    static func readCredentialsFromFile() -> String? {
        guard let content = try? String(contentsOf: codexAuthFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        return content
    }

    static func normalizeCredentialsBlob(_ creds: String?) -> String? {
        guard let creds else { return nil }
        let raw = creds.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already valid JSON?
        if let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return raw
        }

        // Hex-encoded?
        let compact = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        if compact.count % 2 == 0,
           compact.allSatisfy({ $0.isHexDigit }),
           let bytes = Data(hexString: compact),
           let decoded = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let data = decoded.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return decoded
        }

        return raw
    }

    static func readCodexCredentials() -> String? {
        normalizeCredentialsBlob(readCredentialsFromFile())
    }

    // MARK: - JWT decode (no verification)

    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        let rem = payload.count % 4
        if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+")
                                                    .replacingOccurrences(of: "_", with: "/")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Credential parsing

    static func emailFromCredentials(_ creds: String?) -> String? {
        guard let creds, let data = creds.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let tokens = json["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let email = payload["email"] as? String { return email }

        for key in ["email", "user", "account"] {
            if let val = json[key] as? String {
                let range = NSRange(val.startIndex..., in: val)
                if emailRegex.firstMatch(in: val, range: range) != nil { return val }
            }
        }
        return nil
    }

    static func planFromCredentials(_ creds: String?) -> String {
        guard let creds, let data = creds.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "chatgpt" }

        if let tokens = json["tokens"] as? [String: Any],
           let idToken = tokens["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let authInfo = payload["https://api.openai.com/auth"] as? [String: Any],
           let plan = authInfo["chatgpt_plan_type"] as? String { return plan }

        return json["auth_mode"] as? String ?? "chatgpt"
    }

    // MARK: - OAuth token refresh

    static func refreshCredentials(_ credsJSON: String) throws -> String? {
        let normalized = normalizeCredentialsBlob(credsJSON) ?? credsJSON
        guard let data = normalized.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = json["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String else { return nil }

        var request = URLRequest(url: URL(string: oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(oauthClientID)"
        request.httpBody = body.data(using: .utf8)

        var refreshed: [String: Any]?
        var httpError: Int?
        var responseBody: String?

        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, resp, _ in
            defer { sema.signal() }
            if let resp = resp as? HTTPURLResponse {
                httpError = resp.statusCode >= 400 ? resp.statusCode : nil
                responseBody = data.flatMap { String(data: $0, encoding: .utf8) }
            }
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                refreshed = json
            }
        }.resume()
        sema.wait()

        if let code = httpError {
            let body = responseBody ?? ""
            if [400, 401].contains(code),
               body.contains("already been used") || body.contains("invalid_grant") || body.contains("token_invalidated") {
                throw CodexCredentialsExpiredError()
            }
            return nil
        }

        guard let refreshed else { return nil }
        var updated = json
        for key in ["access_token", "refresh_token", "id_token", "token_type", "expires_in", "account_id"] {
            if let val = refreshed[key] { tokens[key] = val }
        }
        updated["tokens"] = tokens
        updated["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        guard let encoded = try? JSONSerialization.data(withJSONObject: updated) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    // MARK: - Write credentials

    static func writeCodexCredentials(_ creds: String) throws {
        let normalized = normalizeCredentialsBlob(creds) ?? creds
        guard let data = normalized.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw RuntimeError("Invalid Codex credentials; refusing to write ~/.codex/auth.json.")
        }
        try? FileManager.default.createDirectory(at: codexAuthFile.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try normalized.write(to: codexAuthFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: codexAuthFile.path)
    }

    // MARK: - Auth commands

    static func runCodexLogout() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codexCmd())
        proc.arguments = ["logout"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
    }

    static func launchCodexLoginTerminal() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-switcher-codex-login-\(pid).command")
        let codexPath = codexCmd().replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/zsh
        echo "Claude Switcher - Codex login"
        echo ""
        echo "Complete the Codex login flow in this Terminal window."
        echo "When login succeeds, return to Claude Switcher."
        echo ""
        '\(codexPath)' login -c 'cli_auth_credentials_store="file"'
        status=$?
        echo ""
        if [ $status -eq 0 ]; then
          echo "Codex login completed. You can close this window."
        else
          echo "Codex login failed or was cancelled. You can close this window."
        fi
        echo ""
        read -k 1 "?Press any key to close..."
        exit $status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [scriptURL.path]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw RuntimeError("Could not open Terminal for Codex login.")
        }
    }

    static func runCodexLogin(timeout: TimeInterval = loginTimeout) -> Bool {
        try? launchCodexLoginTerminal()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let creds = readCredentialsFromFile()
            if let creds, emailFromCredentials(creds) != nil { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    // MARK: - Account management

    static func importCurrentCodexAccount(configPath: URL = ConfigManager.defaultConfigPath) -> AccountInfo? {
        guard let creds = readCodexCredentials() else { return nil }
        guard let email = emailFromCredentials(creds) else { return nil }
        guard (try? ClaudeCore.validateEmail(email)) != nil else { return nil }

        KeychainManager.writeCredentials(service: "\(keychainPrefix)\(email)", account: email, password: creds)
        let account = AccountInfo(email: email, subscriptionType: planFromCredentials(creds),
                                  orgName: "", active: true, keychainAccount: email, provider: "codex")
        ConfigManager.addAccount(account, path: configPath)
        ConfigManager.setActiveAccount(email: email, provider: "codex", path: configPath)
        return account
    }

    static func switchCodexAccount(to targetEmail: String, configPath: URL = ConfigManager.defaultConfigPath) throws {
        let active = ConfigManager.getActiveAccount(provider: "codex", path: configPath)

        if let active, let currentCreds = readCodexCredentials() {
            KeychainManager.writeCredentials(service: "\(keychainPrefix)\(active.email)",
                                             account: active.keychainAccount, password: currentCreds)
        }

        _ = try ClaudeCore.validateEmail(targetEmail)
        guard let targetCreds = KeychainManager.readCredentials(service: "\(keychainPrefix)\(targetEmail)") else {
            throw RuntimeError("Credentials not found for Codex account \(targetEmail)")
        }

        let accounts = ConfigManager.loadAccounts(path: configPath)
        guard let targetAccount = accounts.first(where: { $0.email == targetEmail && $0.provider == "codex" }) else {
            throw RuntimeError("Codex account \(targetEmail) not found in config")
        }

        var finalCreds = normalizeCredentialsBlob(targetCreds) ?? targetCreds
        do {
            if let refreshed = try refreshCredentials(finalCreds) {
                finalCreds = refreshed
                KeychainManager.writeCredentials(service: "\(keychainPrefix)\(targetEmail)",
                                                 account: targetAccount.keychainAccount, password: finalCreds)
            }
        } catch is CodexCredentialsExpiredError {
            throw RuntimeError("Saved Codex session for \(targetEmail) expired. Use Add Codex account to sign in again.")
        }

        try writeCodexCredentials(finalCreds)
        var updated = accounts
        for i in updated.indices where updated[i].provider == "codex" {
            updated[i].active = (updated[i].email == targetEmail)
        }
        ConfigManager.saveAccounts(updated, path: configPath)
    }

    static func addNewCodexAccount(configPath: URL = ConfigManager.defaultConfigPath) -> AccountInfo? {
        let currentCreds = readCodexCredentials()
        let currentEmail = emailFromCredentials(currentCreds)

        if let creds = currentCreds, let email = currentEmail {
            KeychainManager.writeCredentials(service: "\(keychainPrefix)\(email)", account: email, password: creds)
        }

        runCodexLogout()
        try? FileManager.default.removeItem(at: codexAuthFile)

        guard runCodexLogin() else {
            if let creds = currentCreds { try? writeCodexCredentials(creds) }
            return nil
        }

        if let result = importCurrentCodexAccount(configPath: configPath) {
            return result
        }
        if let creds = currentCreds { try? writeCodexCredentials(creds) }
        return nil
    }

    static func removeCodexAccount(email: String, configPath: URL = ConfigManager.defaultConfigPath) {
        KeychainManager.deleteCredentials(service: "\(keychainPrefix)\(email)")
        ConfigManager.removeAccount(email: email, provider: "codex", path: configPath)
    }
}

struct CodexCredentialsExpiredError: Error {}

// MARK: - Data hex helper

extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
