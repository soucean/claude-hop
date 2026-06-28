import Foundation

enum AutoSwitch {
    static func shouldAutoSwitch(activeUsage: UsageState, enabled: Bool, threshold: Double) -> Bool {
        enabled && activeUsage.available && activeUsage.isExhausted(threshold: threshold)
    }

    static func chooseTarget(
        provider: String,
        accounts: [AccountInfo],
        activeEmail: String,
        usageByAccount: [String: UsageState],
        hasCredentials: (AccountInfo) -> Bool,
        threshold: Double = 100.0
    ) -> AccountInfo? {
        let candidates = accounts.filter {
            $0.provider == provider && $0.email != activeEmail && hasCredentials($0)
        }

        var knownAvailable: [AccountInfo] = []
        var unknownUsage: [AccountInfo] = []

        for account in candidates {
            let key = "\(account.provider):\(account.email)"
            if let state = usageByAccount[key], state.available {
                if !state.isExhausted(threshold: threshold) {
                    knownAvailable.append(account)
                }
            } else {
                unknownUsage.append(account)
            }
        }

        return knownAvailable.first ?? unknownUsage.first
    }
}
