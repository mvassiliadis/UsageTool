import Foundation
import Testing
@testable import UsageTool

private final class MemoryPreferencesStore: AppPreferencesPersistence {
    private var values: [String: Data] = [:]

    func usageToolData(forKey key: String) -> Data? { values[key] }
    func setUsageToolData(_ data: Data, forKey key: String) { values[key] = data }
}

@MainActor
struct DomainTests {
    @Test func remainingPercentageIsClampedAndRawValuePreserved() {
        let over = UsageWindow.fromUsedPercent(125, id: .fiveHour, resetsAt: nil)
        #expect(over.usedPercent == 125)
        #expect(over.remainingFraction == 0)
        let under = UsageWindow.fromUsedPercent(-20, id: .sevenDay, resetsAt: nil)
        #expect(under.remainingFraction == 1)
    }

    @Test func elapsedResetExpiresInsteadOfFabricatingCapacity() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow.fromUsedPercent(80, id: .fiveHour, resetsAt: now.addingTimeInterval(-1))
        #expect(window.expiringIfNeeded(at: now).remainingFraction == nil)
    }

    @Test func missingAndReportedZeroRemainDistinct() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            provider: .claude,
            source: .claudeCodeStatusLine,
            observedAt: now,
            windows: [.fromUsedPercent(100, id: .fiveHour, resetsAt: now.addingTimeInterval(100))]
        )
        let state = ProviderStateResolver.resolve(snapshot: snapshot, now: now, staleAfter: 1_000, requiredWindows: [.fiveHour, .sevenDay])
        guard case .partial(let normalized, let missing) = state else { Issue.record("Expected partial"); return }
        #expect(normalized.windows[0].remainingFraction == 0)
        #expect(missing == [.sevenDay])
        #expect(UsageFormatters.percent(nil) == nil)
        #expect(UsageFormatters.percent(0) == "0%")
    }

    @Test func staleStateIsIndependentFromPartial() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = UsageSnapshot(provider: .claude, source: .claudeCodeStatusLine, observedAt: now.addingTimeInterval(-500))
        let state = ProviderStateResolver.resolve(snapshot: snapshot, now: now, staleAfter: 100, requiredWindows: [.fiveHour, .sevenDay])
        guard case .stale = state else { Issue.record("Expected stale"); return }
    }

    @Test func settingsPersistenceContainsNoSecretField() throws {
        let defaults = MemoryPreferencesStore()
        let settings = AppSettings(defaults: defaults)
        settings.preferences.refreshCadence = .fifteenMinutes
        let data = try #require(defaults.usageToolData(forKey: "UsageTool.preferences.v1"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.lowercased().contains("key"))
        #expect(!text.contains("sk-or-"))
        #expect(AppSettings(defaults: defaults).preferences.refreshCadence == .fifteenMinutes)
    }

    @Test func compactCurrencyPlacesMagnitudeSuffixNextToLocalizedNumber() {
        let amount = Decimal(12_400)
        #expect(UsageFormatters.currency(amount, compact: true, locale: Locale(identifier: "en_US")) == "$12.4k")
        #expect(UsageFormatters.currency(amount, compact: true, locale: Locale(identifier: "de_DE")) == "12,4k $")
        #expect(UsageFormatters.currency(amount, compact: true, locale: Locale(identifier: "fr_FR")) == "12,4k $US")
    }

    @Test func relativeAgeDoesNotProduceJustNowAgo() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(UsageFormatters.relativeAge(since: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(UsageFormatters.relativeAge(since: now.addingTimeInterval(-90), now: now) == "1m ago")
    }

    @Test func storeLifecycleStartsOnceAndStopsWithoutExternalProviders() async throws {
        let defaults = MemoryPreferencesStore()
        let settings = AppSettings(defaults: defaults)
        settings.preferences.refreshCadence = .manual
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(
            settings: settings,
            openRouter: OpenRouterService(client: OpenRouterClient(), secretStore: MemorySecretStore()),
            claudeSnapshotURL: directory.appendingPathComponent("claude-usage.json"),
            claudeHomeURL: directory.appendingPathComponent("home", isDirectory: true),
            monitoringEnabled: false,
            initialRefreshEnabled: false,
            snapshotWatchingEnabled: false
        )
        store.start()
        #expect(store.isStarted)
        store.start()
        #expect(store.isStarted)
        store.stop()
        #expect(!store.isStarted)
    }

    @Test func clockReclassificationPreservesLoadingAndErrors() {
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = UsageSnapshot(
            provider: .codex,
            source: .codexAppServer,
            observedAt: now.addingTimeInterval(-10),
            windows: [.fromUsedPercent(10, id: .fiveHour, resetsAt: now.addingTimeInterval(100))]
        )
        let loading = ProviderState.loading(previous: snapshot)
        let network = ProviderState.networkError(previous: snapshot, message: "offline")
        #expect(UsageStore.reclassified(loading, now: now, staleAfter: 30) == loading)
        #expect(UsageStore.reclassified(network, now: now, staleAfter: 30) == network)
        let connected = ProviderState.connected(snapshot)
        guard case .connected = UsageStore.reclassified(connected, now: now, staleAfter: 30) else {
            Issue.record("Expected connected state to be re-resolved")
            return
        }
    }

    @Test func codexOneWindowIsCompleteWhileClaudeOneWindowIsPartial() throws {
        let defaults = MemoryPreferencesStore()
        let store = UsageStore(
            settings: AppSettings(defaults: defaults),
            openRouter: OpenRouterService(client: OpenRouterClient(), secretStore: MemorySecretStore()),
            claudeSnapshotURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            claudeHomeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            monitoringEnabled: false,
            initialRefreshEnabled: false
        )
        let window = UsageWindow.fromUsedPercent(20, id: .fiveHour, resetsAt: Date().addingTimeInterval(100))
        store.accept(UsageSnapshot(provider: .codex, source: .codexAppServer, observedAt: Date(), windows: [window]))
        guard case .connected = store.states[.codex] else { Issue.record("Expected complete Codex state"); return }
        store.accept(UsageSnapshot(provider: .claude, source: .claudeCodeStatusLine, observedAt: Date(), windows: [window]))
        guard case .partial(_, let missing) = store.states[.claude] else { Issue.record("Expected partial Claude state"); return }
        #expect(missing == [.sevenDay])
    }

    @Test func unavailableMenuValueAndWarningPreferencesAreDistinct() throws {
        let defaults = MemoryPreferencesStore()
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(
            settings: settings,
            openRouter: OpenRouterService(client: OpenRouterClient(), secretStore: MemorySecretStore()),
            claudeSnapshotURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            claudeHomeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            monitoringEnabled: false,
            initialRefreshEnabled: false
        )
        #expect(store.menuBarValue(for: .codex) == "—")
        store.accept(UsageSnapshot(
            provider: .codex,
            source: .codexAppServer,
            observedAt: Date(),
            windows: [.fromUsedPercent(95, id: .fiveHour, resetsAt: Date().addingTimeInterval(100))]
        ))
        #expect(store.menuBarLabel(for: .codex).hasPrefix("⚠ "))
        settings.preferences.showWarningSymbol = false
        #expect(!store.menuBarLabel(for: .codex).hasPrefix("⚠ "))
    }

    @Test func localValidationScenariosSeedDistinctStatesWithoutProviders() async throws {
        let safeHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = UsageStore(
            settings: AppSettings(defaults: nil, systemIntegrationEnabled: false),
            openRouter: OpenRouterService(
                client: OpenRouterClient(baseURL: URL(string: "https://local-validation.invalid/api/v1")!),
                secretStore: MemorySecretStore()
            ),
            claudeSnapshotURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            claudeHomeURL: safeHome,
            monitoringEnabled: false,
            initialRefreshEnabled: false,
            snapshotWatchingEnabled: false,
            providerOperationsEnabled: false
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        store.installLocalValidationScenario("populated", now: now)
        guard case .connected = store.states[.codex] else { Issue.record("Expected connected Codex fixture"); return }
        guard case .partial(_, let missing) = store.states[.claude] else { Issue.record("Expected partial Claude fixture"); return }
        #expect(missing == [.sevenDay])
        guard case .connected(let router) = store.states[.openRouter] else { Issue.record("Expected connected OpenRouter fixture"); return }
        #expect(router.credits?.remaining == Decimal(string: "18.20"))
        #expect(store.settings.preferences.refreshCadence == .manual)
        #expect(!store.settings.preferences.refreshOnOpen)
        #expect(store.settings.preferences.mainItemVisible)
        #expect(!store.settings.preferences.separateItems.values.contains(true))
        #expect(store.claudeHomeURL == safeHome)
        #expect(!store.providerOperationsEnabled)
        let seededStates = store.states
        await store.refreshAll(manual: true)
        #expect(store.states == seededStates)
        #expect(store.manualRefreshGeneration == 0)

        store.installLocalValidationScenario("errors", now: now)
        guard case .unavailable(reason: .notSignedIn) = store.states[.codex] else { Issue.record("Expected unavailable Codex fixture"); return }
        guard case .stale = store.states[.claude] else { Issue.record("Expected stale Claude fixture"); return }
        guard case .credentialExpired = store.states[.openRouter] else { Issue.record("Expected expired OpenRouter fixture"); return }

        store.installLocalValidationScenario("empty", now: now)
        #expect(store.states.values.allSatisfy { $0 == .disconnected })
    }
}
