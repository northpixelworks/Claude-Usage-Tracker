//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security

/// Manages synchronization of Claude Code CLI credentials between system Keychain and profiles
class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()

    /// Cached resolved keychain service name (in-memory, cleared per app session)
    private var resolvedServiceName: String?

    /// UserDefaults key for persisting the last successfully resolved hashed service name
    /// so we don't re-run the expensive `security dump-keychain` on every launch.
    private static let persistedServiceNameKey = "ClaudeCodeSyncService.resolvedServiceName"

    /// UserDefaults key marking that hashed-name discovery has already been attempted
    /// once on this machine. When set, we avoid `security dump-keychain` on launch.
    private static let discoveryAttemptedKey = "ClaudeCodeSyncService.discoveryAttempted"

    /// Timeout for blocking `/usr/bin/security` invocations. macOS 26.3.x has been
    /// observed to hang indefinitely on `security` subprocesses in some environments
    /// (see issue #179), so every shell-out is bounded to avoid deadlocking launch.
    private static let securityCommandTimeout: TimeInterval = 3.0

    private init() {}

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials using a fallback chain:
    /// 1. ~/.claude/.credentials.json (always complete, not subject to keychain truncation)
    /// 2. System Keychain (may be truncated for large payloads >2KB)
    /// 3. Regex extraction of accessToken from truncated keychain data (last resort)
    func readSystemCredentials() throws -> String? {
        // On macOS Claude Code rotates the KEYCHAIN only; the file is usually a stale
        // mirror. Read both and prefer the fresher (later expiresAt; tie → keychain).
        let fileJSON = readCredentialsFile()

        // 2. Try keychain
        let keychainData: String?
        do {
            keychainData = try readKeychainCredentials()
        } catch {
            if let fileJSON { return fileJSON }
            throw error
        }

        guard let rawJSON = keychainData else {
            // No keychain entry; the file (if any) is all we have
            return fileJSON
        }

        // 3. Validate keychain JSON
        if let data = rawJSON.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let fileJSON,
               let fileExpiry = extractTokenExpiry(from: fileJSON),
               fileExpiry > (extractTokenExpiry(from: rawJSON) ?? .distantPast) {
                LoggingService.shared.log("Using .credentials.json (fresher than keychain)")
                return fileJSON
            }
            return rawJSON
        }

        // Keychain data is truncated; the complete file wins if present
        if let fileJSON { return fileJSON }

        // 4. Keychain data is truncated/invalid — try regex extraction
        LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
        if let token = extractAccessTokenViaRegex(from: rawJSON) {
            let minimalJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
            LoggingService.shared.log("Built minimal credentials from regex-extracted token")
            return minimalJSON
        }

        // 5. All attempts failed
        throw ClaudeCodeError.invalidJSON
    }

    // MARK: - Private Credential Sources

    /// Reads credentials from ~/.claude/.credentials.json or ~/.claude/credentials.json file
    private func readCredentialsFile() -> String? {
        let paths = [
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".credentials.json"),
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }

            // Validate it's actually valid JSON
            guard let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log("credentials file contains invalid JSON: \(fileURL.lastPathComponent)")
                continue
            }

            LoggingService.shared.log("Read credentials from \(fileURL.lastPathComponent)")
            return jsonString
        }

        return nil
    }

    /// Result of a bounded `/usr/bin/security` invocation.
    private struct SecurityCommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Runs `/usr/bin/security` with the given arguments and a hard timeout.
    /// If the timeout elapses, the subprocess is terminated and `timedOut` is true.
    /// This is critical: without the timeout, a hung `security` call blocks the
    /// calling thread (and, if called from main, the whole app) indefinitely.
    private func runSecurityCommand(
        arguments: [String],
        timeout: TimeInterval = ClaudeCodeSyncService.securityCommandTimeout
    ) -> SecurityCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            LoggingService.shared.log("runSecurityCommand: failed to launch security: \(error.localizedDescription)")
            return nil
        }

        // Wait for the process with a hard deadline. DispatchGroup lets us block
        // the current thread up to `timeout` seconds, then terminate if still running.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            LoggingService.shared.log("runSecurityCommand: TIMEOUT after \(timeout)s, terminating security subprocess (args: \(arguments.prefix(2).joined(separator: " ")))")
            process.terminate()
            // Give it a brief moment to die, then force-kill if needed
            _ = group.wait(timeout: .now() + 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return SecurityCommandResult(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true)
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: false
        )
    }

    /// Reads Claude Code credentials from system Keychain using security command
    private func readKeychainCredentials() throws -> String? {
        let serviceName = resolveServiceName()
        guard let result = runSecurityCommand(arguments: [
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"  // Print password only
        ]) else {
            // Failed to launch security — treat as "no credentials"
            return nil
        }

        if result.timedOut {
            LoggingService.shared.log("readKeychainCredentials: security command timed out")
            return nil
        }

        let exitCode = result.exitCode

        if exitCode == 0 {
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } else if exitCode == 44 {
            // Exit code 44 = item not found
            return nil
        } else {
            LoggingService.shared.log("Failed to read keychain: \(result.stderr)")
            throw ClaudeCodeError.keychainReadFailed(status: OSStatus(exitCode))
        }
    }

    /// Extracts accessToken from potentially truncated JSON using regex
    private func extractAccessTokenViaRegex(from rawString: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              let tokenRange = Range(match.range(at: 1), in: rawString) else {
            return nil
        }
        return String(rawString[tokenRange])
    }

    // MARK: - Keychain Service Name Discovery

    private static let legacyServiceName = "Claude Code-credentials"

    /// Resolves the correct keychain service name for Claude Code credentials.
    /// Claude Code v2.1.52+ changed from "Claude Code-credentials" to
    /// "Claude Code-credentials-HASH".
    ///
    /// Resolution order (each step is bounded by `securityCommandTimeout`):
    /// 1. In-memory cache
    /// 2. UserDefaults-persisted name from a previous successful resolution
    /// 3. Legacy name probe (`find-generic-password`)
    /// 4. Hashed-name discovery (`dump-keychain`) — only if discovery has not
    ///    been attempted before OR the caller explicitly forced a retry
    ///
    /// Important: `security dump-keychain` is the call most prone to hanging
    /// on macOS 26.3.x (see #179), so we persist a "discovery attempted" flag
    /// and never re-run it on subsequent launches unless the cache is invalidated.
    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName {
            return cached
        }

        // Honor any previously persisted resolution — this avoids the expensive
        // `dump-keychain` shell-out on every launch after the first.
        if let persisted = UserDefaults.standard.string(forKey: Self.persistedServiceNameKey),
           !persisted.isEmpty {
            resolvedServiceName = persisted
            return persisted
        }

        // Try legacy name first (fast path, bounded by timeout)
        if keychainItemExists(serviceName: Self.legacyServiceName) {
            persistResolvedServiceName(Self.legacyServiceName)
            return Self.legacyServiceName
        }

        // Only run the (potentially slow/hanging) hashed-name discovery ONCE
        // per machine. If we've already tried and failed, default to the legacy
        // name and let downstream callers handle the "no credentials" case.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.discoveryAttemptedKey) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        // First-time discovery attempt — mark as attempted BEFORE running so that
        // even if the command hangs and gets force-terminated by the timeout,
        // we won't retry it on the next launch.
        defaults.set(true, forKey: Self.discoveryAttemptedKey)

        if let hashedName = findHashedServiceName() {
            persistResolvedServiceName(hashedName)
            LoggingService.shared.log("Resolved hashed keychain service name: \(hashedName)")
            return hashedName
        }

        // Default to legacy name (will fail gracefully if not found)
        resolvedServiceName = Self.legacyServiceName
        return Self.legacyServiceName
    }

    /// Persists a successfully resolved service name to UserDefaults and in-memory cache.
    private func persistResolvedServiceName(_ name: String) {
        resolvedServiceName = name
        UserDefaults.standard.set(name, forKey: Self.persistedServiceNameKey)
    }

    /// Checks if a keychain item exists with the given service name, bounded by
    /// `securityCommandTimeout` so a hung `security` process can't block the caller.
    private func keychainItemExists(serviceName: String) -> Bool {
        guard let result = runSecurityCommand(arguments: [
            "find-generic-password", "-s", serviceName, "-a", NSUserName()
        ]) else {
            return false
        }
        if result.timedOut {
            LoggingService.shared.log("keychainItemExists: security command timed out for service '\(serviceName)'")
            return false
        }
        return result.exitCode == 0
    }

    /// Searches the keychain for a hashed service name matching "Claude Code-credentials-*".
    /// This uses `security dump-keychain` which can be slow or hang on some macOS
    /// versions, so it is bounded by a longer timeout and only called once per machine.
    private func findHashedServiceName() -> String? {
        // `dump-keychain` enumerates every keychain item and can be slow on large
        // keychains; give it a slightly more generous budget than other commands
        // but still a hard ceiling to prevent indefinite hangs.
        guard let result = runSecurityCommand(arguments: ["dump-keychain"], timeout: 5.0) else {
            return nil
        }

        if result.timedOut {
            LoggingService.shared.log("findHashedServiceName: `security dump-keychain` timed out — falling back to legacy name")
            return nil
        }

        guard result.exitCode == 0 else { return nil }

        let output = result.stdout
        let prefix = "Claude Code-credentials-"

        // Parse service names from dump-keychain output (format: "svce"<blob>="ServiceName")
        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"svce\""), line.contains(prefix) else { continue }
            // Extract the value between quotes after the =
            if let equalsRange = line.range(of: "=\""),
               let endQuoteRange = line.range(of: "\"", range: equalsRange.upperBound..<line.endIndex) {
                let name = String(line[equalsRange.upperBound..<endQuoteRange.lowerBound])
                if name.hasPrefix(prefix) {
                    return name
                }
            }
        }
        return nil
    }

    /// Invalidates the cached service name, forcing re-discovery on next access.
    /// This also clears the persisted resolution and the discovery-attempted flag
    /// so a subsequent call will re-run the full resolution chain.
    func invalidateServiceNameCache() {
        resolvedServiceName = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.persistedServiceNameKey)
        defaults.removeObject(forKey: Self.discoveryAttemptedKey)
    }

    /// Writes Claude Code credentials to system Keychain using security command.
    /// Every subprocess invocation is bounded by `securityCommandTimeout` so a
    /// hung `security` process cannot block the caller indefinitely.
    func writeSystemCredentials(_ jsonData: String) throws {
        let serviceName = resolveServiceName()
        LoggingService.shared.log("Writing credentials to keychain using security command (service: \(serviceName))")

        // Add new item using security command
        guard let addResult = runSecurityCommand(arguments: [
            "add-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w", jsonData,
            "-U"  // Update if exists
        ]) else {
            throw ClaudeCodeError.keychainWriteFailed(status: -1)
        }

        if addResult.timedOut {
            LoggingService.shared.log("❌ writeSystemCredentials: add step timed out")
            throw ClaudeCodeError.keychainWriteFailed(status: -1)
        }

        if addResult.exitCode == 0 {
            LoggingService.shared.log("✅ Added Claude Code system credentials successfully using security command")
        } else {
            LoggingService.shared.log("❌ Failed to add credentials: \(addResult.stderr)")
            throw ClaudeCodeError.keychainWriteFailed(status: OSStatus(addResult.exitCode))
        }
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        guard let jsonData = try readSystemCredentials() else {
            throw ClaudeCodeError.noCredentialsFound
        }

        // Validate JSON format
        guard let data = jsonData.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.invalidJSON
        }

        // Save to profile directly
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = jsonData
        profiles[index].cliAccountUuid = systemAccountIdentity()
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)")
    }

    /// Applies profile's CLI credentials to system (overwrites current login)
    func applyProfileCredentials(_ profileId: UUID) throws {
        LoggingService.shared.log("🔄 Applying CLI credentials for profile: \(profileId)")

        let profiles = ProfileStore.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }),
              let jsonData = profile.cliCredentialsJSON else {
            LoggingService.shared.log("❌ No CLI credentials found for profile: \(profileId)")
            throw ClaudeCodeError.noProfileCredentials
        }

        LoggingService.shared.log("📦 Found CLI credentials, writing to keychain...")
        try writeSystemCredentials(jsonData)

        LoggingService.shared.log("✅ Applied profile CLI credentials to system: \(profileId)")
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = nil
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        let subType = oauth["subscriptionType"] as? String ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []

        return (subType, scopes)
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        // Claude Code CLI stores expiresAt in milliseconds since epoch
        // Values > 1e12 are definitely milliseconds (year 2001+ in ms vs year 33658 in seconds)
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    /// Opaque OAuth tokens do not expose a stable account identity. A shared,
    /// nonempty refresh/access token proves the same login; otherwise require
    /// the user to explicitly reconnect rather than guessing after rotation.
    static func credentialsMatch(_ stored: String?, _ candidate: String) -> Bool {
        func oauth(_ text: String?) -> [String: Any]? {
            guard let text, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["claudeAiOauth"] as? [String: Any]
        }
        guard let old = oauth(stored), let new = oauth(candidate) else { return false }
        return ["refreshToken", "accessToken"].contains { key in
            guard let token = old[key] as? String, !token.isEmpty else { return false }
            return token == new[key] as? String
        }
    }

    // MARK: - Active Profile Continuity & Idle Refresh
    // Fork adaptation of upstream #268 (c75607c) and the single-writer model (eee15cf).
    // Claude Code rotates BOTH tokens on refresh, so token equality alone breaks after
    // every rotation and the tracker went dormant. The account id from ~/.claude.json
    // survives rotation and proves the same login.

    private static let oauthRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// In-flight idle refresh, so concurrent fetches never spend the refresh token twice.
    @MainActor private var idleRefreshTask: Task<String?, Never>?

    /// Account id of the login Claude Code currently holds (`oauthAccount.accountUuid`,
    /// email as fallback), or nil if ~/.claude.json is missing/unreadable.
    func systemAccountIdentity() -> String? {
        let candidates = [
            Constants.ClaudePaths.homeDirectory.appendingPathComponent(".claude.json"),
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".claude.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["oauthAccount"] as? [String: Any] else { continue }
            if let uuid = account["accountUuid"] as? String, !uuid.isEmpty { return uuid }
            if let email = account["emailAddress"] as? String, !email.isEmpty { return "email:\(email.lowercased())" }
        }
        return nil
    }

    /// True when the system login provably belongs to `profile`: a shared token
    /// (unrotated) or the same recorded Claude account id (rotated).
    func systemCredentialsBelong(to profile: Profile, systemJSON: String) -> Bool {
        if Self.credentialsMatch(profile.cliCredentialsJSON, systemJSON) { return true }
        guard let recorded = profile.cliAccountUuid else { return false }
        return recorded == systemAccountIdentity()
    }

    func extractRefreshToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// Synchronous gate: can the active Claude profile be served by the system login,
    /// counting an expired token that is refreshable (idle CLI after sleep)?
    func hasUsableSystemCredentials(for profile: Profile) -> Bool {
        guard profile.providerKind == .claude,
              let systemJSON = try? readSystemCredentials(),
              extractAccessToken(from: systemJSON) != nil,
              systemCredentialsBelong(to: profile, systemJSON: systemJSON) else { return false }
        return !isTokenExpired(systemJSON) || extractRefreshToken(from: systemJSON) != nil
    }

    /// Returns usable system credentials for the ACTIVE Claude profile and mirrors them
    /// into the profile (keeps the continuity chain across rotations). If the token has
    /// expired, Claude Code is idle (it refreshes ~60s before expiry while in use), so the
    /// tracker refreshes ONCE and writes the rotated lineage back to the keychain (+ file
    /// mirror) so the CLI picks it up seamlessly on its next run.
    @MainActor
    func freshSystemCredentials(for profile: Profile) async -> String? {
        guard profile.providerKind == .claude,
              let systemJSON = try? readSystemCredentials(),
              systemCredentialsBelong(to: profile, systemJSON: systemJSON) else { return nil }

        if !isTokenExpired(systemJSON) {
            mirrorSystemCredentials(systemJSON, into: profile.id)
            return systemJSON
        }

        if let running = idleRefreshTask { return await running.value }
        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.idleRefreshTask = nil }
            return await self.refreshIdleSystemCredentials(systemJSON, profileId: profile.id)
        }
        idleRefreshTask = task
        return await task.value
    }

    @MainActor
    private func refreshIdleSystemCredentials(_ systemJSON: String, profileId: UUID) async -> String? {
        // Re-read: the CLI may have refreshed while we waited.
        if let latest = try? readSystemCredentials(), !isTokenExpired(latest) {
            mirrorSystemCredentials(latest, into: profileId)
            return latest
        }
        guard let refreshToken = extractRefreshToken(from: systemJSON) else { return nil }
        do {
            let refreshed = try await performTokenRefresh(refreshToken: refreshToken)
            guard let updatedJSON = mergeRefreshedCredentials(into: systemJSON, refreshed: refreshed) else {
                LoggingService.shared.logError("Idle refresh: could not merge refreshed credentials")
                return nil
            }
            do {
                try writeSystemCredentials(updatedJSON)
                writeCredentialsFileIfPresent(updatedJSON)
            } catch {
                LoggingService.shared.logError("Idle refresh: refreshed tokens but keychain writeback failed — CLI may need /login", error: error)
            }
            mirrorSystemCredentials(updatedJSON, into: profileId)
            LoggingService.shared.log("✓ Idle refresh: renewed expired Claude Code token and wrote it back to the keychain")
            return updatedJSON
        } catch {
            LoggingService.shared.logError("Idle refresh failed (non-fatal)", error: error)
            return nil
        }
    }

    /// Stores verified system credentials on the profile and records the account id.
    @MainActor
    private func mirrorSystemCredentials(_ json: String, into profileId: UUID) {
        let recorded = ProfileManager.shared.profiles.first(where: { $0.id == profileId })?.cliAccountUuid
        ProfileManager.shared.mirrorCLICredentials(json, accountUuid: recorded ?? systemAccountIdentity(), for: profileId)
    }

    /// Keeps an existing ~/.claude/.credentials.json mirror in step (0600); never creates one.
    private func writeCredentialsFileIfPresent(_ json: String) {
        let url = Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            LoggingService.shared.logError("Idle refresh: could not update .credentials.json mirror", error: error)
        }
    }

    private struct OAuthRefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    /// Posts the `refresh_token` grant to platform.claude.com.
    private func performTokenRefresh(refreshToken: String) async throws -> OAuthRefreshResponse {
        let clientId = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_CLIENT_ID"]
            ?? Self.defaultOAuthClientID
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        var request = URLRequest(url: Self.oauthRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 4xx bodies are {"error": ...} payloads without tokens — safe to log.
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "ClaudeCodeSyncService.refresh", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Token refresh HTTP \(status): \(snippet)"])
        }
        return try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
    }

    /// Merges a refresh response into the `claudeAiOauth` payload, preserving other fields.
    private func mergeRefreshedCredentials(into cliJSON: String, refreshed: OAuthRefreshResponse) -> String? {
        guard let data = cliJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        oauth["accessToken"] = refreshed.access_token
        if let newRefreshToken = refreshed.refresh_token {
            oauth["refreshToken"] = newRefreshToken
        }
        // Claude Code stores expiresAt in milliseconds since epoch.
        oauth["expiresAt"] = Int64(Date().timeIntervalSince1970 * 1000) + Int64(refreshed.expires_in) * 1000
        root["claudeAiOauth"] = oauth
        // Single-line JSON: newlines corrupt `security add-generic-password -w` payloads.
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try readSystemCredentials() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        // Update profile's stored credentials with fresh ones
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }

        guard systemCredentialsBelong(to: profiles[index], systemJSON: freshJSON) else {
            LoggingService.shared.log("Skipping automatic CLI sync: account identity could not be verified")
            return
        }
        profiles[index].cliCredentialsJSON = freshJSON
        profiles[index].cliAccountUuid = profiles[index].cliAccountUuid ?? systemAccountIdentity()
        profiles[index].cliAccountSyncedAt = Date()  // Update sync timestamp
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp")
    }
}

// MARK: - ClaudeCodeError

enum ClaudeCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case noProfileCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found in system Keychain. Please log in to Claude Code first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(let status):
            return "Failed to read credentials from system Keychain (status: \(status))."
        case .keychainWriteFailed(let status):
            return "Failed to write credentials to system Keychain (status: \(status))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        }
    }
}
