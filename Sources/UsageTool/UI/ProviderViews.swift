import SwiftUI

struct ProviderMark: View {
    let provider: ProviderID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric private var tileSize = 24
    @ScaledMetric private var markSize = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tile)
                .fill(accent.opacity(provider == .openRouter ? (colorScheme == .dark ? 0.30 : 0.12) : (colorScheme == .dark ? 0.20 : 0.14)))
            image
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: markSize, height: provider == .openRouter ? markSize * 0.72 : markSize)
                .accessibilityHidden(true)
        }
        .frame(width: tileSize, height: tileSize)
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tile)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }

    private var image: Image {
        switch provider {
        case .codex: Image("Provider/OpenAI")
        case .claude: Image("Provider/ClaudeSpark")
        case .openRouter: Image(colorScheme == .dark ? "Provider/OpenRouter-Cloud" : "Provider/OpenRouter-Grape")
        }
    }

    private var accent: Color {
        switch provider {
        case .codex: Color("Accent/Codex")
        case .claude: Color("Accent/Claude")
        case .openRouter: Color("Accent/OpenRouter")
        }
    }
}

struct CapacityBar: View {
    let fraction: Double?
    let color: Color
    let dimmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            if let fraction {
                Capsule()
                    .fill(contrast == .increased
                        ? AnyShapeStyle(Color(nsColor: .tertiaryLabelColor).opacity(0.25))
                        : AnyShapeStyle(.quaternary))
                let width = geometry.size.width * min(max(fraction, 0), 1)
                Capsule()
                    .fill(fillColor.opacity(dimmed ? 0.4 : 1))
                    .frame(width: width)
                    .overlay {
                        if differentiate && fraction < Thresholds.lowFraction {
                            HatchPattern().clipShape(Capsule()).opacity(0.30)
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15), value: width)
            } else {
                Capsule().stroke(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(height: 6)
    }

    private var fillColor: Color {
        guard let fraction else { return color }
        if fraction < Thresholds.criticalFraction { return .red }
        if fraction < Thresholds.lowFraction { return .yellow }
        return color
    }
}

private struct HatchPattern: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width + size.height, by: 5) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(.primary), lineWidth: 1)
        }
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay {
                if contrast == .increased { Capsule().stroke(tint, lineWidth: 1) }
            }
    }
}

