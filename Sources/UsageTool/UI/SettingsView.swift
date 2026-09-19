import AppKit
import SwiftUI

/// Opens Settings and pulls its window in front of whatever the user is looking at.
///
/// `LSUIElement` keeps the app at `.accessory` activation policy, so neither `openSettings()`
/// nor `SettingsLink` activates the app: an already-open window is ordered front *within* the
/// app and stays buried behind the frontmost one. Activating from the scene's `onAppear` only
/// covers the first open, because the view is never torn down again — so every call site opens
/// through here instead.
@MainActor
func openSettingsWindow(_ openSettings: OpenSettingsAction) {
    openSettings()
    bringSettingsWindowForward()
    // SwiftUI may only create the window, or order it front, on the next turn of the run loop.
    Task { @MainActor in bringSettingsWindowForward() }
}

/// Activates the app and raises the Settings window.
///
/// `NSApp.activate()` is only a request: under macOS's cooperative activation the frontmost app
/// can keep the front spot, and Xcode reliably does, which left Settings behind it. Raising the
/// window itself does not go through activation, so `orderFrontRegardless()` gets it on screen
/// whether or not the activation request is granted.
@MainActor
func bringSettingsWindowForward() {
    NSApp.activate()
    guard let window = settingsWindow() else { return }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}

/// SwiftUI owns the Settings window, so there is no reference to keep. Prefer its own window
/// identifier and fall back on shape: the accessory app's only other windows are the borderless
/// menu-bar panels and whatever panel is on top of Settings at the time.
@MainActor
private func settingsWindow() -> NSWindow? {
    if let identified = NSApp.windows.first(where: {
        $0.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true
    }) {
        return identified
    }
    return NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.settingsTab) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ProviderSettingsView().tabItem { Label("Providers", systemImage: "point.3.connected.trianglepath.dotted") }.tag(SettingsTab.providers)
            MenuBarSettingsView().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }.tag(SettingsTab.menuBar)
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: DesignTokens.Settings.width)
        .frame(minHeight: DesignTokens.Settings.minHeight)
    }
}

private struct GeneralSettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Refresh") {
                Picker("Refresh every", selection: refreshCadenceBinding) {
                    ForEach(RefreshCadence.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Refresh when the popover opens", isOn: preferenceBinding(\.refreshOnOpen))
                Picker("Mark data stale after", selection: preferenceBinding(\.staleAfter)) {
                    Text("10 minutes").tag(TimeInterval(600))
                    Text("30 minutes").tag(TimeInterval(1_800))
                    Text("60 minutes").tag(TimeInterval(3_600))
                    Text("3 hours").tag(TimeInterval(10_800))
                }
            }
            Section("Display") {
                Picker("Headline window", selection: preferenceBinding(\.headlineRule)) {
                    ForEach(HeadlineRule.allCases) { Text($0.label).tag($0) }
                }
                Picker("Show reset times as", selection: preferenceBinding(\.resetDisplay)) {
                    Text("Countdown").tag(ResetDisplay.countdown)
                    Text("Time").tag(ResetDisplay.time)
                }.pickerStyle(.segmented)
            }
            Section("System") {
                Toggle("Open at login", isOn: Binding(
                    get: { settings.preferences.launchAtLogin },
                    set: { value in Task { await settings.setLaunchAtLogin(value) } }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.settings.preferences[keyPath: keyPath] }, set: {
            store.settings.preferences[keyPath: keyPath] = $0
        })
    }


    private var refreshCadenceBinding: Binding<RefreshCadence> {
        Binding(get: { store.settings.preferences.refreshCadence }, set: {
            store.settings.preferences.refreshCadence = $0
            store.refreshCadenceDidChange()
        })
    }
}

private struct ProviderSettingsView: View {
    @Environment(UsageStore.self) private var store
    @State private var keyEntry = ""
    @State private var keyEntryEnabled = false
    @State private var showDisclosure = false
    @State private var showClaudeSheet = false
    @State private var testingProvider: ProviderID?
    @State private var inlineError: String?

