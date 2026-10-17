//
//  ProviderUsageSnapshot.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-04-01.
//

import Foundation
import SwiftUI

// MARK: - Accent Style

/// Controls the visual accent applied to a metric row
enum MetricAccentStyle: String, Codable, Equatable {
    case primary       // Default provider accent
    case secondary     // Subdued / child metric
    case warning       // Overage / cost-related
    case info          // Informational display only
}

// MARK: - Provider Metric Row

/// A single usage metric row that the dashboard can render for any provider.
/// Captures what the UI needs without assuming Claude-specific semantics.
struct ProviderMetricRow: Identifiable, Equatable {
    let id: String
    let title: String
    let tag: String?
    let subtitle: String?
    let usedPercentage: Double?
    let remainingPercentage: Double?
    let resetTime: Date?
    let periodDuration: TimeInterval?
    let supportsPaceMarkers: Bool
    let accentStyle: MetricAccentStyle

    init(
        id: String,
        title: String,
        tag: String? = nil,
        subtitle: String? = nil,
        usedPercentage: Double? = nil,
        remainingPercentage: Double? = nil,
        resetTime: Date? = nil,
        periodDuration: TimeInterval? = nil,
        supportsPaceMarkers: Bool = false,
        accentStyle: MetricAccentStyle = .primary
    ) {
        self.id = id
        self.title = title
        self.tag = tag
        self.subtitle = subtitle
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
        self.resetTime = resetTime
        self.periodDuration = periodDuration
        self.supportsPaceMarkers = supportsPaceMarkers
        self.accentStyle = accentStyle
    }
}

// MARK: - Supplementary Card Kind

/// The type of supplementary card to render below the primary metric rows
enum SupplementaryCardKind: Equatable {
    /// API usage card with spend/credit progress bar
    case apiUsage(APIUsage)
    /// API cost card with daily chart and per-model breakdown
    case apiCost(APIUsage)
    /// Simple key-value display (e.g. overage balance)
    case keyValue(label: String, value: String, valueColor: Color?)
    /// Provider-specific status display
    case providerStatus(connected: Bool, statusText: String)
}

// MARK: - Provider Supplementary Card

/// A supplementary dashboard card rendered below primary metric rows
struct ProviderSupplementaryCard: Identifiable, Equatable {
    let id: String
    let kind: SupplementaryCardKind

    static func == (lhs: ProviderSupplementaryCard, rhs: ProviderSupplementaryCard) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

// MARK: - Provider Usage Snapshot

/// Provider-neutral container for all usage data the dashboard needs to render.
/// Each provider adapter converts its native data into this format.
struct ProviderUsageSnapshot: Equatable {
    let provider: UsageProviderKind
    let title: String
    let subtitle: String?
    let primaryRows: [ProviderMetricRow]
    let secondaryCards: [ProviderSupplementaryCard]
    let fetchedAt: Date

    init(
        provider: UsageProviderKind,
        title: String,
        subtitle: String? = nil,
        primaryRows: [ProviderMetricRow] = [],
        secondaryCards: [ProviderSupplementaryCard] = [],
        fetchedAt: Date = Date()
    ) {
        self.provider = provider
        self.title = title
        self.subtitle = subtitle
        self.primaryRows = primaryRows
        self.secondaryCards = secondaryCards
        self.fetchedAt = fetchedAt
    }

    /// Billing data belongs to this snapshot's profile, never the active profile's cache.
    var apiUsage: APIUsage? {
        for card in secondaryCards {
            if case .apiUsage(let usage) = card.kind { return usage }
        }
        return nil
    }

    /// Empty snapshot for initial/loading state
    static func empty(for provider: UsageProviderKind) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            title: provider.displayName,
            subtitle: nil,
            primaryRows: [],
            secondaryCards: []
        )
    }
}
