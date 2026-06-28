import Foundation

struct AccountInfo: Codable, Equatable {
    var email: String
    var subscriptionType: String
    var orgName: String
    var active: Bool
    var keychainAccount: String
    var oauthAccount: [String: AnyCodable]?
    var provider: String

    enum CodingKeys: String, CodingKey {
        case email
        case subscriptionType = "subscription_type"
        case orgName = "org_name"
        case active
        case keychainAccount = "keychain_account"
        case oauthAccount = "oauth_account"
        case provider
    }
}

struct AppSettings: Codable {
    var autoSwitch: [String: Bool]
    var autoSwitchThreshold: Double

    enum CodingKeys: String, CodingKey {
        case autoSwitch = "auto_switch"
        case autoSwitchThreshold = "auto_switch_threshold"
    }

    init(autoSwitch: [String: Bool] = ["claude": false, "codex": false],
         autoSwitchThreshold: Double = 100.0) {
        self.autoSwitch = autoSwitch
        self.autoSwitchThreshold = autoSwitchThreshold
    }
}

// Wrapper to encode/decode arbitrary JSON values
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [String: AnyCodable]: try container.encode(v)
        case let v as [AnyCodable]: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simple equality — good enough for oauth_account comparison
        let lData = try? JSONEncoder().encode(lhs)
        let rData = try? JSONEncoder().encode(rhs)
        return lData == rData
    }
}

extension AccountInfo {
    var accountKey: AccountKey { (provider, email) }
}

typealias AccountKey = (provider: String, email: String)
