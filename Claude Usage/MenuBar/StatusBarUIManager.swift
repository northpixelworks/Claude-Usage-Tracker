//
//  StatusBarUIManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import Combine

/// Manages multiple menu bar status items for different metrics
final class StatusBarUIManager {
    private struct MultiProfileStatusItemKey: Hashable {
        let profileId: UUID
        let metricType: MenuBarMetricType
    }

    // Dictionary to hold multiple status items keyed by metric type (single profile mode)
    private var statusItems: [MenuBarMetricType: NSStatusItem] = [:]

    // Dictionary to hold status items keyed by profile ID + metric type (multi-profile mode)
    private var multiProfileStatusItems: [MultiProfileStatusItemKey: NSStatusItem] = [:]

    // Current display mode
    private var isMultiProfileMode: Bool = false

    private var appearanceObservers: [NSKeyValueObservation] = []
    private var appearanceDebounceTimer: Timer?

    // Image cache to avoid redundant button.image assignments (which trigger KVO)
    private var lastImageData: [ObjectIdentifier: Data] = [:]

    // Icon renderer for creating menu bar images
    private let renderer = MenuBarIconRenderer()

    weak var delegate: StatusBarUIManagerDelegate?

    // MARK: - Stable identity helpers

    private static let autosavePrefix = "claudeUsageTracker"
    private static let defaultLogoPlaceholderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private static let defaultLogoPlaceholderKey = MultiProfileStatusItemKey(profileId: defaultLogoPlaceholderUUID, metricType: .session)
    private static let defaultLogoAutosaveName: NSStatusItem.AutosaveName = "\(autosavePrefix).defaultLogo"

    private static func autosaveName(for metricType: MenuBarMetricType) -> NSStatusItem.AutosaveName {
        "\(autosavePrefix).metric.\(metricType.rawValue)"
    }

    private static func autosaveName(for itemKey: MultiProfileStatusItemKey) -> NSStatusItem.AutosaveName {
        if itemKey == defaultLogoPlaceholderKey {
            return defaultLogoAutosaveName
        }

        return "\(autosavePrefix).multiProfile.\(itemKey.profileId.uuidString).\(itemKey.metricType.rawValue)"
    }

    private static func multiProfilePrimaryKey(for profileId: UUID) -> MultiProfileStatusItemKey {
        MultiProfileStatusItemKey(profileId: profileId, metricType: .session)
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    /// Sets up status bar items based on configuration
    func setup(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Remove all existing items first
        cleanup()

        // Check if there are any enabled metrics
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = Self.defaultLogoAutosaveName
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                button.action = action
                button.target = target
                // Set a temporary placeholder - will be updated with actual logo
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Status bar button is nil - screens: \(NSScreen.screens.count)")
            }

            // Use a special key to identify the default icon
            statusItems[.session] = statusItem  // Use session as placeholder key
            LoggingService.shared.logUIEvent("Status bar initialized with default app logo (no credentials)")
        } else {
            // Create status items for enabled metrics
            for metricConfig in config.enabledMetrics {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.autosaveName = Self.autosaveName(for: metricConfig.metricType)
                // Override any persisted false from a prior cmd-drag.
                statusItem.isVisible = true

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                } else {
                    LoggingService.shared.logWarning("Status bar button is nil for \(metricConfig.metricType.displayName) - screens: \(NSScreen.screens.count)")
                }

                statusItems[metricConfig.metricType] = statusItem
            }

