//
//  Profile.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Represents a complete isolated profile with all credentials and settings
struct Profile: Codable, Identifiable, Equatable {
    // MARK: - Identity
    let id: UUID
    var name: String

    // MARK: - Provider
    var providerKind: UsageProviderKind

    // MARK: - Provider-Scoped Credentials
    var providerCredentials: ProviderCredentials?

    // MARK: - Legacy Credentials (kept for migration, mapped to providerCredentials)
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    // MARK: - CLI Account Sync Metadata
    var hasCliAccount: Bool
    var cliAccountSyncedAt: Date?
    /// Claude account id (`oauthAccount.accountUuid` in ~/.claude.json) proven for this
    /// profile's CLI login. Survives token rotation, unlike the tokens themselves.
    var cliAccountUuid: String?

    // MARK: - Usage Data (Per-Profile)
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    // MARK: - Appearance Settings (Per-Profile)
    var iconConfig: MenuBarIconConfiguration

    // MARK: - Behavior Settings (Per-Profile)
    var refreshInterval: TimeInterval
    var autoStartSessionEnabled: Bool
    var checkOverageLimitEnabled: Bool

    // MARK: - Notification Settings (Per-Profile)
    var notificationSettings: NotificationSettings

    // MARK: - Display Configuration
    var isSelectedForDisplay: Bool  // For multi-profile menu bar mode

    // MARK: - Metadata
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        providerKind: UsageProviderKind = .claude,
        providerCredentials: ProviderCredentials? = nil,
        claudeSessionKey: String? = nil,
        organizationId: String? = nil,
        apiSessionKey: String? = nil,
        apiOrganizationId: String? = nil,
        apiSessionKeyExpiry: Date? = nil,
        cliCredentialsJSON: String? = nil,
        hasCliAccount: Bool = false,
        cliAccountSyncedAt: Date? = nil,
        cliAccountUuid: String? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil,
        iconConfig: MenuBarIconConfiguration = .default,
        refreshInterval: TimeInterval = 30.0,
        autoStartSessionEnabled: Bool = false,
        checkOverageLimitEnabled: Bool = true,
        notificationSettings: NotificationSettings = NotificationSettings(),
        isSelectedForDisplay: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.providerKind = providerKind
        self.providerCredentials = providerCredentials
        self.claudeSessionKey = claudeSessionKey
        self.organizationId = organizationId
        self.apiSessionKey = apiSessionKey
        self.apiOrganizationId = apiOrganizationId
        self.apiSessionKeyExpiry = apiSessionKeyExpiry
        self.cliCredentialsJSON = cliCredentialsJSON
        self.hasCliAccount = hasCliAccount
        self.cliAccountSyncedAt = cliAccountSyncedAt
        self.cliAccountUuid = cliAccountUuid
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
        self.iconConfig = iconConfig
        self.refreshInterval = refreshInterval
        self.autoStartSessionEnabled = autoStartSessionEnabled
        self.checkOverageLimitEnabled = checkOverageLimitEnabled
        self.notificationSettings = notificationSettings
        self.isSelectedForDisplay = isSelectedForDisplay
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    // MARK: - Computed Properties

    /// Claude credentials from either legacy fields or provider credentials
    var claudeCredentials: ClaudeProviderCredentials? {
        if let creds = providerCredentials?.claude {
            return creds
        }
        // Fallback to legacy fields for un-migrated profiles
        if claudeSessionKey != nil || organizationId != nil || apiSessionKey != nil || cliCredentialsJSON != nil {
            return ClaudeProviderCredentials(
                sessionKey: claudeSessionKey,
                organizationId: organizationId,
                apiSessionKey: apiSessionKey,
                apiOrganizationId: apiOrganizationId,
                apiSessionKeyExpiry: apiSessionKeyExpiry,
                cliCredentialsJSON: cliCredentialsJSON,
                hasCliAccount: hasCliAccount,
                cliAccountSyncedAt: cliAccountSyncedAt
            )
        }
        return nil
    }

    /// Codex credentials from provider credentials
    var codexCredentials: CodexProviderCredentials? {
        providerCredentials?.codex
    }

    /// Copilot credentials from provider credentials
    var copilotCredentials: CopilotProviderCredentials? {
        providerCredentials?.copilot
    }

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    /// True if profile has credentials that can fetch usage data
    var hasUsageCredentials: Bool {
        switch providerKind {
        case .claude:
            return hasClaudeAI || hasAPIConsole || hasValidCLIOAuth
        case .codex:
            return codexCredentials != nil || CodexAuthService.shared.hasLocalAuth
        case .copilot:
            return copilotCredentials?.githubToken != nil || CopilotAuthService.shared.hasCLIToken
        }
    }

    /// True if profile has CLI OAuth credentials that are not expired
    var hasValidCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        return !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON)
    }

    var hasAnyCredentials: Bool {
        switch providerKind {
        case .claude:
            return hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil
        case .codex:
            return codexCredentials != nil || CodexAuthService.shared.hasLocalAuth
        case .copilot:
            return copilotCredentials?.githubToken != nil || CopilotAuthService.shared.hasCLIToken
        }
    }
}

// MARK: - ProfileCredentials (for compatibility)
/// Simple struct for passing credentials around
struct ProfileCredentials {
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    var hasCLI: Bool {
        cliCredentialsJSON != nil
    }
}
