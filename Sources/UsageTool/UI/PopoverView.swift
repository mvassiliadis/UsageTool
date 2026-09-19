import AppKit
import SwiftUI

struct PopoverView: View {
    let focus: ProviderID?
    /// Measured height of the provider list. `MenuBarExtra(.window)` sizes its window from the
    /// root view's definite height and collapses a height-flexible root to its minimum, so the
    /// list is given a concrete height instead of being left to fill whatever it is offered.
    @State private var listHeight = DesignTokens.Popover.maxContentHeight
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    init(focus: ProviderID? = nil) { self.focus = focus }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.hasConnectedProvider {
                ScrollView {
                    VStack(spacing: 0) {
                        let providers = store.settings.preferences.providerOrder.filter { store.settings.preferences.showProvider[$0] ?? true }
                        ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                            ProviderBlockView(provider: provider)
                            if index < providers.count - 1 { Divider().padding(.horizontal, DesignTokens.Space.x8) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.never)
                // `fixedSize` would also make the root definite, but it sizes the scroll view to
                // its content and then clips it, leaving rows unreachable. A measured height
                // keeps it an ordinary scroll view that scrolls once the list exceeds the cap.
                .frame(height: min(listHeight, DesignTokens.Popover.maxContentHeight))
            } else {
                ContentUnavailableView {
                    Label("No providers connected yet", systemImage: "gauge.with.dots.needle.0percent")
                } description: {
                    VStack(spacing: 8) {
                        Text("Connect Codex, Claude Code, or OpenRouter to see usage at a glance.")
                        HStack(spacing: 8) {
                            ForEach(ProviderID.allCases) { provider in
                                HStack(spacing: 5) {
                                    ProviderMark(provider: provider)
                                    Text(provider.displayName).font(.caption)
                                }
                            }
                        }
                    }
                } actions: {
                    Button("Open Settings…") { openSettings() }
                        .buttonStyle(.glassProminent)
                }
                // `ContentUnavailableView` is greedy: left alone it reports no useful height,
                // the popover collapses around it and its action is clipped. Sizing it to its
                // own content keeps the popover's root height definite and fits the whole state.
                // It has no scrollable content of its own, so `fixedSize` is safe here.
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, DesignTokens.Space.x8)
        .padding(.top, DesignTokens.Space.x12)
        .padding(.bottom, DesignTokens.Space.x10)
        .frame(width: DesignTokens.Popover.width)
        .onAppear { store.popoverOpened(focusedOn: focus) }
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.headline)
            Spacer()
            Button {
                Task { await store.refreshAll(manual: true) }
            } label: {
                if store.isRefreshing && reduceMotion { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").symbolEffect(.rotate, isActive: store.isRefreshing) }
            }
            .buttonStyle(.borderless).frame(width: 24, height: 24)
            .disabled(!store.providerOperationsEnabled)
            .help("Refresh now (⌘R)").keyboardShortcut("r")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).frame(width: 24, height: 24)
                .help("Settings… (⌘,)")
        }
        .frame(height: 28)
        .padding(.horizontal, DesignTokens.Space.x8)
        .padding(.bottom, DesignTokens.Space.x8)
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(footerText(at: context.date)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Quit") {
                store.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary).keyboardShortcut("q")
        }
        .padding(.horizontal, DesignTokens.Space.x8)
        .padding(.top, DesignTokens.Space.x8)
    }

    private func footerText(at date: Date) -> String {
        if store.isRefreshing { return "Refreshing…" }
        guard let updated = store.lastSuccessfulRefresh else { return "Nothing to refresh" }
        let age = UsageFormatters.relativeAge(since: updated, now: date)
        let cadence = store.settings.preferences.refreshCadence
        return cadence == .manual ? "Updated \(age) · Manual refresh" : "Updated \(age) · Refreshes every \(cadence.rawValue / 60) min"
    }
}
