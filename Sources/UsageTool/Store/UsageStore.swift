import AppKit
import Foundation
import Network
import Observation
import SwiftUI

@MainActor
@Observable
final class UsageStore {
    private(set) var states: [ProviderID: ProviderState] = Dictionary(
        uniqueKeysWithValues: ProviderID.allCases.map { ($0, .disconnected) }
    )
    var expandedProviders: Set<ProviderID> = []
    var focusedProvider: ProviderID?
    var settingsTab = SettingsTab.general
    var settingsProvider: ProviderID?
    private(set) var lastSuccessfulRefresh: Date?
    private(set) var isOffline = false
    private(set) var isSleeping = false
    private(set) var manualRefreshGeneration = 0
    private(set) var isStarted = false
    private(set) var codexExecutableResolution: CodexExecutableResolution?
    private(set) var codexExecutableProblem: CodexExecutableProblem?

    var resolvedCodexExecutablePath: String? { codexExecutableResolution?.url.path }

    let settings: AppSettings
    let claudeSnapshotURL: URL
    let claudeHomeURL: URL
    let providerOperationsEnabled: Bool

    @ObservationIgnored private let openRouter: OpenRouterService
    @ObservationIgnored private let codexLocator: CodexExecutableLocator
    @ObservationIgnored private var codex: CodexAppServerClient?
    /// The resolution the live client was built from. A change means the child must be replaced.
    @ObservationIgnored private var codexClientResolution: CodexExecutableResolution?
    @ObservationIgnored private var claudeWatcher: ClaudeSnapshotWatcher?
    @ObservationIgnored private let claudeReader = ClaudeSnapshotReader()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "dev.usagetool.network-monitor")
    @ObservationIgnored private var cadenceTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let monitoringEnabled: Bool
    @ObservationIgnored private let initialRefreshEnabled: Bool
    @ObservationIgnored private let snapshotWatchingEnabled: Bool

    init(
        settings: AppSettings,
        openRouter: OpenRouterService,
        claudeSnapshotURL: URL,
        claudeHomeURL: URL,
        codexLocator: CodexExecutableLocator = CodexExecutableLocator(),
        monitoringEnabled: Bool = true,
        initialRefreshEnabled: Bool = true,
        snapshotWatchingEnabled: Bool = true,
        providerOperationsEnabled: Bool = true
    ) {
        self.settings = settings
        self.openRouter = openRouter
        self.claudeSnapshotURL = claudeSnapshotURL
        self.claudeHomeURL = claudeHomeURL
        self.codexLocator = codexLocator
        self.monitoringEnabled = monitoringEnabled
        self.initialRefreshEnabled = initialRefreshEnabled
        self.snapshotWatchingEnabled = snapshotWatchingEnabled
        self.providerOperationsEnabled = providerOperationsEnabled
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if snapshotWatchingEnabled {
            claudeWatcher = ClaudeSnapshotWatcher(url: claudeSnapshotURL, reader: claudeReader) { [weak self] snapshot in
                self?.accept(snapshot)
            }
            claudeWatcher?.start()
        }
        if monitoringEnabled {
            startNetworkMonitoring()
            startPowerMonitoring()
        }
        scheduleCadence()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.reclassifyStates()
            }
        }
        guard initialRefreshEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.openRouter.hasCredential() { await self.refresh(.openRouter) }
            await self.refresh(.codex)
        }
    }

    func stop() {
        isStarted = false
        cadenceTask?.cancel()
        cadenceTask = nil
        clockTask?.cancel()
        clockTask = nil
        claudeWatcher?.stop()
        claudeWatcher = nil
        pathMonitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        Task { await codex?.disconnect() }
    }

    func stopSynchronouslyForTermination() {
        cadenceTask?.cancel()
        clockTask?.cancel()
        CodexChildProcessRegistry.shared.terminateSynchronously()
    }

    func refreshAll(manual: Bool = false) async {
        guard providerOperationsEnabled else { return }
        guard !isSleeping else { return }
        if isOffline {
            for provider in [ProviderID.codex, .openRouter] {
                guard Self.shouldApplyOfflineError(to: states[provider] ?? .disconnected) else { continue }
                states[provider] = .networkError(previous: states[provider]?.snapshot, message: "Network is offline")
            }
            return
        }
        if manual { manualRefreshGeneration += 1 }
        async let codexRefresh: Void = refresh(.codex, manual: manual)
        async let routerRefresh: Void = refresh(.openRouter, manual: manual)
        _ = await (codexRefresh, routerRefresh)
        if manual {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: "Usage updated",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }

    func refresh(_ provider: ProviderID, manual: Bool = false) async {
        guard providerOperationsEnabled else { return }
        guard !isSleeping else { return }
        switch provider {
        case .codex: await refreshCodex()
        case .claude:
            if let snapshot = await claudeReader.read(from: claudeSnapshotURL) { accept(snapshot) }
        case .openRouter: await refreshOpenRouter(manual: manual)
        }
    }

    func connectOpenRouter(key: String) async throws {
        guard providerOperationsEnabled else { throw LocalValidationOperationError.disabled }
        states[.openRouter] = .loading(previous: states[.openRouter]?.snapshot)
        do {
            let snapshot = try await openRouter.connect(key: key)
            accept(snapshot)
        } catch {
            applyOpenRouterError(error)
            throw error
        }
    }

    func disconnectOpenRouter() async throws {
        guard providerOperationsEnabled else { throw LocalValidationOperationError.disabled }
        try await openRouter.disconnect()
        states[.openRouter] = .disconnected
    }

    func popoverOpened(focusedOn provider: ProviderID?) {
        focusedProvider = provider
        if settings.preferences.refreshOnOpen,
           lastSuccessfulRefresh.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            Task { await refreshAll() }
        }
        if provider != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.focusedProvider = nil
            }
        }
    }

    func openProviderSettings(_ provider: ProviderID) {
        settingsProvider = provider
        settingsTab = .providers
    }

    func toggleExpanded(_ provider: ProviderID) {
        if expandedProviders.contains(provider) { expandedProviders.remove(provider) }
        else { expandedProviders.insert(provider) }
    }

    func snapshot(for provider: ProviderID) -> UsageSnapshot? { states[provider]?.snapshot }

    func headlineWindow(for provider: ProviderID) -> UsageWindow? {
        guard let windows = snapshot(for: provider)?.windows.filter({ $0.remainingFraction != nil }), !windows.isEmpty else { return nil }
        switch settings.preferences.headlineRule {
        case .fiveHour: return windows.first(where: { $0.id == .fiveHour }) ?? windows.first
        case .sevenDay: return windows.first(where: { $0.id == .sevenDay }) ?? windows.first
        case .lowest: return windows.min(by: { ($0.remainingFraction ?? 2) < ($1.remainingFraction ?? 2) })
        }
    }

    func menuBarValue(for provider: ProviderID) -> String {
        guard let state = states[provider] else { return "—" }
        switch state {
        case .loading(let previous) where previous == nil: return "…"
        case .authError, .credentialExpired, .networkError(previous: nil, message: _): return "!"
        case .unavailable: return "—"
        default: break
        }
        if provider == .openRouter {
            guard let balance = state.snapshot?.credits else { return "—" }
            return UsageFormatters.currency(balance.remaining, compact: true)
        }
        return UsageFormatters.percent(headlineWindow(for: provider)?.remainingFraction) ?? "—"
    }

    func menuBarLabel(for provider: ProviderID) -> String {
        let value = menuBarValue(for: provider)
        let format = settings.preferences.itemFormats[provider] ?? .nameAndValue
        let core: String
        switch format {
        case .nameAndValue: core = "\(provider.displayName) \(value)"
        case .valueOnly: core = value
        case .shortName: core = "\(provider.shortName) \(value)"
        }
        let staleSuffix = if case .stale = states[provider] { " ◷" } else { "" }
        let warningPrefix = settings.preferences.showWarningSymbol && isCritical(provider) ? "⚠ " : ""
        return warningPrefix + core + staleSuffix
    }

    // MARK: - Menu-bar scene bindings
    //
    // `MenuBarExtra(isInserted:)` watches its controller's visibility with KVO and pushes the
    // current value back through the binding on *every* scene-graph update, not only when the
    // user adds or removes the item. Mutating `@Observable` preferences from that write-back
    // re-dirties the graph, which produces another write-back, and the app spins forever in
    // `AppGraph.graphDidChange()`: the status items are never installed and no menu-bar click is
    // ever delivered. Both setters below must therefore be strict no-ops for an unchanged value.

    /// Insertion binding for the combined menu-bar item.
    func mainMenuItemBinding() -> Binding<Bool> {
        Binding(get: { [settings] in
            settings.preferences.mainItemVisible
        }, set: { [settings] newValue in
            guard settings.preferences.mainItemVisible != newValue else { return }
            settings.preferences.mainItemVisible = newValue
            settings.normalizeMenuVisibility()
        })
    }

    /// Insertion binding for a provider's optional standalone menu-bar item.
    func separateMenuItemBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(get: { [weak self] in
            self?.shouldShowSeparateMenuItem(provider) ?? false
        }, set: { [weak self] newValue in
            guard let self else { return }
            guard shouldShowSeparateMenuItem(provider) != newValue else { return }
            // While unavailable items are hidden, the item disappearing must not clear the
            // user's stored preference for it.
            if settings.preferences.hideUnavailableItems,
               settings.preferences.separateItems[provider] == true,
               !newValue { return }
            guard settings.preferences.separateItems[provider] != newValue else { return }
            settings.preferences.separateItems[provider] = newValue
            settings.normalizeMenuVisibility()
        })
    }

    func shouldShowSeparateMenuItem(_ provider: ProviderID) -> Bool {
        guard settings.preferences.showProvider[provider] ?? true,
              settings.preferences.separateItems[provider] ?? false else { return false }
        return !(settings.preferences.hideUnavailableItems && isUnavailable(provider))
    }

    func isCritical(_ provider: ProviderID) -> Bool {
        if provider == .openRouter {
            return snapshot(for: provider)?.credits.map { $0.remaining < Thresholds.criticalCredits } ?? false
        }
        return headlineWindow(for: provider)?.remainingFraction.map { $0 < Thresholds.criticalFraction } ?? false
    }

    private func isUnavailable(_ provider: ProviderID) -> Bool {
        switch states[provider] ?? .disconnected {
        case .disconnected, .unavailable: true
        default: false
        }
    }

    var summaryLabel: String {
        let visible = settings.preferences.providerOrder.filter {
            (settings.preferences.showProvider[$0] ?? true) &&
                !(settings.preferences.hideUnavailableItems && isUnavailable($0))
        }
        return visible.map(menuBarValue).joined(separator: " · ")
    }

    var isRefreshing: Bool { states.values.contains(where: \.isLoading) }

    var hasConnectedProvider: Bool {
        states.values.contains { state in
            switch state {
            case .connected, .stale, .partial, .loading(previous: .some),
                 .credentialExpired(_, previous: .some), .networkError(previous: .some, message: _): true
            default: false
            }
        }
    }

    private func refreshCodex() async {
        let previous = states[.codex]?.snapshot
        states[.codex] = .loading(previous: previous)
        guard let resolution = resolveCodexExecutable() else {
            await tearDownCodexClient()
            states[.codex] = .unavailable(reason: codexExecutableProblem?.unavailableReason ?? .executableMissing)
            return
        }
        // A configured path that now resolves elsewhere must not keep talking to the old child.
        if codexClientResolution != resolution { await tearDownCodexClient() }
        if codex == nil {
            codexClientResolution = resolution
            codex = CodexAppServerClient(
                executableURL: resolution.url,
                interpreterDirectories: resolution.interpreterDirectories
            ) { [weak self] snapshot in
                await MainActor.run { self?.accept(snapshot) }
            }
        }
        do {
            guard let snapshot = try await codex?.readSnapshot() else { throw CodexAdapterError.terminated }
            accept(snapshot)
        } catch CodexAdapterError.notSignedIn {
            states[.codex] = .unavailable(reason: .notSignedIn)
        } catch CodexAdapterError.unsupportedAuthMode {
            states[.codex] = .unavailable(reason: .unsupportedAuthMode)
        } catch CodexAdapterError.executableMissing {
            states[.codex] = .unavailable(reason: .executableMissing)
        } catch {
            states[.codex] = .networkError(previous: previous, message: error.localizedDescription)
        }
    }

    private func refreshOpenRouter(manual: Bool) async {
        let previous = states[.openRouter]?.snapshot
        guard await openRouter.hasCredential() else {
            states[.openRouter] = .disconnected
            return
        }
        states[.openRouter] = .loading(previous: previous)
        do {
            accept(try await openRouter.refresh(manual: manual))
        } catch { applyOpenRouterError(error, previous: previous) }
    }

    private func applyOpenRouterError(_ error: Error, previous: UsageSnapshot? = nil) {
        switch error {
        case OpenRouterError.notManagementKey:
            states[.openRouter] = .authError(message: "Not a management key")
        case OpenRouterError.credentialExpired(let date):
            states[.openRouter] = .credentialExpired(expiredAt: date ?? Date(), previous: previous)
        case OpenRouterError.unauthorized, OpenRouterError.forbidden:
            states[.openRouter] = .authError(message: "Key rejected")
        case OpenRouterError.missingCredential:
            states[.openRouter] = .disconnected
        default:
            states[.openRouter] = .networkError(previous: previous, message: error.localizedDescription)
        }
    }

    func accept(_ snapshot: UsageSnapshot) {
        if snapshot.provider == .codex, snapshot.windows.isEmpty {
            states[.codex] = .unavailable(reason: .noUsageData)
            return
        }
        let required = Self.requiredWindows(for: snapshot)
        states[snapshot.provider] = ProviderStateResolver.resolve(
            snapshot: snapshot,
            now: Date(),
            staleAfter: settings.preferences.staleAfter,
            requiredWindows: required
        )
        lastSuccessfulRefresh = max(lastSuccessfulRefresh ?? .distantPast, snapshot.observedAt)
    }

    func reclassifyStates(at now: Date = Date()) {
        for provider in ProviderID.allCases {
            guard let state = states[provider] else { continue }
            states[provider] = Self.reclassified(state, now: now, staleAfter: settings.preferences.staleAfter)
        }
    }

    /// Re-runs discovery and publishes the outcome for Settings. Read-only: it stats files and
    /// never launches anything, so it is safe to call from a view's `task`.
    @discardableResult
    func resolveCodexExecutable() -> CodexExecutableResolution? {
        switch codexLocator.locate(configuredPath: settings.preferences.codexExecutablePath) {
        case .success(let resolution):
            codexExecutableResolution = resolution
            codexExecutableProblem = nil
            return resolution
        case .failure(let problem):
            codexExecutableResolution = nil
            codexExecutableProblem = problem
            return nil
        }
    }

    /// Called when the user edits, browses for, or clears the Codex executable path.
    func codexExecutablePathDidChange() {
        resolveCodexExecutable()
        Task { [weak self] in
            guard let self else { return }
            await self.tearDownCodexClient()
            await self.refresh(.codex, manual: true)
        }
    }

    private func tearDownCodexClient() async {
        await codex?.disconnect()
        codex = nil
        codexClientResolution = nil
    }

    func refreshCadenceDidChange() {
        scheduleCadence()
    }

    private func scheduleCadence() {
        cadenceTask?.cancel()
        guard settings.preferences.refreshCadence != .manual else { return }
        let base = settings.preferences.refreshCadence.rawValue
        cadenceTask = Task { [weak self] in
            while !Task.isCancelled {
                let jittered = max(60, Int(Double(base) * Double.random(in: 0.9 ... 1.1)))
                try? await Task.sleep(for: .seconds(jittered))
                guard let self else { return }
                guard !self.isOffline, !self.isSleeping else { continue }
                await self.refresh(.openRouter)
            }
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = self.isOffline
                self.isOffline = path.status != .satisfied
                if wasOffline, !self.isOffline, !self.isSleeping { await self.refreshAll() }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func startPowerMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSleeping = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSleeping = false
                if !self.isOffline { await self.refreshAll() }
            }
        })
    }

    static func shouldApplyOfflineError(to state: ProviderState) -> Bool {
        switch state {
        case .connected, .stale, .partial, .loading(previous: .some), .networkError:
            true
        case .disconnected, .loading(previous: nil), .unavailable, .authError, .credentialExpired:
            false
        }
    }

    static func requiredWindows(for snapshot: UsageSnapshot) -> [WindowID]? {
        switch snapshot.provider {
        case .claude: [.fiveHour, .sevenDay]
        case .codex: snapshot.windows.map(\.id)
        case .openRouter: nil
        }
    }

    static func reclassified(_ state: ProviderState, now: Date, staleAfter: TimeInterval) -> ProviderState {
        let snapshot: UsageSnapshot
        switch state {
        case .connected(let value), .stale(let value, _), .partial(let value, _): snapshot = value
        case .disconnected, .loading, .unavailable, .authError, .credentialExpired, .networkError:
            return state
        }
        return ProviderStateResolver.resolve(
            snapshot: snapshot,
            now: now,
            staleAfter: staleAfter,
            requiredWindows: requiredWindows(for: snapshot)
        )
    }

