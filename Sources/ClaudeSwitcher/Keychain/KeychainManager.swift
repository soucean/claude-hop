import Foundation
import Security

enum KeychainManager {
    // Claude CLI may append a machine-specific hash: "Claude Code-credentials-{hash}"
    static let claudeServicePrefix = "Claude Code-credentials"

    // Cached after first resolution — invalidated when switch occurs
    private static var _claudeService: String?

    static var claudeService: String {
        if let cached = _claudeService { return cached }
        _claudeService = resolveClaudeService()
        return _claudeService!
    }

    static func invalidateClaudeServiceCache() {
        _claudeService = nil
    }

    private static func resolveClaudeService() -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else {
            return claudeServicePrefix
        }
        let services = items.compactMap { $0[kSecAttrService] as? String }
            .filter { $0.hasPrefix(claudeServicePrefix) }
            .sorted { $0.count > $1.count }
        return services.first ?? claudeServicePrefix
    }

    static func readCredentials(service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    @discardableResult
    static func writeCredentials(service: String, account: String, password: String) -> Bool {
        // Delete all existing entries for this service first
        while deleteCredentials(service: service) {}

        guard let data = password.data(using: .utf8) else { return false }
        let attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteCredentials(service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func readAccountAttribute(service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attrs = result as? [CFString: Any],
              let account = attrs[kSecAttrAccount] as? String else { return nil }
        return account
    }
}
