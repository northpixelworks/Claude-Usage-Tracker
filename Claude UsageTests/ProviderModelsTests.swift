import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderModelsTests: XCTestCase {

    // MARK: - UsageProviderKind Tests

    func testClaudeDisplayName() {
        XCTAssertEqual(UsageProviderKind.claude.displayName, "Claude")
    }

    func testClaudeIconName() {
        XCTAssertEqual(UsageProviderKind.claude.iconName, "brain.head.profile")
    }

    func testClaudeAccentColor() {
        XCTAssertNotNil(UsageProviderKind.claude.accentColor)
    }

    func testCodexDisplayName() {
        XCTAssertEqual(UsageProviderKind.codex.displayName, "Codex")
    }

    func testCodexIconName() {
        XCTAssertEqual(UsageProviderKind.codex.iconName, "terminal.fill")
    }

    func testCopilotDisplayName() {
        XCTAssertEqual(UsageProviderKind.copilot.displayName, "GitHub Copilot")
    }

    func testCopilotIconName() {
        XCTAssertEqual(UsageProviderKind.copilot.iconName, "airplane")
    }

    func testCaseIterableReturnsAllCases() {
        let allCases = UsageProviderKind.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.claude))
        XCTAssertTrue(allCases.contains(.codex))
        XCTAssertTrue(allCases.contains(.copilot))
    }

    func testIdentifiable() {
        XCTAssertEqual(UsageProviderKind.claude.id, "claude")
        XCTAssertEqual(UsageProviderKind.codex.id, "codex")
        XCTAssertEqual(UsageProviderKind.copilot.id, "copilot")
    }

    func testCodableRoundTrip() throws {
        for kind in UsageProviderKind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(UsageProviderKind.self, from: data)
            XCTAssertEqual(kind, decoded)
        }
    }

    // MARK: - Profile Provider Tests

    func testDefaultProviderKindIsClaude() {
        let profile = Profile(name: "Test")
        XCTAssertEqual(profile.providerKind, .claude)
    }

    func testProfileWithCodexProvider() {
        let profile = Profile(name: "Codex Profile", providerKind: .codex)
        XCTAssertEqual(profile.providerKind, .codex)
        XCTAssertEqual(profile.name, "Codex Profile")
    }

    func testProfileWithCopilotProvider() {
        let creds = ProviderCredentials(
            copilot: CopilotProviderCredentials(githubToken: "ghp_test123")
        )
        let profile = Profile(
            name: "Copilot Profile",
            providerKind: .copilot,
            providerCredentials: creds
        )
        XCTAssertEqual(profile.providerKind, .copilot)
        XCTAssertNotNil(profile.copilotCredentials)
    }

    func testHasUsageCredentialsClaude_withSessionKey() {
        let profile = Profile(
            name: "Claude",
            providerKind: .claude,
            claudeSessionKey: "sk-test",
            organizationId: "org-123"
        )
        XCTAssertTrue(profile.hasUsageCredentials)
    }

    func testHasUsageCredentialsClaude_withoutCredentials() {
        let profile = Profile(name: "Claude", providerKind: .claude)
        XCTAssertFalse(profile.hasUsageCredentials)
    }

    func testHasUsageCredentialsCopilot_withToken() {
        let creds = ProviderCredentials(
            copilot: CopilotProviderCredentials(githubToken: "ghp_token")
        )
        let profile = Profile(
            name: "Copilot",
            providerKind: .copilot,
            providerCredentials: creds
        )
        XCTAssertTrue(profile.hasUsageCredentials)
    }

    func testHasUsageCredentialsCopilot_withoutToken() {
        // Profile with no stored copilot credentials should report none from the profile itself.
        // Note: Profile.hasUsageCredentials also checks CopilotAuthService.shared.hasCLIToken
        // (system singleton), making it environment-dependent. We test the profile-level contract
        // here: no stored credentials means copilotCredentials is nil.
        let profile = Profile(name: "Copilot", providerKind: .copilot)
        XCTAssertNil(profile.copilotCredentials?.githubToken)
        XCTAssertNil(profile.providerCredentials?.copilot)
    }

    // MARK: - ProviderUsageSnapshot Tests

    func testSnapshotCreationWithRows() {
        let rows = [
            makeMetricRow(id: "session", title: "Session", usedPercentage: 45.0),
            makeMetricRow(id: "weekly", title: "Weekly", usedPercentage: 30.0)
        ]
        let fetchDate = Date()
        let snapshot = ProviderUsageSnapshot(
            provider: .claude,
            title: "Claude",
            primaryRows: rows,
            fetchedAt: fetchDate
        )

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.title, "Claude")
        XCTAssertNil(snapshot.subtitle)
        XCTAssertEqual(snapshot.primaryRows.count, 2)
        XCTAssertTrue(snapshot.secondaryCards.isEmpty)
        XCTAssertEqual(snapshot.fetchedAt, fetchDate)
    }

    func testEmptySnapshot() {
        let snapshot = ProviderUsageSnapshot.empty(for: .codex)

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.title, "Codex")
        XCTAssertNil(snapshot.subtitle)
        XCTAssertTrue(snapshot.primaryRows.isEmpty)
        XCTAssertTrue(snapshot.secondaryCards.isEmpty)
    }

    func testSnapshotWithSubtitleAndCards() {
        let card = ProviderSupplementaryCard(
            id: "status",
            kind: .providerStatus(connected: true, statusText: "Connected")
        )
        let snapshot = ProviderUsageSnapshot(
            provider: .copilot,
            title: "Copilot",
            subtitle: "Personal Plan",
            secondaryCards: [card]
        )

        XCTAssertEqual(snapshot.subtitle, "Personal Plan")
        XCTAssertEqual(snapshot.secondaryCards.count, 1)
    }

    // MARK: - ProviderMetricRow Tests

    func testMetricRowDefaults() {
        let row = ProviderMetricRow(id: "test", title: "Test Metric")

        XCTAssertEqual(row.id, "test")
        XCTAssertEqual(row.title, "Test Metric")
        XCTAssertNil(row.tag)
        XCTAssertNil(row.subtitle)
        XCTAssertNil(row.usedPercentage)
        XCTAssertNil(row.remainingPercentage)
        XCTAssertNil(row.resetTime)
        XCTAssertNil(row.periodDuration)
        XCTAssertFalse(row.supportsPaceMarkers)
        XCTAssertEqual(row.accentStyle, .primary)
    }

    func testMetricRowWithAllProperties() {
        let resetTime = Date().addingTimeInterval(3600)
        let row = ProviderMetricRow(
            id: "session",
            title: "Session Usage",
            tag: "weekly",
            subtitle: "5-hour window",
            usedPercentage: 65.0,
            remainingPercentage: 35.0,
            resetTime: resetTime,
            periodDuration: 18000,
            supportsPaceMarkers: true,
            accentStyle: .warning
        )

        XCTAssertEqual(row.id, "session")
        XCTAssertEqual(row.title, "Session Usage")
        XCTAssertEqual(row.tag, "weekly")
        XCTAssertEqual(row.subtitle, "5-hour window")
        XCTAssertEqual(row.usedPercentage, 65.0)
        XCTAssertEqual(row.remainingPercentage, 35.0)
        XCTAssertEqual(row.resetTime, resetTime)
        XCTAssertEqual(row.periodDuration, 18000)
        XCTAssertTrue(row.supportsPaceMarkers)
        XCTAssertEqual(row.accentStyle, .warning)
    }

    // MARK: - MetricAccentStyle Tests

    func testMetricAccentStyleValues() {
        XCTAssertEqual(MetricAccentStyle.primary.rawValue, "primary")
        XCTAssertEqual(MetricAccentStyle.secondary.rawValue, "secondary")
        XCTAssertEqual(MetricAccentStyle.warning.rawValue, "warning")
        XCTAssertEqual(MetricAccentStyle.info.rawValue, "info")
    }

    func testMetricAccentStyleCodable() throws {
        for style in [MetricAccentStyle.primary, .secondary, .warning, .info] {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(MetricAccentStyle.self, from: data)
            XCTAssertEqual(style, decoded)
        }
    }

    // MARK: - ClaudeUsageSnapshotAdapter Tests

    func testAdapterCreatesClaudeSnapshot() {
        let usage = makeClaudeUsage(sessionPercentage: 50.0, weeklyPercentage: 30.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.title, "Claude")
    }

    func testAdapterCreatesSessionAndWeeklyRows() {
        let usage = makeClaudeUsage(sessionPercentage: 45.0, weeklyPercentage: 25.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        XCTAssertGreaterThanOrEqual(snapshot.primaryRows.count, 2)

        let sessionRow = snapshot.primaryRows.first { $0.id == "claude-session" }
        XCTAssertNotNil(sessionRow)
        XCTAssertEqual(sessionRow?.usedPercentage, 45.0)

        let weeklyRow = snapshot.primaryRows.first { $0.id == "claude-weekly" }
        XCTAssertNotNil(weeklyRow)
        XCTAssertEqual(weeklyRow?.usedPercentage, 25.0)
    }

    func testAdapterSessionRowSupportsPaceMarkers() {
        let usage = makeClaudeUsage(sessionPercentage: 10.0, weeklyPercentage: 5.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        let sessionRow = snapshot.primaryRows.first { $0.id == "claude-session" }
        XCTAssertTrue(sessionRow?.supportsPaceMarkers == true)
    }

    func testAdapterWeeklyRowSupportsPaceMarkers() {
        let usage = makeClaudeUsage(sessionPercentage: 10.0, weeklyPercentage: 5.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        let weeklyRow = snapshot.primaryRows.first { $0.id == "claude-weekly" }
        XCTAssertTrue(weeklyRow?.supportsPaceMarkers == true)
    }

    func testAdapterNilApiUsageCreatesNoCards() {
        let usage = makeClaudeUsage(sessionPercentage: 20.0, weeklyPercentage: 10.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        XCTAssertTrue(snapshot.secondaryCards.isEmpty)
    }

    func testAdapterWithApiUsageCreatesCard() {
        let usage = makeClaudeUsage(sessionPercentage: 20.0, weeklyPercentage: 10.0)
        let apiUsage = makeAPIUsage(currentSpendCents: 500, prepaidCreditsCents: 10000)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: apiUsage)

        let apiCard = snapshot.secondaryCards.first { $0.id == "claude-api-usage" }
        XCTAssertNotNil(apiCard)
    }

    func testAdapterWithApiCostCreatesAdditionalCard() {
        let usage = makeClaudeUsage(sessionPercentage: 20.0, weeklyPercentage: 10.0)
        let apiUsage = makeAPIUsage(
            currentSpendCents: 500,
            prepaidCreditsCents: 10000,
            apiTokenCostCents: 123.45
        )

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: apiUsage)

        let costCard = snapshot.secondaryCards.first { $0.id == "claude-api-cost" }
        XCTAssertNotNil(costCard)
    }

    func testAdapterOpusRowIncludedWhenUsed() {
        let usage = makeClaudeUsage(
            sessionPercentage: 20.0,
            weeklyPercentage: 10.0,
            opusWeeklyTokensUsed: 5000,
            opusWeeklyPercentage: 15.0
        )

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        let opusRow = snapshot.primaryRows.first { $0.id == "claude-opus-weekly" }
        XCTAssertNotNil(opusRow)
        XCTAssertEqual(opusRow?.usedPercentage, 15.0)
        XCTAssertEqual(opusRow?.accentStyle, .secondary)
    }

    func testAdapterOpusRowOmittedWhenZero() {
        let usage = makeClaudeUsage(sessionPercentage: 20.0, weeklyPercentage: 10.0)

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        let opusRow = snapshot.primaryRows.first { $0.id == "claude-opus-weekly" }
        XCTAssertNil(opusRow)
    }

    func testAdapterSonnetRowIncludedWhenUsed() {
        let usage = makeClaudeUsage(
            sessionPercentage: 20.0,
            weeklyPercentage: 10.0,
            sonnetWeeklyTokensUsed: 3000,
            sonnetWeeklyPercentage: 8.0
        )

        let snapshot = ClaudeUsageSnapshotAdapter.snapshot(from: usage, apiUsage: nil)

        let sonnetRow = snapshot.primaryRows.first { $0.id == "claude-sonnet-weekly" }
        XCTAssertNotNil(sonnetRow)
        XCTAssertEqual(sonnetRow?.usedPercentage, 8.0)
    }

    // MARK: - ProviderHistory Tests

    func testHistoryPointCreation() {
        let timestamp = Date()
        let point = ProviderHistoryPoint(
            provider: .claude,
            series: .session,
            timestamp: timestamp,
            value: 42.5,
            unit: .percentage
        )

        XCTAssertEqual(point.provider, .claude)
        XCTAssertEqual(point.series, .session)
        XCTAssertEqual(point.timestamp, timestamp)
        XCTAssertEqual(point.value, 42.5)
        XCTAssertEqual(point.unit, .percentage)
        XCTAssertNil(point.resetTime)
        XCTAssertTrue(point.metadata.isEmpty)
    }

    func testHistoryDataFilterByProvider() {
        let points = [
            ProviderHistoryPoint(provider: .claude, series: .session, timestamp: Date(), value: 10),
            ProviderHistoryPoint(provider: .codex, series: .monthly, timestamp: Date(), value: 20),
            ProviderHistoryPoint(provider: .claude, series: .weekly, timestamp: Date(), value: 30)
        ]
        let data = ProviderHistoryData(points: points)

        let claudePoints = data.points(for: .claude)
        XCTAssertEqual(claudePoints.count, 2)

        let codexPoints = data.points(for: .codex)
        XCTAssertEqual(codexPoints.count, 1)
    }

    func testHistoryDataFilterBySeries() {
        let points = [
            ProviderHistoryPoint(provider: .claude, series: .session, timestamp: Date(), value: 10),
            ProviderHistoryPoint(provider: .claude, series: .weekly, timestamp: Date(), value: 20),
            ProviderHistoryPoint(provider: .codex, series: .session, timestamp: Date(), value: 30)
        ]
        let data = ProviderHistoryData(points: points)

        let sessionPoints = data.points(for: .session)
        XCTAssertEqual(sessionPoints.count, 2)

        let weeklyPoints = data.points(for: .weekly)
        XCTAssertEqual(weeklyPoints.count, 1)
    }

    func testHistoryDataFilterByProviderAndSeries() {
        let points = [
            ProviderHistoryPoint(provider: .claude, series: .session, timestamp: Date(), value: 10),
            ProviderHistoryPoint(provider: .claude, series: .weekly, timestamp: Date(), value: 20),
            ProviderHistoryPoint(provider: .codex, series: .session, timestamp: Date(), value: 30)
        ]
        let data = ProviderHistoryData(points: points)

        let filtered = data.points(for: .claude, series: .session)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.value, 10)
    }

    func testHistoryDataSeriesGrouping() {
        let points = [
            ProviderHistoryPoint(provider: .claude, series: .session, timestamp: Date(), value: 10),
            ProviderHistoryPoint(provider: .claude, series: .session, timestamp: Date(), value: 20),
            ProviderHistoryPoint(provider: .claude, series: .weekly, timestamp: Date(), value: 30)
        ]
        let data = ProviderHistoryData(points: points)

        let series = data.series(for: .claude)
        XCTAssertEqual(series.count, 2)

        let sessionSeries = series.first { $0.kind == .session }
        XCTAssertNotNil(sessionSeries)
        XCTAssertEqual(sessionSeries?.points.count, 2)
        XCTAssertEqual(sessionSeries?.provider, .claude)
        XCTAssertEqual(sessionSeries?.displayName, ProviderHistorySeriesKind.session.displayName)
    }

    func testEmptyHistoryData() {
        let data = ProviderHistoryData()

        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(data.count, 0)
        XCTAssertTrue(data.points(for: .claude).isEmpty)
        XCTAssertTrue(data.series(for: .claude).isEmpty)
    }

    func testHistoryDataAddPoint() {
        var data = ProviderHistoryData()
        let point = ProviderHistoryPoint(
            provider: .claude,
            series: .session,
            timestamp: Date(),
            value: 55.0
        )

        data.addPoint(point)

        XCTAssertEqual(data.count, 1)
        XCTAssertFalse(data.isEmpty)
    }

    // MARK: - HistoryValueUnit Tests

    func testHistoryValueUnitRawValues() {
        XCTAssertEqual(HistoryValueUnit.percentage.rawValue, "percentage")
        XCTAssertEqual(HistoryValueUnit.tokens.rawValue, "tokens")
        XCTAssertEqual(HistoryValueUnit.requests.rawValue, "requests")
        XCTAssertEqual(HistoryValueUnit.cents.rawValue, "cents")
        XCTAssertEqual(HistoryValueUnit.dollars.rawValue, "dollars")
        XCTAssertEqual(HistoryValueUnit.count.rawValue, "count")
    }

    // MARK: - ProviderHistorySeriesKind Tests

    func testHistorySeriesKindCases() {
        let allCases = ProviderHistorySeriesKind.allCases
        XCTAssertTrue(allCases.contains(.session))
        XCTAssertTrue(allCases.contains(.weekly))
        XCTAssertTrue(allCases.contains(.monthly))
        XCTAssertTrue(allCases.contains(.billing))
        XCTAssertTrue(allCases.contains(.premiumRequests))
        XCTAssertTrue(allCases.contains(.chatRequests))
        XCTAssertTrue(allCases.contains(.experimental))
    }

    func testHistorySeriesKindDisplayNames() {
        XCTAssertFalse(ProviderHistorySeriesKind.session.displayName.isEmpty)
        XCTAssertFalse(ProviderHistorySeriesKind.weekly.displayName.isEmpty)
        XCTAssertFalse(ProviderHistorySeriesKind.billing.displayName.isEmpty)
    }

    // MARK: - ClaudeHistoryAdapter Tests

    func testSessionResetConvertsToSessionSeries() {
        let resetTime = Date()
        let snapshot = UsageSnapshot(
            resetType: .sessionReset,
            sessionTokensUsed: 5000,
            sessionPercentage: 45.0,
            triggeringResetTime: resetTime
        )

        let points = ClaudeHistoryAdapter.historyPoints(from: snapshot)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.provider, .claude)
        XCTAssertEqual(points.first?.series, .session)
        XCTAssertEqual(points.first?.value, 45.0)
        XCTAssertEqual(points.first?.unit, .percentage)
        XCTAssertEqual(points.first?.resetTime, resetTime)
    }

    func testWeeklyResetConvertsToWeeklySeries() {
        let resetTime = Date()
        let snapshot = UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: 50000,
            weeklyPercentage: 60.0,
            triggeringResetTime: resetTime
        )

        let points = ClaudeHistoryAdapter.historyPoints(from: snapshot)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.provider, .claude)
        XCTAssertEqual(points.first?.series, .weekly)
        XCTAssertEqual(points.first?.value, 60.0)
        XCTAssertEqual(points.first?.unit, .percentage)
    }

    func testBillingCycleResetConvertsToBillingSeries() {
        let resetTime = Date()
        let snapshot = UsageSnapshot(
            resetType: .billingCycle,
            apiSpendCents: 2500,
            apiCurrency: "USD",
            triggeringResetTime: resetTime
        )

        let points = ClaudeHistoryAdapter.historyPoints(from: snapshot)

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.provider, .claude)
        XCTAssertEqual(points.first?.series, .billing)
        XCTAssertEqual(points.first?.value, 2500.0)
        XCTAssertEqual(points.first?.unit, .cents)
        XCTAssertEqual(points.first?.metadata["currency"], "USD")
    }

    func testSessionResetWithNoDataReturnsEmpty() {
        let snapshot = UsageSnapshot(
            resetType: .sessionReset,
            triggeringResetTime: Date()
        )

        let points = ClaudeHistoryAdapter.historyPoints(from: snapshot)

        XCTAssertTrue(points.isEmpty)
    }

    func testWeeklyResetWithNoDataReturnsEmpty() {
        let snapshot = UsageSnapshot(
            resetType: .weeklyReset,
            triggeringResetTime: Date()
        )

        let points = ClaudeHistoryAdapter.historyPoints(from: snapshot)

        XCTAssertTrue(points.isEmpty)
    }

    // MARK: - ProviderCredentials Tests

    func testProviderCredentialsCodableRoundTrip() throws {
        let creds = ProviderCredentials(
            claude: ClaudeProviderCredentials(
                sessionKey: "sk-test-key",
                organizationId: "org-123"
            ),
            codex: CodexProviderCredentials(authSource: .apiKey, apiKey: "codex-key"),
            copilot: CopilotProviderCredentials(githubToken: "ghp_token123")
        )

        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(ProviderCredentials.self, from: data)

        XCTAssertEqual(creds, decoded)
    }

    func testClaudeCredentialsStoreRetrieve() {
        let claudeCreds = ClaudeProviderCredentials(
            sessionKey: "sk-session",
            organizationId: "org-abc",
            cliCredentialsJSON: "{\"token\": \"test\"}"
        )
        let creds = ProviderCredentials(claude: claudeCreds)

        XCTAssertNotNil(creds.claude)
        XCTAssertEqual(creds.claude?.sessionKey, "sk-session")
        XCTAssertEqual(creds.claude?.organizationId, "org-abc")
        XCTAssertEqual(creds.claude?.cliCredentialsJSON, "{\"token\": \"test\"}")
        XCTAssertNil(creds.codex)
        XCTAssertNil(creds.copilot)
    }

    func testClaudeCredentialsComputedProperties() {
        let withClaudeAI = ClaudeProviderCredentials(
            sessionKey: "sk-key",
            organizationId: "org-id"
        )
        XCTAssertTrue(withClaudeAI.hasClaudeAI)
        XCTAssertFalse(withClaudeAI.hasAPIConsole)

        let withAPI = ClaudeProviderCredentials(
            apiSessionKey: "api-key",
            apiOrganizationId: "api-org"
        )
        XCTAssertFalse(withAPI.hasClaudeAI)
        XCTAssertTrue(withAPI.hasAPIConsole)

        let withCLI = ClaudeProviderCredentials(
            cliCredentialsJSON: "{}",
            hasCliAccount: true
        )
        XCTAssertTrue(withCLI.hasCLI)
    }

    func testCodexCredentialsWithAuthJson() {
        let codexCreds = CodexProviderCredentials(authSource: .authJson)
        let creds = ProviderCredentials(codex: codexCreds)

        XCTAssertNotNil(creds.codex)
        XCTAssertEqual(creds.codex?.authSource, .authJson)
        XCTAssertNil(creds.codex?.apiKey)
    }

    func testCodexCredentialsWithApiKey() {
        let codexCreds = CodexProviderCredentials(
            authSource: .apiKey,
            apiKey: "sk-codex-key-123"
        )
        let creds = ProviderCredentials(codex: codexCreds)

        XCTAssertNotNil(creds.codex)
        XCTAssertEqual(creds.codex?.authSource, .apiKey)
        XCTAssertEqual(creds.codex?.apiKey, "sk-codex-key-123")
    }

    func testCopilotCredentialsStoreRetrieve() {
        let copilotCreds = CopilotProviderCredentials(
            githubToken: "ghp_abc123",
            mode: .orgReporting,
            organizationLogin: "my-org"
        )
        let creds = ProviderCredentials(copilot: copilotCreds)

        XCTAssertNotNil(creds.copilot)
        XCTAssertEqual(creds.copilot?.githubToken, "ghp_abc123")
        XCTAssertEqual(creds.copilot?.mode, .orgReporting)
        XCTAssertEqual(creds.copilot?.organizationLogin, "my-org")
    }

    func testCopilotCredentialsDefaultMode() {
        let copilotCreds = CopilotProviderCredentials(githubToken: "ghp_xyz")

        XCTAssertEqual(copilotCreds.mode, .personalExperimental)
        XCTAssertNil(copilotCreds.enterpriseSlug)
        XCTAssertNil(copilotCreds.organizationLogin)
    }

    func testCopilotProviderModeDisplayNames() {
        XCTAssertEqual(CopilotProviderMode.personalExperimental.displayName, "Personal (Experimental)")
        XCTAssertEqual(CopilotProviderMode.orgReporting.displayName, "Organization Reporting")
    }

    func testProviderCredentialsHasAny() {
        let empty = ProviderCredentials()
        XCTAssertFalse(empty.hasAny)

        let withClaude = ProviderCredentials(
            claude: ClaudeProviderCredentials(sessionKey: "sk")
        )
        XCTAssertTrue(withClaude.hasAny)

        let withCodex = ProviderCredentials(
            codex: CodexProviderCredentials()
        )
        XCTAssertTrue(withCodex.hasAny)

        let withCopilot = ProviderCredentials(
            copilot: CopilotProviderCredentials()
        )
        XCTAssertTrue(withCopilot.hasAny)
    }

    // MARK: - Helpers

    private func makeClaudeUsage(
        sessionPercentage: Double,
        weeklyPercentage: Double,
        opusWeeklyTokensUsed: Int = 0,
        opusWeeklyPercentage: Double = 0,
        sonnetWeeklyTokensUsed: Int = 0,
        sonnetWeeklyPercentage: Double = 0
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(sessionPercentage * 1000),
            sessionLimit: 100_000,
            sessionPercentage: sessionPercentage,
            sessionResetTime: Date().addingTimeInterval(3600),
            weeklyTokensUsed: Int(weeklyPercentage * 10_000),
            weeklyLimit: 1_000_000,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: Date().addingTimeInterval(86400),
            opusWeeklyTokensUsed: opusWeeklyTokensUsed,
            opusWeeklyPercentage: opusWeeklyPercentage,
            sonnetWeeklyTokensUsed: sonnetWeeklyTokensUsed,
            sonnetWeeklyPercentage: sonnetWeeklyPercentage,
            sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    private func makeAPIUsage(
        currentSpendCents: Int,
        prepaidCreditsCents: Int,
        apiTokenCostCents: Double? = nil
    ) -> APIUsage {
        APIUsage(
            currentSpendCents: currentSpendCents,
            resetsAt: Date().addingTimeInterval(86400 * 30),
            prepaidCreditsCents: prepaidCreditsCents,
            currency: "USD",
            apiTokenCostCents: apiTokenCostCents,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func makeMetricRow(
        id: String,
        title: String,
        usedPercentage: Double? = nil
    ) -> ProviderMetricRow {
        ProviderMetricRow(
            id: id,
            title: title,
            usedPercentage: usedPercentage
        )
    }
}
