//
//  ClaudeUsageProviderFetcher.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-04-01.
//

import Foundation

/// Fetches Claude usage data and converts it to the provider-neutral snapshot format.
/// Wraps the existing ClaudeAPIService fetch logic behind the UsageProviderFetcher protocol.
@MainActor
class ClaudeUsageProviderFetcher: UsageProviderFetcher {
    let providerKind: UsageProviderKind = .claude

    private let apiService: ClaudeAPIService

    init(apiService: ClaudeAPIService? = nil) {
        self.apiService = apiService ?? ClaudeAPIService()
    }

    func fetchUsage(for profile: Profile) async throws -> ProviderUsageSnapshot {
        let claudeUsage = try await fetchClaudeUsage(for: profile)

        // Fetch API usage separately (non-fatal if it fails)
        var apiUsage: APIUsage? = nil
        if let apiSessionKey = profile.apiSessionKey,
           let orgId = profile.apiOrganizationId {
            apiUsage = try? await apiService.fetchAPIUsageData(
                organizationId: orgId,
                apiSessionKey: apiSessionKey
            )
        }

        return ClaudeUsageSnapshotAdapter.snapshot(from: claudeUsage, apiUsage: apiUsage)
    }

    /// Fetches raw ClaudeUsage using the profile's credentials (priority-based)
    func fetchClaudeUsage(for profile: Profile) async throws -> ClaudeUsage {
        // Priority 1: claude.ai session key (cookie-based)
        // This path already fetches overage/credit grant data internally.
        if let sessionKey = profile.claudeSessionKey,
           let orgId = profile.organizationId {
            return try await apiService.fetchUsageData(sessionKey: sessionKey, organizationId: orgId)
        }

        // Priority 2: Active profile — system CLI login (Claude Code keeps it fresh).
        // Verified by token or account id, mirrored into the profile, and refreshed
        // once with keychain writeback when an idle CLI let it expire (#268).
        if profile.id == ProfileManager.shared.activeProfile?.id,
           let systemCredentials = await ClaudeCodeSyncService.shared.freshSystemCredentials(for: profile),
           !ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials),
           let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
            var usage = try await apiService.fetchUsageData(oauthAccessToken: accessToken)
            await supplementOverageIfNeeded(&usage, profile: profile)
            return usage
        }

        // Priority 3: Saved CLI OAuth token from profile (non-active profiles never
        // touch the system login, whose lineage belongs to the active account).
        if let cliJSON = profile.cliCredentialsJSON,
           !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON),
           let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: cliJSON) {
            var usage = try await apiService.fetchUsageData(oauthAccessToken: accessToken)
            // CLI OAuth can't fetch org-scoped overage data; supplement via session key if available
            await supplementOverageIfNeeded(&usage, profile: profile)
            return usage
        }

        throw AppError(
            code: .sessionKeyNotFound,
            message: "Missing credentials for profile '\(profile.name)'",
            isRecoverable: false
        )
    }

    /// Supplements overage/credit grant data for CLI OAuth paths that can't fetch it themselves.
    /// Only called from CLI OAuth branches — never from the session key path (which handles it internally).
    private func supplementOverageIfNeeded(_ usage: inout ClaudeUsage, profile: Profile) async {
        guard profile.checkOverageLimitEnabled,
              let sessionKey = profile.claudeSessionKey,
              let orgId = profile.organizationId else { return }
        await apiService.supplementOverageData(&usage, sessionKey: sessionKey, organizationId: orgId)
    }
}
