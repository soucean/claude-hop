import Foundation

private let emailRegex = try! NSRegularExpression(pattern: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#)

private let extraPaths = [
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
]

enum ClaudeCore {
    static let claudeStateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    // MARK: - Subprocess helper

    @discardableResult
    static func runProcess(_ args: [String], interactive: Bool = false) -> (output: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())

        if interactive {
            proc.standardInput = FileHandle.standardInput
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError = FileHandle.standardError
        } else {
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try? proc.run()
            proc.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (out.trimmingCharacters(in: .whitespacesAndNewlines), proc.terminationStatus)
        }

        try? proc.run()
        proc.waitUntilExit()
        return ("", proc.terminationStatus)
    }

    // MARK: - Binary discovery

    static func findClaude() -> String? {
        if let found = findInPATH("claude") { return found }
        return extraPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func checkClaudeCLI() -> Bool { findClaude() != nil }

    private static func claudeCmd() -> String { findClaude() ?? "claude" }

    private static func findInPATH(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in paths {
            let full = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    // MARK: - Validation

    static func validateEmail(_ email: String) throws -> String {
        let range = NSRange(email.startIndex..., in: email)
        guard emailRegex.firstMatch(in: email, range: range) != nil, email.count <= 254 else {
            throw RuntimeError("Invalid email format: \(email)")
        }
        return email
    }

    // MARK: - Auth commands

    static func getAuthStatus() -> [String: Any]? {
        let (out, code) = runProcess([claudeCmd(), "auth", "status", "--json"])
        guard code == 0, !out.isEmpty,
              let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    static func runAuthLogout() {
        runProcess([claudeCmd(), "auth", "logout"])
    }

    static func runAuthLogin() -> Bool {
        runProcess([claudeCmd(), "auth", "login"], interactive: true).exitCode == 0
    }

    // MARK: - ~/.claude.json

    static func readOauthAccount() -> [String: AnyCodable]? {
        guard let data = try? Data(contentsOf: claudeStateFile),
              let json = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let oauth = json["oauthAccount"] else { return nil }
        if case let dict as [String: AnyCodable] = oauth.value { return dict }
        return nil
    }

    static func writeOauthAccount(_ oauthAccount: [String: AnyCodable]) {
        guard let data = try? Data(contentsOf: claudeStateFile),
              var json = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else { return }
        json["oauthAccount"] = AnyCodable(oauthAccount)
        guard let encoded = try? JSONEncoder().encode(json) else { return }
        try? encoded.write(to: claudeStateFile)
    }

    // MARK: - Account management

    static func importCurrentAccount(configPath: URL = ConfigManager.defaultConfigPath) -> AccountInfo? {
        var creds: String?
        for _ in 0..<5 {
            creds = KeychainManager.readCredentials(service: KeychainManager.claudeService)
            if creds != nil { break }
            Thread.sleep(forTimeInterval: 1)
        }
        guard let creds else { return nil }

        let acctAttr = KeychainManager.readAccountAttribute(service: KeychainManager.claudeService) ?? "unknown"
        let status = getAuthStatus()
        let email: String
        let subType: String
        let orgName: String

        if let s = status, let e = s["email"] as? String {
            email = e
            subType = s["subscriptionType"] as? String ?? "unknown"
            orgName = s["orgName"] as? String ?? ""
        } else {
            guard let data = creds.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let e = json["email"] as? String else { return nil }
            email = e
            subType = "unknown"
            orgName = ""
        }

        guard (try? validateEmail(email)) != nil else { return nil }
        KeychainManager.writeCredentials(service: "claude-switcher:\(email)", account: acctAttr, password: creds)

        let oauth = readOauthAccount()
        let account = AccountInfo(email: email, subscriptionType: subType, orgName: orgName,
                                  active: true, keychainAccount: acctAttr,
                                  oauthAccount: oauth, provider: "claude")
        ConfigManager.addAccount(account, path: configPath)
        ConfigManager.setActiveAccount(email: email, provider: "claude", path: configPath)
        return account
    }

    static func switchAccount(to targetEmail: String, configPath: URL = ConfigManager.defaultConfigPath) throws {
        let active = ConfigManager.getActiveAccount(provider: "claude", path: configPath)

        if let active {
            if let currentCreds = KeychainManager.readCredentials(service: KeychainManager.claudeService) {
                KeychainManager.writeCredentials(service: "claude-switcher:\(active.email)",
                                                 account: active.keychainAccount, password: currentCreds)
            }
            if var active = ConfigManager.getActiveAccount(provider: "claude", path: configPath),
               let oauth = readOauthAccount() {
                active.oauthAccount = oauth
                ConfigManager.addAccount(active, path: configPath)
            }
        }

        _ = try validateEmail(targetEmail)
        guard let targetCreds = KeychainManager.readCredentials(service: "claude-switcher:\(targetEmail)") else {
            throw RuntimeError("Credentials not found in Keychain for \(targetEmail)")
        }

        let accounts = ConfigManager.loadAccounts(path: configPath)
        guard let targetAccount = accounts.first(where: { $0.email == targetEmail && $0.provider == "claude" }) else {
            throw RuntimeError("Account \(targetEmail) not found in config")
        }

        KeychainManager.writeCredentials(service: KeychainManager.claudeService,
                                         account: targetAccount.keychainAccount, password: targetCreds)
        if let oauth = targetAccount.oauthAccount {
            writeOauthAccount(oauth)
        }
        ConfigManager.setActiveAccount(email: targetEmail, provider: "claude", path: configPath)
    }

    static func addNewAccount(configPath: URL = ConfigManager.defaultConfigPath) -> AccountInfo? {
        let active = ConfigManager.getActiveAccount(provider: "claude", path: configPath)
        if let active,
           let creds = KeychainManager.readCredentials(service: KeychainManager.claudeService) {
            KeychainManager.writeCredentials(service: "claude-switcher:\(active.email)",
                                             account: active.keychainAccount, password: creds)
        }

        runAuthLogout()
        while KeychainManager.deleteCredentials(service: KeychainManager.claudeService) {}

        guard runAuthLogin() else {
            if let active,
               let prev = KeychainManager.readCredentials(service: "claude-switcher:\(active.email)") {
                KeychainManager.writeCredentials(service: KeychainManager.claudeService,
                                                 account: active.keychainAccount, password: prev)
            }
            return nil
        }

        if let result = importCurrentAccount(configPath: configPath) {
            return result
        }

        if let active,
           let prev = KeychainManager.readCredentials(service: "claude-switcher:\(active.email)") {
            KeychainManager.writeCredentials(service: KeychainManager.claudeService,
                                             account: active.keychainAccount, password: prev)
        }
        return nil
    }

    static func removeSavedAccount(email: String, configPath: URL = ConfigManager.defaultConfigPath) {
        KeychainManager.deleteCredentials(service: "claude-switcher:\(email)")
        ConfigManager.removeAccount(email: email, provider: "claude", path: configPath)
    }
}

struct RuntimeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
