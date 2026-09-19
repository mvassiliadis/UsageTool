import AppKit
import SwiftUI

@MainActor
final class UsageToolApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: UsageStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        store?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stopSynchronouslyForTermination()
    }

}

@main
struct UsageToolApp: App {
    @NSApplicationDelegateAdaptor(UsageToolApplicationDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @State private var store: UsageStore

    init() {
        let environment = ProcessInfo.processInfo.environment
#if DEBUG && USAGETOOL_LOCAL_VALIDATION_BUILD
        // A validation-variant binary must remain isolated even if it is opened from
        // Finder without the documented launch environment.
        let isolatedRuntime = true
        NSApplication.shared.setActivationPolicy(.regular)
        let settings = AppSettings(defaults: nil, systemIntegrationEnabled: false)
        settings.preferences.refreshCadence = .manual
        settings.preferences.refreshOnOpen = false
        settings.preferences.codexExecutablePath = "/nonexistent/usagetool-validation-codex"
        let support = if let path = environment["USAGETOOL_VALIDATION_SUPPORT_PATH"] {
            URL(fileURLWithPath: path, isDirectory: true)
        } else {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageToolLocalValidation", isDirectory: true)
        }
        let claudeHome = support.appendingPathComponent("home", isDirectory: true)
        let service = OpenRouterService(
            client: OpenRouterClient(baseURL: URL(string: "https://local-validation.invalid/api/v1")!),
            secretStore: MemorySecretStore()
        )
#else
        let isTestHost = environment["XCTestConfigurationFilePath"] != nil
        let isolatedRuntime = isTestHost
        let settings: AppSettings
        let support: URL
        let claudeHome: URL
        let service: OpenRouterService
        if isTestHost {
            settings = AppSettings(defaults: nil, systemIntegrationEnabled: false)
            settings.preferences.refreshCadence = .manual
            settings.preferences.refreshOnOpen = false
            settings.preferences.mainItemVisible = false
            settings.preferences.codexExecutablePath = "/nonexistent/usagetool-test-codex"
            support = FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageToolTestHost", isDirectory: true)
            claudeHome = support.appendingPathComponent("home", isDirectory: true)
            service = OpenRouterService(
                client: OpenRouterClient(baseURL: URL(string: "https://test.invalid/api/v1")!),
                secretStore: MemorySecretStore()
            )
        } else {
            settings = AppSettings()
            support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/UsageTool", isDirectory: true)
            claudeHome = FileManager.default.homeDirectoryForCurrentUser
            service = OpenRouterService(client: OpenRouterClient(), secretStore: KeychainStore())
        }
#endif
        _settings = State(initialValue: settings)
        let store = UsageStore(
            settings: settings,
            openRouter: service,
            claudeSnapshotURL: support.appendingPathComponent("claude-usage.json"),
            claudeHomeURL: claudeHome,
            monitoringEnabled: !isolatedRuntime,
            initialRefreshEnabled: !isolatedRuntime,
            snapshotWatchingEnabled: !isolatedRuntime,
            providerOperationsEnabled: !isolatedRuntime
        )
#if DEBUG && USAGETOOL_LOCAL_VALIDATION_BUILD
        store.installLocalValidationScenario(environment["USAGETOOL_VALIDATION_SCENARIO"] ?? "populated")
#endif
        _store = State(initialValue: store)
        appDelegate.store = store
    }

#if USAGETOOL_LOCAL_VALIDATION_BUILD
    var body: some Scene {
        WindowGroup("UsageTool Local Preview") {
            validationRoot
                .environment(store)
                .preferredColorScheme(validationColorScheme)
        }
        .windowResizability(.contentSize)
    }

    private var validationColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["USAGETOOL_VALIDATION_APPEARANCE"] {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    @ViewBuilder
    private var validationRoot: some View {
        if ProcessInfo.processInfo.environment["USAGETOOL_VALIDATION_WINDOW"] == "settings" {
            SettingsView()
                .frame(width: DesignTokens.Settings.width)
                .frame(minHeight: DesignTokens.Settings.minHeight)
        } else {
            PopoverView()
                .frame(width: DesignTokens.Popover.width)
                .frame(minHeight: 520)
        }
    }
#else
    var body: some Scene {
        MenuBarExtra(isInserted: mainItemBinding) {
            PopoverView().environment(store)
        } label: {
            HStack(spacing: 4) {
                Image("usage.gauge")
                if settings.preferences.mainItemStyle == .iconAndSummary { Text(store.summaryLabel).monospacedDigit() }
            }
            .help("UsageTool · \(store.summaryLabel)")
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: separateBinding(.codex)) {
            PopoverView(focus: .codex).environment(store)
        } label: { menuBarText(.codex) }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: separateBinding(.claude)) {
            PopoverView(focus: .claude).environment(store)
        } label: { menuBarText(.claude) }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: separateBinding(.openRouter)) {
            PopoverView(focus: .openRouter).environment(store)
        } label: { menuBarText(.openRouter) }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                // `LSUIElement` keeps the app at `.accessory` activation policy, so opening the
                // Settings window does not bring the app forward and it can surface behind
                // whatever was frontmost. Activate explicitly when the window appears.
                .onAppear { NSApp.activate() }
        }
        .windowResizability(.contentSize)
    }
#endif

    private var mainItemBinding: Binding<Bool> { store.mainMenuItemBinding() }

    private func separateBinding(_ provider: ProviderID) -> Binding<Bool> {
        store.separateMenuItemBinding(provider)
    }

    private func menuBarText(_ provider: ProviderID) -> some View {
        Text(store.menuBarLabel(for: provider))
            .monospacedDigit()
            .foregroundStyle(settings.preferences.useWarningColor && store.isCritical(provider) ? Color.red : Color.primary)
            .help(menuHelp(provider))
    }

    private func menuHelp(_ provider: ProviderID) -> String {
        "\(provider.displayName) · \(store.menuBarValue(for: provider)) · \(store.states[provider]?.snapshot.map { "Updated \(UsageFormatters.relativeAge(since: $0.effectiveDate, now: Date()))" } ?? "Unavailable")"
    }
}
