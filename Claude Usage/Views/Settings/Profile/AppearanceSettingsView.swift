//
//  AppearanceSettingsView.swift
//  Claude Usage - Menu Bar Appearance Settings
//
//  Created by Claude Code on 2025-12-27.
//

import SwiftUI

/// Menu bar icon appearance and customization with multi-metric support
struct AppearanceSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var configuration: MenuBarIconConfiguration = .default
    @State private var profileConfigs: [UUID: MenuBarIconConfiguration] = [:]
    @State private var saveDebounceTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "appearance.title".localized,
                    subtitle: "appearance.subtitle".localized
                )

                // Global Settings
                SettingsSectionCard(
                    title: "appearance.global_settings".localized,
                    subtitle: "appearance.global_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        SettingToggle(
                            title: "appearance.monochrome_title".localized,
                            description: "appearance.monochrome_description".localized,
                            isOn: Binding(
                                get: { configuration.colorMode == .monochrome },
                                set: { newValue in
                                    configuration.colorMode = newValue ? .monochrome : .multiColor
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_labels_title".localized,
                            description: "appearance.show_labels_description".localized,
                            isOn: Binding(
                                get: { configuration.showIconNames },
                                set: { newValue in
                                    configuration.showIconNames = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_remaining_title".localized,
                            description: "appearance.show_remaining_description".localized,
                            isOn: Binding(
                                get: { configuration.showRemainingPercentage },
                                set: { newValue in
                                    configuration.showRemainingPercentage = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_time_marker_title".localized,
                            description: "appearance.show_time_marker_description".localized,
                            isOn: Binding(
                                get: { configuration.showTimeMarker },
                                set: { newValue in
                                    configuration.showTimeMarker = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_pace_marker_title".localized,
                            description: "appearance.show_pace_marker_description".localized,
                            isOn: Binding(
                                get: { configuration.showPaceMarker },
                                set: { newValue in
                                    configuration.showPaceMarker = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.pace_coloring_title".localized,
                            description: "appearance.pace_coloring_description".localized,
                            isOn: Binding(
                                get: { configuration.usePaceColoring },
                                set: { newValue in
                                    configuration.usePaceColoring = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.orange_warning_title".localized,
                            description: "appearance.orange_warning_description".localized,
                            isOn: Binding(
                                get: { configuration.showOrangeWarning },
                                set: { newValue in
                                    configuration.showOrangeWarning = newValue
                                    saveConfiguration()
                                }
                            )
                        )
                    }
                }

                // Per-Profile Metrics Configuration
                SettingsSectionCard(
                    title: "appearance.menu_bar_metrics".localized,
                    subtitle: "appearance.metrics_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileMetricsCard(
                                profile: profile,
                                config: Binding(
                                    get: { profileConfigs[profile.id] ?? profile.iconConfig },
                                    set: { newValue in
                                        profileConfigs[profile.id] = newValue
                                        saveConfiguration(for: profile.id)
                                    }
                                ),
                                profileManager: profileManager
                            )
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadAllProfileConfigs()
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
            }
        }
        .onChange(of: profileManager.activeProfile?.id) { _, newProfileId in
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
            }
        }
        .onChange(of: profileManager.profiles.count) { _, _ in
            loadAllProfileConfigs()
        }
    }

    // MARK: - Helper Methods

    private func loadAllProfileConfigs() {
        for profile in profileManager.profiles {
            profileConfigs[profile.id] = profile.iconConfig
        }
    }

    private func saveConfiguration() {
        guard let profileId = profileManager.activeProfile?.id else {
            LoggingService.shared.logError("Cannot save appearance: no active profile")
            return
        }

        profileManager.updateIconConfig(configuration, for: profileId)
        NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)

        let enabledCount = configuration.metrics.filter { $0.isEnabled }.count
        LoggingService.shared.log("Saved icon configuration to profile (enabled: \(enabledCount))")
    }

    private func saveConfiguration(for profileId: UUID) {
        guard let config = profileConfigs[profileId] else { return }

        profileManager.updateIconConfig(config, for: profileId)
        NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)

        // Keep the active profile's global config in sync
        if profileId == profileManager.activeProfile?.id {
            configuration = config
        }

        let enabledCount = config.metrics.filter { $0.isEnabled }.count
        LoggingService.shared.log("Saved icon configuration to profile \(profileId) (enabled: \(enabledCount))")
    }
}

// MARK: - Per-Profile Metrics Card

private struct ProfileMetricsCard: View {
    let profile: Profile
    @Binding var config: MenuBarIconConfiguration
    @ObservedObject var profileManager: ProfileManager

    /// Metric types relevant for this profile's provider
    private var relevantMetrics: [MenuBarMetricType] {
        switch profile.providerKind {
        case .claude:
            return [.session, .week, .api]
        case .codex:
            return [.session, .week]
        case .copilot:
            return [.week]  // monthly quota shown as "week" metric type
        }
    }

    /// Whether this profile's metrics are actually visible in the menu bar
    private var isVisibleInMenuBar: Bool {
        if profileManager.displayMode == .single {
            return profile.id == profileManager.activeProfile?.id
        } else {
            return profile.isSelectedForDisplay
        }
    }

    /// Whether any metric is enabled for this profile
    private var hasEnabledMetrics: Bool {
        relevantMetrics.contains { metricType in
            config.metrics.first(where: { $0.metricType == metricType })?.isEnabled == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            // Profile header
            HStack(spacing: 8) {
                Image(systemName: profile.providerKind.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SettingsColors.primary)
                    .frame(width: 18)

                Text(profile.name)
                    .font(.system(size: 12, weight: .semibold))

                Text(profile.providerKind.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )

                Spacer()

                // Status indicator
                if hasEnabledMetrics && !isVisibleInMenuBar {
                    Label {
                        Text(profileManager.displayMode == .single
                             ? "appearance.not_active_profile".localized
                             : "appearance.not_selected_for_display".localized)
                            .font(.system(size: 9))
                    } icon: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.orange)
                } else if hasEnabledMetrics && isVisibleInMenuBar {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green.opacity(0.7))
                }
            }

            // Metric cards for this profile
            ForEach(relevantMetrics, id: \.self) { metricType in
                if let metricIndex = config.metrics.firstIndex(where: { $0.metricType == metricType }) {
                    MetricIconCard(
                        metricType: metricType,
                        config: Binding(
                            get: { config.metrics[metricIndex] },
                            set: { newValue in
                                config.metrics[metricIndex] = newValue
                            }
                        ),
                        onConfigChanged: {
                            // Trigger the binding's setter to persist
                            let current = config
                            config = current
                        }
                    )
                }
            }
        }
        .padding(DesignTokens.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.cardBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

// MARK: - Previews

#Preview {
    AppearanceSettingsView()
        .frame(width: 520, height: 600)
}
