import Foundation

enum KeychainManager {
    static let claudeServicePrefix = "Claude Code-credentials"
    private static var _claudeService: String?

    static var claudeService: String {
        if let cached = _claudeService { return cached }
        _claudeService = resolveClaudeService()
        return _claudeService!
    }

    static func invalidateClaudeServiceCache() { _claudeService = nil }

    // Try service names without reading secrets — plain lookup first, dump only as last resort.
    private static func resolveClaudeService() -> String {
        // Fast path: plain name (used after fresh login)
        let (_, plainCode) = run("/usr/bin/security", [
            "find-generic-password", "-s", claudeServicePrefix
        ])
        if plainCode == 0 {
            NSLog("[ClaudeHop] resolveClaudeService — found plain: %@", claudeServicePrefix)
            return claudeServicePrefix
        }

        // Slow path: dump metadata only (no passwords) to discover hashed variant
        // Only reaches here if plain service name doesn't exist
        let (output, _) = run("/usr/bin/security", ["dump-keychain"])
        var found: [String] = []
        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"svce\""), line.contains(claudeServicePrefix) else { continue }
            if let eqRange = line.range(of: "=\""), line.hasSuffix("\"") {
                let name = String(line[eqRange.upperBound..<line.index(before: line.endIndex)])
                if name.hasPrefix(claudeServicePrefix) { found.append(name) }
            }
        }
        let chosen = found.sorted { $0.count > $1.count }.first ?? claudeServicePrefix
        NSLog("[ClaudeHop] resolveClaudeService — found via dump: %@", chosen)
        return chosen
    }

    static func readCredentials(service: String) -> String? {
        let (output, code) = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard code == 0, !output.isEmpty else { return nil }
        return output
    }

    @discardableResult
    static func writeCredentials(service: String, account: String, password: String) -> Bool {
        while deleteCredentials(service: service) {}
        let (_, code) = run("/usr/bin/security", [
            "add-generic-password", "-s", service, "-a", account, "-w", password,
        ])
        return code == 0
    }

    @discardableResult
    static func deleteCredentials(service: String) -> Bool {
        let (_, code) = run("/usr/bin/security", ["delete-generic-password", "-s", service])
        return code == 0
    }

    static func readAccountAttribute(service: String) -> String? {
        let (output, code) = run("/usr/bin/security", ["find-generic-password", "-s", service])
        guard code == 0 else { return nil }
        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"acct\"") else { continue }
            // Line format:  "acct"<blob>="user@example.com"
            if let eqRange = line.range(of: "=\""), line.hasSuffix("\"") {
                return String(line[eqRange.upperBound..<line.index(before: line.endIndex)])
            }
        }
        return nil
    }

    // MARK: - Internal subprocess helper

    private static func run(_ path: String, _ args: [String]) -> (String, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, proc.terminationStatus)
    }
}