    var body: some View {
        Form {
            providerSection(.codex) {
                LabeledContent("Status") { statusLabel(.codex) }
                codexExecutableRow
                if let snapshot = store.snapshot(for: .codex) {
                    LabeledContent("Windows", value: snapshot.windows.map { "\($0.label) \(UsageFormatters.percent($0.remainingFraction) ?? "—")" }.joined(separator: " · "))
                }
                HStack { Spacer(); testButton(.codex) }
            } footer: {
                Text("UsageTool finds Codex on PATH, in Homebrew, and in the usual Node version-manager locations; choose an executable only to override that. Reads subscription limits only from the documented local Codex App Server. UsageTool never reads Codex credentials. This integration is experimental because the app-server command is not yet a production-stable interface.")
            }

            providerSection(.claude) {
                LabeledContent("Adapter") { statusLabel(.claude) }
                LabeledContent("Snapshot") {
                    Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary)
                    Text("…/UsageTool/claude-usage.json").monospaced().textSelection(.enabled)
                    Button("Reveal") { revealSnapshot() }
                }
                if let snapshot = store.snapshot(for: .claude) {
                    LabeledContent("Windows", value: snapshot.windows.map { "\($0.label) \(UsageFormatters.percent($0.remainingFraction) ?? "—")" }.joined(separator: " · "))
                }
                HStack { Spacer(); Button("Configure Adapter…") { showClaudeSheet = true }.buttonStyle(.bordered) }
            } footer: {
                Text("A bundled helper keeps only the 5-hour and 7-day rate-limit windows. It stores no session IDs, paths, cost, context, models, plan, spend limit, or credentials. Updates only while a Claude Code session is running.")
            }

            providerSection(.openRouter) {
                LabeledContent("Management key") {
                    SecureField("sk-or-…", text: $keyEntry)
                        .frame(width: 220)
                        .disabled(!keyEntryEnabled || !store.providerOperationsEnabled)
                    Button(keyEntryEnabled ? "Save" : "Add…") {
                        if keyEntryEnabled { Task { await saveOpenRouterKey() } }
                        else { showDisclosure = true }
                    }
                    .disabled(!store.providerOperationsEnabled)
                }
                if let inlineError { Text(inlineError).font(.subheadline).foregroundStyle(.red) }
                LabeledContent("Status") { statusLabel(.openRouter) }
                HStack {
                    if store.snapshot(for: .openRouter) != nil {
                        Button("Disconnect", role: .destructive) { Task { try? await store.disconnectOpenRouter() } }
                            .disabled(!store.providerOperationsEnabled)
                    }
                    Spacer(); testButton(.openRouter)
                }
            } footer: {
                Label("Stored in the macOS Keychain and sent only to openrouter.ai. This key can manage your OpenRouter API keys; no balance-only scope is documented.", systemImage: "lock.fill")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showDisclosure) {
            OpenRouterDisclosureSheet {
                keyEntryEnabled = true
                showDisclosure = false
            }
        }
        .sheet(isPresented: $showClaudeSheet) { ClaudeAdapterSheet() }
        .task { store.resolveCodexExecutable() }
    }

    /// One row, because the path the app will actually launch is the only thing worth showing here:
    /// a GUI app's `PATH` is not the user's shell `PATH`, so "it works in Terminal" proves nothing.
    @ViewBuilder
    private var codexExecutableRow: some View {
        LabeledContent("Executable") {
            VStack(alignment: .leading, spacing: 6) {
                if let resolution = store.codexExecutableResolution {
                    statusLine(symbol: "checkmark.circle.fill", color: .green, text: resolution.url.path, monospaced: true)
                    caption(resolution.origin == .configured ? "Chosen manually" : "Found automatically · \(resolution.origin.label)")
                } else if let problem = store.codexExecutableProblem {
                    statusLine(symbol: "exclamationmark.triangle.fill", color: .orange, text: problem.message, monospaced: false)
                    if case .configuredPathNotExecutable(let path) = problem { caption(path, monospaced: true) }
                    else { caption("Install Codex, or choose its executable.") }
                }
                HStack {
                    Button("Choose…") { chooseCodexExecutable() }
                    if !store.settings.preferences.codexExecutablePath.isEmpty {
                        Button("Use Automatic") { commitCodexPath("") }
                    }
                }
            }
        }
    }

