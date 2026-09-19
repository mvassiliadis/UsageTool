import Foundation
import Testing
@testable import UsageTool

/// Counts writes so a test can assert that an unchanged preference never reaches persistence.
private final class CountingPreferencesStore: AppPreferencesPersistence {
    private var values: [String: Data] = [:]
    private(set) var writeCount = 0

    func usageToolData(forKey key: String) -> Data? { values[key] }

    func setUsageToolData(_ data: Data, forKey key: String) {
        writeCount += 1
        values[key] = data
    }
}

/// Coverage for the preference rules behind the menu-bar items.
///
/// The items are `NSStatusItem`s owned by `MenuBarItemsController`, which reads visibility from
/// these preferences and never writes back to them. The status bar itself cannot be driven from an
/// automated test, so these tests pin the rules the controller reads. Manual verification of the
/// real items and popover is documented in `Documentation/Manual-Verification.md`.
@MainActor
struct MenuBarSceneTests {
    private func makeStore(
        _ configure: (inout AppPreferences) -> Void = { _ in }
    ) -> (UsageStore, AppSettings, CountingPreferencesStore) {
        let persistence = CountingPreferencesStore()
        let settings = AppSettings(defaults: persistence, systemIntegrationEnabled: false)
        configure(&settings.preferences)
        let store = UsageStore(
            settings: settings,
            openRouter: OpenRouterService(
                client: OpenRouterClient(baseURL: URL(string: "https://tests.invalid/api/v1")!),
                secretStore: MemorySecretStore()
            ),
            claudeSnapshotURL: URL(fileURLWithPath: "/nonexistent/usagetool-tests/claude-usage.json"),
            claudeHomeURL: URL(fileURLWithPath: "/nonexistent/usagetool-tests/home"),
            monitoringEnabled: false,
            initialRefreshEnabled: false,
            snapshotWatchingEnabled: false,
            providerOperationsEnabled: false
        )
        return (store, settings, persistence)
    }

    @Test func visibilityChangesApplyAndPersist() {
        let (store, settings, persistence) = makeStore { $0.separateItems[.codex] = true }
        let writesBefore = persistence.writeCount

        settings.preferences.mainItemVisible = false
        settings.normalizeMenuVisibility()
        #expect(settings.preferences.mainItemVisible == false)

        settings.preferences.separateItems[.claude] = true
        settings.normalizeMenuVisibility()
        #expect(settings.preferences.separateItems[.claude] == true)
        #expect(store.shouldShowSeparateMenuItem(.claude) == true)
        #expect(persistence.writeCount > writesBefore)
    }

    /// Hiding the last item would leave the app unreachable, so normalization restores the main one.
    @Test func hidingEveryItemRestoresTheMainItem() {
        let (_, settings, _) = makeStore()
        settings.preferences.mainItemVisible = false
        settings.normalizeMenuVisibility()
        #expect(settings.preferences.mainItemVisible == true)
    }

    /// An item hidden by `hideUnavailableItems` is only hidden: the stored preference stands, so
    /// the item comes back by itself once the provider reports again.
    @Test func autoHiddenSeparateItemKeepsStoredPreference() {
        let (store, settings, _) = makeStore {
            $0.hideUnavailableItems = true
            $0.separateItems[.codex] = true
        }

        #expect(store.shouldShowSeparateMenuItem(.codex) == false)
        #expect(settings.preferences.separateItems[.codex] == true)
    }

    @Test func normalizeMenuVisibilityIsIdempotent() {
        let (_, settings, persistence) = makeStore()
        settings.normalizeMenuVisibility()
        let writesBefore = persistence.writeCount
        let before = settings.preferences

        for _ in 0 ..< 10 { settings.normalizeMenuVisibility() }

        #expect(settings.preferences == before)
        #expect(persistence.writeCount == writesBefore)
    }

    @Test func normalizeMenuVisibilityRepairsProviderOrderExactlyOnce() {
        let (_, settings, persistence) = makeStore { $0.providerOrder = [.openRouter] }
        let writesBefore = persistence.writeCount

        settings.normalizeMenuVisibility()

        #expect(settings.preferences.providerOrder.first == .openRouter)
        #expect(Set(settings.preferences.providerOrder) == Set(ProviderID.allCases))
        #expect(persistence.writeCount == writesBefore + 1)
    }

    @Test func unchangedPreferenceAssignmentIsNotPersisted() {
        let (_, settings, persistence) = makeStore()
        let writesBefore = persistence.writeCount

        settings.preferences = settings.preferences

        #expect(persistence.writeCount == writesBefore)
    }
}
