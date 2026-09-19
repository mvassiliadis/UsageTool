import Foundation
import Observation
import ServiceManagement

protocol AppPreferencesPersistence: AnyObject {
    func usageToolData(forKey key: String) -> Data?
    func setUsageToolData(_ data: Data, forKey key: String)
}

extension UserDefaults: AppPreferencesPersistence {
    func usageToolData(forKey key: String) -> Data? { data(forKey: key) }
    func setUsageToolData(_ data: Data, forKey key: String) { set(data, forKey: key) }
}

enum RefreshCadence: Int, Codable, CaseIterable, Sendable, Identifiable {
    case manual = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    var id: Int { rawValue }
    var label: String { self == .manual ? "Manually" : "\(rawValue / 60) minutes" }
}

enum HeadlineRule: String, Codable, CaseIterable, Sendable, Identifiable {
    case fiveHour
    case sevenDay
    case lowest
    var id: Self { self }
    var label: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "7-day"
        case .lowest: "Lowest remaining"
        }
    }
}

enum ResetDisplay: String, Codable, CaseIterable, Sendable, Identifiable {
    case countdown
    case time
    var id: Self { self }
}

enum MainItemStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case iconOnly
    case iconAndSummary
    var id: Self { self }
}

enum MenuItemFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case nameAndValue
    case valueOnly
    case shortName
    var id: Self { self }
    var label: String {
        switch self {
        case .nameAndValue: "Name and value"
        case .valueOnly: "Value only"
        case .shortName: "Short name"
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var refreshCadence: RefreshCadence = .fiveMinutes
    var refreshOnOpen = true
    var staleAfter: TimeInterval = 30 * 60
    var headlineRule: HeadlineRule = .fiveHour
    var resetDisplay: ResetDisplay = .countdown
    var launchAtLogin = false
    var showProvider: [ProviderID: Bool] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, true) })
    var mainItemVisible = true
    var mainItemStyle: MainItemStyle = .iconOnly
    var separateItems: [ProviderID: Bool] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, false) })
    var itemFormats: [ProviderID: MenuItemFormat] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, .nameAndValue) })
    var providerOrder: [ProviderID] = ProviderID.allCases
    var showWarningSymbol = true
    var useWarningColor = false
    var hideUnavailableItems = false
    /// An explicit Codex executable override. Empty means automatic discovery
    /// (see `CodexExecutableLocator`), which is the default.
    var codexExecutablePath: String = ""
}

@MainActor
@Observable
final class AppSettings {
    private static let key = "UsageTool.preferences.v1"
    @ObservationIgnored private let persistence: (any AppPreferencesPersistence)?
    @ObservationIgnored private let systemIntegrationEnabled: Bool

    var preferences: AppPreferences {
        didSet {
            // SwiftUI writes `MenuBarExtra(isInserted:)` bindings back on every scene
            // update. Persisting an unchanged value is pure overhead, so skip it.
            guard preferences != oldValue else { return }
            persist()
        }
    }

    init(defaults: (any AppPreferencesPersistence)? = UserDefaults.standard, systemIntegrationEnabled: Bool = true) {
        persistence = defaults
        self.systemIntegrationEnabled = systemIntegrationEnabled
        var migrated = false
        if let data = defaults?.usageToolData(forKey: Self.key),
           var decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            // Builds before executable discovery existed persisted the hardcoded default as if the
            // user had chosen it. No UI could set it, so it is not an explicit override: carrying
            // it forward would pin every upgrading install to a path that usually doesn't exist.
            if decoded.codexExecutablePath == CodexExecutableLocator.legacyDefaultConfiguredPath {
                decoded.codexExecutablePath = ""
                migrated = true
            }
            preferences = decoded
        } else {
            preferences = AppPreferences()
        }
        normalizeMenuVisibility()
        // Assignments inside an initializer bypass `didSet`, so the migration is written explicitly
        // rather than left to whichever later edit happens to persist.
        if migrated { persist() }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard systemIntegrationEnabled else {
            preferences.launchAtLogin = enabled
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            preferences.launchAtLogin = enabled
        } catch {
            preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Repairs menu-bar visibility and provider ordering.
    ///
    /// This is called from binding setters that SwiftUI invokes on every scene update, so it
    /// must be idempotent: it writes `preferences` at most once, and only when the normalized
    /// value actually differs. Writing an `@Observable` property unconditionally re-dirties the
    /// scene graph and live-locks the app before any status item is installed.
    func normalizeMenuVisibility() {
        var normalized = preferences
        if !normalized.mainItemVisible,
           !normalized.separateItems.values.contains(true) {
            normalized.mainItemVisible = true
        }
        let known = Set(ProviderID.allCases)
        var order = normalized.providerOrder.filter { known.contains($0) }
        for provider in ProviderID.allCases where !order.contains(provider) {
            order.append(provider)
        }
        normalized.providerOrder = order
        guard normalized != preferences else { return }
        preferences = normalized
    }

    private func persist() {
        guard let persistence, let data = try? JSONEncoder().encode(preferences) else { return }
        persistence.setUsageToolData(data, forKey: Self.key)
    }
}