    private func statusLine(symbol: String, color: Color, text: String, monospaced: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func caption(_ text: String, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    private func commitCodexPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.settings.preferences.codexExecutablePath != trimmed else { return }
        store.settings.preferences.codexExecutablePath = trimmed
        store.codexExecutablePathDidChange()
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose the codex executable to launch."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Node version managers install under dot-directories, which are hidden by default.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = store.codexExecutableResolution?.url.deletingLastPathComponent()
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        commitCodexPath(url.path)
    }

    private func providerSection<Content: View, Footer: View>(
        _ provider: ProviderID,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        Section {
            Toggle("Show \(provider.displayName)", isOn: providerVisibility(provider))
            content()
        } header: {
            HStack { ProviderMark(provider: provider); Text(provider.displayName).font(.headline) }
        } footer: { footer() }
    }

    private func providerVisibility(_ provider: ProviderID) -> Binding<Bool> {
        Binding(get: { store.settings.preferences.showProvider[provider] ?? true }, set: {
            store.settings.preferences.showProvider[provider] = $0
        })
    }

    @ViewBuilder
    private func statusLabel(_ provider: ProviderID) -> some View {
        if testingProvider == provider { ProgressView().controlSize(.small); Text("Testing…") }
        else {
            let state = store.states[provider] ?? .disconnected
            let presentation = statusPresentation(state)
            Image(systemName: presentation.symbol).foregroundStyle(presentation.color)
            Text(presentation.text)
        }
    }

    private func statusPresentation(_ state: ProviderState) -> (symbol: String, color: Color, text: String) {
        switch state {
        case .connected(let snapshot):
            return ("checkmark.circle.fill", .green, "Connected · updated \(UsageFormatters.relativeAge(since: snapshot.effectiveDate, now: Date()))")
        case .partial(let snapshot, _):
            return ("checkmark.circle.fill", .green, "Connected · partial report · \(UsageFormatters.relativeAge(since: snapshot.effectiveDate, now: Date()))")
        case .stale(_, let age): return ("clock.badge.exclamationmark", .secondary, "Stale · last reported \(UsageFormatters.relativeAge(since: Date().addingTimeInterval(-age), now: Date()))")
        case .loading: return ("arrow.clockwise", .secondary, "Loading…")
        case .authError(let message): return ("key.slash", .red, message)
        case .credentialExpired(let date, _): return ("calendar.badge.exclamationmark", .red, "Management key expired \(date.formatted(date: .abbreviated, time: .omitted)). Replace it.")
        case .networkError(_, let message): return ("wifi.exclamationmark", .secondary, message)
        case .unavailable(let reason): return ("minus.circle", Color(nsColor: .tertiaryLabelColor), reason.message)
        case .disconnected: return ("circle.dotted", Color(nsColor: .tertiaryLabelColor), "Not set up")
        }
    }

    private func testButton(_ provider: ProviderID) -> some View {
        Button("Test Connection") {
            testingProvider = provider
            Task {
                await store.refresh(provider, manual: true)
                testingProvider = nil
            }
        }
        .buttonStyle(.bordered)
        .disabled(testingProvider != nil || !store.providerOperationsEnabled)
    }

    private func saveOpenRouterKey() async {
        inlineError = keyEntry.hasPrefix("sk-or-") ? nil : "Doesn’t look like an OpenRouter key"
        do {
            try await store.connectOpenRouter(key: keyEntry)
            keyEntry = ""
            keyEntryEnabled = false
            inlineError = nil
        } catch { inlineError = error.localizedDescription }
    }

    private func revealSnapshot() {
        NSWorkspace.shared.activateFileViewerSelecting([store.claudeSnapshotURL])
    }
}

private struct OpenRouterDisclosureSheet: View {
    let continueAction: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About OpenRouter management keys").font(.title2.weight(.semibold))
            Text("OpenRouter’s credits endpoint (`/api/v1/credits`) only accepts a management key. OpenRouter doesn’t document a narrower, balance-only scope, so UsageTool can’t ask for less.")
            Text("A management key can create, edit and revoke your account’s API keys, although it can’t make completion requests. UsageTool uses it for exactly one thing: reading your credit balance.")
            Text("Create the key with an expiry date. UsageTool stores it in the macOS Keychain, sends it only to openrouter.ai, and reminds you a week before it expires.")
            HStack {
                Link("Open OpenRouter Keys…", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue", action: continueAction).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
    }
}

private struct ClaudeAdapterSheet: View {
    private enum SetupMode: String, CaseIterable, Identifiable {
        case guided = "Guided"
        case manual = "Manual"
        var id: Self { self }
    }

    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Detecting…"
    @State private var message: String?
    @State private var mode = SetupMode.guided
    @State private var manualSnippet = ""
    @State private var existingCommand: String?
    @State private var isInstalled = false
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up the Claude Code status-line adapter").font(.title2.weight(.semibold))
            Text("Claude Code passes status JSON on stdin. UsageTool’s helper retains only sanitized 5-hour and 7-day windows and atomically writes them to its managed snapshot. No credentials or session identifiers are stored.")
                .font(.subheadline).foregroundStyle(.secondary)
            LabeledContent("Detected", value: status)
            Picker("Setup method", selection: $mode) {
                ForEach(SetupMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == .guided {
                GroupBox {
                    HStack {
                        Text("Installs the bundled helper, backs up settings.json, merges only statusLine, and preserves any existing command in a chain.")
                        Spacer()
                        Button(isInstalled ? "Reinstall Adapter" : "Install Adapter") {
                            Task { @MainActor in await install() }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.providerOperationsEnabled || isWorking)
                    }
                }
            } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manualSnippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Text("Add this object to ~/.claude/settings.json. Keep your existing command in the generated chain to preserve your status line.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(manualSnippet, forType: .string)
                            }
                        }
                    }
                }
            }
            Label("Snapshot: ~/Library/Application Support/UsageTool/claude-usage.json — managed and written atomically.", systemImage: "doc.badge.gearshape")
            Label("Data appears after Claude Code’s first API response and ages into Stale between sessions.", systemImage: "clock")
            Label("The helper never reads credentials or stores session IDs, working directories, transcript paths, cost, context, models, plans, or spend limits.", systemImage: "lock.fill")
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                HelpLink(destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
                Spacer()
                Button("Remove Adapter", role: .destructive) {
                    Task { @MainActor in await remove() }
                }
                    .disabled(!store.providerOperationsEnabled || isWorking)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .task { @MainActor in await inspect() }
    }

