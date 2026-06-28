import Foundation

private let configVersion = 2

enum ConfigManager {
    static let defaultConfigPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-switcher/accounts.json")
    }()

    // MARK: - Read / Write

    private static func readData(path: URL = defaultConfigPath) -> ConfigFile {
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return ConfigFile()
        }
        return file
    }

    private static func writeData(_ file: ConfigFile, path: URL = defaultConfigPath) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    // MARK: - Public API

    static func loadAccounts(path: URL = defaultConfigPath) -> [AccountInfo] {
        readData(path: path).accounts
    }

    static func saveAccounts(_ accounts: [AccountInfo], path: URL = defaultConfigPath) {
        var file = readData(path: path)
        file.accounts = accounts
        writeData(file, path: path)
    }

    static func addAccount(_ account: AccountInfo, path: URL = defaultConfigPath) {
        var accounts = loadAccounts(path: path)
        accounts.removeAll { $0.email == account.email && $0.provider == account.provider }
        accounts.append(account)
        saveAccounts(accounts, path: path)
    }

    static func removeAccount(email: String, provider: String = "claude", path: URL = defaultConfigPath) {
        var accounts = loadAccounts(path: path)
        accounts.removeAll { $0.email == email && $0.provider == provider }
        saveAccounts(accounts, path: path)
    }

    static func getActiveAccount(provider: String = "claude", path: URL = defaultConfigPath) -> AccountInfo? {
        loadAccounts(path: path).first { $0.active && $0.provider == provider }
    }

    static func setActiveAccount(email: String, provider: String = "claude", path: URL = defaultConfigPath) {
        var accounts = loadAccounts(path: path)
        for i in accounts.indices where accounts[i].provider == provider {
            accounts[i].active = (accounts[i].email == email)
        }
        saveAccounts(accounts, path: path)
    }

    static func loadSettings(path: URL = defaultConfigPath) -> AppSettings {
        readData(path: path).settings
    }

    static func saveSettings(_ settings: AppSettings, path: URL = defaultConfigPath) {
        var file = readData(path: path)
        file.settings = settings
        writeData(file, path: path)
    }

    static func setAutoSwitchEnabled(_ enabled: Bool, provider: String, path: URL = defaultConfigPath) {
        var settings = loadSettings(path: path)
        settings.autoSwitch[provider] = enabled
        saveSettings(settings, path: path)
    }
}

// MARK: - Internal file shape

private struct ConfigFile: Codable {
    var version: Int = configVersion
    var settings: AppSettings = AppSettings()
    var accounts: [AccountInfo] = []
}