struct ProviderBlockView: View {
    let provider: ProviderID
    @Environment(UsageStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if case .disconnected = state {
                disconnectedView
            } else {
                fullView
            }
        }
        .padding(.vertical, DesignTokens.Space.x10)
        .padding(.horizontal, DesignTokens.Space.x8)
        .background(highlight, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .focusSection()
        .onKeyPress(.return) { store.toggleExpanded(provider); return .handled }
        .onKeyPress(.space) { store.toggleExpanded(provider); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .accessibilityHint("Press Return for details")
    }

    private var state: ProviderState { store.states[provider] ?? .disconnected }
    private var snapshot: UsageSnapshot? { state.snapshot }
    private var accent: Color {
        switch provider {
        case .codex: Color("Accent/Codex")
        case .claude: Color("Accent/Claude")
        case .openRouter: Color("Accent/OpenRouter")
        }
    }
    private var highlight: Color {
        if store.focusedProvider == provider { return accent.opacity(0.06) }
        if hovering || focused { return Color.primary.opacity(0.05) }
        return .clear
    }
    private var isDimmed: Bool {
        switch state {
        case .stale, .networkError(previous: .some, message: _): true
        default: false
        }
    }

    private var disconnectedView: some View {
        HStack(spacing: DesignTokens.Space.x10) {
            ProviderMark(provider: provider)
            Text(provider.displayName).font(.headline)
            Text("· Not set up").foregroundStyle(.secondary)
            Spacer()
            Button("Set up…") { showSettings() }.buttonStyle(.bordered).controlSize(.small)
        }
        .frame(minHeight: 28)
    }

    private var fullView: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.x8) {
            Button(action: { store.toggleExpanded(provider) }) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerAccessibilityLabel)
            if provider != .openRouter, shouldShowWindowRows {
                VStack(spacing: DesignTokens.Space.x6) {
                    ForEach(displayWindows) { window in
                        UsageWindowRow(window: window, provider: provider, dimmed: isDimmed)
                    }
                }
                .padding(.leading, 34)
            }
            if let action = actionLabel {
                HStack {
                    Text(action.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(action.button) {
                        if action.button == "Retry" { Task { await store.refresh(provider, manual: true) } }
                        else { showSettings() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.leading, 34)
            }
            if store.expandedProviders.contains(provider), let snapshot {
                detailView(snapshot)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.expandedProviders.contains(provider))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.x10) {
            ProviderMark(provider: provider)
            VStack(alignment: .leading, spacing: DesignTokens.Space.x2) {
                Text(provider.displayName).font(.headline).foregroundStyle(.primary)
                Text(sourceCaption).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 4) {
                    if let statusSymbol { Image(systemName: statusSymbol.name).foregroundStyle(statusSymbol.color).font(.system(size: 13)) }
                    if case .loading(previous: nil) = state { ProgressView().controlSize(.small) }
                    Text(heroValue)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isDimmed ? .secondary : heroAvailable ? .primary : Color(nsColor: .tertiaryLabelColor))
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 4) {
                    if let pill { StatusPill(text: pill.text, symbol: pill.symbol, tint: pill.tint) }
                    else { Text(heroCaption).font(.caption).foregroundStyle(.secondary) }
                    if hovering || focused || store.expandedProviders.contains(provider) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(store.expandedProviders.contains(provider) ? 90 : 0))
                    }
                }
            }
        }
        .frame(minHeight: 32)
    }

    private var displayWindows: [UsageWindow] {
        let existing = snapshot?.windows ?? []
        var values = existing
        if provider == .claude {
            for id in [WindowID.fiveHour, .sevenDay] where !values.contains(where: { $0.id == id }) {
                values.append(.init(id: id, usedPercent: nil, remainingFraction: nil, resetsAt: nil))
            }
        }
        return values.sorted { lhs, rhs in
            let order: [WindowID: Int] = [.fiveHour: 0, .sevenDay: 1]
            return order[lhs.id, default: 2] < order[rhs.id, default: 2]
        }
    }

    private var shouldShowWindowRows: Bool {
        switch state {
        case .unavailable, .authError, .credentialExpired: false
        default: true
        }
    }

    private var heroValue: String {
        switch state {
        case .loading(previous: nil), .unavailable, .authError, .credentialExpired: return "—"
        case .networkError(previous: nil, message: _): return "—"
        default: break
        }
        if provider == .openRouter {
            return snapshot?.credits.map { UsageFormatters.credits($0.remaining) } ?? "—"
        }
        return UsageFormatters.percent(store.headlineWindow(for: provider)?.remainingFraction) ?? "—"
    }

    private var heroAvailable: Bool { heroValue != "—" }
    private var heroCaption: String {
        if provider == .openRouter { return "credits remaining" }
        guard let window = store.headlineWindow(for: provider) else { return "not reported" }
        return store.settings.preferences.headlineRule == .lowest ? "lowest · \(window.label)" : window.label
    }

    private var sourceCaption: String {
        switch state {
        case .loading(previous: nil): return "Loading…"
        case .unavailable(let reason): return reason.message
        case .authError(let message): return message
        case .credentialExpired: return "Management key expired"
        case .networkError(let previous, _):
            if let previous { return "Couldn’t refresh · showing \(UsageFormatters.relativeAge(since: previous.observedAt, now: Date()))" }
            return provider == .openRouter ? "Couldn’t reach OpenRouter" : "Couldn’t refresh"
        default:
            guard let snapshot else { return "Not set up" }
            var caption = snapshot.source.caption
            if provider == .claude { caption += " · \(UsageFormatters.relativeAge(since: snapshot.effectiveDate, now: Date()))" }
            if case .stale(_, let age) = state, provider != .claude { caption += " · \(UsageFormatters.relativeAge(since: Date().addingTimeInterval(-age), now: Date()))" }
            return caption
        }
    }

    private var pill: (text: String, symbol: String, tint: Color)? {
        switch state {
        case .stale: return ("Stale", "clock.badge.exclamationmark", .secondary)
        case .authError: return ("Auth error", "key.slash", .red)
        case .credentialExpired: return ("Expired", "calendar.badge.exclamationmark", .red)
        case .networkError: return ("Offline", "wifi.exclamationmark", .secondary)
        case .unavailable: return ("Unavailable", "minus.circle", Color(nsColor: .tertiaryLabelColor))
        default:
            if let credential = snapshot?.credential,
               case .expiring(let date) = credential.status(at: Date()) {
                return ("Expires in \(max(0, Int(date.timeIntervalSinceNow / 86_400)))d", "calendar.badge.exclamationmark", .yellow)
            }
            if provider == .openRouter, snapshot?.credits?.remaining == 0 { return ("Exhausted", "nosign", .red) }
            if provider != .openRouter, store.headlineWindow(for: provider)?.remainingFraction == 0 { return ("Exhausted", "nosign", .red) }
            return nil
        }
    }

    private var statusSymbol: (name: String, color: Color)? {
        if let fraction = provider == .openRouter ? nil : store.headlineWindow(for: provider)?.remainingFraction {
            if fraction == 0 { return ("nosign", .red) }
            if fraction < Thresholds.criticalFraction { return ("exclamationmark.triangle.fill", .red) }
            if fraction < Thresholds.lowFraction { return ("exclamationmark.circle.fill", .yellow) }
        }
        if let remaining = snapshot?.credits?.remaining {
            if remaining == 0 { return ("nosign", .red) }
            if remaining < Thresholds.criticalCredits { return ("exclamationmark.triangle.fill", .red) }
            if remaining < Thresholds.lowCredits { return ("exclamationmark.circle.fill", .yellow) }
        }
        return nil
    }

    private var actionLabel: (detail: String, button: String)? {
        switch state {
        case .authError: ("This key can’t read credits.", "Fix…")
        case .credentialExpired(let date, _): ("Expired \(date.formatted(date: .abbreviated, time: .omitted)). Create a new key.", "Fix…")
        case .networkError: ("", "Retry")
        case .unavailable(let reason): (reason.message, "Learn more")
        default: nil
        }
    }

    private func detailView(_ snapshot: UsageSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if provider == .openRouter, let balance = snapshot.credits {
                detailRow("Total credited", UsageFormatters.credits(balance.totalCredits))
                detailRow("Total used", UsageFormatters.credits(balance.totalUsage))
                detailRow("Fetched", UsageFormatters.absolute(snapshot.observedAt))
                if let expiry = snapshot.credential?.expiresAt { detailRow("Management key", "Expires \(expiry.formatted(date: .abbreviated, time: .omitted))") }
                else { detailRow("Management key", "No expiry") }
            } else {
                ForEach(snapshot.windows) { window in
                    detailRow("\(window.label) resets", window.resetsAt.map { UsageFormatters.absolute($0) } ?? "Not reported")
                }
                if provider == .codex, let plan = snapshot.plan { detailRow("Plan", plan) }
                if provider == .codex, let path = store.resolvedCodexExecutablePath { detailRow("Executable", path) }
                if let reported = snapshot.reportedAt { detailRow("Reported", UsageFormatters.absolute(reported)) }
                if provider == .claude { detailRow("Snapshot", store.claudeSnapshotURL.path) }
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).foregroundStyle(.primary) }
    }

    private var headerAccessibilityLabel: String {
        "\(provider.displayName), \(heroValue), \(sourceCaption)"
    }

    private func showSettings() {
        store.openProviderSettings(provider)
        openSettingsWindow(openSettings)
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let provider: ProviderID
    let dimmed: Bool
    @Environment(UsageStore.self) private var store
    @ScaledMetric private var labelWidth = 44
    @ScaledMetric private var valueWidth = 44
    @ScaledMetric private var resetWidth = 66

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading).lineLimit(1)
            CapacityBar(fraction: window.remainingFraction, color: accent, dimmed: dimmed)
            HStack(spacing: 4) {
                if let fraction = window.remainingFraction, fraction < Thresholds.lowFraction {
                    Image(systemName: fraction < Thresholds.criticalFraction ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(fraction < Thresholds.criticalFraction ? .red : .yellow)
                }
                Text(UsageFormatters.percent(window.remainingFraction) ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .frame(width: valueWidth, alignment: .trailing)
            let reset = formattedReset
            Text(reset ?? (window.remainingFraction == nil ? "Not reported" : "—"))
                .font(.subheadline).foregroundStyle(.secondary).frame(width: resetWidth, alignment: .trailing).lineLimit(1)
                .help(window.resetsAt.map { UsageFormatters.absolute($0) } ?? "Not reported")
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) window")
        .accessibilityValue("\(UsageFormatters.percent(window.remainingFraction) ?? "not reported") remaining, \(formattedReset ?? "reset not reported")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var formattedReset: String? {
        switch store.settings.preferences.resetDisplay {
        case .countdown: UsageFormatters.resetCountdown(to: window.resetsAt, now: Date())
        case .time: UsageFormatters.resetTime(window.resetsAt, now: Date())
        }
    }

    private var accent: Color {
        provider == .codex ? Color("Accent/Codex") : Color("Accent/Claude")
    }
}
