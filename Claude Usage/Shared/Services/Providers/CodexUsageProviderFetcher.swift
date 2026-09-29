//
//  CodexUsageProviderFetcher.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-04-01.
//

import Foundation
import SwiftUI

/// Fetches Codex usage data from the same OAuth-backed usage endpoint used by
/// the Codex CLI / ChatGPT-backed Codex flow.
@MainActor
class CodexUsageProviderFetcher: UsageProviderFetcher {
    let providerKind: UsageProviderKind = .codex

    private let authService: CodexAuthService
    private let session: URLSession

    init(authService: CodexAuthService? = nil, session: URLSession = .shared) {
        self.authService = authService ?? CodexAuthService.shared
        self.session = session
    }

    func fetchUsage(for profile: Profile) async throws -> ProviderUsageSnapshot {
        let validation = authService.validateAuth()
        let showProviderDetails = SharedDataStore.shared.loadPopoverShowProviderDetails()

        guard authService.readAuthState() != nil else {
            throw AppError(code: .apiUnauthorized, message: "Codex authentication is unavailable or expired.")
        }

        do {
            // Refreshes stale tokens (8-day rule) and retries once after a 401 with a
            // forced refresh, writing rotated tokens back to auth.json (upstream 52bc240).
            let response: CodexUsageAPIResponse
            let credentials = try await authService.freshCredentials()
            do {
                response = try await fetchUsageResponse(accessToken: credentials.accessToken, accountId: credentials.accountId)
            } catch is CodexTokenRejected {
                // Only a 401 means the token itself was rejected; retry once, refreshed.
                let refreshed = try await authService.freshCredentials(force: true)
                do {
                    response = try await fetchUsageResponse(accessToken: refreshed.accessToken, accountId: refreshed.accountId)
                } catch is CodexTokenRejected {
                    throw AppError(code: .apiUnauthorized, message: "Codex authentication was rejected. Reconnect your account.")
                }
            }

            var rows: [ProviderMetricRow] = []
            var cards: [ProviderSupplementaryCard] = [
                ProviderSupplementaryCard(
                    id: "codex-status",
                    kind: .providerStatus(connected: true, statusText: "Connected")
                )
            ]

            if let primary = response.rateLimit?.primaryWindow {
                let isWeekly = primary.limitWindowSeconds == 7 * 24 * 60 * 60
                rows.append(ProviderMetricRow(
                    id: isWeekly ? "codex-weekly-window" : "codex-primary-window",
                    title: isWeekly ? "Weekly Usage" : "Session Usage",
                    tag: isWeekly ? "Weekly" : nil,
                    subtitle: isWeekly ? "7-day window" : "5-hour window",
                    usedPercentage: Double(primary.usedPercent),
                    resetTime: Date(timeIntervalSince1970: TimeInterval(primary.resetAt)),
                    periodDuration: TimeInterval(primary.limitWindowSeconds),
                    supportsPaceMarkers: true,
                    accentStyle: .primary
                ))
            }

            if let secondary = response.rateLimit?.secondaryWindow {
                rows.append(ProviderMetricRow(
                    id: "codex-secondary-window",
                    title: "Weekly Usage",
                    tag: "Weekly",
                    usedPercentage: Double(secondary.usedPercent),
                    resetTime: Date(timeIntervalSince1970: TimeInterval(secondary.resetAt)),
                    periodDuration: TimeInterval(secondary.limitWindowSeconds),
                    supportsPaceMarkers: true,
                    accentStyle: .secondary
                ))
            }

            if showProviderDetails {
                if let accountLabel = validation.accountEmail {
                    cards.append(ProviderSupplementaryCard(
                        id: "codex-account",
                        kind: .keyValue(label: "Account", value: accountLabel, valueColor: nil)
                    ))
                }

                if let credits = response.credits {
                    if credits.unlimited {
                        cards.append(ProviderSupplementaryCard(
                            id: "codex-credits-unlimited",
                            kind: .keyValue(label: "Credits", value: "Unlimited", valueColor: .adaptiveGreen)
                        ))
                    } else if let balance = credits.balance {
                        cards.append(ProviderSupplementaryCard(
                            id: "codex-credits-balance",
                            kind: .keyValue(
                                label: "Credits",
                                value: String(format: "%.0f remaining", balance),
                                valueColor: balance > 0 ? .adaptiveGreen : .secondary
                            )
                        ))
                    }
                }
            }

            return ProviderUsageSnapshot(
                provider: .codex,
                title: "Codex",
                subtitle: response.planType?.capitalized ?? "Connected",
                primaryRows: rows,
                secondaryCards: cards,
                fetchedAt: Date()
            )
        } catch {
            LoggingService.shared.logError("Codex usage fetch failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func fetchUsageResponse(accessToken: String, accountId: String?) async throws -> CodexUsageAPIResponse {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw CodexTokenRejected()
            }
            if httpResponse.statusCode == 403 {
                throw AppError(code: .apiUnauthorized, message: "Codex authentication was rejected. Reconnect your account.")
            }
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
    }
}

/// 401 from the usage endpoint: the access token was rejected (refreshable).
private struct CodexTokenRejected: Error {}

private struct CodexUsageAPIResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateWindow?
    let secondaryWindow: CodexRateWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateWindow: Decodable {
    let usedPercent: Int
    let limitWindowSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private struct CodexCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        if let numeric = try? container.decode(Double.self, forKey: .balance) {
            balance = numeric
        } else if let intValue = try? container.decode(Int.self, forKey: .balance) {
            balance = Double(intValue)
        } else if let stringValue = try? container.decode(String.self, forKey: .balance) {
            balance = Double(stringValue)
        } else {
            balance = nil
        }
    }
}