    @MainActor
    private func installer() -> ClaudeAdapterInstaller? {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "usagetool-statusline")
                ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/usagetool-statusline") as URL? else { return nil }
        return ClaudeAdapterInstaller(
            homeURL: store.claudeHomeURL,
            applicationSupportURL: store.claudeSnapshotURL.deletingLastPathComponent(),
            bundledHelperURL: helper
        )
    }

    @MainActor
    private func inspect() async {
        guard let installer = installer() else { status = "Bundled helper unavailable"; return }
        let result = await installer.inspect()
        switch result.kind {
        case .notInstalled:
            status = "No status line configured"
            isInstalled = false
        case .installed(let chained):
            status = chained ? "Installed · composes with your status line" : "Installed"
            isInstalled = true
        case .configuredElsewhere(let command):
            let incompatible = command == "Unsupported statusLine type"
            status = incompatible ? "Unsupported statusLine type · use Manual setup" : "Existing status line detected · will be chained"
            existingCommand = incompatible ? nil : command
            if incompatible { mode = .manual }
            isInstalled = false
        case .invalidSettings:
            status = "Settings couldn’t be parsed · use Manual setup"
            mode = .manual
            isInstalled = false
        }
        manualSnippet = await installer.manualSnippet(existingCommand: existingCommand)
    }

    @MainActor
    private func install() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        guard let installer = installer() else { return }
        do { _ = try await installer.install(); message = "Installed · Claude Code will report after its next API response"; await inspect() }
        catch ClaudeAdapterInstallerError.incompatibleStatusLine {
            mode = .manual
            manualSnippet = await installer.manualSnippet(existingCommand: existingCommand)
            message = "The existing statusLine can’t be merged safely. Use the Manual snippet."
        } catch { message = "Couldn’t install safely: \(error.localizedDescription)" }
    }

    @MainActor
    private func remove() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        guard let installer = installer() else { return }
        do { try await installer.remove(); message = "Adapter removed; the previous status line was restored."; await inspect() }
        catch ClaudeAdapterInstallerError.currentConfigurationChanged {
            message = "Couldn’t remove safely because the configuration changed."
        } catch {
            message = "Couldn’t remove safely: \(error.localizedDescription)"
        }
    }
}

