//
//  CodexAuthService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-04-01.
//

import Foundation

/// Service for detecting and reading Codex CLI authentication state.
/// Reads from ~/.codex/auth.json to determine if the user has Codex configured.
@MainActor
class CodexAuthService {
    static let shared = CodexAuthService()

    private let authFileOverride: URL?

    /// In-flight token refresh so concurrent fetches never reuse a rotated refresh token.
    fileprivate var inflightRefresh: Task<(accessToken: String, accountId: String?), Error>?

    /// Refresh token already spent by us, with the tokens it produced. If writing them
    /// back to auth.json failed, the file still holds the spent token; refreshing with
    /// it again would count as reuse and make OpenAI revoke the whole token family.
    fileprivate var spentRefreshToken: String?
    fileprivate var refreshedInMemory: (accessToken: String, accountId: String?)?

    init(authFileURL: URL? = nil) { self.authFileOverride = authFileURL }

    /// Path to the Codex auth file
    var authFilePath: URL {
        if let authFileOverride { return authFileOverride }
        let home = Constants.ClaudePaths.homeDirectory
        return home.appendingPathComponent(".codex").appendingPathComponent("auth.json")
    }

    /// Whether a Codex auth file exists on disk
    var hasLocalAuth: Bool {
        FileManager.default.fileExists(atPath: authFilePath.path)
    }

    /// Reads and parses the Codex auth.json file
    func readAuthState() -> CodexAuthState? {
        guard hasLocalAuth else { return nil }
        do {
            let data = try Data(contentsOf: authFilePath)
            let state = try JSONDecoder().decode(CodexAuthState.self, from: data)
            return state
        } catch {
            LoggingService.shared.logError("CodexAuthService: Failed to read auth.json: \(error.localizedDescription)")
            return nil
        }
    }

    /// Validates that the stored auth state is usable
    func validateAuth() -> CodexAuthValidation {
        guard let state = readAuthState() else {
            return CodexAuthValidation(isValid: false, statusText: "Not configured", accountEmail: nil)
        }

        let resolvedAccessToken = state.resolvedAccessToken
        let hasToken = resolvedAccessToken != nil && !(resolvedAccessToken?.isEmpty ?? true)
        let isExpired: Bool
        if let expiry = state.resolvedExpiresAt {
            isExpired = expiry < Date()
        } else {
            isExpired = false
        }

        if hasToken && !isExpired {
            return CodexAuthValidation(
                isValid: true,
                statusText: "Connected",
                accountEmail: state.resolvedAccountLabel
            )
        } else if hasToken && isExpired {
            return CodexAuthValidation(
                isValid: false,
                statusText: "Token expired",
                accountEmail: state.resolvedAccountLabel
            )
        } else {
            return CodexAuthValidation(
                isValid: false,
                statusText: "Missing token",
                accountEmail: nil
            )
        }
    }
}

// MARK: - Token Refresh
// Ported from upstream v3.3.0 (52bc240), which mirrors the Codex CLI / CodexBar
// discipline: refresh when last_refresh is older than 8 days or after a 401, rotate
// the refresh token exactly once (OpenAI revokes the family on reuse), and write the
// result back to auth.json atomically so the Codex CLI keeps working.

extension CodexAuthService {
    private static let tokenRefreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// The Codex CLI's own public OAuth client id.
    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let refreshAge: TimeInterval = 8 * 24 * 60 * 60

    /// Returns a usable access token and account id, refreshing (with auth.json
    /// write-back) when stale or when `force` is set after a 401.
    func freshCredentials(force: Bool = false) async throws -> (accessToken: String, accountId: String?) {
        guard let root = readAuthJSON() else {
            throw AppError(code: .apiUnauthorized, message: "Codex authentication is unavailable or expired.")
        }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let accessToken = Self.string(tokens, "access_token", "accessToken")
            ?? Self.string(root, "access_token", "accessToken")
            ?? (root["OPENAI_API_KEY"] as? String)
        let refreshToken = Self.string(tokens, "refresh_token", "refreshToken")
            ?? Self.string(root, "refresh_token", "refreshToken")
        let accountId = Self.string(tokens, "account_id", "accountId") ?? (root["account_id"] as? String)

        // Our earlier refresh never reached disk: keep using its result, never re-spend.
        if let refreshToken, refreshToken == spentRefreshToken, let refreshedInMemory {
            return refreshedInMemory
        }

        let lastRefresh = Self.parseDate(root["last_refresh"])
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > Self.refreshAge } ?? true
        // A forced retry soon after a refresh cannot help (the 401 is not about token
        // age); capping forced refreshes to one per hour avoids rotating on every poll.
        let justRefreshed = lastRefresh.map { Date().timeIntervalSince($0) < 60 * 60 } ?? false
        guard let refreshToken, (force && !justRefreshed) || (!force && stale) else {
            guard let accessToken, !accessToken.isEmpty else {
                throw AppError(code: .apiUnauthorized, message: "Codex authentication is unavailable or expired.")
            }
            return (accessToken, accountId)
        }