#if DEBUG
    /// Seeds UI-only fixtures for an explicitly opted-in local smoke-test launch.
    /// This path never starts provider processes, file watchers, Keychain access, or network monitoring.
    func installLocalValidationScenario(_ scenario: String, now: Date = Date()) {
        settings.preferences.refreshCadence = .manual
        settings.preferences.refreshOnOpen = false
        settings.preferences.mainItemStyle = .iconAndSummary

        switch scenario {
        case "empty":
            states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, .disconnected) })
            lastSuccessfulRefresh = nil
        case "errors":
            let claude = UsageSnapshot(
                provider: .claude,
                source: .claudeCodeStatusLine,
                observedAt: now.addingTimeInterval(-7_200),
                reportedAt: now.addingTimeInterval(-7_200),
                windows: [
                    .fromUsedPercent(88, id: .fiveHour, resetsAt: now.addingTimeInterval(3_600)),
                    .fromUsedPercent(46, id: .sevenDay, resetsAt: now.addingTimeInterval(172_800)),
                ]
            )
            let router = UsageSnapshot(
                provider: .openRouter,
                source: .openRouterCreditsAPI,
                observedAt: now.addingTimeInterval(-120),
                credits: .init(totalCredits: 25, totalUsage: 24.75),
                credential: .init(isManagementKey: true, expiresAt: now.addingTimeInterval(-3_600), label: nil)
            )
            states[.codex] = .unavailable(reason: .notSignedIn)
            states[.claude] = .stale(claude, age: 7_200)
            states[.openRouter] = .credentialExpired(expiredAt: now.addingTimeInterval(-3_600), previous: router)
            lastSuccessfulRefresh = claude.observedAt
        default:
            accept(.init(
                provider: .codex,
                source: .codexAppServer,
                observedAt: now.addingTimeInterval(-45),
                plan: "Plus",
                windows: [
                    .fromUsedPercent(36, id: .fiveHour, resetsAt: now.addingTimeInterval(7_200)),
                    .fromUsedPercent(82, id: .sevenDay, resetsAt: now.addingTimeInterval(345_600)),
                ]
            ))
            accept(.init(
                provider: .claude,
                source: .claudeCodeStatusLine,
                observedAt: now.addingTimeInterval(-90),
                reportedAt: now.addingTimeInterval(-90),
                windows: [
                    .fromUsedPercent(92, id: .fiveHour, resetsAt: now.addingTimeInterval(1_800)),
                ]
            ))
            accept(.init(
                provider: .openRouter,
                source: .openRouterCreditsAPI,
                observedAt: now.addingTimeInterval(-30),
                credits: .init(totalCredits: 50, totalUsage: 31.80),
                credential: .init(isManagementKey: true, expiresAt: now.addingTimeInterval(3 * 86_400), label: nil)
            ))
        }
    }
#endif
}

private enum LocalValidationOperationError: LocalizedError {
    case disabled

    var errorDescription: String? {
        "Provider operations are disabled in the isolated local preview."
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers
    case menuBar
    case about
    var id: Self { self }
}