private struct MenuBarSettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        Form {
            Section("Preview") {
                HStack(spacing: 10) {
                    Text("⋯").foregroundStyle(.tertiary)
                    if store.settings.preferences.mainItemVisible {
                        Image("usage.gauge").frame(width: 16, height: 16)
                        if store.settings.preferences.mainItemStyle == .iconAndSummary { Text(store.summaryLabel) }
                    }
                    ForEach(store.settings.preferences.providerOrder.filter { store.settings.preferences.separateItems[$0] ?? false }) {
                        Text(store.menuBarLabel(for: $0))
                    }
                    Spacer(); Image(systemName: "wifi").foregroundStyle(.tertiary); Text("10:55 AM").foregroundStyle(.tertiary)
                }
                .font(.body.monospacedDigit()).padding(.horizontal, 10).frame(height: 28)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            }
            Section("Main item") {
                Toggle("Show icon", isOn: mainVisibility)
                Picker("Icon style", selection: preferenceBinding(\.mainItemStyle)) {
                    Text("Icon only").tag(MainItemStyle.iconOnly)
                    Text("Icon and summary").tag(MainItemStyle.iconAndSummary)
                }.pickerStyle(.segmented)
            }
            Section {
                List {
                    ForEach(store.settings.preferences.providerOrder) { provider in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            ProviderMark(provider: provider)
                            Text(provider.displayName)
                            Spacer()
                            Picker("", selection: itemFormat(provider)) {
                                ForEach(MenuItemFormat.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 135)
                            Text(store.menuBarLabel(for: provider)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Toggle("", isOn: separateVisibility(provider)).labelsHidden().accessibilityLabel("Show \(provider.displayName) in menu bar")
                        }.frame(height: 34)
                    }.onMove(perform: move)
                }.frame(height: 132)
            } header: {
                Text("Separate items")
            } footer: {
                Text("Show a text item for each provider. Drag to reorder. At least one menu-bar item must stay visible.")
            }
            Section("Warnings") {
                Toggle("Show a warning symbol below 10%", isOn: preferenceBinding(\.showWarningSymbol))
                Toggle("Use color for warnings", isOn: preferenceBinding(\.useWarningColor))
                Toggle("Hide items while unavailable", isOn: preferenceBinding(\.hideUnavailableItems))
            }
        }.formStyle(.grouped)
    }

    private var mainVisibility: Binding<Bool> {
        Binding(get: { store.settings.preferences.mainItemVisible }, set: { value in
            if !value && !store.settings.preferences.separateItems.values.contains(true) { return }
            store.settings.preferences.mainItemVisible = value
        })
    }
    private func separateVisibility(_ provider: ProviderID) -> Binding<Bool> {
        Binding(get: { store.settings.preferences.separateItems[provider] ?? false }, set: { value in
            store.settings.preferences.separateItems[provider] = value
            store.settings.normalizeMenuVisibility()
        })
    }
    private func itemFormat(_ provider: ProviderID) -> Binding<MenuItemFormat> {
        Binding(get: { store.settings.preferences.itemFormats[provider] ?? .nameAndValue }, set: { store.settings.preferences.itemFormats[provider] = $0 })
    }
    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.settings.preferences[keyPath: keyPath] }, set: { store.settings.preferences[keyPath: keyPath] = $0 })
    }
    private func move(from source: IndexSet, to destination: Int) {
        store.settings.preferences.providerOrder.move(fromOffsets: source, toOffset: destination)
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text("UsageTool").font(.title2.weight(.semibold))
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Privacy") {
                Text("UsageTool talks only to openrouter.ai and the local Codex App Server, and reads the sanitized snapshot written by its own Claude Code status-line adapter. OpenRouter’s management key is stored only in the macOS Keychain.")
            }
            Section("Links") {
                Link("OpenRouter management keys", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                Link("Codex App Server documentation", destination: URL(string: "https://learn.chatgpt.com/docs/app-server")!)
                Link("Claude Code status line documentation", destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
            }
        }.formStyle(.grouped)
    }
}