        if let running = inflightRefresh { return try await running.value }
        let task = Task<(accessToken: String, accountId: String?), Error> { @MainActor in
            defer { self.inflightRefresh = nil }
            let refreshed = try await self.performRefresh(refreshToken: refreshToken)
            var updatedTokens = tokens
            updatedTokens["access_token"] = refreshed["access_token"] as? String ?? accessToken
            updatedTokens["refresh_token"] = refreshed["refresh_token"] as? String ?? refreshToken
            if let idToken = refreshed["id_token"] as? String { updatedTokens["id_token"] = idToken }
            let result = (accessToken: updatedTokens["access_token"] as? String ?? "", accountId: accountId)
            self.spentRefreshToken = refreshToken
            self.refreshedInMemory = result
            var updatedRoot = root
            updatedRoot["tokens"] = updatedTokens
            updatedRoot["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            do {
                try self.writeAuthJSON(updatedRoot)
            } catch {
                LoggingService.shared.logError("CodexAuthService: refreshed tokens but auth.json write-back failed; using them in memory", error: error)
            }
            LoggingService.shared.log("✓ CodexAuthService: refreshed Codex tokens")
            return result
        }
        inflightRefresh = task
        do {
            return try await task.value
        } catch where !force {
            // Proactive (8-day) refresh failed, e.g. offline right after wake: the
            // current access token usually still works, so keep using it.
            guard let accessToken, !accessToken.isEmpty else { throw error }
            LoggingService.shared.logError("CodexAuthService: proactive refresh failed; using current token", error: error)
            return (accessToken, accountId)
        }
    }

    private func readAuthJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: authFilePath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Atomic write-back preserving unknown keys: stage a 0600 temp file, then rename.
    private func writeAuthJSON(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let url = authFilePath
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".auth.json.claude-usage-staged-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staged.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staged)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private func performRefresh(refreshToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: Self.tokenRefreshURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppError(code: .apiUnauthorized, message: "Codex login expired. Run `codex login` to reconnect.",
                           technicalDetails: "Token refresh returned HTTP \(status)")
        }
        return json
    }

    private static func string(_ dict: [String: Any], _ snake: String, _ camel: String) -> String? {
        for key in [snake, camel] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Codex Auth Models

/// Represents the parsed contents of ~/.codex/auth.json
struct CodexAuthState: Codable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
    let email: String?
    let accountId: String?
    let tokens: NestedCodexTokens?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case email
        case accountId = "account_id"
        case tokens
    }

    var resolvedAccessToken: String? {
        accessToken ?? tokens?.accessToken
    }

    var resolvedRefreshToken: String? {
        refreshToken ?? tokens?.refreshToken
    }

    var resolvedExpiresAt: Date? {
        expiresAt ?? tokens?.expiresAt
    }

    var resolvedAccountLabel: String? {
        if let email, !email.isEmpty {
            return email
        }

        if let nestedAccountId = tokens?.accountId, !nestedAccountId.isEmpty {
            return Self.maskedIdentifier(nestedAccountId)
        }

        if let accountId, !accountId.isEmpty {
            return Self.maskedIdentifier(accountId)
        }

        return nil
    }

    private static func maskedIdentifier(_ value: String) -> String {
        guard value.count > 10 else { return value }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }
}

struct NestedCodexTokens: Codable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case accountId = "account_id"
    }
}

/// Result of validating Codex auth state
struct CodexAuthValidation {
    let isValid: Bool
    let statusText: String
    let accountEmail: String?
}
