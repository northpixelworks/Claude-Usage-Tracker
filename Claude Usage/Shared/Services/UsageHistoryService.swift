//
//  UsageHistoryService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-01-26.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Service for managing usage history data
@MainActor
class UsageHistoryService {
    static let shared = UsageHistoryService(historyDirectory: UsageHistoryService.defaultHistoryDirectory)

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Key prefix for profile-specific history storage
    private let historyKeyPrefix = "usageHistory_"
    private let lastSessionRecordTimePrefix = "lastSessionRecordTime_"
    private let lastWeeklyRecordTimePrefix = "lastWeeklyRecordTime_"

    /// Maximum snapshots to keep per type (to prevent excessive data)
    private let maxSessionSnapshots = 1000   // ~7 days at 10-min intervals
    private let maxWeeklySnapshots = 500     // ~6 weeks at 2-hour intervals

    /// Recording intervals for periodic snapshots
    private let sessionRecordingInterval: TimeInterval = 10 * 60  // 10 minutes
    private let weeklyRecordingInterval: TimeInterval = 2 * 60 * 60  // 2 hours

    /// Directory for history blobs. nil keeps blobs in `defaults` (test isolation).
    private let historyDirectory: URL?

    /// UserDefaults key marking that the one-time UserDefaults→file migration ran.
    private let historyMigrationDoneKey = "usageHistoryMigratedToFiles_v1"

    init(defaults: UserDefaults = .standard, historyDirectory: URL? = nil) {
        self.defaults = defaults
        self.historyDirectory = historyDirectory
        migrateHistoryToFilesIfNeeded()
    }

    // MARK: - File-Based History Storage (upstream c5d549f / #260)
    // History blobs grow to several MB per profile. In UserDefaults they push the
    // app's domain past the 4 MB CFPreferences limit, after which macOS silently
    // drops ALL writes to it — including profile credentials. Keep them in files.

