//
//  ManageProfilesView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI

struct ManageProfilesView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showingCreateProfile = false
    @State private var newProfileName = ""
    @State private var selectedProvider: UsageProviderKind = .claude
    @State private var pendingDeleteProfile: Profile?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "profiles.title".localized,
                    subtitle: "profiles.subtitle".localized
                )

                // Profile List
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileRow(profile: profile) {
                                pendingDeleteProfile = profile
                            }
                                .padding(.vertical, DesignTokens.Spacing.extraSmall)

                            if profile.id != profileManager.profiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Create New Profile Button
                SettingsButton(
                    title: "profiles.create_new".localized,
                    icon: "plus.circle.fill"
                ) {
                    showingCreateProfile = true
                }

                // Multi-Profile Display Section
                SettingsSectionCard(
                    title: "multiprofile.title".localized,
                    subtitle: "multiprofile.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        // Main toggle
                        SettingToggle(
                            title: "multiprofile.enable_title".localized,
                            description: "multiprofile.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { profileManager.displayMode == .multi },
                                set: { enabled in
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                    // Post notification for menu bar to update
                                    NotificationCenter.default.post(name: .displayModeChanged, object: nil)
                                }
                            )
                        )

                        // Profile selection (visible when multi-profile is ON)
                        if profileManager.displayMode == .multi {
                            Divider()

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.select_profiles".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                ForEach(profileManager.profiles) { profile in
                                    VStack(alignment: .leading, spacing: 6) {
                                        ProfileSelectionRow(
                                            profile: profile,
                                            isSelected: profile.isSelectedForDisplay,
                                            isActive: profileManager.activeProfile?.id == profile.id,
                                            onToggle: {
                                                let selectedCount = profileManager.profiles.filter { $0.isSelectedForDisplay }.count
                                                if profile.isSelectedForDisplay && selectedCount <= 1 {
                                                    return
                                                }
                                                profileManager.toggleProfileSelection(profile.id)
                                                NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                            }
                                        )

                                        if profile.isSelectedForDisplay {
                                            MultiProfileStylePicker(
                                                selectedStyle: Binding(
                                                    get: {
                                                        profile.iconConfig.multiProfileIconStyle ?? profileManager.multiProfileConfig.iconStyle
                                                    },
                                                    set: { newStyle in
                                                        var config = profile.iconConfig
                                                        config.multiProfileIconStyle = newStyle
                                                        profileManager.updateIconConfig(config, for: profile.id)
                                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                                    }
                                                )
                                            )
                                            .padding(.leading, 28)
                                        }
                                    }
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.filter({ $0.isSelectedForDisplay }).count == 1 {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                        Text("multiprofile.at_least_one".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Show Week Toggle
                            SettingToggle(
                                title: "multiprofile.show_week".localized,
                                description: "multiprofile.show_week_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showWeek },
                                    set: { showWeek in
                                        var config = profileManager.multiProfileConfig
                                        config.showWeek = showWeek
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Profile Label Toggle
                            SettingToggle(
                                title: "multiprofile.show_label".localized,
                                description: "multiprofile.show_label_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showProfileLabel },
                                    set: { showLabel in
                                        var config = profileManager.multiProfileConfig
                                        config.showProfileLabel = showLabel
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Use System Color Toggle
                            SettingToggle(
                                title: "multiprofile.use_system_color".localized,
                                description: "multiprofile.use_system_color_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.useSystemColor },
                                    set: { useSystemColor in
                                        var config = profileManager.multiProfileConfig
                                        config.useSystemColor = useSystemColor
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Show Time Marker Toggle
                            SettingToggle(
                                title: "appearance.show_time_marker_title".localized,
                                description: "appearance.show_time_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showTimeMarker },
                                    set: { showMarker in
                                        var config = profileManager.multiProfileConfig
                                        config.showTimeMarker = showMarker
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Pace Marker Toggle
                            SettingToggle(
                                title: "appearance.show_pace_marker_title".localized,
                                description: "appearance.show_pace_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showPaceMarker },
                                    set: { showPace in
                                        var config = profileManager.multiProfileConfig
                                        config.showPaceMarker = showPace
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Pace-Aware Bar Colors Toggle
                            SettingToggle(
                                title: "appearance.pace_coloring_title".localized,
                                description: "appearance.pace_coloring_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.usePaceColoring },
                                    set: { usePace in
                                        var config = profileManager.multiProfileConfig
                                        config.usePaceColoring = usePace
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Fork: optional orange warning (off = green/red only)
                            SettingToggle(
                                title: "appearance.orange_warning_title".localized,
                                description: "appearance.orange_warning_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showOrangeWarning },
                                    set: { showOrange in
                                        var config = profileManager.multiProfileConfig
                                        config.showOrangeWarning = showOrange
                                        profileManager.updateMultiProfileConfig(config)
                                        NotificationCenter.default.post(name: .multiProfileConfigChanged, object: nil)
                                    }
                                )
                            )

                            // Info message
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("multiprofile.info".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, DesignTokens.Spacing.small)
                        }
                    }
                }

                // Auto-Switch Profile Section
                SettingsSectionCard(
                    title: "auto_switch.title".localized,
                    subtitle: "auto_switch.subtitle".localized
                ) {
                    SettingToggle(
                        title: "auto_switch.enable_title".localized,
                        description: "auto_switch.enable_description".localized,
                        badge: .new,
                        isOn: Binding(
                            get: { SharedDataStore.shared.loadAutoSwitchProfileEnabled() },
                            set: { enabled in
                                SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled)
                            }
                        )
                    )
                }

                // Info Card
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("profiles.about_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        Text("profiles.about_description".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("profiles.about_credentials".localized)
                            BulletPoint("profiles.about_api".localized)
                            BulletPoint("profiles.about_cli".localized)
                            BulletPoint("profiles.about_appearance".localized)
                            BulletPoint("profiles.about_notifications".localized)
                            BulletPoint("profiles.about_refresh".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, DesignTokens.Spacing.small)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .alert("profiles.delete_title".localized, isPresented: Binding(
            get: { pendingDeleteProfile != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteProfile = nil
                }
            }
        )) {
            Button("common.cancel".localized, role: .cancel) {
                pendingDeleteProfile = nil
            }
            Button("common.delete".localized, role: .destructive) {
                guard let pendingDeleteProfile else { return }

                do {
                    try profileManager.deleteProfile(pendingDeleteProfile.id)
                } catch {
                    errorMessage = error.localizedDescription
                }

                self.pendingDeleteProfile = nil
            }
        } message: {
            Text(
                pendingDeleteProfile.map {
                    String(format: "profiles.delete_confirm".localized, $0.name)
                } ?? ""
            )
        }
        .sheet(isPresented: $showingCreateProfile) {
            CreateProfileSheet(
                profileName: $newProfileName,
                selectedProvider: $selectedProvider,
                onSave: {
                    createNewProfile()
                },
                onCancel: {
                    showingCreateProfile = false
                    newProfileName = ""
                }
            )
        }
    }

    private func createNewProfile() {
        let name = newProfileName.isEmpty ? nil : newProfileName
        _ = profileManager.createProfile(name: name, providerKind: selectedProvider)
        showingCreateProfile = false
        newProfileName = ""
        selectedProvider = .claude
    }
}

private struct MultiProfileStylePicker: View {
    @Binding var selectedStyle: MultiProfileIconStyle

    private let columns = [
        GridItem(.adaptive(minimum: 130, maximum: 180), spacing: DesignTokens.Spacing.small, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.small) {
            ForEach(MultiProfileIconStyle.allCases, id: \.self) { style in
                Button {
                    selectedStyle = style
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: style.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selectedStyle == style ? .accentColor : .secondary)
                            .frame(width: 14)

                        Text(style.shortNameKey.localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selectedStyle == style ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selectedStyle == style ? Color.accentColor.opacity(0.65) : DesignTokens.Colors.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: Profile
    let onDeleteRequest: () -> Void
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isEditing = false
    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Profile Icon
            Image(systemName: profile.providerKind == .claude
                ? (profile.hasCliAccount ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.fill")
                : profile.providerKind.iconName)
                .font(.system(size: 24))
                .foregroundColor(profileManager.activeProfile?.id == profile.id ? profile.providerKind.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Profile Name", text: $editedName, onCommit: {
                        saveProfileName()
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 14, weight: .medium))

                        if profileManager.activeProfile?.id == profile.id {
                            Text("profiles.active_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }
                }

                Text(profileInfo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !isEditing {
                    // Rename Button
                    Button(action: {
                        editedName = profile.name
                        isEditing = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("profiles.rename".localized)

                    // Activate Button (if not active)
                    if profileManager.activeProfile?.id != profile.id {
                        Button(action: {
                            Task {
                                await profileManager.activateProfile(profile.id)
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("profiles.activate".localized)
                    }

                    // Delete Button (if not the last profile)
                    if profileManager.profiles.count > 1 {
                        Button(action: {
                            onDeleteRequest()
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("profiles.delete".localized)
                    }
                } else {
                    // Save Button
                    Button(action: {
                        saveProfileName()
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)

                    // Cancel Button
                    Button(action: {
                        isEditing = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var profileInfo: String {
        var parts: [String] = []

        if profile.hasCliAccount {
            parts.append("profiles.cli_synced".localized)
        }

        parts.append("\("profiles.created".localized) \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")

        return parts.joined(separator: " • ")
    }

    private func saveProfileName() {
        if !editedName.isEmpty && editedName != profile.name {
            var updated = profile
            updated.name = editedName
            profileManager.updateProfile(updated)
        }
        isEditing = false
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @Binding var profileName: String
    @Binding var selectedProvider: UsageProviderKind
    let onSave: () -> Void
    let onCancel: () -> Void

    private let providerColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("profiles.create_title".localized)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.name_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("profiles.name_placeholder".localized, text: $profileName)
                    .textFieldStyle(.roundedBorder)

                Text("profiles.name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Provider type selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 8) {
                    ForEach(UsageProviderKind.allCases) { provider in
                        Button(action: { selectedProvider = provider }) {
                            HStack(spacing: 6) {
                                Image(systemName: provider.iconName)
                                    .font(.system(size: 12))
                                Text(provider.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedProvider == provider ? provider.accentColor.opacity(0.15) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedProvider == provider ? provider.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .foregroundColor(selectedProvider == provider ? provider.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Select which AI provider this profile tracks. GitHub-based usage is listed as GitHub Copilot.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.plain)

                Button("common.create".localized) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
