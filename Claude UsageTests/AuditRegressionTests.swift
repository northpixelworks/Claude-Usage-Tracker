import XCTest
@testable import Claude_Usage

@MainActor
private final class MemoryCredentialVault: ProfileCredentialStorage {
    var data: Data?
    var failReads = false
    var failWrites = false
    var corruptWrites = false
    var writeCount = 0

    func loadProfileVault() throws -> Data? {
        if failReads { throw KeychainError.loadFailed(status: -25308) }
        return data
    }
    func saveProfileVault(_ data: Data) throws {
        if failWrites { throw KeychainError.saveFailed(status: -25308) }
        writeCount += 1
        self.data = corruptWrites ? Data("{}".utf8) : data
    }
}

private final class FailingFlushDefaults: UserDefaults {
    nonisolated(unsafe) var failFlush = false
    override func synchronize() -> Bool { failFlush ? false : super.synchronize() }
}

@MainActor
final class ProfileCredentialStorageTests: XCTestCase {
    private func withStore(_ body: (ProfileStore, UserDefaults, MemoryCredentialVault) throws -> Void) throws {
        let suite = "usage-audit-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = MemoryCredentialVault()
        let store = ProfileStore(defaults: defaults, credentialStorage: vault, errorHandler: { _ in })
        try body(store, defaults, vault)
    }

    private func profileWithSecrets() -> Profile {
        Profile(name: "Test", providerCredentials: ProviderCredentials(
            claude: ClaudeProviderCredentials(sessionKey: "nested-session-secret", apiSessionKey: "nested-api-secret", cliCredentialsJSON: "nested-cli-secret"),
            codex: CodexProviderCredentials(apiKey: "codex-secret"),
            copilot: CopilotProviderCredentials(githubToken: "github-secret")
        ), claudeSessionKey: "legacy-session-secret", apiSessionKey: "legacy-api-secret", cliCredentialsJSON: "legacy-cli-secret")
    }

    func testMigratesAllSecretLocationsAndRestoresAfterRelaunch() throws {
        try withStore { store, defaults, vault in
            let original = profileWithSecrets()
            defaults.set(try JSONEncoder().encode([original]), forKey: "profiles_v3")
            XCTAssertEqual(store.loadProfiles(), [original])
            XCTAssertNil(defaults.data(forKey: "profiles_v3"))
            let metadata = try XCTUnwrap(defaults.data(forKey: "profiles_v4"))
            XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("secret"))
            XCTAssertTrue(String(decoding: try XCTUnwrap(vault.data), as: UTF8.self).contains("github-secret"))
            let relaunched = ProfileStore(defaults: defaults, credentialStorage: vault, errorHandler: { _ in })
            XCTAssertEqual(relaunched.loadProfiles(), [original])
        }
    }

    func testFailedMigrationPreservesOriginalPreferencesAndRetries() throws {
        try withStore { store, defaults, vault in
            let original = profileWithSecrets()
            let legacy = try JSONEncoder().encode([original])
            defaults.set(legacy, forKey: "profiles_v3")
            vault.failWrites = true
            XCTAssertEqual(store.loadProfiles(), [original])
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), legacy)
            XCTAssertNil(defaults.data(forKey: "profiles_v4"))
            vault.failWrites = false
            XCTAssertEqual(store.loadProfiles(), [original])
            XCTAssertNil(defaults.data(forKey: "profiles_v3"))
        }
    }

    func testReadBackVerificationPreventsRemovingLegacyCredentials() throws {
        try withStore { store, defaults, vault in
            let original = profileWithSecrets()
            let legacy = try JSONEncoder().encode([original])
            defaults.set(legacy, forKey: "profiles_v3")
            vault.corruptWrites = true
            XCTAssertEqual(store.loadProfiles(), [original])
            XCTAssertEqual(defaults.data(forKey: "profiles_v3"), legacy)
            XCTAssertNil(defaults.data(forKey: "profiles_v4"))
        }
    }

    func testLockedVaultCannotBeOverwrittenByRedactedProfiles() throws {
        try withStore { store, defaults, vault in
            let original = profileWithSecrets()
            try store.saveProfilesSecurely([original])
            let savedVault = vault.data
            let savedMetadata = defaults.data(forKey: "profiles_v4")
            vault.failReads = true
            let relaunched = ProfileStore(defaults: defaults, credentialStorage: vault, errorHandler: { _ in })
            let redacted = relaunched.loadProfiles()
            XCTAssertEqual(redacted.map(\.id), [original.id])
            XCTAssertThrowsError(try relaunched.saveProfilesSecurely(redacted))
            XCTAssertEqual(vault.data, savedVault)
            XCTAssertEqual(defaults.data(forKey: "profiles_v4"), savedMetadata)
            vault.failReads = false
            XCTAssertEqual(relaunched.loadProfiles(), [original])
        }
    }

    func testCredentialUpdateFailureLeavesLastSaveReadable() throws {
        try withStore { store, defaults, vault in
            let original = profileWithSecrets()
            try store.saveProfilesSecurely([original])
            var changed = original
            changed.claudeSessionKey = "replacement-secret"
            vault.failWrites = true
            XCTAssertThrowsError(try store.saveProfilesSecurely([changed]))
            vault.failWrites = false
            XCTAssertEqual(store.loadProfiles(), [original])
        }
    }

    func testFailedPreferencesFlushRetainsBothVaultRevisions() throws {
        let suite = "usage-flush-tests-\(UUID())"
        let defaults = try XCTUnwrap(FailingFlushDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = MemoryCredentialVault()
        let store = ProfileStore(defaults: defaults, credentialStorage: vault, errorHandler: { _ in })
        var original = profileWithSecrets()
        try store.saveProfilesSecurely([original])
        let committedMetadata = try XCTUnwrap(defaults.data(forKey: "profiles_v4"))
        original.claudeSessionKey = "replacement-secret"
        defaults.failFlush = true
        XCTAssertThrowsError(try store.saveProfilesSecurely([original]))
        let revisions = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(vault.data)) as? [String: Any])
        XCTAssertEqual(revisions.count, 2)
        // Simulate a restart that only sees the last durable metadata.
        defaults.set(committedMetadata, forKey: "profiles_v4")
        defaults.failFlush = false
        let restarted = ProfileStore(defaults: defaults, credentialStorage: vault, errorHandler: { _ in })
        XCTAssertEqual(restarted.loadProfiles().first?.claudeSessionKey, "legacy-session-secret")
    }

    func testUsageOnlySavesDoNotRewriteKeychainAndDeletionRemovesSecrets() throws {
        try withStore { store, defaults, vault in
            var profile = profileWithSecrets()
            try store.saveProfilesSecurely([profile])
            let writes = vault.writeCount
            profile.claudeUsage = .empty
            try store.saveProfilesSecurely([profile])
            XCTAssertEqual(vault.writeCount, writes)
            XCTAssertEqual(store.loadProfiles(), [profile])
            try store.saveProfilesSecurely([])
            XCTAssertEqual(store.loadProfiles(), [])
            XCTAssertFalse(String(decoding: try XCTUnwrap(vault.data), as: UTF8.self).contains("secret"))
        }
    }
}

