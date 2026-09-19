import Foundation
import Testing
@testable import UsageTool

/// Counts writes so a test can assert that a no-op binding write-back never reaches persistence.
private final class CountingPreferencesStore: AppPreferencesPersistence {
    private var values: [String: Data] = [:]
    private(set) var writeCount = 0

    func usageToolData(forKey key: String) -> Data? { values[key] }

    func setUsageToolData(_ data: Data, forKey key: String) {
        writeCount += 1
        values[key] = data
    }
}

/// `withObservationTracking(_:onChange:)` hands its callback a `@Sendable` closure, so the flag it
/// sets needs a reference box.
private final class ChangeFlag: @unchecked Sendable {
    var didChange = false
}

/// Regression coverage for the menu-bar scene live-lock.
///
/// `MenuBarExtra(isInserted:)` pushes the binding's current value back on every scene-graph
/// update. When those setters mutated `@Observable` preferences unconditionally, each write-back
/// invalidated the graph and produced another write-back, so the app never finished a scene update
/// — the status item was never installed and clicks were never delivered. The invariant that keeps
/// the graph settling is: writing the value the getter already reports must not mutate anything.
///
/// MenuBarExtra itself cannot be driven from an automated test, so these tests pin the invariant at
/// the binding and preference layer. Manual verification of the real status item is documented in
/// `Documentation/Manual-Verification.md`.
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

    @Test func mainItemWriteBackOfCurrentValueDoesNotMutateOrPersist() {
        let (store, settings, persistence) = makeStore()
        let binding = store.mainMenuItemBinding()
        let before = settings.preferences
        let writesBefore = persistence.writeCount

        for _ in 0 ..< 10 { binding.wrappedValue = binding.wrappedValue }

        #expect(settings.preferences == before)
        #expect(persistence.writeCount == writesBefore)
    }

    @Test func separateItemWriteBackOfCurrentValueDoesNotMutateOrPersist() {
        let (store, settings, persistence) = makeStore()
        let before = settings.preferences
        let writesBefore = persistence.writeCount

        for provider in ProviderID.allCases {
            let binding = store.separateMenuItemBinding(provider)
            for _ in 0 ..< 10 { binding.wrappedValue = binding.wrappedValue }
        }

        #expect(settings.preferences == before)
        #expect(persistence.writeCount == writesBefore)
    }

    /// The precise property that stops the scene graph from re-dirtying itself.
    @Test func writeBackOfCurrentValueEmitsNoObservationChange() {
        let (store, settings, _) = makeStore()
        let bindings = [store.mainMenuItemBinding()] + ProviderID.allCases.map { store.separateMenuItemBinding($0) }

        for binding in bindings {
            let flag = ChangeFlag()
            withObservationTracking {
                _ = settings.preferences
            } onChange: {
                flag.didChange = true
            }
            binding.wrappedValue = binding.wrappedValue
            #expect(flag.didChange == false)
        }
    }

    @Test func realVisibilityChangesStillApply() {
        let (store, settings, persistence) = makeStore { $0.separateItems[.codex] = true }
        let writesBefore = persistence.writeCount

        store.mainMenuItemBinding().wrappedValue = false
        #expect(settings.preferences.mainItemVisible == false)

        store.separateMenuItemBinding(.claude).wrappedValue = true
        #expect(settings.preferences.separateItems[.claude] == true)
        #expect(store.separateMenuItemBinding(.claude).wrappedValue == true)
        #expect(persistence.writeCount > writesBefore)
    }

    /// Hiding the last item would leave the app unreachable, so normalization restores the main one.
    @Test func hidingEveryItemRestoresTheMainItem() {
        let (store, settings, _) = makeStore()
        store.mainMenuItemBinding().wrappedValue = false
        #expect(settings.preferences.mainItemVisible == true)
    }

    /// An item hidden by `hideUnavailableItems` must not silently clear the user's preference.
    @Test func autoHiddenSeparateItemKeepsStoredPreference() {
        let (store, settings, _) = makeStore {
            $0.hideUnavailableItems = true
            $0.separateItems[.codex] = true
        }
        #expect(store.shouldShowSeparateMenuItem(.codex) == false)

        store.separateMenuItemBinding(.codex).wrappedValue = false

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
