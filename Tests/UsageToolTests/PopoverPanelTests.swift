import AppKit
import SwiftUI
import Testing
@testable import UsageTool

/// Regression coverage for the popover a menu-bar item opens.
///
/// These tests install a real `NSStatusItem` through `MenuBarStatusItem` and click its button, so
/// they run the production path — `toggle()`, `present()`, the panel and its hosting controller —
/// rather than a copy of it. The item is removed again as each test ends.
///
/// This is the path that crashed: with `sizingOptions = [.preferredContentSize]` the click did not
/// merely misbehave, it killed the process. AppKit applies a content view controller's preferred
/// size by resizing the window *and displaying it* synchronously, and `PopoverView` changes its
/// own height from inside that layout pass — it measures its provider list and feeds the
/// measurement back into the list's frame — so the pass re-entered itself about 6,800 times until
/// the main thread's 8 MB stack was gone (`EXC_BAD_ACCESS`, "Thread stack size exceeded due to
/// excessive recursion"). Reverting `MenuBarStatusItem.present()` to that option makes every test
/// here crash the test process again, bar the one with no connected provider: that branch of
/// `PopoverView` does not measure itself, which is why the popover only ever crashed for a user
/// who had a provider connected.
@MainActor
@Suite(.serialized)
struct PopoverPanelTests {
    private func makeStore(scenario: String) -> UsageStore {
        let store = UsageStore(
            settings: AppSettings(defaults: nil, systemIntegrationEnabled: false),
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
        store.installLocalValidationScenario(scenario)
        return store
    }

    /// A menu-bar item of this app's own, kept out of the real items' autosaved positions.
    private func makeItem(_ store: UsageStore) -> MenuBarStatusItem {
        MenuBarStatusItem(focus: nil, autosaveName: "dev.usagetool.tests.popover", store: store)
    }

    /// Clicks the item the way the user does, then runs the main run loop so anything the layout
    /// deferred to a later turn is applied before the panel is measured.
    private func click(_ item: MenuBarStatusItem) throws -> MenuBarPanel {
        let button = try #require(item.statusItem.button)
        button.performClick(nil)
        return try #require(openPanel())
    }

    private func openPanel() -> MenuBarPanel? {
        NSApp.windows.compactMap { $0 as? MenuBarPanel }.first { $0.isVisible }
    }

    private func settle() {
        for _ in 0 ..< 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @Test func clickingAnItemWithConnectedProvidersOpensThePopover() throws {
        let item = makeItem(makeStore(scenario: "populated"))
        defer { item.remove() }

        let panel = try click(item)
        settle()

        #expect(panel.frame.width == DesignTokens.Popover.width)
        #expect(panel.frame.height > PopoverChrome.caretHeight)
        #expect(panel.frame.height <= DesignTokens.Popover.maxHeight + PopoverChrome.caretHeight)
    }

    @Test func clickingAnItemWithNoConnectedProviderOpensThePopover() throws {
        let item = makeItem(makeStore(scenario: "empty"))
        defer { item.remove() }

        let panel = try click(item)
        settle()

        #expect(panel.frame.width == DesignTokens.Popover.width)
        #expect(panel.frame.height > PopoverChrome.caretHeight)
    }

    /// The panel must follow its content and stay hung from the menu bar while it does: expanding
    /// a provider row changes the popover's height from inside a layout pass, exactly as the
    /// first measurement of the provider list does.
    @Test func expandingAProviderRowResizesThePanelBelowTheMenuBar() throws {
        let store = makeStore(scenario: "populated")
        let item = makeItem(store)
        defer { item.remove() }

        let panel = try click(item)
        settle()
        let collapsed = panel.frame

        store.toggleExpanded(.codex)
        panel.layoutIfNeeded()
        settle()

        #expect(panel.frame.height > collapsed.height)
        #expect(panel.frame.height <= DesignTokens.Popover.maxHeight + PopoverChrome.caretHeight)
        #expect(panel.frame.maxY == collapsed.maxY)
    }

    /// The panel is sized before it is ordered in, so opening it does not show one frame at some
    /// other height first.
    @Test func thePopoverOpensAtTheHeightItKeeps() throws {
        let item = makeItem(makeStore(scenario: "populated"))
        defer { item.remove() }

        let panel = try click(item)
        let heightOnOpen = panel.frame.height
        settle()

        #expect(heightOnOpen == panel.frame.height)
    }

    @Test func clickingAnOpenItemAgainDismissesThePopover() throws {
        let item = makeItem(makeStore(scenario: "populated"))
        defer { item.remove() }

        let panel = try click(item)
        settle()
        item.dismiss()

        #expect(!panel.isVisible)
        #expect(openPanel() == nil)
    }
}