@MainActor
final class AccountIsolationTests: XCTestCase {
    private func credentials(access: String, refresh: String) -> String {
        "{\"claudeAiOauth\":{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}}"
    }

    func testAutomaticSyncRejectsAnotherAccountAndUnknownIdentity() {
        let accountA = credentials(access: "access-a", refresh: "refresh-a")
        let accountB = credentials(access: "access-b", refresh: "refresh-b")
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch(accountA, accountB))
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch(nil, accountB))
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch("{}", accountB))
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch("invalid", accountB))
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch(credentials(access: "", refresh: ""), credentials(access: "", refresh: "")))
    }

    func testAutomaticSyncAcceptsOnlyProvenTokenContinuity() {
        let old = credentials(access: "expired-access", refresh: "same-refresh")
        let refreshed = credentials(access: "fresh-access", refresh: "same-refresh")
        XCTAssertTrue(ClaudeCodeSyncService.credentialsMatch(old, refreshed))
        XCTAssertTrue(ClaudeCodeSyncService.credentialsMatch(refreshed, refreshed))
        XCTAssertFalse(ClaudeCodeSyncService.credentialsMatch(old, credentials(access: "rotated-access", refresh: "rotated-refresh")))
    }

    func testLateResponseCannotReplaceNewerResponseForSameProfile() {
        let tracker = ProfileRefreshTracker()
        let profile = Profile(name: "A")
        let slow = tracker.begin(for: profile)
        let fast = tracker.begin(for: profile)
        XCTAssertTrue(tracker.accepts(fast, currentProfiles: [profile]))
        XCTAssertFalse(tracker.accepts(slow, currentProfiles: [profile]))
    }

    func testRefreshesStayBoundToTheirOriginalProfiles() {
        let tracker = ProfileRefreshTracker()
        let a = Profile(name: "A", claudeSessionKey: "a")
        let b = Profile(name: "B", claudeSessionKey: "b")
        let requestA = tracker.begin(for: a)
        let requestB = tracker.begin(for: b)
        XCTAssertEqual(requestA.profile.id, a.id)
        XCTAssertEqual(requestB.profile.id, b.id)
        XCTAssertTrue(tracker.accepts(requestA, currentProfiles: [b, a]))
        XCTAssertTrue(tracker.accepts(requestB, currentProfiles: [b, a]))
        XCTAssertFalse(tracker.accepts(requestA, currentProfiles: [b]))
    }

    func testChangedCredentialsInvalidatePendingResponseButUsageDoesNot() {
        let tracker = ProfileRefreshTracker()
        var profile = Profile(name: "A", claudeSessionKey: "old")
        let request = tracker.begin(for: profile)
        profile.claudeUsage = .empty
        profile.name = "Renamed"
        XCTAssertTrue(tracker.accepts(request, currentProfiles: [profile]))
        profile.claudeSessionKey = "new"
        XCTAssertFalse(tracker.accepts(request, currentProfiles: [profile]))
    }
}