    static var defaultHistoryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? Constants.ClaudePaths.homeDirectory.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Claude Usage", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private func blobURL(forKey key: String) -> URL? {
        guard let historyDirectory else { return nil }
        if !FileManager.default.fileExists(atPath: historyDirectory.path) {
            try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        }
        return historyDirectory.appendingPathComponent("\(key).json")
    }

    private func readBlob(forKey key: String) -> Data? {
        guard let url = blobURL(forKey: key) else { return defaults.data(forKey: key) }
        return try? Data(contentsOf: url)
    }

    private func writeBlob(_ data: Data, forKey key: String) throws {
        guard let url = blobURL(forKey: key) else {
            defaults.set(data, forKey: key)
            return
        }
        try data.write(to: url, options: [.atomic])
    }

    private func removeBlob(forKey key: String) {
        if let url = blobURL(forKey: key) {
            try? FileManager.default.removeItem(at: url)
        }
        // Best-effort removal of any legacy UserDefaults blob.
        defaults.removeObject(forKey: key)
    }

    /// One-time migration of `usageHistory_*` / `providerHistory_*` blobs out of
    /// UserDefaults into files. A key is removed only after its file was written.
    private func migrateHistoryToFilesIfNeeded() {
        guard historyDirectory != nil, !defaults.bool(forKey: historyMigrationDoneKey) else { return }
        var migrated = 0
        var failed = 0
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(historyKeyPrefix) || key.hasPrefix("providerHistory_") {
            guard let data = value as? Data, let url = blobURL(forKey: key) else { continue }
            do {
                try data.write(to: url, options: [.atomic])
                defaults.removeObject(forKey: key)
                migrated += 1
            } catch {
                failed += 1
                LoggingService.shared.logStorageError("migrateHistoryToFiles(\(key))", error: error)
            }
        }
        if failed == 0 {
            defaults.set(true, forKey: historyMigrationDoneKey)
        }
        LoggingService.shared.logInfo("UsageHistory: migrated \(migrated) history blob(s) from UserDefaults to files")
    }

    // MARK: - Persistent Timestamp Tracking

    /// Gets the last session recording time for a profile (persisted)
    private func getLastSessionRecordTime(for profileId: UUID) -> Date? {
        return defaults.object(forKey: "\(lastSessionRecordTimePrefix)\(profileId.uuidString)") as? Date
    }

    /// Sets the last session recording time for a profile (persisted)
    private func setLastSessionRecordTime(_ date: Date, for profileId: UUID) {
        defaults.set(date, forKey: "\(lastSessionRecordTimePrefix)\(profileId.uuidString)")
    }

    /// Gets the last weekly recording time for a profile (persisted)
    private func getLastWeeklyRecordTime(for profileId: UUID) -> Date? {
        return defaults.object(forKey: "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)") as? Date
    }

    /// Sets the last weekly recording time for a profile (persisted)
    private func setLastWeeklyRecordTime(_ date: Date, for profileId: UUID) {
        defaults.set(date, forKey: "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)")
    }

    // MARK: - Storage Key

    /// Generates the storage key for a specific profile's history
    private func storageKey(for profileId: UUID) -> String {
        return "\(historyKeyPrefix)\(profileId.uuidString)"
    }

    // MARK: - Save/Load History

    /// Saves usage history for a profile
    func saveHistory(_ history: UsageHistoryData, for profileId: UUID) {
        do {
            let data = try encoder.encode(history)
            try writeBlob(data, forKey: storageKey(for: profileId))
            LoggingService.shared.logStorageSave("usageHistory for profile \(profileId.uuidString.prefix(8))")
        } catch {
            LoggingService.shared.logStorageError("saveHistory", error: error)
        }
    }

    /// Loads usage history for a profile
    func loadHistory(for profileId: UUID) -> UsageHistoryData {
        guard let data = readBlob(forKey: storageKey(for: profileId)) else {
            return UsageHistoryData()
        }

        do {
            let history = try decoder.decode(UsageHistoryData.self, from: data)
            return history
        } catch {
            LoggingService.shared.logStorageError("loadHistory", error: error)
            return UsageHistoryData()
        }
    }

    // MARK: - Record Resets

    /// Records a session reset snapshot
    func recordSessionReset(for profileId: UUID, previousUsage: ClaudeUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordSessionReset: No previous usage data to record")
            return
        }

        // Only record if there was actual usage
        guard usage.sessionTokensUsed > 0 || usage.sessionPercentage > 0 else {
            LoggingService.shared.logInfo("recordSessionReset: Skipping snapshot - no usage to record")
            return
        }

        let snapshot = UsageSnapshot.fromSessionReset(usage, resetTime: resetTime)

        var history = loadHistory(for: profileId)
        history.addSnapshot(snapshot)

        // Prune old session snapshots if exceeding limit
        let sessionCount = history.sessionSnapshots.count
        if sessionCount > maxSessionSnapshots {
            let toRemove = sessionCount - maxSessionSnapshots
            let oldestSessions = history.sessionSnapshots.suffix(toRemove)
            let idsToRemove = Set(oldestSessions.map { $0.id })
            history.snapshots.removeAll { idsToRemove.contains($0.id) }
        }

        saveHistory(history, for: profileId)
        LoggingService.shared.logInfo("Recorded session reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.sessionPercentage)% usage")
    }

    /// Records a weekly reset snapshot
    func recordWeeklyReset(for profileId: UUID, previousUsage: ClaudeUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordWeeklyReset: No previous usage data to record")
            return
        }

        // Only record if there was actual usage
        guard usage.weeklyTokensUsed > 0 || usage.weeklyPercentage > 0 else {
            LoggingService.shared.logInfo("recordWeeklyReset: Skipping snapshot - no usage to record")
            return
        }

        let snapshot = UsageSnapshot.fromWeeklyReset(usage, resetTime: resetTime)

        var history = loadHistory(for: profileId)
        history.addSnapshot(snapshot)
        saveHistory(history, for: profileId)

        LoggingService.shared.logInfo("Recorded weekly reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.weeklyPercentage)% usage")
    }

    /// Records a billing cycle reset snapshot
    func recordBillingCycleReset(for profileId: UUID, previousUsage: APIUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordBillingCycleReset: No previous usage data to record")
            return
        }

        // Only record if there was actual spend (keep original logic)
        guard usage.currentSpendCents > 0 else {
            LoggingService.shared.logInfo("recordBillingCycleReset: Skipping snapshot - no spend to record")
            return
        }

        let snapshot = UsageSnapshot.fromBillingCycleReset(usage, resetTime: resetTime)

        var history = loadHistory(for: profileId)
        history.addSnapshot(snapshot)
        saveHistory(history, for: profileId)

        LoggingService.shared.logInfo("Recorded billing cycle snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.formattedUsed) spent")
    }

    // MARK: - Periodic Recording

    /// Records session usage periodically (every 10 minutes)
    func recordSessionPeriodic(for profileId: UUID, usage: ClaudeUsage) {
        let now = Date()

        // Check if enough time has passed since last recording (using persisted timestamp)
        if let lastRecord = getLastSessionRecordTime(for: profileId) {
            let elapsed = now.timeIntervalSince(lastRecord)
            if elapsed < sessionRecordingInterval {
                return  // Not enough time passed
            }
        }

        // Create periodic snapshot
        let snapshot = UsageSnapshot(
            resetType: .sessionReset,
            sessionTokensUsed: usage.sessionTokensUsed,
            sessionPercentage: usage.sessionPercentage,
            triggeringResetTime: now
        )

        var history = loadHistory(for: profileId)
        history.addSnapshot(snapshot)

        // Prune old session snapshots if exceeding limit
        let sessionCount = history.sessionSnapshots.count
        if sessionCount > maxSessionSnapshots {
            let toRemove = sessionCount - maxSessionSnapshots
            let oldestSessions = history.sessionSnapshots.suffix(toRemove)
            let idsToRemove = Set(oldestSessions.map { $0.id })
            history.snapshots.removeAll { idsToRemove.contains($0.id) }
        }

        saveHistory(history, for: profileId)
        setLastSessionRecordTime(now, for: profileId)
        LoggingService.shared.logInfo("Recorded periodic session snapshot: \(usage.sessionPercentage)%")
    }

    /// Records weekly usage periodically (every 2 hours)
    func recordWeeklyPeriodic(for profileId: UUID, usage: ClaudeUsage) {
        let now = Date()

        // Check if enough time has passed since last recording (using persisted timestamp)
        if let lastRecord = getLastWeeklyRecordTime(for: profileId) {
            let elapsed = now.timeIntervalSince(lastRecord)
            if elapsed < weeklyRecordingInterval {
                return  // Not enough time passed
            }
        }

        // Create periodic snapshot
        let snapshot = UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: usage.weeklyTokensUsed,
            weeklyPercentage: usage.weeklyPercentage,
            opusWeeklyTokensUsed: usage.opusWeeklyTokensUsed,
            opusWeeklyPercentage: usage.opusWeeklyPercentage,
            sonnetWeeklyTokensUsed: usage.sonnetWeeklyTokensUsed,
            sonnetWeeklyPercentage: usage.sonnetWeeklyPercentage,
            triggeringResetTime: now
        )

        var history = loadHistory(for: profileId)
        history.addSnapshot(snapshot)

        // Prune old weekly snapshots if exceeding limit
        let weeklyCount = history.weeklySnapshots.count
        if weeklyCount > maxWeeklySnapshots {
            let toRemove = weeklyCount - maxWeeklySnapshots
            let oldestWeekly = history.weeklySnapshots.suffix(toRemove)
            let idsToRemove = Set(oldestWeekly.map { $0.id })
            history.snapshots.removeAll { idsToRemove.contains($0.id) }
        }

        saveHistory(history, for: profileId)
        setLastWeeklyRecordTime(now, for: profileId)
        LoggingService.shared.logInfo("Recorded periodic weekly snapshot: \(usage.weeklyPercentage)%")
    }

    // MARK: - Query Methods

    /// Gets session snapshots for a profile (sorted newest first)
    func getSessionSnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).sessionSnapshots
    }

    /// Gets weekly snapshots for a profile (sorted newest first)
    func getWeeklySnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).weeklySnapshots
    }

    /// Gets billing cycle snapshots for a profile (sorted newest first)
    func getBillingCycleSnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).billingCycleSnapshots
    }

    /// Gets all snapshots for a profile (sorted newest first)
    func getAllSnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).snapshots.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Export

    /// Exports history to file in specified format
    func exportToFile(for profileId: UUID, resetType: ResetType? = nil, format: ExportFormat = .json) {
        let history = loadHistory(for: profileId)
        let content: String
        let fileExtension: String

        switch format {
        case .json:
            if let type = resetType {
                content = history.exportToJSON(for: type) ?? ""
            } else {
                content = history.exportToJSON() ?? ""
            }
            fileExtension = "json"

        case .csv:
            if let type = resetType {
                content = history.exportToCSV(for: type)
            } else {
                content = history.exportToCSV()
            }
            fileExtension = "csv"
        }

        guard !content.isEmpty else {
            LoggingService.shared.logError("Failed to export history")
            return
        }

        // Create save panel
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())

        let typeSuffix = resetType?.rawValue ?? "all"
        savePanel.nameFieldStringValue = "claude-usage-history-\(typeSuffix)-\(dateStr).\(fileExtension)"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    LoggingService.shared.logInfo("Exported history to \(url.path)")
                } catch {
                    LoggingService.shared.logError("Failed to save export file: \(error.localizedDescription)")
                }
            }
        }
    }

    enum ExportFormat {
        case json
        case csv
    }

    // MARK: - Provider-Neutral Recording

    /// Records a provider-neutral usage snapshot for any provider type.
    /// Converts ProviderUsageSnapshot metrics into UsageSnapshot format for unified storage.
    func recordProviderSnapshot(for profileId: UUID, provider: UsageProviderKind, snapshot: ProviderUsageSnapshot) {
        let now = Date()

        // Use session recording interval for throttling
        let throttleKey = "lastProviderRecordTime_\(provider.rawValue)_\(profileId.uuidString)"
        if let lastRecord = defaults.object(forKey: throttleKey) as? Date {
            let elapsed = now.timeIntervalSince(lastRecord)
            if elapsed < sessionRecordingInterval {
                return
            }
        }

        // Create a generic usage snapshot from the provider's primary metric
        guard let primaryRow = snapshot.primaryRows.first else { return }

        let usageSnapshot = UsageSnapshot(
            resetType: .sessionReset,
            sessionTokensUsed: 0,
            sessionPercentage: primaryRow.usedPercentage ?? 0,
            triggeringResetTime: now
        )

        var history = loadHistory(for: profileId)
        history.addSnapshot(usageSnapshot)

        // Prune if needed
        let sessionCount = history.sessionSnapshots.count
        if sessionCount > maxSessionSnapshots {
            let toRemove = sessionCount - maxSessionSnapshots
            let oldestSessions = history.sessionSnapshots.suffix(toRemove)
            let idsToRemove = Set(oldestSessions.map { $0.id })
            history.snapshots.removeAll { idsToRemove.contains($0.id) }
        }

        saveHistory(history, for: profileId)
        defaults.set(now, forKey: throttleKey)
        LoggingService.shared.logInfo("Recorded \(provider.displayName) snapshot for profile \(profileId.uuidString.prefix(8))")
    }

    /// Records provider-neutral history points directly into the provider history store.
    /// This is the preferred method for non-Claude providers.
    func recordProviderHistoryPoints(for profileId: UUID, points: [ProviderHistoryPoint]) {
        guard !points.isEmpty else { return }

        let storageKey = "providerHistory_\(profileId.uuidString)"

        var historyData: ProviderHistoryData
        if let data = readBlob(forKey: storageKey),
           let existing = try? decoder.decode(ProviderHistoryData.self, from: data) {
            historyData = existing
        } else {
            historyData = ProviderHistoryData(points: [])
        }

        historyData.points.append(contentsOf: points)

        // Prune to keep max 2000 points per profile
        if historyData.points.count > 2000 {
            historyData.points = Array(historyData.points.suffix(2000))
        }

        if let encoded = try? encoder.encode(historyData) {
            do {
                try writeBlob(encoded, forKey: storageKey)
            } catch {
                LoggingService.shared.logStorageError("recordProviderHistoryPoints", error: error)
            }
        }

        LoggingService.shared.logInfo("Recorded \(points.count) provider history points for profile \(profileId.uuidString.prefix(8))")
    }

    /// Loads provider-neutral history data for a profile
    func loadProviderHistory(for profileId: UUID) -> ProviderHistoryData {
        let storageKey = "providerHistory_\(profileId.uuidString)"
        guard let data = readBlob(forKey: storageKey) else {
            return ProviderHistoryData(points: [])
        }

        do {
            return try decoder.decode(ProviderHistoryData.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadProviderHistory", error: error)
            return ProviderHistoryData(points: [])
        }
    }

    /// Clears provider-neutral history for a profile
    func clearProviderHistory(for profileId: UUID) {
        let storageKey = "providerHistory_\(profileId.uuidString)"
        removeBlob(forKey: storageKey)
        LoggingService.shared.logInfo("Cleared provider history for profile \(profileId.uuidString.prefix(8))")
    }

    // MARK: - Cleanup

    /// Deletes all history for a profile
    func deleteHistory(for profileId: UUID) {
        removeBlob(forKey: storageKey(for: profileId))
        // Also delete persisted timestamps
        defaults.removeObject(forKey: "\(lastSessionRecordTimePrefix)\(profileId.uuidString)")
        defaults.removeObject(forKey: "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)")
        // Also delete provider-neutral history
        removeBlob(forKey: "providerHistory_\(profileId.uuidString)")
        LoggingService.shared.logInfo("Deleted usage history for profile \(profileId.uuidString.prefix(8))")
    }

    /// Clears all snapshots for a profile but keeps the history structure
    func clearHistory(for profileId: UUID) {
        saveHistory(UsageHistoryData(), for: profileId)
        LoggingService.shared.logInfo("Cleared usage history for profile \(profileId.uuidString.prefix(8))")
    }

    /// Clears snapshots of a specific type for a profile
    func clearHistory(for profileId: UUID, resetType: ResetType) {
        var history = loadHistory(for: profileId)
        history.snapshots.removeAll { $0.resetType == resetType }
        saveHistory(history, for: profileId)
        LoggingService.shared.logInfo("Cleared \(resetType.rawValue) history for profile \(profileId.uuidString.prefix(8))")
    }
}
