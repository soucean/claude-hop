import AppKit
import UserNotifications

private let autoSwitchCooldown: TimeInterval = 60
private let usageRefreshInterval: TimeInterval = 300

private let providerLabels = ["claude": "Claude Code", "codex": "Codex CLI"]

class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        controller = MenuBarController()
    }
}

// MARK: - MenuBarController

class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var usageCache: [String: String] = [:]
    private var usageStateCache: [String: UsageState] = [:]
    private var refreshInProgress = false
    private var switchInProgress: Set<String> = []
    private var lastAutoSwitchAttempt: [String: Date] = [:]
    private var lastFetchDate: Date?
    private let minFetchInterval: TimeInterval = 30
    private var refreshTimer: Timer?
    private let configPath = ConfigManager.defaultConfigPath

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupIcon()
        firstLaunch()
        rebuildMenu()
        fetchAllUsage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: usageRefreshInterval, repeats: true) { [weak self] _ in
            self?.fetchAllUsage()
        }
    }

    // MARK: - Icon

    private func setupIcon() {
        // Try bundle resource first, fall back to SF Symbol
        if let button = statusItem.button {
            if let img = NSImage(named: "icon") {
                img.isTemplate = true
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "ClaudeHop")
                button.image?.isTemplate = true
            }
        }
    }

    // MARK: - First launch

    private func firstLaunch() {
        guard !configPath.exists else { return }

        var importedAny = false

        if ClaudeCore.checkClaudeCLI() {
            if let imported = ClaudeCore.importCurrentAccount(configPath: configPath) {
                importedAny = true
                notify(title: "ClaudeHop", subtitle: "Claude account imported",
                       body: "\(imported.email) (\(imported.subscriptionType))")
            }
        }

        if CodexCore.checkCodexCLI() {
            if let imported = CodexCore.importCurrentCodexAccount(configPath: configPath) {
                importedAny = true
                notify(title: "ClaudeHop", subtitle: "Codex account imported",
                       body: "\(imported.email) (\(imported.subscriptionType))")
            }
        }

        if !importedAny && !ClaudeCore.checkClaudeCLI() && !CodexCore.checkCodexCLI() {
            showAlert(title: "CLI not found",
                      message: "Please install Claude Code or Codex CLI before using ClaudeHop.")
        }
    }

    // MARK: - Menu building

    private func rebuildMenu() {
        let menu = NSMenu()
        let accounts = ConfigManager.loadAccounts(path: configPath)

        let claudeAccounts = accounts.filter { $0.provider == "claude" }
        let codexAccounts = accounts.filter { $0.provider == "codex" }

        if !claudeAccounts.isEmpty {
            addProviderSection(to: menu, provider: "claude", accounts: claudeAccounts)
        }
        if !codexAccounts.isEmpty {
            if !claudeAccounts.isEmpty { menu.addItem(.separator()) }
            addProviderSection(to: menu, provider: "codex", accounts: codexAccounts)
        }

        menu.addItem(.separator())
        addAutoSwitchMenu(to: menu)
        menu.addItem(makeItem("✚  Add Claude account...", action: #selector(onAddClaude)))
        menu.addItem(makeItem("✚  Add Codex account...", action: #selector(onAddCodex)))
        menu.addItem(makeItem("↻  Refresh usage", action: #selector(onRefreshUsage)))

        if !accounts.isEmpty {
            let removeMenu = NSMenuItem(title: "−  Remove account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for account in accounts {
                let label = account.provider == "claude" ? "Claude" : "Codex"
                let item = NSMenuItem(title: "[\(label)] \(account.email)", action: #selector(onRemoveAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account
                sub.addItem(item)
            }
            removeMenu.submenu = sub
            menu.addItem(removeMenu)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("⏻  Quit", action: #selector(onQuit)))

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        fetchAllUsage()
    }

    private func addProviderSection(to menu: NSMenu, provider: String, accounts: [AccountInfo]) {
        let label = providerLabels[provider] ?? provider
        let header = NSMenuItem(title: "── \(label) ──", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for account in accounts {
            let hasCreds = hasCredentials(account)
            let prefix = account.active ? "◉  " : "○  "
            let cacheKey = "\(account.provider):\(account.email)"

            if hasCreds {
                let title = "\(prefix)\(account.email) (\(account.subscriptionType))"
                let sel = provider == "claude" ? #selector(onClaudeAccountClick(_:)) : #selector(onCodexAccountClick(_:))
                let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                item.target = self
                item.representedObject = account
                menu.addItem(item)

                let usageText = usageCache[cacheKey] ?? "•••"
                let usageItem = NSMenuItem(title: "       │  \(usageText)", action: nil, keyEquivalent: "")
                usageItem.isEnabled = false
                menu.addItem(usageItem)
            } else {
                let item = NSMenuItem(title: "\(prefix)\(account.email) (unavailable)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
    }

    private func addAutoSwitchMenu(to menu: NSMenu) {
        let settings = ConfigManager.loadSettings(path: configPath)
        let autoItem = NSMenuItem(title: "Auto-switch", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for provider in ["claude", "codex"] {
            let label = providerLabels[provider] ?? provider
            let item = NSMenuItem(title: label, action: #selector(onToggleAutoSwitch(_:)), keyEquivalent: "")
            item.target = self
            item.state = settings.autoSwitch[provider] == true ? .on : .off
            item.representedObject = provider
            sub.addItem(item)
        }
        autoItem.submenu = sub
        menu.addItem(autoItem)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Credentials check

    private func hasCredentials(_ account: AccountInfo) -> Bool {
        let service = account.provider == "claude"
            ? "claude-switcher:\(account.email)"
            : "codex-switcher:\(account.email)"
        return KeychainManager.readCredentials(service: service) != nil
    }

    // MARK: - Account actions

    @objc private func onClaudeAccountClick(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? AccountInfo else { return }
        switchAccount(provider: "claude", email: account.email)
    }

    @objc private func onCodexAccountClick(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? AccountInfo else { return }
        switchAccount(provider: "codex", email: account.email)
    }

    private func switchAccount(provider: String, email: String) {
        let active = ConfigManager.getActiveAccount(provider: provider, path: configPath)
        guard active?.email != email else { return }
        guard !switchInProgress.contains(provider) else {
            notify(title: "ClaudeHop",
                   subtitle: "\(providerLabels[provider] ?? provider) switch already running",
                   body: "Wait for the current switch to finish.")
            return
        }

        switchInProgress.insert(provider)

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var errorMessage: String?
            do {
                if provider == "claude" {
                    try ClaudeCore.switchAccount(to: email, configPath: self.configPath)
                } else {
                    try CodexCore.switchCodexAccount(to: email, configPath: self.configPath)
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.switchInProgress.remove(provider)
                if let msg = errorMessage {
                    self.showAlert(title: "Error", message: msg)
                } else {
                    self.notify(title: "ClaudeHop",
                                subtitle: "\(providerLabels[provider] ?? provider) account switched",
                                body: email)
                }
                self.rebuildMenu()
                self.fetchAllUsage(force: true)
            }
        }
    }

    @objc private func onAddClaude(_ sender: Any) {
        guard ClaudeCore.checkClaudeCLI() else {
            showAlert(title: "Claude CLI not found",
                      message: "Please install Claude Code before adding an account.")
            return
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let result = ClaudeCore.addNewAccount(configPath: self.configPath)
            DispatchQueue.main.async {
                if let r = result {
                    self.notify(title: "ClaudeHop", subtitle: "Claude account added",
                                body: "\(r.email) (\(r.subscriptionType))")
                } else {
                    self.notify(title: "ClaudeHop", subtitle: "Cancelled",
                                body: "Login was cancelled or failed.")
                }
                self.rebuildMenu()
                self.fetchAllUsage(force: true)
            }
        }
    }

    @objc private func onAddCodex(_ sender: Any) {
        guard CodexCore.checkCodexCLI() else {
            showAlert(title: "Codex CLI not found",
                      message: "Please install Codex CLI before adding an account.")
            return
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let result = CodexCore.addNewCodexAccount(configPath: self.configPath)
            DispatchQueue.main.async {
                if let r = result {
                    self.notify(title: "ClaudeHop", subtitle: "Codex account added",
                                body: "\(r.email) (\(r.subscriptionType))")
                } else {
                    self.notify(title: "ClaudeHop", subtitle: "Cancelled",
                                body: "Login was cancelled or failed.")
                }
                self.rebuildMenu()
                self.fetchAllUsage(force: true)
            }
        }
    }

    @objc private func onToggleAutoSwitch(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        let settings = ConfigManager.loadSettings(path: configPath)
        let enabled = !(settings.autoSwitch[provider] ?? false)
        ConfigManager.setAutoSwitchEnabled(enabled, provider: provider, path: configPath)
        rebuildMenu()
        notify(title: "ClaudeHop",
               subtitle: "Auto-switch \(providerLabels[provider] ?? provider)",
               body: enabled ? "Enabled" : "Disabled")
    }

    @objc private func onRemoveAccount(_ sender: NSMenuItem) {
        guard let account = sender.representedObject as? AccountInfo else { return }
        let active = ConfigManager.getActiveAccount(provider: account.provider, path: configPath)
        if active?.email == account.email {
            showAlert(title: "Cannot remove",
                      message: "You cannot remove the active \(providerLabels[account.provider] ?? account.provider) account. Switch first.")
            return
        }
        if account.provider == "claude" {
            ClaudeCore.removeSavedAccount(email: account.email, configPath: configPath)
        } else {
            CodexCore.removeCodexAccount(email: account.email, configPath: configPath)
        }
        notify(title: "ClaudeHop",
               subtitle: "\(providerLabels[account.provider] ?? account.provider) account removed",
               body: account.email)
        rebuildMenu()
        fetchAllUsage(force: true)
    }

    @objc private func onRefreshUsage(_ sender: Any) { fetchAllUsage(force: true) }

    @objc private func onQuit(_ sender: Any) { NSApplication.shared.terminate(nil) }

    // MARK: - Usage fetching

    private func fetchAllUsage(force: Bool = false) {
        let now = Date()
        if !force, let last = lastFetchDate, now.timeIntervalSince(last) < minFetchInterval { return }
        guard !refreshInProgress else { return }
        refreshInProgress = true
        lastFetchDate = now

        // Show loading state in-place (no menu rebuild needed)
        let accounts = ConfigManager.loadAccounts(path: configPath)
        for account in accounts {
            usageCache["\(account.provider):\(account.email)"] = "Loading..."
        }
        updateUsageLabels()
        let activeByProvider: [String: AccountInfo?] = [
            "claude": ConfigManager.getActiveAccount(provider: "claude", path: configPath),
            "codex": ConfigManager.getActiveAccount(provider: "codex", path: configPath),
        ]
        let settings = ConfigManager.loadSettings(path: configPath)

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            for account in accounts {
                let key = "\(account.provider):\(account.email)"
                let isActive = activeByProvider[account.provider]??.email == account.email
                let state = self.fetchUsageState(account: account, isActive: isActive)
                self.usageStateCache[key] = state
                self.usageCache[key] = state.display
            }

            var autoSwitchResults: [(String, String)] = []
            for provider in ["claude", "codex"] {
                if let result = self.attemptAutoSwitch(provider: provider, settings: settings) {
                    autoSwitchResults.append(result)
                }
            }

            DispatchQueue.main.async {
                self.refreshInProgress = false
                let switched = autoSwitchResults.contains { $0.0 == "switched" }
                if switched { self.rebuildMenu() }
                self.updateUsageLabels()
                if switched { self.fetchAllUsage(force: true) }
            }
        }
    }

    private func fetchUsageState(account: AccountInfo, isActive: Bool) -> UsageState {
        if account.provider == "claude" {
            let usage = isActive
                ? ClaudeUsage.fetchActiveUsageWithRefresh(activeEmail: account.email)
                : ClaudeUsage.fetchUsageForAccount(email: account.email)
            return ClaudeUsage.claudeUsageState(usage)
        } else {
            let usage = isActive ? CodexUsage.fetchActiveCodexUsage() : CodexUsage.fetchCodexUsageForAccount(email: account.email)
            return CodexUsage.codexUsageState(usage)
        }
    }

    private func attemptAutoSwitch(provider: String, settings: AppSettings) -> (String, String)? {
        guard let active = ConfigManager.getActiveAccount(provider: provider, path: configPath) else { return nil }
        let key = "\(provider):\(active.email)"
        guard let state = usageStateCache[key],
              AutoSwitch.shouldAutoSwitch(activeUsage: state,
                                          enabled: settings.autoSwitch[provider] ?? false,
                                          threshold: settings.autoSwitchThreshold) else { return nil }

        let now = Date()
        if let last = lastAutoSwitchAttempt[provider], now.timeIntervalSince(last) < autoSwitchCooldown { return nil }
        lastAutoSwitchAttempt[provider] = now

        let accounts = ConfigManager.loadAccounts(path: configPath)
        guard let target = AutoSwitch.chooseTarget(
            provider: provider, accounts: accounts, activeEmail: active.email,
            usageByAccount: usageStateCache, hasCredentials: hasCredentials,
            threshold: settings.autoSwitchThreshold
        ) else { return ("no_target", active.email) }

        do {
            if provider == "claude" {
                try ClaudeCore.switchAccount(to: target.email, configPath: configPath)
            } else {
                try CodexCore.switchCodexAccount(to: target.email, configPath: configPath)
            }
        } catch {
            return ("error", error.localizedDescription)
        }

        let label = providerLabels[provider] ?? provider
        DispatchQueue.main.async {
            self.notify(title: "ClaudeHop", subtitle: "Auto-switched \(label)", body: target.email)
        }
        return ("switched", target.email)
    }

    // Update usage text in-place so the menu reflects new data even while it's open.
    private func updateUsageLabels() {
        guard let menu = statusItem.menu else { return }
        let items = menu.items
        for (i, item) in items.enumerated() {
            guard let account = item.representedObject as? AccountInfo else { continue }
            let key = "\(account.provider):\(account.email)"
            let text = usageCache[key] ?? "•••"
            let nextIdx = i + 1
            if nextIdx < items.count {
                items[nextIdx].title = "       │  \(text)"
            }
        }
    }

    // MARK: - Notifications & alerts

    private func notify(title: String, subtitle: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[Notification] \(subtitle): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
    }
}

// MARK: - URL extension

private extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