private final class UsageStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseStatus = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var responseError: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.responseError {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseStatus, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class ProviderFailureRegressionTests: XCTestCase {
    // All stubs are in this one sequential test; other tests never install this protocol.
    func testBothProvidersPropagateHTTPNetworkAndDecodingFailures() async throws {
        let authFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("{\"tokens\":{\"access_token\":\"synthetic-test-token\"}}".utf8).write(to: authFile)
        defer { try? FileManager.default.removeItem(at: authFile) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UsageStubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let codex = CodexUsageProviderFetcher(authService: CodexAuthService(authFileURL: authFile), session: session)
        let copilot = CopilotUsageProviderFetcher(session: session)
        let providers: [(UsageProviderFetcher, Profile, String)] = [
            (codex, Profile(name: "Codex", providerKind: .codex), "{\"rate_limit\":{\"primary_window\":{\"used_percent\":42,\"limit_window_seconds\":18000,\"reset_at\":2000000000}}}"),
            (copilot, Profile(name: "Copilot", providerKind: .copilot, providerCredentials: ProviderCredentials(copilot: CopilotProviderCredentials(githubToken: "synthetic-test-token"))), "{\"copilot_plan\":\"pro\",\"quota_snapshots\":{\"premium_interactions\":{\"entitlement\":100,\"remaining\":58,\"percent_remaining\":58}}}")
        ]
        for (fetcher, profile, validJSON) in providers {
            UsageStubURLProtocol.responseError = nil
            UsageStubURLProtocol.responseStatus = 200
            UsageStubURLProtocol.responseBody = Data(validJSON.utf8)
            let good = try await fetcher.fetchUsage(for: profile)
            XCTAssertEqual(good.primaryRows.first?.usedPercentage, 42)
            for status in [401, 403, 429, 500] {
                UsageStubURLProtocol.responseStatus = status
                do {
                    _ = try await fetcher.fetchUsage(for: profile)
                    XCTFail("\(profile.providerKind) converted HTTP \(status) into a successful snapshot")
                } catch {
                    if status == 401 || status == 403 {
                        XCTAssertEqual((error as? AppError)?.code, .apiUnauthorized)
                    }
                }
            }
            UsageStubURLProtocol.responseStatus = 200
            UsageStubURLProtocol.responseBody = Data("invalid json".utf8)
            do {
                _ = try await fetcher.fetchUsage(for: profile)
                XCTFail("Malformed response must fail")
            } catch { XCTAssertTrue(error is DecodingError) }
            UsageStubURLProtocol.responseError = URLError(.notConnectedToInternet)
            do {
                _ = try await fetcher.fetchUsage(for: profile)
                XCTFail("Offline request must fail")
            } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        }
        UsageStubURLProtocol.responseError = nil
        UsageStubURLProtocol.responseBody = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":13,\"limit_window_seconds\":604800,\"reset_at\":2000000000},\"secondary_window\":null}}".utf8)
        let weeklyOnly = try await codex.fetchUsage(for: Profile(name: "Codex", providerKind: .codex))
        XCTAssertEqual(weeklyOnly.primaryRows.count, 1)
        XCTAssertEqual(weeklyOnly.primaryRows.first?.title, "Weekly Usage")
        XCTAssertEqual(weeklyOnly.primaryRows.first?.tag, "Weekly")
        XCTAssertEqual(weeklyOnly.primaryRows.first?.usedPercentage, 13)
    }

    func testMissingCodexAuthIsNotASuccessfulEmptySnapshot() async throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fetcher = CodexUsageProviderFetcher(authService: CodexAuthService(authFileURL: absent))
        do {
            _ = try await fetcher.fetchUsage(for: Profile(name: "Missing", providerKind: .codex))
            XCTFail("Missing auth must fail")
        } catch { XCTAssertEqual((error as? AppError)?.code, .apiUnauthorized) }
    }
}

