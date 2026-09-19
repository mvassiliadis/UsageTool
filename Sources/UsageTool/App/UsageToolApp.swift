import AppKit
import SwiftUI

@MainActor
final class UsageToolApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: UsageStore?
    /// Nil in the local-validation variant and under XCTest, neither of which installs menu-bar
    /// items. See `MenuBarItemsController` for why the app owns these instead of `MenuBarExtra`.
    var menuBarItems: MenuBarItemsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        store?.start()
        menuBarItems?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarItems?.stop()
        store?.stopSynchronouslyForTermination()
    }

}

@main
struct UsageToolApp: App {
    @NSApplicationDelegateAdaptor(UsageToolApplicationDelegate.self) private var appDelegate
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
        // Neither the test host nor the local-validation variant may touch the real menu bar.
        if !isolatedRuntime { appDelegate.menuBarItems = MenuBarItemsController(store: store) }
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
            // Wrapped exactly as the menu-bar panel wraps it, so the preview shows the real
            // caret and panel outline; the caret is centred because there is no item to aim at.
            PopoverChromeContainer(caretX: DesignTokens.Popover.width / 2) {
                PopoverView()
                    .frame(width: DesignTokens.Popover.width)
                    .frame(minHeight: 520)
            }
            .padding(DesignTokens.Space.x16)
        }
    }
#else
    // The menu-bar items are not scenes: they are `NSStatusItem`s driven by
    // `MenuBarItemsController`, so the popover can be a transparent panel with a caret that
    // points at the item that opened it. Settings stays a scene.
    var body: some Scene {
        Settings {
            SettingsView()
                .environment(store)
                // Backstop for a first open that did not come through `openSettingsWindow`;
                // it fires only once, which is why every call site raises the window as well.
                .onAppear { bringSettingsWindowForward() }
        }
        .windowResizability(.contentSize)
    }
#endif
}
