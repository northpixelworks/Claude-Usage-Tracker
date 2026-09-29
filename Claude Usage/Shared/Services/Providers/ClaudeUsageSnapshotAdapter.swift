//
//  ClaudeUsageSnapshotAdapter.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-04-01.
//

import Foundation
import SwiftUI

/// Converts Claude-specific usage data into the provider-neutral ProviderUsageSnapshot format.
/// This adapter ensures the existing Claude experience renders identically through the new
/// provider-neutral dashboard while enabling other providers to plug into the same UI.
enum ClaudeUsageSnapshotAdapter {

    /// Converts ClaudeUsage + optional APIUsage into a ProviderUsageSnapshot
    static func snapshot(from usage: ClaudeUsage, apiUsage: APIUsage?) -> ProviderUsageSnapshot {
        var rows: [ProviderMetricRow] = []
        var cards: [ProviderSupplementaryCard] = []

        // Primary: Session Usage (5-hour window)
        rows.append(ProviderMetricRow(
            id: "claude-session",
            title: "menubar.session_usage".localized,
            subtitle: "menubar.5_hour_window".localized,
            usedPercentage: usage.effectiveSessionPercentage,
            resetTime: usage.sessionResetTime,
            periodDuration: Constants.sessionWindow,
            supportsPaceMarkers: true,
            accentStyle: .primary
        ))

        // All Models (Weekly)
        rows.append(ProviderMetricRow(
            id: "claude-weekly",
            title: "menubar.all_models".localized,
            tag: "menubar.weekly".localized,
            usedPercentage: usage.weeklyPercentage,
            resetTime: usage.weeklyResetTime,
            periodDuration: Constants.weeklyWindow,
            supportsPaceMarkers: true,
            accentStyle: .primary
        ))

        // Claude Design (Weekly) - only if there's usage
        if usage.designWeeklyTokensUsed > 0 {
            rows.append(ProviderMetricRow(
                id: "claude-design-weekly",
                title: "menubar.design_usage".localized,
                tag: "menubar.weekly".localized,
                usedPercentage: usage.designWeeklyPercentage,
                resetTime: usage.designWeeklyResetTime,
                accentStyle: .secondary
            ))
        }

        // Fable (Weekly) - only if there's usage
        if usage.fableWeeklyTokensUsed > 0 {
            rows.append(ProviderMetricRow(
                id: "claude-fable-weekly",
                title: "menubar.fable_usage".localized,
                tag: "menubar.weekly".localized,
                usedPercentage: usage.fableWeeklyPercentage,
                resetTime: usage.fableWeeklyResetTime,
                accentStyle: .secondary
            ))
        }

        // Opus (Weekly) - only if there's usage
        if usage.opusWeeklyTokensUsed > 0 {
            rows.append(ProviderMetricRow(
                id: "claude-opus-weekly",
                title: "menubar.opus_usage".localized,
                tag: "menubar.weekly".localized,
                usedPercentage: usage.opusWeeklyPercentage,
                accentStyle: .secondary
            ))
        }

        // Sonnet (Weekly) - only if there's usage
        if usage.sonnetWeeklyTokensUsed > 0 {
            rows.append(ProviderMetricRow(
                id: "claude-sonnet-weekly",
                title: "menubar.sonnet_usage".localized,
                usedPercentage: usage.sonnetWeeklyPercentage,
                resetTime: usage.sonnetWeeklyResetTime,
                accentStyle: .secondary
            ))
        }

        // Extra usage (cost-based limits)
        if let used = usage.costUsed, let limit = usage.costLimit, let currency = usage.costCurrency, limit > 0 {
            let usedPercentage = (used / limit) * 100.0
            rows.append(ProviderMetricRow(
                id: "claude-extra-usage",
                title: "menubar.extra_usage".localized,
                subtitle: String(format: "%.2f / %.2f %@", used / 100.0, limit / 100.0, currency),
                usedPercentage: usedPercentage,
                accentStyle: .warning
            ))
        }

        // Credit grant balance (gifted or purchased — shown independently)
        if let balance = usage.overageBalance, let balanceCurrency = usage.overageBalanceCurrency {
            cards.append(ProviderSupplementaryCard(
                id: "claude-overage-balance",
                kind: .keyValue(
                    label: "popover.overage_balance".localized,
                    value: String(format: "%.2f %@", balance / 100.0, balanceCurrency.uppercased()),
                    valueColor: .adaptiveGreen
                )
            ))
        }

        // API Usage card
        if let apiUsage = apiUsage {
            cards.append(ProviderSupplementaryCard(
                id: "claude-api-usage",
                kind: .apiUsage(apiUsage)
            ))

            // API Cost card (only if cost data available)
            if let costCents = apiUsage.apiTokenCostCents, costCents > 0 {
                cards.append(ProviderSupplementaryCard(
                    id: "claude-api-cost",
                    kind: .apiCost(apiUsage)
                ))
            }
        }

        return ProviderUsageSnapshot(
            provider: .claude,
            title: "Claude",
            subtitle: nil,
            primaryRows: rows,
            secondaryCards: cards,
            fetchedAt: usage.lastUpdated
        )
    }
}