@MainActor
final class RefreshCoordinatorRegressionTests: XCTestCase {
    @MainActor
    private final class PendingFetches {
        var continuations: [UUID: CheckedContinuation<ProviderUsageSnapshot, Error>] = [:]
        func fetch(_ profile: Profile) async throws -> ProviderUsageSnapshot {
            try await withCheckedThrowingContinuation { continuations[profile.id] = $0 }
        }
        func complete(_ profile: Profile, result: Result<ProviderUsageSnapshot, Error>) {
            continuations.removeValue(forKey: profile.id)?.resume(with: result)
        }
    }

    private func profile(_ name: String) -> Profile {
        Profile(name: name, providerKind: .copilot,
                providerCredentials: ProviderCredentials(copilot: CopilotProviderCredentials(githubToken: "synthetic-\(name)")))
    }

    private func snapshot(_ value: Double) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(provider: .copilot, title: "Test", primaryRows: [
            ProviderMetricRow(id: "test-quota", title: "Usage", usedPercentage: value)
        ])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Refresh did not reach expected state")
    }

    func testSwitchDuringRequestCannotReplaceNewActiveSnapshot() async throws {
        let suite = "usage-refresh-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults, credentialStorage: MemoryCredentialVault(), errorHandler: { _ in })
        let profiles = ProfileManager(profileStore: store)
        let a = profile("A"), b = profile("B")
        profiles.profiles = [a, b]
        profiles.activeProfile = a
        let pending = PendingFetches()
        let manager = MenuBarManager(profileManager: profiles, usageHistory: UsageHistoryService(defaults: defaults),
                                     snapshotFetcher: { try await pending.fetch($0) }, statusFetcher: { .unknown })
        manager.refreshUsage()
        await waitUntil { pending.continuations[a.id] != nil }
        profiles.activeProfile = b
        manager.refreshUsage()
        await waitUntil { pending.continuations[b.id] != nil }
        pending.complete(b, result: .success(snapshot(20)))
        await waitUntil { !manager.isRefreshing }
        XCTAssertEqual(manager.providerSnapshot?.primaryRows.first?.usedPercentage, 20)
        pending.complete(a, result: .success(snapshot(90)))
        // Allow the old task to run its completion code after the new account.
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(manager.providerSnapshot?.primaryRows.first?.usedPercentage, 20)
        XCTAssertEqual(profiles.activeProfile?.id, b.id)
    }

    func testFailureRetainsLastGoodSnapshotAndSuccessTimestamp() async throws {
        let suite = "usage-refresh-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults, credentialStorage: MemoryCredentialVault(), errorHandler: { _ in })
        let profiles = ProfileManager(profileStore: store)
        let account = profile("A")
        profiles.profiles = [account]
        profiles.activeProfile = account
        var shouldFail = false
        let manager = MenuBarManager(profileManager: profiles, usageHistory: UsageHistoryService(defaults: defaults), snapshotFetcher: { _ in
            if shouldFail { throw AppError(code: .apiUnauthorized, message: "Test authentication failure") }
            return self.snapshot(42)
        }, statusFetcher: { .unknown })
        manager.refreshUsage()
        await waitUntil { !manager.isRefreshing }
        let lastSuccess = try XCTUnwrap(manager.lastSuccessfulRefreshTime)
        shouldFail = true
        manager.refreshUsage()
        await waitUntil { !manager.isRefreshing }
        XCTAssertEqual(manager.providerSnapshot?.primaryRows.first?.usedPercentage, 42)
        XCTAssertEqual(manager.lastSuccessfulRefreshTime, lastSuccess)
        XCTAssertEqual(manager.consecutiveRefreshFailures, 1)
        XCTAssertTrue(manager.hasCredentialError)
        XCTAssertNotNil(manager.lastRefreshError)
    }

    func testMultiProfilePartialFailureIsNotReportedAsSuccess() async throws {
        let suite = "usage-refresh-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults, credentialStorage: MemoryCredentialVault(), errorHandler: { _ in })
        let profiles = ProfileManager(profileStore: store)
        let a = profile("A"), b = profile("B")
        profiles.profiles = [a, b]
        profiles.activeProfile = a
        profiles.displayMode = .multi
        let manager = MenuBarManager(profileManager: profiles, usageHistory: UsageHistoryService(defaults: defaults), snapshotFetcher: { profile in
            if profile.id == b.id { throw URLError(.notConnectedToInternet) }
            return self.snapshot(25)
        }, statusFetcher: { .unknown })
        manager.refreshUsage()
        await waitUntil { !manager.isRefreshing }
        XCTAssertEqual(manager.providerSnapshot?.primaryRows.first?.usedPercentage, 25)
        XCTAssertNil(manager.lastSuccessfulRefreshTime)
        XCTAssertEqual(manager.consecutiveRefreshFailures, 1)
        XCTAssertNotNil(manager.lastRefreshError)
    }
}
