import Cocoa
import SwiftUI
import Combine

class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?  // Legacy - kept for backwards compatibility
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    private let refreshRequests = ProfileRefreshTracker()
    private var latestRefreshBatch = UUID()
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var providerSnapshot: ProviderUsageSnapshot?
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var apiUsage: APIUsage?
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?
    @Published private(set) var clickedProfileAPIUsage: APIUsage?
    @Published private(set) var clickedProfileSnapshot: ProviderUsageSnapshot?

    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Track last known reset times for history recording
    private var lastKnownSessionResetTime: [UUID: Date] = [:]
    private var lastKnownWeeklyResetTime: [UUID: Date] = [:]
    private var lastKnownAPIResetTime: [UUID: Date] = [:]

    // Track if a reset was just recorded to prevent duplicate periodic snapshots
    private var resetJustRecorded: [UUID: (session: Bool, weekly: Bool)] = [:]

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Timestamp of the most recent popover close. Used to debounce the
    // status-item click that dismisses the popover: that same click also fires
    // togglePopover, which would otherwise immediately re-show the popover
    // (the "click makes it bounce back instead of closing" race).
    private var lastPopoverCloseDate: Date = .distantPast

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?

    // GitHub star prompt window reference
    private var githubPromptWindow: NSWindow?

    // Feedback prompt window reference
    private var feedbackWindow: NSWindow?

    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?

    private let apiService = ClaudeAPIService()
    private let statusService = ClaudeStatusService()
    private let dataStore = DataStore.shared
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager: ProfileManager
    private let usageHistory: UsageHistoryService
    private let snapshotFetcherOverride: ((Profile) async throws -> ProviderUsageSnapshot)?
    private let statusFetcherOverride: (() async throws -> ClaudeStatus)?

    init(profileManager: ProfileManager? = nil,
         usageHistory: UsageHistoryService? = nil,
         snapshotFetcher: ((Profile) async throws -> ProviderUsageSnapshot)? = nil,
         statusFetcher: (() async throws -> ClaudeStatus)? = nil) {
        self.profileManager = profileManager ?? .shared
        self.usageHistory = usageHistory ?? .shared
        self.snapshotFetcherOverride = snapshotFetcher
        self.statusFetcherOverride = statusFetcher
        super.init()
    }

    private func fetchServiceStatus() async throws -> ClaudeStatus {
        if let statusFetcherOverride { return try await statusFetcherOverride() }
        return try await statusService.fetchStatus()
    }
    private let autoStartService = AutoStartSessionService.shared

    // Provider fetchers
    private lazy var claudeFetcher = ClaudeUsageProviderFetcher(apiService: apiService)
    private lazy var codexFetcher = CodexUsageProviderFetcher()
    private lazy var copilotFetcher = CopilotUsageProviderFetcher()

    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    // Cache provider snapshots for non-Claude profiles so the popover can render them
    private var cachedProviderSnapshots: [UUID: ProviderUsageSnapshot] = [:]

    // Observer for refresh interval changes
    private var refreshIntervalObserver: NSKeyValueObservation?

    // Observer for icon style changes
    private var iconStyleObserver: NSObjectProtocol?

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile)
    private var displayModeObserver: NSObjectProtocol?

    // Observer for multi-profile visual config changes
    private var multiProfileConfigObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast

    // MARK: - Image Caching (CPU Optimization)
    private var cachedImage: NSImage?
    private var cachedImageKey: String = ""
    private var updateDebounceTimer: Timer?
    private var cachedIsDarkMode: Bool = false

    func setup() {
        // Initialize cached appearance to avoid layout recursion
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode()
        } else {
            // Single profile mode - setup with active profile's config
            let config = profileManager.activeProfile?.iconConfig ?? .default
            let hasUsageCredentials = hasAnyAvailableCredentials()

            // If no usage credentials, create empty config to show default logo
            let displayConfig: MenuBarIconConfiguration
            if !hasUsageCredentials {
                displayConfig = MenuBarIconConfiguration(
                    colorMode: config.colorMode,
                    singleColorHex: config.singleColorHex,
                    showIconNames: config.showIconNames,
                    metrics: config.metrics.map { metric in
                        var updatedMetric = metric
                        updatedMetric.isEnabled = false
                        return updatedMetric
                    }
                )
            } else {
                displayConfig = config
            }

            statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)
        }

        // Setup popover
        setupPopover()

        // Load saved data from active profile first (provides immediate feedback)
        if let profile = profileManager.activeProfile {
            if hasAnyAvailableCredentials(for: profile) {
                // Credentials available - show saved usage data if available
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
                if let savedAPIUsage = profile.apiUsage {
                    apiUsage = savedAPIUsage
                }
            } else {
                // No credentials available - clear any old usage data and show default logo
                usage = .empty
                apiUsage = nil
                LoggingService.shared.log("MenuBarManager: No credentials available, showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            // Skip only if no credentials are available for the active profile.
            guard self.hasAnyAvailableCredentials() else {
                LoggingService.shared.log("Skipping network-available refresh (no credentials available)")
                return
            }

            // Always refresh if we haven't had a successful refresh yet (e.g. after restart)
            if self.lastSuccessfulRefreshTime == nil {
                LoggingService.shared.log("Network available - no successful refresh yet, fetching immediately")
                self.refreshUsage()
            } else {
                let timeSinceLastRefresh = Date().timeIntervalSince(self.lastRefreshTriggerTime)
                if timeSinceLastRefresh > 2.0 {  // At least 2 seconds since last refresh
                    self.refreshUsage()
                } else {
                    LoggingService.shared.log("Skipping network-available refresh (too soon after last refresh)")
                }
            }
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (brief delay to let the run loop stabilize at launch)
        if hasAnyAvailableCredentials() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refreshUsage()
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no credentials available)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Start auto-start session service (5-minute cycle for all profiles)
        autoStartService.start()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()

        // Observe display mode changes (single/multi profile)
        observeDisplayModeChanges()
        observeMultiProfileConfigChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()
    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()

        // Command palette action observers
        setupCommandPaletteObservers()
    }

    private func setupCommandPaletteObservers() {
        NotificationCenter.default.addObserver(forName: .commandPaletteRefresh, object: nil, queue: .main) { [weak self] _ in
            self?.refreshUsage()
        }
        NotificationCenter.default.addObserver(forName: .commandPaletteForceRefreshAll, object: nil, queue: .main) { [weak self] _ in
            self?.refreshUsage()
        }
        NotificationCenter.default.addObserver(forName: .commandPaletteCopyUsage, object: nil, queue: .main) { [weak self] _ in
            self?.copyUsageToClipboard()
        }
        NotificationCenter.default.addObserver(forName: .commandPaletteDetachPopover, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let popover = self.popover, popover.isShown else { return }
            popover.performClose(nil)
            // Post detach event that the popover handles
        }
        NotificationCenter.default.addObserver(forName: .commandPaletteShowFeedback, object: nil, queue: .main) { [weak self] _ in
            self?.showFeedbackPrompt()
        }
    }

    private func copyUsageToClipboard() {
        var lines: [String] = []
        if let profile = profileManager.activeProfile {
            lines.append("Profile: \(profile.name)")
        }
        lines.append("Session: \(usage.sessionPercentage)%")
        lines.append("Weekly: \(usage.weeklyPercentage)%")
        if let api = apiUsage {
            lines.append("API Credits: \(api.formattedUsed) / \(api.formattedTotal)")
        }
        let text = lines.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func cleanup() {
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkMonitor.stopMonitoring()
        autoStartService.stop()
        cancellables.removeAll()  // Clean up Combine subscriptions
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        if let iconStyleObserver = iconStyleObserver {
            NotificationCenter.default.removeObserver(iconStyleObserver)
            self.iconStyleObserver = nil
        }
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let multiProfileConfigObserver = multiProfileConfigObserver {
            NotificationCenter.default.removeObserver(multiProfileConfigObserver)
            self.multiProfileConfigObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        statusItem = nil
        statusBarUIManager?.cleanup()
        statusBarUIManager = nil

        // Clean up history tracking dictionaries to prevent memory leaks
        lastKnownSessionResetTime.removeAll()
        lastKnownWeeklyResetTime.removeAll()
        lastKnownAPIResetTime.removeAll()
        resetJustRecorded.removeAll()
    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        lastKnownSessionResetTime.removeValue(forKey: profileId)
        lastKnownWeeklyResetTime.removeValue(forKey: profileId)
        lastKnownAPIResetTime.removeValue(forKey: profileId)
        resetJustRecorded.removeValue(forKey: profileId)
        autoSwitchedProfileIds.remove(profileId)
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self = self, let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                Task { @MainActor in
                    await self.handleProfileSwitch(to: profile)
                }
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) async {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")

        // A previous account's pending request must not update global error UI.
        latestRefreshBatch = UUID()
        isRefreshing = false
        lastRefreshError = nil
        consecutiveRefreshFailures = 0
        hasCredentialError = false
        lastSuccessfulRefreshTime = nil

        // 1. Load saved data from new profile (for immediate display)
        await MainActor.run {
            if let savedUsage = profile.claudeUsage {
                self.usage = savedUsage
            } else {
                self.usage = .empty
            }

            if let savedAPIUsage = profile.apiUsage {
                self.apiUsage = savedAPIUsage
            } else {
                self.apiUsage = nil
            }

            if profile.providerKind == .claude {
                self.providerSnapshot = nil
            } else {
                self.providerSnapshot = self.cachedProviderSnapshots[profile.id] ?? .empty(for: profile.providerKind)
            }
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        // IMPORTANT: In multi-profile mode, we update all icons, not just switch config
        if profileManager.displayMode == .multi {
            // Multi-profile mode - update icons without recreating status items
            updateMultiProfileDisplay()
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(with: profile.iconConfig)
        }

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh only if credentials are available
        if shouldAttemptUsageRefresh(for: profile) {
            self.lastRefreshTriggerTime = Date()
            refreshUsage()
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without available credentials")
        }
    }

    private func recreatePopover() {
        // Close existing popover if open
        if popover?.isShown == true {
            closePopover()
        }

        // Recreate popover with fresh content
        let newPopover = NSPopover()
        newPopover.contentSize = preferredPopoverSize()
        newPopover.behavior = .semitransient
        // Disabled to avoid an infinite layout-recursion crash on macOS 26/27.
        // The hosting controller's sizingOptions/preferredContentSize (PR #200)
        // keep the popover sized to its content; with animation on, each animated
        // resize re-triggers layout (updateAnimatedWindowSize -> setFrame -> layout)
        // and never converges, overflowing the main-thread stack. Disabling only the
        // animation breaks the loop while preserving content sizing/positioning.
        // See Discussion #64.
        newPopover.animates = false
        newPopover.delegate = self
        newPopover.contentViewController = createContentViewController()

        self.popover = newPopover

        LoggingService.shared.log("MenuBarManager: Popover recreated for profile switch")
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        // Check if the active profile has any usable credentials available.
        let hasUsageCredentials = hasAnyAvailableCredentials()

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = preferredPopoverSize()
        popover.behavior = .semitransient  // Changed to allow detaching
        // Disabled to avoid an infinite layout-recursion crash on macOS 26/27.
        // The hosting controller's sizingOptions/preferredContentSize (PR #200)
        // keep the popover sized to its content; with animation on, each animated
        // resize re-triggers layout (updateAnimatedWindowSize -> setFrame -> layout)
        // and never converges, overflowing the main-thread stack. Disabling only the
        // animation breaks the loop while preserving content sizing/positioning.
        // See Discussion #64.
        popover.animates = false
        popover.delegate = self

        popover.contentViewController = createContentViewController()
        self.popover = popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshPopoverUsage()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.preferredContentSize = preferredPopoverSize()
        hostingController.sizingOptions = .preferredContentSize
        return hostingController
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Right-click → context menu instead of toggling the popover (upstream c6c962f)
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(for: sender as? NSStatusBarButton)
            return
        }

        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }

        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           let profileId = statusBarUIManager?.profileId(for: button),
           let profile = profileManager.profiles.first(where: { $0.id == profileId }) {
            // Set the clicked profile data
            clickedProfileId = profileId
            clickedProfileUsage = profile.claudeUsage ?? .empty
            clickedProfileAPIUsage = profile.apiUsage
            clickedProfileSnapshot = profile.providerKind == .claude
                ? nil
                : (cachedProviderSnapshots[profile.id] ?? .empty(for: profile.providerKind))
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = profileManager.activeProfile?.id
            clickedProfileUsage = nil  // Will use manager.usage
            clickedProfileAPIUsage = nil  // Will use manager.apiUsage
            clickedProfileSnapshot = nil
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            return
        }

        // Otherwise toggle the popover
        if let popover = popover {
            popover.contentSize = preferredPopoverSize()
            if popover.isShown {
                // Check if clicking the same button or a different one
                if currentPopoverButton === button {
                    // Same button - close the popover
                    closePopover()
                } else {
                    // Different button - close current and show at new position
                    popover.close()
                    stopMonitoringForOutsideClicks()
                    popover.contentSize = preferredPopoverSize()
                    showPopover(popover, from: button)
                    currentPopoverButton = button
                    startMonitoringForOutsideClicks()
                    refreshPopoverUsage()
                }
            } else {
                // Popover not shown - show it.
                // Guard against the dismiss/re-open race: if the popover was just
                // closed (e.g. the outside-click monitor handled this same click a
                // moment before the button action fired), treat this click as the
                // dismissing click and don't immediately re-open it.
                if Date().timeIntervalSince(lastPopoverCloseDate) < 0.25 {
                    return
                }
                // Stop any existing monitor first
                stopMonitoringForOutsideClicks()
                // Update content view controller for current profile data
                popover.contentViewController = createContentViewController()
                popover.contentSize = preferredPopoverSize()
                showPopover(popover, from: button)
                currentPopoverButton = button
                startMonitoringForOutsideClicks()
                refreshPopoverUsage()
            }
        }
    }

    /// Shows `popover` anchored to a status bar button and gives its backing window
    /// the Space placement a menu bar popover needs to appear over a full-screen app.
    private func showPopover(_ popover: NSPopover, from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.enableDisplayOnFullScreenSpaces()
            // AppKit hands initial key focus to the first focusable control in
            // the popover, drawing a focus ring. Nothing in the popover needs
            // initial keyboard focus, so drop first responder to the window itself.
            window.makeFirstResponder(nil)
        }
    }

    /// Shows a lightweight context menu (Refresh / Settings / Quit) anchored to the
    /// status bar button that received the right-click.
    private func showContextMenu(for button: NSStatusBarButton?) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "common.refresh".localized, action: #selector(contextMenuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "common.settings".localized, action: #selector(preferencesClicked), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "common.quit".localized, action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        if let button, let window = button.window {
            let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            menu.popUp(positioning: nil, at: NSPoint(x: screenRect.origin.x, y: screenRect.origin.y), in: nil)
        }
    }

    @objc private func contextMenuRefresh() {
        refreshUsage()
    }

    private func preferredPopoverSize() -> NSSize {
        let visibleProfileCount = max(popoverDisplayProfiles().count, 1)
        let computedHeight = Constants.WindowSizes.expandedPopoverBaseHeight
            + (CGFloat(visibleProfileCount) * Constants.WindowSizes.expandedPopoverSectionHeight)

        return NSSize(
            width: Constants.WindowSizes.expandedPopoverWidth,
            height: min(Constants.WindowSizes.expandedPopoverMaxHeight, computedHeight)
        )
    }

    private func closePopover() {
        popover?.close()
        stopMonitoringForOutsideClicks()
        currentPopoverButton = nil
        lastPopoverCloseDate = Date()
    }

    private func startMonitoringForOutsideClicks() {
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.close()
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        // Check if in multi-profile mode
        if profileManager.displayMode == .multi {
            // Update multi-profile icons using profiles from profileManager
            let config = profileManager.multiProfileConfig
            let selectedProfiles = profileManager.getSelectedProfiles()
            let snapshots = multiProfileSnapshots(for: selectedProfiles)
            statusBarUIManager?.updateMultiProfileButtons(
                profiles: selectedProfiles,
                snapshots: snapshots,
                config: config
            )
        } else {
            guard let activeProfile = profileManager.activeProfile else { return }

            if activeProfile.providerKind == .claude {
                statusBarUIManager?.updateAllButtons(
                    usage: usage,
                    apiUsage: apiUsage
                )
            } else {
                let snapshot = providerSnapshot
                    ?? cachedProviderSnapshots[activeProfile.id]
                    ?? .empty(for: activeProfile.providerKind)

                statusBarUIManager?.updateAllButtons(
                    snapshot: snapshot,
                    profile: activeProfile
                )
            }
        }
    }

    /// Updates a specific metric's status bar icon
    private func updateStatusBarIcon(for metricType: MenuBarMetricType) {
        statusBarUIManager?.updateButton(
            for: metricType,
            usage: usage,
            apiUsage: apiUsage
        )
    }

    // Legacy method kept for backwards compatibility (now uses new system)
    private func updateStatusButton(_ button: NSStatusBarButton, usage: ClaudeUsage) {
        // This method is deprecated but kept for any remaining references
        // The new system handles updates through updateAllStatusBarIcons()
        updateAllStatusBarIcons()
    }

    // MARK: - Icon Style: Battery (Classic)

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.lastAutoRefreshTime = Date()
            self?.refreshUsage()
        }
        refreshTimer?.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
        LoggingService.shared.log("Started auto-refresh with interval: \(interval)s")
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Debounce: only refresh if at least 10 seconds since last auto-refresh
            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastAutoRefreshTime)
            guard timeSinceLastRefresh > 10 else {
                LoggingService.shared.log("MenuBarManager: Skipping wake refresh (debounce)")
                return
            }
            LoggingService.shared.log("MenuBarManager: Wake from sleep detected, refreshing after delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.lastAutoRefreshTime = Date()
                self?.refreshUsage()
            }
        }
    }

    private func restartAutoRefresh() {
        // Invalidate existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Start new timer with updated interval
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        // Observe the same UserDefaults instance that DataStore uses
        refreshIntervalObserver = dataStore.userDefaults.observe(\.refreshInterval, options: [.new]) { [weak self] _, change in
            if let newValue = change.newValue, newValue > 0 {
                DispatchQueue.main.async {
                    self?.restartAutoRefresh()
                }
            }
        }
    }

    private func observeIconStyleChanges() {
        // Observe icon style changes from settings (now consolidated with menuBarIconConfigChanged)
        iconStyleObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Clear cache to force redraw with new style
            self.cachedImageKey = ""
            self.updateAllStatusBarIcons()
        }
    }

    private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                // In multi-profile mode, never rebuild the single-profile status items.
                if self.profileManager.displayMode == .multi {
                    self.updateMultiProfileDisplay()
                    return
                }

                // Check if active profile has usage credentials
                guard let profile = self.profileManager.activeProfile,
                      self.hasAnyAvailableCredentials(for: profile) else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: config)
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = profile.iconConfig
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage()
            }
        }
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    // Multi-profile mode - update icons without recreating status items
                    self.updateMultiProfileDisplay()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeMultiProfileConfigChanges() {
        multiProfileConfigObserver = NotificationCenter.default.addObserver(
            forName: .multiProfileConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.updateMultiProfileDisplay()
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Observe display mode changes (single/multi profile)
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func handleDisplayModeChange() {
        let displayMode = profileManager.displayMode

        LoggingService.shared.log("MenuBarManager: Display mode changed to \(displayMode.rawValue)")

        if displayMode == .multi {
            // Switch to multi-profile mode
            setupMultiProfileMode()
        } else {
            // Switch back to single profile mode
            setupSingleProfileMode()
        }
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    /// Checks whether the given profile has any credentials that can currently
    /// be used to fetch usage. For Claude we allow a fallback to the system
    /// Claude CLI credentials, but only for the active profile.
    private func hasAnyAvailableCredentials(for profile: Profile? = nil) -> Bool {
        guard let profile = profile ?? profileManager.activeProfile else { return false }

        if profile.hasUsageCredentials {
            return true
        }

        guard profile.providerKind == .claude,
              profile.id == profileManager.activeProfile?.id else {
            return false
        }

        // Counts an expired-but-refreshable login too, so an idle CLI after sleep
        // gets refreshed instead of leaving the tracker dormant (#268).
        return ClaudeCodeSyncService.shared.hasUsableSystemCredentials(for: profile)
    }

    private func setupMultiProfileMode() {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            config: config,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let snapshots = self.multiProfileSnapshots(for: selectedProfiles)
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: selectedProfiles,
                snapshots: snapshots,
                config: config
            )
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        // Refresh data for all selected profiles that have credentials
        refreshAllSelectedProfiles()
    }

    private func updateMultiProfileDisplay() {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.updateMultiProfileConfiguration(
            profiles: selectedProfiles,
            config: config,
            target: self,
            action: #selector(togglePopover)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let snapshots = self.multiProfileSnapshots(for: selectedProfiles)
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: selectedProfiles,
                snapshots: snapshots,
                config: config
            )
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile display updated incrementally with \(selectedProfiles.count) profiles")
    }

    /// Refreshes usage data for all profiles selected for multi-profile display
    private func refreshAllSelectedProfiles() {
        let selectedProfiles = profileManager.profiles.filter {
            $0.isSelectedForDisplay && shouldAttemptUsageRefresh(for: $0)
        }

        guard !selectedProfiles.isEmpty else {
            LoggingService.shared.log("MenuBarManager: No selected profiles with usage credentials to refresh")
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(selectedProfiles.count) selected profiles for multi-profile mode")

        refreshProfiles(selectedProfiles, updateStatusBarIconsForCurrentMode: true)
    }

    /// Profiles that should be available in the popover selector.
    /// In single-profile menu bar mode we still want the popup to expose all
    /// configured provider profiles, not just the active one.
    func popoverDisplayProfiles() -> [Profile] {
        let activeProfileId = profileManager.activeProfile?.id

        let candidates = profileManager.profiles.filter { profile in
            profile.id == activeProfileId
                || profile.providerKind != .claude
                || profile.hasUsageCredentials
        }

        return candidates.sorted { lhs, rhs in
            if lhs.id == activeProfileId { return true }
            if rhs.id == activeProfileId { return false }
            if lhs.providerKind != rhs.providerKind {
                return lhs.providerKind.rawValue < rhs.providerKind.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Returns the latest provider-neutral snapshot for a given profile using
    /// live manager state for the active profile and cached/saved state for the rest.
    func snapshotForPopover(profile: Profile) -> ProviderUsageSnapshot {
        let isActiveProfile = profile.id == profileManager.activeProfile?.id

        switch profile.providerKind {
        case .claude:
            let claudeUsage = isActiveProfile ? usage : (profile.claudeUsage ?? .empty)
            let apiUsage = isActiveProfile ? self.apiUsage : profile.apiUsage
            return ClaudeUsageSnapshotAdapter.snapshot(from: claudeUsage, apiUsage: apiUsage)

        case .codex, .copilot:
            if isActiveProfile, let providerSnapshot {
                return providerSnapshot
            }
            return cachedProviderSnapshots[profile.id] ?? .empty(for: profile.providerKind)
        }
    }

    /// Refreshes every profile surfaced inside the popover so the in-popover
    /// selector can switch instantly without showing stale placeholders.
    func refreshPopoverUsage() {
        let profiles = popoverDisplayProfiles().filter { shouldAttemptUsageRefresh(for: $0) }

        guard !profiles.isEmpty else {
            refreshUsage()
            return
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(profiles.count) profiles for popover display")
        refreshProfiles(profiles, updateStatusBarIconsForCurrentMode: true)
    }

    private func multiProfileSnapshots(for profiles: [Profile]) -> [UUID: ProviderUsageSnapshot] {
        profiles.reduce(into: [UUID: ProviderUsageSnapshot]()) { partialResult, profile in
            partialResult[profile.id] = snapshotForPopover(profile: profile)
        }
    }

    private func refreshProfiles(_ profiles: [Profile], updateStatusBarIconsForCurrentMode: Bool) {
        guard !profiles.isEmpty else { return }
        let requests = profiles.map { refreshRequests.begin(for: $0) }
        let batchID = UUID()
        latestRefreshBatch = batchID
        isRefreshing = true
        let userInitiated = abs(lastRefreshTriggerTime.timeIntervalSinceNow) < 5

        Task { @MainActor in
            async let statusResult = fetchServiceStatus()
            var failures: [AppError] = []
            var successes = 0
            var freshActiveUsage: (ProfileRefreshTracker.Request, ClaudeUsage)?

            for request in requests {
                let profile = request.profile
                guard canCommit(request) else { continue }
                do {
                    if profile.providerKind == .claude {
                        let newUsage = try await fetchUsageForProfile(profile)
                        guard canCommit(request) else { continue }
                        let previous = profileManager.profiles.first { $0.id == profile.id }?.claudeUsage
                        checkAndRecordSessionReset(profileId: profile.id, previousUsage: previous, newUsage: newUsage)
                        checkAndRecordWeeklyReset(profileId: profile.id, previousUsage: previous, newUsage: newUsage)
                        let flags = resetJustRecorded[profile.id] ?? (session: false, weekly: false)
                        if !flags.session { usageHistory.recordSessionPeriodic(for: profile.id, usage: newUsage) }
                        if !flags.weekly { usageHistory.recordWeeklyPeriodic(for: profile.id, usage: newUsage) }
                        resetJustRecorded[profile.id] = (session: false, weekly: false)
                        profileManager.saveClaudeUsage(newUsage, for: profile.id)

                        if let active = profileManager.activeProfile, active.id == profile.id {
                            usage = newUsage
                            freshActiveUsage = (request, newUsage)
                            if StatuslineService.shared.isInstalled {
                                StatuslineService.shared.writeUsageCache(usage: newUsage, profileName: active.name)
                            }
                            NotificationManager.shared.checkAndNotify(
                                usage: newUsage, profileName: active.name, settings: active.notificationSettings
                            )
                        }
                    } else {
                        let snapshot = try await fetchProviderSnapshot(for: profile)
                        guard canCommit(request) else { continue }
                        cachedProviderSnapshots[profile.id] = snapshot
                        usageHistory.recordProviderSnapshot(
                            for: profile.id, provider: profile.providerKind, snapshot: snapshot
                        )
                        if profileManager.activeProfile?.id == profile.id { providerSnapshot = snapshot }
                    }
                    successes += 1
                } catch {
                    guard canCommit(request) else { continue }
                    let appError = AppError.wrap(error)
                    failures.append(appError)
                    ErrorLogger.shared.log(appError, severity: .error)
                    // Keep the last successful cache/history; never synthesize an
                    // empty, freshly-timestamped success from a failed request.
                }

                if profile.providerKind == .claude,
                   let apiSessionKey = profile.apiSessionKey,
                   let orgId = profile.apiOrganizationId {
                    do {
                        let newAPIUsage = try await apiService.fetchAPIUsageData(organizationId: orgId, apiSessionKey: apiSessionKey)
                        guard canCommit(request) else { continue }
                        let previous = profileManager.profiles.first { $0.id == profile.id }?.apiUsage
                        checkAndRecordBillingCycleReset(profileId: profile.id, previousUsage: previous, newUsage: newAPIUsage)
                        profileManager.saveAPIUsage(newAPIUsage, for: profile.id)
                        if profileManager.activeProfile?.id == profile.id { apiUsage = newAPIUsage }
                        successes += 1
                    } catch {
                        guard canCommit(request) else { continue }
                        failures.append(AppError.wrap(error))
                        LoggingService.shared.logError("API usage refresh failed: \(error.localizedDescription)")
                    }
                }
            }

            do {
                let newStatus = try await statusResult
                if latestRefreshBatch == batchID { status = newStatus }
            } catch {
                LoggingService.shared.log("Service status refresh failed: \(error.localizedDescription)")
            }
            guard latestRefreshBatch == batchID else { return }
            isRefreshing = false
            if updateStatusBarIconsForCurrentMode { updateAllStatusBarIcons() }

            if let error = failures.first {
                consecutiveRefreshFailures += 1
                lastRefreshError = error.message
                hasCredentialError = failures.contains { $0.code == .apiUnauthorized || $0.code == .sessionKeyExpired }
                ErrorRecovery.shared.recordFailure(for: .api)
                if userInitiated { ErrorPresenter.shared.showAlert(for: error) }
            } else if successes > 0 {
                consecutiveRefreshFailures = 0
                lastRefreshError = nil
                hasCredentialError = false
                lastSuccessfulRefreshTime = Date()
                ErrorRecovery.shared.recordSuccess(for: .api)
                if userInitiated { showSuccessNotification() }
            }

            if let (request, newUsage) = freshActiveUsage, canCommit(request),
               let active = profileManager.activeProfile, active.id == request.profile.id {
                checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: active)
            }
        }
    }

    private func canCommit(_ request: ProfileRefreshTracker.Request) -> Bool {
        refreshRequests.accepts(request, currentProfiles: profileManager.profiles)
    }

    /// Fetches usage data for a specific profile using its credentials
    private func fetchUsageForProfile(_ profile: Profile) async throws -> ClaudeUsage {
        // Delegate to the provider fetcher which handles the priority chain
        // and supplements overage/credit grant data for CLI OAuth paths.
        return try await claudeFetcher.fetchClaudeUsage(for: profile)
    }

    /// Returns the appropriate fetcher for a given provider kind
    func providerFetcher(for kind: UsageProviderKind) -> UsageProviderFetcher {
        switch kind {
        case .claude:  return claudeFetcher
        case .codex:   return codexFetcher
        case .copilot: return copilotFetcher
        }
    }

    /// Fetches a provider-neutral usage snapshot for any profile
    func fetchProviderSnapshot(for profile: Profile) async throws -> ProviderUsageSnapshot {
        if let snapshotFetcherOverride { return try await snapshotFetcherOverride(profile) }
        let fetcher = providerFetcher(for: profile.providerKind)
        return try await fetcher.fetchUsage(for: profile)
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let hasUsageCredentials = hasAnyAvailableCredentials(for: profile)
        let config = profile.iconConfig

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    func refreshUsage() {
        // In multi-profile mode, refresh ALL selected profiles
        if profileManager.displayMode == .multi {
            refreshAllSelectedProfiles()
            return
        }

        // Single profile mode - refresh only active profile
        guard let profile = profileManager.activeProfile else {
            LoggingService.shared.log("MenuBarManager.refreshUsage: No active profile")
            return
        }

        // Detailed logging
        LoggingService.shared.log("MenuBarManager.refreshUsage called:")
        LoggingService.shared.log("  - Profile: '\(profile.name)'")
        LoggingService.shared.log("  - hasUsageCredentials: \(profile.hasUsageCredentials)")

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard shouldAttemptUsageRefresh(for: profile) else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        refreshProfiles([profile], updateStatusBarIconsForCurrentMode: true)
    }

    private func shouldAttemptUsageRefresh(for profile: Profile) -> Bool {
        if profile.providerKind == .claude {
            return hasAnyAvailableCredentials(for: profile)
        }

        return profile.hasUsageCredentials
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile hit 100% and switches to the next available one
    private func checkAutoSwitchIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        let profileId = currentProfile.id

        // If usage dropped below 100%, clear the flag (session reset)
        if usage.effectiveSessionPercentage < 100.0 {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: usage must be >= 100%
        guard usage.effectiveSessionPercentage >= 100.0 else { return }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Find the next available profile
        guard let nextProfile = findNextAvailableProfile(after: currentProfile) else {
            LoggingService.shared.log("AutoSwitch: All profiles at 100% or unavailable, staying on '\(currentProfile.name)'")
            return
        }

        LoggingService.shared.log("AutoSwitch: Switching from '\(currentProfile.name)' to '\(nextProfile.name)'")

        // Activate the next profile
        let fromName = currentProfile.name
        let toName = nextProfile.name
        let notificationSettings = currentProfile.notificationSettings
        Task {
            await profileManager.activateProfile(nextProfile.id)

            await MainActor.run {
                // Send notification
                NotificationManager.shared.sendAutoSwitchNotification(
                    fromProfile: fromName,
                    toProfile: toName,
                    settings: notificationSettings
                )

                // Post notification for UI reactivity
                NotificationCenter.default.post(name: .autoSwitchProfileTriggered, object: nil)
            }
        }
    }

    /// Finds the next profile with available session capacity, wrapping around
    private func findNextAvailableProfile(after currentProfile: Profile) -> Profile? {
        let profiles = profileManager.profiles
        guard let currentIndex = profiles.firstIndex(where: { $0.id == currentProfile.id }) else { return nil }

        let count = profiles.count
        for offset in 1..<count {
            let index = (currentIndex + offset) % count
            let candidate = profiles[index]

            // Must have usage credentials
            guard candidate.hasUsageCredentials else { continue }

            // If no saved usage data, treat as available
            guard let candidateUsage = candidate.claudeUsage else { return candidate }

            // Must be below 100%
            if candidateUsage.effectiveSessionPercentage < 100.0 {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Reset Detection for History Recording

    /// Normalizes a date to minute precision for comparison (ignores seconds)
    private func normalizeToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Checks if a session reset occurred and records a snapshot if so
    private func checkAndRecordSessionReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownSessionResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.sessionResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownSessionResetTime[profileId] = newResetTime
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Session reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    usageHistory.recordSessionReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.sessionResetTime  // Use original reset time, not normalized
                    )
                }
            }

            // Mark that session reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.session = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownSessionResetTime[profileId] = newResetTime
    }

    /// Checks if a weekly reset occurred and records a snapshot if so
    private func checkAndRecordWeeklyReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownWeeklyResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.weeklyResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownWeeklyResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial weekly reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Weekly reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    usageHistory.recordWeeklyReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.weeklyResetTime  // Use original reset time, not normalized
                    )
                }
            }

            // Mark that weekly reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.weekly = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownWeeklyResetTime[profileId] = newResetTime
    }

    /// Checks if a billing cycle reset occurred and records a snapshot if so
    private func checkAndRecordBillingCycleReset(
        profileId: UUID,
        previousUsage: APIUsage?,
        newUsage: APIUsage
    ) {
        let lastKnown = lastKnownAPIResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.resetsAt)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownAPIResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial API reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Billing cycle reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    usageHistory.recordBillingCycleReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.resetsAt  // Use original reset time, not normalized
                    )
                }
            }
        }

        // Update the last known reset time
        lastKnownAPIResetTime[profileId] = newResetTime
    }

    @objc private func preferencesClicked() {
        // Close the popover or detached window first
        closePopoverOrWindow()

        // If settings window already exists, just bring it to front
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Small delay to ensure smooth transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Temporarily show dock icon for the settings window (like setup wizard)
            NSApp.setActivationPolicy(.regular)

            // Create and show the settings window
            let window = SettingsWindowBuilder.makeWindow(size: Constants.WindowSizes.settingsWindow)
            window.title = "Claude Usage - Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.settingsWindow = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// Shows the GitHub star prompt window
    func showGitHubStarPrompt() {
        // If window already exists, just bring it to front
        if let existingWindow = githubPromptWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Temporarily show dock icon for the prompt window
        NSApp.setActivationPolicy(.regular)

        // Create the GitHub star prompt view
        let promptView = GitHubStarPromptView(
            onStar: { [weak self] in
                self?.handleGitHubStarClick()
            },
            onMaybeLater: { [weak self] in
                self?.handleMaybeLaterClick()
            },
            onDontAskAgain: { [weak self] in
                self?.handleDontAskAgainClick()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 300, height: 145))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        // Store reference
        githubPromptWindow = window

        // Mark that we've shown the prompt
        dataStore.saveLastGitHubStarPromptDate(Date())

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleGitHubStarClick() {
        // Open GitHub repository
        if let url = URL(string: Constants.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }

        // Mark as starred
        dataStore.saveHasStarredGitHub(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleMaybeLaterClick() {
        // Just close the window - the prompt will show again after the reminder interval
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleDontAskAgainClick() {
        // Mark to never show again
        dataStore.saveNeverShowGitHubPrompt(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Feedback Prompt

    /// Shows the feedback collection prompt window
    func showFeedbackPrompt() {
        if let existingWindow = feedbackWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let promptView = FeedbackPromptView(
            onSubmit: { [weak self] _, _, _, _ in
                SharedDataStore.shared.saveHasSubmittedFeedback(true)
                // Close after a brief delay to show the thanks state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.closeFeedbackWindow()
                }
            },
            onRemindLater: { [weak self] in
                SharedDataStore.shared.saveLastFeedbackPromptDate(Date())
                self?.closeFeedbackWindow()
            },
            onDontAskAgain: { [weak self] in
                SharedDataStore.shared.saveNeverShowFeedbackPrompt(true)
                self?.closeFeedbackWindow()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        feedbackWindow = window
        SharedDataStore.shared.saveLastFeedbackPromptDate(Date())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFeedbackWindow() {
        feedbackWindow?.close()
        feedbackWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        // Allow popover to be detached by dragging
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        // Record every close (transient dismiss, outside-click monitor, or
        // explicit close) so togglePopover can debounce the dismissing click
        // and avoid the "click bounces the popover back open" race.
        lastPopoverCloseDate = Date()
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        // Stop monitoring for outside clicks when detaching
        stopMonitoringForOutsideClicks()

        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshPopoverUsage()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Constants.WindowSizes.popoverSize),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(Constants.WindowSizes.popoverSize)
        window.isReleasedWhenClosed = false
        window.level = .floating
        // Allow a torn-off popover to stay on a full-screen app's Space.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isRestorable = false
        window.delegate = self
        window.backgroundColor = .clear

        // Store reference to the detached window
        detachedWindow = window

        return window
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered TIFF data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cachedImageKey = ""
        updateAllStatusBarIcons()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // Hide dock icon again when settings window closes
                NSApp.setActivationPolicy(.accessory)
                settingsWindow = nil
            } else if window == detachedWindow {
                // Clear detached window reference when closed
                detachedWindow = nil
            } else if window == githubPromptWindow {
                // Hide dock icon again when GitHub prompt window closes
                NSApp.setActivationPolicy(.accessory)
                githubPromptWindow = nil
            }
        }
    }
}