            LoggingService.shared.logUIEvent("Status bar initialized with \(config.enabledMetrics.count) metrics")
        }

        observeAppearanceChanges()
    }

    /// Updates status bar items based on new configuration (incremental approach)
    func updateConfiguration(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Determine what the new set of items should be
        let newMetricTypes: Set<MenuBarMetricType>
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo using .session as placeholder
            newMetricTypes = [.session]
        } else {
            newMetricTypes = Set(config.enabledMetrics.map { $0.metricType })
        }

        let currentMetricTypes = Set(statusItems.keys)

        // Step 1: Remove items that are no longer needed
        let itemsToRemove = currentMetricTypes.subtracting(newMetricTypes)
        for metricType in itemsToRemove {
            if let statusItem = statusItems[metricType] {
                if let button = statusItem.button {
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Removed status item for \(metricType.displayName)")
            }
            statusItems.removeValue(forKey: metricType)
        }

        // Step 2: Add items that are new
        let itemsToAdd = newMetricTypes.subtracting(currentMetricTypes)
        for metricType in itemsToAdd {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = config.enabledMetrics.isEmpty
                ? Self.defaultLogoAutosaveName
                : Self.autosaveName(for: metricType)
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                button.action = action
                button.target = target
                if metricType == .session {
                    // Default logo placeholder
                    button.title = ""
                }
            }

            statusItems[metricType] = statusItem
            LoggingService.shared.logUIEvent("Created status item for \(metricType.displayName)")
        }

        // Step 3: Items that already exist don't need recreation, just keep them
        // Their images will be updated by updateAllButtons() or updateButton()

        LoggingService.shared.logUIEvent("Status bar configuration updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentMetricTypes.intersection(newMetricTypes).count)")
    }

    func cleanup() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // Clean up single profile status items
        for (_, statusItem) in statusItems {
            // Clear button references first
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            // Then remove from status bar
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItems.removeAll()

        // Clean up multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        multiProfileStatusItems.removeAll()

        isMultiProfileMode = false

        LoggingService.shared.logUIEvent("Status bar cleaned up")
    }

    // MARK: - Multi-Profile Mode

    /// Fixed placeholder length for freshly-created multi-profile status items. Creating
    /// them at a concrete length (rather than .variableLength) avoids the macOS 26 (Tahoe)
    /// recursive variable-width NSISEngine solve during a multi-item rebuild (profile
    /// switch). setMultiProfileImage replaces it with the real coarse-rounded width.
    private static let multiProfilePlaceholderLength: CGFloat = 32

    /// Sets up status bar for multi-profile display mode
    func setupMultiProfile(profiles: [Profile], config: MultiProfileDisplayConfig, target: AnyObject, action: Selector) {
        // Clean up existing items
        cleanup()

        isMultiProfileMode = true

        let selectedProfiles = profiles.filter { $0.isSelectedForDisplay }
        let selectedItems = multiProfileItemKeys(for: selectedProfiles, globalConfig: config)

        if selectedItems.isEmpty {
            // No profiles selected - show default logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = Self.defaultLogoAutosaveName
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true
            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Multi-profile status bar button is nil - screens: \(NSScreen.screens.count)")
            }
            multiProfileStatusItems[Self.defaultLogoPlaceholderKey] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: No profiles selected, showing default logo")
        } else {
            // Create one status item per selected profile
            for item in selectedItems {
                let statusItem = NSStatusBar.system.statusItem(withLength: Self.multiProfilePlaceholderLength)
                statusItem.autosaveName = Self.autosaveName(for: item)
                // Override any persisted false from a prior cmd-drag.
                statusItem.isVisible = true

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                } else {
                    LoggingService.shared.logWarning("Multi-profile status bar button is nil for \(item.profileId.uuidString.prefix(8))/\(item.metricType.rawValue) - screens: \(NSScreen.screens.count)")
                }

                multiProfileStatusItems[item] = statusItem
            }

            LoggingService.shared.logUIEvent("Multi-profile: Created \(selectedItems.count) status items")
        }

        observeAppearanceChanges()
    }

    func updateMultiProfileConfiguration(profiles: [Profile], config: MultiProfileDisplayConfig, target: AnyObject, action: Selector) {
        guard isMultiProfileMode else {
            setupMultiProfile(profiles: profiles, config: config, target: target, action: action)
            return
        }

        let selectedItems = multiProfileItemKeys(for: profiles, globalConfig: config)
        let newItemKeys: Set<MultiProfileStatusItemKey> = selectedItems.isEmpty
            ? [Self.defaultLogoPlaceholderKey]
            : Set(selectedItems)
        let currentItemKeys = Set(multiProfileStatusItems.keys)

        let itemsToRemove = currentItemKeys.subtracting(newItemKeys)
        for itemKey in itemsToRemove {
            if let statusItem = multiProfileStatusItems[itemKey] {
                if let button = statusItem.button {
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Multi-profile: Removed status item for \(itemKey.profileId.uuidString.prefix(8))/\(itemKey.metricType.rawValue)")
            }
            multiProfileStatusItems.removeValue(forKey: itemKey)
        }

        let itemsToAdd = newItemKeys.subtracting(currentItemKeys)
        if selectedItems.isEmpty, itemsToAdd.contains(Self.defaultLogoPlaceholderKey) {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = Self.defaultLogoAutosaveName
            // Override any persisted false from a prior cmd-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.title = ""
            }

            multiProfileStatusItems[Self.defaultLogoPlaceholderKey] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: Added default logo")
        } else {
            for itemKey in selectedItems where itemsToAdd.contains(itemKey) {
                let statusItem = NSStatusBar.system.statusItem(withLength: Self.multiProfilePlaceholderLength)
                statusItem.autosaveName = Self.autosaveName(for: itemKey)
                // Override any persisted false from a prior cmd-drag.
                statusItem.isVisible = true

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                }

                multiProfileStatusItems[itemKey] = statusItem
                LoggingService.shared.logUIEvent("Multi-profile: Added status item for \(itemKey.profileId.uuidString.prefix(8))/\(itemKey.metricType.rawValue)")
            }
        }

        LoggingService.shared.logUIEvent("Multi-profile config updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentItemKeys.intersection(newItemKeys).count)")
    }

    /// Updates all multi-profile status items
    func updateMultiProfileButtons(
        profiles: [Profile],
        snapshots: [UUID: ProviderUsageSnapshot],
        config: MultiProfileDisplayConfig
    ) {
        guard isMultiProfileMode else { return }

        let selectedItems = multiProfileItemKeys(for: profiles, globalConfig: config)
        if selectedItems.isEmpty {
            if let statusItem = multiProfileStatusItems[Self.defaultLogoPlaceholderKey],
               let button = statusItem.button {
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true
                setMultiProfileImage(statusItem, button: button, image: logoImage)
                button.toolTip = "Claude Usage"
            }
            return
        }

        for profile in profiles where profile.isSelectedForDisplay {
            let effectiveStyle = profile.iconConfig.multiProfileIconStyle ?? config.iconStyle

            if effectiveStyle == .battery {
                renderBatteryMultiProfile(profile: profile, snapshots: snapshots, config: config)
            } else {
                renderCompactMultiProfile(profile: profile, snapshots: snapshots, config: config, effectiveStyle: effectiveStyle)
            }
        }
    }

    private func renderBatteryMultiProfile(
        profile: Profile,
        snapshots: [UUID: ProviderUsageSnapshot],
        config: MultiProfileDisplayConfig
    ) {
        let profileConfig = profile.iconConfig
        let prefix = String(profile.name.prefix(2)).uppercased()

        guard let snapshot = snapshots[profile.id],
              let syntheticUsage = syntheticUsage(for: snapshot, preferredMetric: .session) else {
            for metricConfig in profileConfig.enabledMetrics {
                let itemKey = MultiProfileStatusItemKey(profileId: profile.id, metricType: metricConfig.metricType)
                if let statusItem = multiProfileStatusItems[itemKey],
                   let button = statusItem.button {
                    let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                    logoImage.isTemplate = true
                    setMultiProfileImage(statusItem, button: button, image: logoImage)
                    button.toolTip = profile.name
                }
            }
            return
        }

        for metricConfig in profileConfig.enabledMetrics {
            let itemKey = MultiProfileStatusItemKey(profileId: profile.id, metricType: metricConfig.metricType)
            guard let statusItem = multiProfileStatusItems[itemKey],
                  let button = statusItem.button else { continue }

            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            let image = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: profileConfig,
                usage: syntheticUsage,
                apiUsage: nil,
                isDarkMode: menuBarIsDark,
                colorMode: profileConfig.colorMode,
                singleColorHex: profileConfig.singleColorHex,
                showIconName: profileConfig.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime,
                profilePrefix: prefix,
                periodDuration: row(for: metricConfig.metricType, in: snapshot, provider: profile.providerKind)?.periodDuration,
                periodLabel: profile.providerKind == .copilot ? "Month" : nil
            )

            image.isTemplate = profileConfig.colorMode == .monochrome && !profileConfig.showPaceMarker
            setMultiProfileImage(statusItem, button: button, image: image)

            let metricName = profile.providerKind == .copilot
                ? "Monthly Premium Usage"
                : metricConfig.metricType.displayName
            button.toolTip = "\(profile.name) • \(metricName)"
        }
    }

    private func renderCompactMultiProfile(
        profile: Profile,
        snapshots: [UUID: ProviderUsageSnapshot],
        config: MultiProfileDisplayConfig,
        effectiveStyle: MultiProfileIconStyle
    ) {
        let itemKey = Self.multiProfilePrimaryKey(for: profile.id)
        guard let statusItem = multiProfileStatusItems[itemKey],
              let button = statusItem.button else { return }

        let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        guard let snapshot = snapshots[profile.id],
              let renderState = multiProfileRenderState(for: profile, snapshot: snapshot, config: config) else {
            let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
            logoImage.isTemplate = true
            setMultiProfileImage(statusItem, button: button, image: logoImage)
            button.toolTip = profile.name
            return
        }

        let renderConfig = MultiProfileDisplayConfig(
            iconStyle: effectiveStyle,
            showWeek: config.showWeek,
            showProfileLabel: config.showProfileLabel,
            useSystemColor: config.useSystemColor,
            showTimeMarker: config.showTimeMarker,
            showPaceMarker: config.showPaceMarker,
            usePaceColoring: config.usePaceColoring
        )

        let image = multiProfileImage(
            for: profile,
            config: renderConfig,
            renderState: renderState,
            isDarkMode: menuBarIsDark
        )

        image.isTemplate = false
        setMultiProfileImage(statusItem, button: button, image: image)
        button.toolTip = tooltip(
            for: profile,
            primaryRow: renderState.primaryRow,
            secondaryRow: renderState.secondaryRow,
            styleName: effectiveStyle.displayName
        )
    }

    private func multiProfileItemKeys(for profiles: [Profile], globalConfig: MultiProfileDisplayConfig) -> [MultiProfileStatusItemKey] {
        profiles
            .filter { $0.isSelectedForDisplay }
            .flatMap { profile -> [MultiProfileStatusItemKey] in
                let effectiveStyle = profile.iconConfig.multiProfileIconStyle ?? globalConfig.iconStyle
                if effectiveStyle == .battery {
                    return profile.iconConfig.enabledMetrics.map { metric in
                        MultiProfileStatusItemKey(profileId: profile.id, metricType: metric.metricType)
                    }
                }
                return [Self.multiProfilePrimaryKey(for: profile.id)]
            }
    }

    private struct MultiProfileRenderState {
        let primaryRow: ProviderMetricRow
        let secondaryRow: ProviderMetricRow?
        let primaryPercentage: Double
        let secondaryPercentage: Double?
        let primaryStatus: UsageStatusLevel
        let secondaryStatus: UsageStatusLevel
        let primaryTimeMarker: CGFloat?
        let secondaryTimeMarker: CGFloat?
        let primaryPaceStatus: PaceStatus?
        let secondaryPaceStatus: PaceStatus?
    }

    private func multiProfileRenderState(
        for profile: Profile,
        snapshot: ProviderUsageSnapshot,
        config: MultiProfileDisplayConfig
    ) -> MultiProfileRenderState? {
        let primaryRow: ProviderMetricRow?
        let secondaryCandidate: ProviderMetricRow?

        switch profile.providerKind {
        case .claude, .codex:
            primaryRow = row(for: .session, in: snapshot, provider: profile.providerKind)
            secondaryCandidate = config.showWeek
                ? row(for: .week, in: snapshot, provider: profile.providerKind)
                : nil
        case .copilot:
            primaryRow = row(for: .week, in: snapshot, provider: profile.providerKind)
            secondaryCandidate = nil
        }

        guard let primaryRow,
              let primaryUsed = primaryRow.usedPercentage else {
            return nil
        }

        let secondaryRow = secondaryCandidate.flatMap { candidate -> ProviderMetricRow? in
            guard config.showWeek,
                  candidate.id != primaryRow.id,
                  candidate.usedPercentage != nil else {
                return nil
            }
            return candidate
        }

        let primaryPercentage = clampedPercentage(primaryUsed)
        let secondaryPercentage = secondaryRow.map { clampedPercentage($0.usedPercentage ?? 0) }
        let primaryStatus = statusLevel(for: primaryRow, usePaceColoring: config.usePaceColoring)
        let secondaryStatus = secondaryRow.map { statusLevel(for: $0, usePaceColoring: config.usePaceColoring) } ?? .safe

        let primaryElapsed = elapsedFraction(for: primaryRow, enabled: true)
        let secondaryElapsed = secondaryRow.flatMap { elapsedFraction(for: $0, enabled: true) }

        let primaryTimeMarker = config.showTimeMarker ? primaryElapsed.map { CGFloat($0) } : nil
        let secondaryTimeMarker = config.showWeek ? secondaryElapsed.map { CGFloat($0) } : nil

        let primaryPaceStatus = paceStatus(for: primaryRow, showPaceMarker: config.showPaceMarker)
        let secondaryPaceStatus = config.showWeek
            ? secondaryRow.flatMap { paceStatus(for: $0, showPaceMarker: config.showPaceMarker) }
            : nil

        return MultiProfileRenderState(
            primaryRow: primaryRow,
            secondaryRow: secondaryRow,
            primaryPercentage: primaryPercentage,
            secondaryPercentage: secondaryPercentage,
            primaryStatus: primaryStatus,
            secondaryStatus: secondaryStatus,
            primaryTimeMarker: primaryTimeMarker,
            secondaryTimeMarker: secondaryTimeMarker,
            primaryPaceStatus: primaryPaceStatus,
            secondaryPaceStatus: secondaryPaceStatus
        )
    }

    private func multiProfileImage(
        for profile: Profile,
        config: MultiProfileDisplayConfig,
        renderState: MultiProfileRenderState,
        isDarkMode: Bool
    ) -> NSImage {
        let showLabel = config.showProfileLabel
        let profileLabel = showLabel ? profile.name : nil
        let profileInitial = String(profile.name.prefix(1)).uppercased()

        switch config.iconStyle {
        case .battery:
            return renderer.createDefaultAppLogo(isDarkMode: isDarkMode)

        case .concentric:
            let secondaryPercentage = config.showWeek ? (renderState.secondaryPercentage ?? 0) : 0
            let secondaryStatus = config.showWeek ? renderState.secondaryStatus : .safe

            if let profileLabel {
                return renderer.createConcentricIconWithLabel(
                    sessionPercentage: renderState.primaryPercentage,
                    weekPercentage: secondaryPercentage,
                    sessionStatus: renderState.primaryStatus,
                    weekStatus: secondaryStatus,
                    profileName: profileLabel,
                    monochromeMode: false,
                    isDarkMode: isDarkMode,
                    useSystemColor: config.useSystemColor,
                    sessionTimeMarker: renderState.primaryTimeMarker,
                    weekTimeMarker: config.showWeek ? renderState.secondaryTimeMarker : nil,
                    sessionPaceStatus: renderState.primaryPaceStatus,
                    weekPaceStatus: config.showWeek ? renderState.secondaryPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            }

            return renderer.createConcentricIcon(
                sessionPercentage: renderState.primaryPercentage,
                weekPercentage: secondaryPercentage,
                sessionStatus: renderState.primaryStatus,
                weekStatus: secondaryStatus,
                profileInitial: profileInitial,
                monochromeMode: false,
                isDarkMode: isDarkMode,
                useSystemColor: config.useSystemColor,
                sessionTimeMarker: renderState.primaryTimeMarker,
                weekTimeMarker: config.showWeek ? renderState.secondaryTimeMarker : nil,
                sessionPaceStatus: renderState.primaryPaceStatus,
                weekPaceStatus: config.showWeek ? renderState.secondaryPaceStatus : nil,
                showPaceMarker: config.showPaceMarker
            )

        case .progressBar:
            return renderer.createMultiProfileProgressBar(
                sessionPercentage: renderState.primaryPercentage,
                weekPercentage: config.showWeek ? renderState.secondaryPercentage : nil,
                sessionStatus: renderState.primaryStatus,
                weekStatus: renderState.secondaryStatus,
                profileName: profileLabel,
                monochromeMode: false,
                isDarkMode: isDarkMode,
                useSystemColor: config.useSystemColor,
                sessionTimeMarker: renderState.primaryTimeMarker,
                weekTimeMarker: config.showWeek ? renderState.secondaryTimeMarker : nil,
                sessionPaceStatus: renderState.primaryPaceStatus,
                weekPaceStatus: config.showWeek ? renderState.secondaryPaceStatus : nil,
                showPaceMarker: config.showPaceMarker
            )

        case .compact:
            return renderer.createCompactDot(
                percentage: renderState.primaryPercentage,
                status: renderState.primaryStatus,
                profileInitial: showLabel ? profileInitial : nil,
                monochromeMode: false,
                isDarkMode: isDarkMode,
                useSystemColor: config.useSystemColor,
                paceStatus: renderState.primaryPaceStatus,
                showPaceMarker: config.showPaceMarker
            )

        case .percentage:
            return renderer.createMultiProfilePercentage(
                sessionPercentage: renderState.primaryPercentage,
                weekPercentage: config.showWeek ? renderState.secondaryPercentage : nil,
                sessionStatus: renderState.primaryStatus,
                weekStatus: renderState.secondaryStatus,
                profileName: profileLabel,
                monochromeMode: false,
                isDarkMode: isDarkMode,
                useSystemColor: config.useSystemColor,
                sessionPaceStatus: renderState.primaryPaceStatus,
                weekPaceStatus: config.showWeek ? renderState.secondaryPaceStatus : nil,
                showPaceMarker: config.showPaceMarker
            )
        }
    }

    private func clampedPercentage(_ percentage: Double) -> Double {
        max(0, min(percentage, 100))
    }

    private func elapsedFraction(for row: ProviderMetricRow, enabled: Bool) -> Double? {
        guard enabled,
              row.supportsPaceMarkers,
              let periodDuration = row.periodDuration else {
            return nil
        }

        return UsageStatusCalculator.elapsedFraction(
            resetTime: row.resetTime,
            duration: periodDuration,
            showRemaining: false
        )
    }

    private func statusLevel(for row: ProviderMetricRow, usePaceColoring: Bool) -> UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: clampedPercentage(row.usedPercentage ?? 0),
            showRemaining: false,
            elapsedFraction: usePaceColoring ? elapsedFraction(for: row, enabled: true) : nil
        )
    }

    private func paceStatus(for row: ProviderMetricRow, showPaceMarker: Bool) -> PaceStatus? {
        guard showPaceMarker,
              let usedPercentage = row.usedPercentage,
              let elapsed = elapsedFraction(for: row, enabled: true) else {
            return nil
        }

        return PaceStatus.calculate(
            usedPercentage: clampedPercentage(usedPercentage),
            elapsedFraction: elapsed
        )
    }

    private func syntheticUsage(for snapshot: ProviderUsageSnapshot, preferredMetric: MenuBarMetricType) -> ClaudeUsage? {
        let meteredRows = snapshot.primaryRows.filter { $0.usedPercentage != nil }
        guard !meteredRows.isEmpty else { return nil }

        let sessionRow = row(for: .session, in: snapshot, provider: snapshot.provider)
            ?? (preferredMetric == .session ? meteredRows.first : nil)
            ?? meteredRows.first
        let weekRow = row(for: .week, in: snapshot, provider: snapshot.provider)
            ?? (preferredMetric == .week ? meteredRows.first : nil)
            ?? meteredRows.dropFirst().first
            ?? sessionRow

        guard let sessionRow else { return nil }

        let sessionPercentage = max(0, min(sessionRow.usedPercentage ?? 0, 100))
        let weekPercentage = max(0, min(weekRow?.usedPercentage ?? 0, 100))
        let sessionLimit = 100
        let weeklyLimit = Constants.weeklyLimit

        return ClaudeUsage(
            sessionTokensUsed: Int(Double(sessionLimit) * (sessionPercentage / 100.0)),
            sessionLimit: sessionLimit,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionRow.resetTime ?? Date().addingTimeInterval(Constants.sessionWindow),
            weeklyTokensUsed: Int(Double(weeklyLimit) * (weekPercentage / 100.0)),
            weeklyLimit: weeklyLimit,
            weeklyPercentage: weekPercentage,
            weeklyResetTime: weekRow?.resetTime ?? Date().addingTimeInterval(Constants.weeklyWindow),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: snapshot.fetchedAt,
            userTimezone: .current
        )
    }

    private func row(for metricType: MenuBarMetricType, in snapshot: ProviderUsageSnapshot, provider: UsageProviderKind) -> ProviderMetricRow? {
        let meteredRows = snapshot.primaryRows.filter { $0.usedPercentage != nil }
        guard !meteredRows.isEmpty else { return nil }

        let matchingRow = meteredRows.first { row in
            let id = row.id.lowercased()
            let title = row.title.lowercased()
            switch metricType {
            case .session:
                if provider == .copilot { return false }
                return id.contains("session") || id.contains("primary") || title.contains("session")
            case .week:
                if provider == .copilot {
                    return id.contains("premium") || id.contains("chat") || title.contains("premium") || title.contains("monthly")
                }
                return id.contains("week") || id.contains("weekly") || id.contains("secondary") || title.contains("week")
            case .api:
                return id.contains("api") || title.contains("api")
            }
        }

        switch metricType {
        case .session:
            return matchingRow ?? meteredRows.first
        case .week:
            return matchingRow ?? meteredRows.dropFirst().first ?? meteredRows.first
        case .api:
            return matchingRow
        }
    }

    private func tooltip(
        for profile: Profile,
        primaryRow: ProviderMetricRow,
        secondaryRow: ProviderMetricRow?,
        styleConfig: MetricIconConfig?
    ) -> String {
        var parts = ["\(profile.name) • \(primaryRow.title)"]

        if let secondaryRow {
            parts.append(secondaryRow.title)
        }

        if let styleConfig {
            parts.append(styleConfig.iconStyle.displayName)
        }

        return parts.joined(separator: " • ")
    }

    private func tooltip(
        for profile: Profile,
        primaryRow: ProviderMetricRow,
        secondaryRow: ProviderMetricRow?,
        styleName: String
    ) -> String {
        var parts = ["\(profile.name) • \(primaryRow.title)"]

        if let secondaryRow {
            parts.append(secondaryRow.title)
        }

        parts.append(styleName)
        return parts.joined(separator: " • ")
    }

    /// Checks if currently in multi-profile mode
    var isInMultiProfileMode: Bool {
        return isMultiProfileMode
    }

    /// Checks if status bar has at least one valid button (for headless mode detection)
    var hasValidStatusBar: Bool {
        // Check single-profile status items
        for (_, statusItem) in statusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Check multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if statusItem.button != nil {
                return true
            }
        }
        return false
    }

    /// Get button for a specific profile (multi-profile mode)
    func button(for profileId: UUID) -> NSStatusBarButton? {
        let preferredOrder: [MenuBarMetricType] = [.session, .week, .api]
        for metricType in preferredOrder {
            if let button = multiProfileStatusItems[MultiProfileStatusItemKey(profileId: profileId, metricType: metricType)]?.button {
                return button
            }
        }
        return multiProfileStatusItems.first(where: { $0.key.profileId == profileId })?.value.button
    }

    /// Find which profile ID owns the given button (multi-profile mode)
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

        for (itemKey, statusItem) in multiProfileStatusItems {
            if statusItem.button === sender {
                return itemKey.profileId
            }
        }
        return nil
    }

    // MARK: - UI Updates

    /// Updates all status bar buttons based on current usage data
    func updateAllButtons(
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        // Get config from active profile
        let profile = ProfileManager.shared.activeProfile
        let config = profile?.iconConfig ?? .default


        // Check if we should show default logo (no usage credentials OR no enabled metrics)
        let hasUsageCredentials = hasRenderableUsageCredentials(for: profile)
        if !hasUsageCredentials || config.enabledMetrics.isEmpty {
            // Show default app logo
            if let statusItem = statusItems[.session],  // We use .session as placeholder key
               let button = statusItem.button {
                // Get actual menu bar appearance from the button
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true  // Let macOS handle the color
                setButtonImage(button, image: logoImage)
            }
            return
        }

        // Normal metric display
        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricType],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Create image directly using our renderer
            let image = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: usage,
                apiUsage: apiUsage,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime
            )

            image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
            button.image = image

            // Usage tooltip
            let metricName = metricConfig.metricType == .session ? "Session" : (metricConfig.metricType == .week ? "Week" : "API")
            let pct: Int
            switch metricConfig.metricType {
            case .session: pct = Int(usage.effectiveSessionPercentage)
            case .week: pct = Int(usage.weeklyPercentage)
            case .api: pct = Int(apiUsage?.usagePercentage ?? 0)
            }
            button.toolTip = "\(metricName): \(pct)%"
        }
    }

    private func hasRenderableUsageCredentials(for profile: Profile?) -> Bool {
        guard let profile else { return false }

        if profile.hasUsageCredentials {
            return true
        }

        guard profile.providerKind == .claude,
              profile.id == ProfileManager.shared.activeProfile?.id else {
            return false
        }

        do {
            if let systemCreds = try ClaudeCodeSyncService.shared.readSystemCredentials(),
               !ClaudeCodeSyncService.shared.isTokenExpired(systemCreds),
               ClaudeCodeSyncService.shared.extractAccessToken(from: systemCreds) != nil {
                return true
            }
        } catch {
            LoggingService.shared.log("StatusBarUIManager.hasRenderableUsageCredentials: system credential check failed: \(error.localizedDescription)")
        }

        return false
    }

    /// Updates single-profile status items using a provider-neutral snapshot.
    /// This is used for providers like Codex and Copilot whose refresh path
    /// populates `ProviderUsageSnapshot` instead of `ClaudeUsage`.
    func updateAllButtons(
        snapshot: ProviderUsageSnapshot,
        profile: Profile
    ) {
        let config = profile.iconConfig

        guard profile.hasUsageCredentials, !config.enabledMetrics.isEmpty else {
            if let statusItem = statusItems[.session],
               let button = statusItem.button {
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true
                setButtonImage(button, image: logoImage)
            }
            return
        }

        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricType],
                  let button = statusItem.button else {
                continue
            }

            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            guard let syntheticUsage = syntheticUsage(for: snapshot, preferredMetric: metricConfig.metricType),
                  let metricRow = row(for: metricConfig.metricType, in: snapshot, provider: profile.providerKind) else {
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true
                setButtonImage(button, image: logoImage)
                button.toolTip = "\(profile.name) • \(profile.providerKind.displayName)"
                continue
            }

            let image = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: syntheticUsage,
                apiUsage: nil,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime,
                profilePrefix: profile.providerKind.menuBarPrefix,
                periodDuration: metricRow.periodDuration,
                periodLabel: profile.providerKind == .copilot ? "Month" : nil
            )

            image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
            setButtonImage(button, image: image)
            button.toolTip = tooltip(for: profile, primaryRow: metricRow, secondaryRow: nil, styleConfig: metricConfig)
        }
    }

    /// Updates a specific metric's button
    func updateButton(
        for metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        guard let statusItem = statusItems[metricType],
              let button = statusItem.button else {
            return
        }

        // Get config from active profile
        let profile = ProfileManager.shared.activeProfile
        let config = profile?.iconConfig ?? .default

        guard let metricConfig = config.config(for: metricType) else {
            return
        }

        // Get the actual menu bar appearance from the button's effective appearance
        let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Create image directly using our renderer
        let image = renderer.createImage(
            for: metricType,
            config: metricConfig,
            globalConfig: config,
            usage: usage,
            apiUsage: apiUsage,
            isDarkMode: menuBarIsDark,
            colorMode: config.colorMode,
            singleColorHex: config.singleColorHex,
            showIconName: config.showIconNames,
            showNextSessionTime: metricConfig.showNextSessionTime
        )

        image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
        button.image = image

        let metricName = metricType == .session ? "Session" : (metricType == .week ? "Week" : "API")
        let pct: Int
        switch metricType {
        case .session: pct = Int(usage.effectiveSessionPercentage)
        case .week: pct = Int(usage.weeklyPercentage)
        case .api: pct = Int(apiUsage?.usagePercentage ?? 0)
        }
        button.toolTip = "\(metricName): \(pct)%"
    }

    /// Get button for a specific metric (used for popover positioning)
    func button(for metricType: MenuBarMetricType) -> NSStatusBarButton? {
        return statusItems[metricType]?.button
    }

    /// Get the first enabled metric's button (for backwards compatibility)
    var primaryButton: NSStatusBarButton? {
        let config = DataStore.shared.loadMenuBarIconConfiguration()
        guard let firstMetric = config.enabledMetrics.first else {
            return nil
        }
        return statusItems[firstMetric.metricType]?.button
    }

    /// Find which metric type owns the given button (sender)
    func metricType(for sender: NSStatusBarButton?) -> MenuBarMetricType? {
        guard let sender = sender else { return nil }

        // Find which status item has this button
        for (metricType, statusItem) in statusItems {
            if statusItem.button === sender {
                return metricType
            }
        }
        return nil
    }

    // MARK: - Appearance Observation

    private var lastObservedAppearanceName: NSAppearance.Name?

    private func observeAppearanceChanges() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // IMPORTANT: Do NOT observe per-button effectiveAppearance.
        // Setting button.image triggers effectiveAppearance KVO on the button,
        // which causes an infinite redraw loop.
        let appObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastObservedAppearanceName else { return }
            self.lastObservedAppearanceName = newName
            // Clear image cache so next update re-renders with new appearance
            self.lastImageData.removeAll()
            self.delegate?.statusBarAppearanceDidChange()
        }
        appearanceObservers.append(appObserver)
    }

    /// Only sets button.image if the image data actually changed.
    /// This prevents triggering effectiveAppearance KVO when the image is identical.
    private func setButtonImage(_ button: NSStatusBarButton, image: NSImage) {
        let buttonId = ObjectIdentifier(button)
        // Avoid NSImage.tiffRepresentation: macOS 26 SDK crashes in
        // SetupTIFFErrorHandler dispatch_once. Hash via CGImage bytes instead.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let newData = cg.dataProvider?.data as Data? else {
            button.image = image
            return
        }
        if lastImageData[buttonId] == newData { return }
        lastImageData[buttonId] = newData
        button.image = image
    }

    /// Multi-profile image setter. macOS 26 (Tahoe) crash fix: with .variableLength,
    /// AppKit recomputes each item's width inside a shared NSISEngine layout pass, which
    /// recurses and overflows the stack with 2+ items. Pin an explicit length, rounded to
    /// a coarse grid so ordinary value changes ("5%" vs "45%") never move it.
    private func setMultiProfileImage(_ statusItem: NSStatusItem, button: NSStatusBarButton, image: NSImage) {
        let stableLength = ceil(image.size.width / 32.0) * 32.0
        if abs(statusItem.length - stableLength) > 0.5 {
            statusItem.length = stableLength
        }
        setButtonImage(button, image: image)
    }

    /// Debounces appearance change notifications so multiple displays/buttons
    /// coalesce into a single delegate callback
    private func scheduleAppearanceUpdate() {
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.delegate?.statusBarAppearanceDidChange()
        }
    }
}

// MARK: - Delegate Protocol

protocol StatusBarUIManagerDelegate: AnyObject {
    func statusBarAppearanceDidChange()
}
