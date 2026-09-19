import AppKit
import CoreText
import SwiftUI

/// The transparent window that hosts `PopoverView` beneath a menu-bar item.
///
/// `MenuBarExtra(.window)` draws its own opaque chrome and exposes neither its status item's
/// position nor its window's frame, so the caret and the centring below the icon cannot be
/// expressed through it. This panel stays transparent and lets `PopoverChromeShape` draw the
/// entire silhouette, including the shadow the window casts from it.
final class MenuBarPanel: NSPanel {
    // A borderless window refuses key status unless it says otherwise, and without it the
    // popover's buttons and ⌘R / ⌘, / ⌘Q shortcuts never receive events.
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            // `.nonactivatingPanel` keeps the accessory app in the background: the panel takes
            // key status without stealing the frontmost app's activation, as a menu does.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override func cancelOperation(_ sender: Any?) {
        (delegate as? MenuBarStatusItem)?.dismiss()
    }
}

/// One menu-bar item and the popover panel it opens.
@MainActor
final class MenuBarStatusItem: NSObject, NSWindowDelegate {
    let statusItem: NSStatusItem

    private let focus: ProviderID?
    private let store: UsageStore
    private var panel: MenuBarPanel?
    /// Clicking an open item resigns the panel's key status — which closes it — before the
    /// button's action runs, so the action would immediately reopen it. Ignore that reopen.
    private var lastDismissal = Date.distantPast

    private static let titleFont: NSFont = {
        let base = NSFont.menuBarFont(ofSize: 0)
        // Percentages and dollar amounts change every refresh; proportional digits make the item
        // shuffle its neighbours around as they do.
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: 0) ?? base
    }()

    init(focus: ProviderID?, autosaveName: String, store: UsageStore) {
        self.focus = focus
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = autosaveName
        if let button = statusItem.button {
            button.font = Self.titleFont
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityLabel("UsageTool")
        }
    }

    func remove() {
        dismiss()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Appearance

    func update(image: NSImage?, title: String, isCritical: Bool, help: String) {
        guard let button = statusItem.button else { return }
        button.image = image
        button.imagePosition = image == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
        if isCritical {
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: Self.titleFont, .foregroundColor: NSColor.systemRed]
            )
        } else {
            // A plain title lets AppKit invert it with the rest of the menu bar; an attributed
            // one with an explicit colour would stay red-on-red over a highlighted item.
            button.title = title
        }
        button.toolTip = help
        button.setAccessibilityValueDescription(help)
    }

    // MARK: - Panel

    @objc private func toggle() {
        if panel != nil {
            dismiss()
        } else if Date().timeIntervalSince(lastDismissal) > 0.2 {
            present()
        }
    }

    private func present() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? itemFrame

        // Centre on the item, then keep the whole panel on screen: an item close to a corner of
        // the display leaves the caret off-centre rather than pushing the panel off the edge.
        let width = DesignTokens.Popover.width
        let leftLimit = visible.minX + PopoverChrome.screenMargin
        let rightLimit = max(visible.maxX - PopoverChrome.screenMargin - width, leftLimit)
        let originX = min(max(itemFrame.midX - width / 2, leftLimit), rightLimit)

        let panel = MenuBarPanel()
        panel.delegate = self
        // A fresh hosting controller on every open is what re-runs `PopoverView`'s `onAppear`,
        // which is where the store learns the popover was opened and which item opened it.
        let content = NSHostingController(
            rootView: PopoverChromeContainer(caretX: itemFrame.midX - originX) {
                PopoverView(focus: focus)
            }
            .environment(store)
        )
        // The popover's height changes as provider rows expand and as content loads; this keeps
        // the panel sized to it, anchored at the menu bar, without a second layout pass here.
        content.sizingOptions = [.preferredContentSize]
        panel.contentViewController = content
        panel.setContentSize(content.view.fittingSize)
        panel.setFrameTopLeftPoint(CGPoint(x: originX, y: itemFrame.minY - PopoverChrome.menuBarGap))

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        lastDismissal = Date()
        statusItem.button?.highlight(false)
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    /// Dismiss on any click outside the panel, including one on another menu-bar item.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

/// Owns the menu-bar items and keeps them in step with preferences and provider state.
///
/// This replaces the four `MenuBarExtra` scenes the app used to declare. Besides the popover
/// styling those scenes made impossible, `MenuBarExtra(isInserted:)`'s write-back was a standing
/// hazard: mutating observable preferences from it re-dirtied the scene graph and live-locked the
/// app. Visibility is now read, never written back, so that cycle cannot form.
@MainActor
final class MenuBarItemsController {
    private enum Item: Hashable {
        case main
        case provider(ProviderID)

        var focus: ProviderID? {
            switch self {
            case .main: nil
            case .provider(let provider): provider
            }
        }

        /// Lets macOS remember where the user dragged each item.
        var autosaveName: String {
            switch self {
            case .main: "dev.usagetool.item.main"
            case .provider(let provider): "dev.usagetool.item.\(provider.rawValue)"
            }
        }
    }

    private let store: UsageStore
    private var items: [Item: MenuBarStatusItem] = [:]
    private var isRunning = false

    init(store: UsageStore) {
        self.store = store
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe()
    }

    func stop() {
        isRunning = false
        for item in items.values { item.remove() }
        items.removeAll()
    }

    /// `sync()` reads the preferences and provider state it renders, so tracking those reads is
    /// enough to know when the items need redrawing. The change callback runs *while* the value
    /// is being mutated, hence the hop to the next turn before reading it back.
    private func observe() {
        guard isRunning else { return }
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        let preferences = store.settings.preferences

        setVisible(.main, preferences.mainItemVisible)
        for provider in ProviderID.allCases {
            setVisible(.provider(provider), store.shouldShowSeparateMenuItem(provider))
        }

        if let main = items[.main] {
            let summary = store.summaryLabel
            main.update(
                image: Self.mainImage,
                title: preferences.mainItemStyle == .iconAndSummary ? summary : "",
                isCritical: false,
                help: "UsageTool · \(summary)"
            )
        }
        for provider in ProviderID.allCases {
            guard let item = items[.provider(provider)] else { continue }
            item.update(
                image: nil,
                title: store.menuBarLabel(for: provider),
                isCritical: preferences.useWarningColor && store.isCritical(provider),
                help: help(for: provider)
            )
        }
    }

    private func setVisible(_ item: Item, _ visible: Bool) {
        if visible, items[item] == nil {
            items[item] = MenuBarStatusItem(focus: item.focus, autosaveName: item.autosaveName, store: store)
        } else if !visible, let existing = items[item] {
            existing.remove()
            items[item] = nil
        }
    }

    private func help(for provider: ProviderID) -> String {
        let age = store.states[provider]?.snapshot
            .map { "Updated \(UsageFormatters.relativeAge(since: $0.effectiveDate, now: Date()))" } ?? "Unavailable"
        return "\(provider.displayName) · \(store.menuBarValue(for: provider)) · \(age)"
    }

    private static let mainImage: NSImage? = {
        let image = NSImage(named: "usage.gauge")
        image?.isTemplate = true
        return image
    }()
}
