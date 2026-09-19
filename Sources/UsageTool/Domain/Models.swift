import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case openRouter

    var id: Self { self }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openRouter: "OpenRouter"
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Cdx"
        case .claude: "Cld"
        case .openRouter: "OR"
        }
    }
}

enum WindowID: Hashable, Codable, Sendable, Identifiable {
    case fiveHour
    case sevenDay
    case other(minutes: Int)

    var id: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        case .other(let minutes): "other-\(minutes)"
        }
    }

    var label: String {
        switch self {
        case .fiveHour: return "5-hour"
        case .sevenDay: return "7-day"
        case .other(let minutes):
            if minutes.isMultiple(of: 60) {
                let hours = minutes / 60
                return "\(hours)-hour"
            }
            return "\(minutes)-minute"
        }
    }

    static func from(durationMinutes: Int) -> Self {
        switch durationMinutes {
        case 300: .fiveHour
        case 10_080: .sevenDay
        default: .other(minutes: durationMinutes)
        }
    }
}

enum DataSource: String, Codable, Sendable {
    case codexAppServer
    case claudeCodeStatusLine
    case openRouterCreditsAPI

    var caption: String {
        switch self {
        case .codexAppServer: "Via local Codex app-server"
        case .claudeCodeStatusLine: "Last reported by Claude Code"
        case .openRouterCreditsAPI: "OpenRouter credits API"
        }
    }
}

struct UsageWindow: Identifiable, Codable, Hashable, Sendable {
    let id: WindowID
    let label: String
    let usedPercent: Double?
    let remainingFraction: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    init(
        id: WindowID,
        label: String? = nil,
        usedPercent: Double?,
        remainingFraction: Double?,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date?
    ) {
        self.id = id
        self.label = label ?? id.label
        self.usedPercent = usedPercent
        self.remainingFraction = remainingFraction.map { min(max($0, 0), 1) }
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    static func fromUsedPercent(
        _ usedPercent: Double,
        id: WindowID,
        label: String? = nil,
        durationMinutes: Int? = nil,
        resetsAt: Date?
    ) -> Self {
        let remaining = min(max(1 - usedPercent / 100, 0), 1)
        return .init(
            id: id,
            label: label,
            usedPercent: usedPercent,
            remainingFraction: remaining,
            windowDurationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }

    func expiringIfNeeded(at now: Date) -> Self {
        guard let resetsAt, resetsAt <= now else { return self }
        return .init(
            id: id,
            label: label,
            usedPercent: usedPercent,
            remainingFraction: nil,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt
        )
    }
}

struct CreditBalance: Codable, Hashable, Sendable {
    let totalCredits: Decimal
    let totalUsage: Decimal
    var remaining: Decimal { totalCredits - totalUsage }
}

struct CredentialInfo: Codable, Hashable, Sendable {
    let isManagementKey: Bool
    let expiresAt: Date?
    let label: String?

    func status(at now: Date, warningInterval: TimeInterval = 7 * 24 * 60 * 60) -> CredentialStatus {
        guard let expiresAt else { return .valid }
        if expiresAt <= now { return .expired(at: expiresAt) }
        if expiresAt.timeIntervalSince(now) <= warningInterval { return .expiring(at: expiresAt) }
        return .valid
    }
}

enum CredentialStatus: Hashable, Sendable {
    case valid
    case expiring(at: Date)
    case expired(at: Date)
}

struct UsageSnapshot: Codable, Hashable, Sendable {
    let provider: ProviderID
    let source: DataSource
    let observedAt: Date
    let reportedAt: Date?
    let plan: String?
    let windows: [UsageWindow]
    let credits: CreditBalance?
    let credential: CredentialInfo?

    init(
        provider: ProviderID,
        source: DataSource,
        observedAt: Date,
        reportedAt: Date? = nil,
        plan: String? = nil,
        windows: [UsageWindow] = [],
        credits: CreditBalance? = nil,
        credential: CredentialInfo? = nil
    ) {
        self.provider = provider
        self.source = source
        self.observedAt = observedAt
        self.reportedAt = reportedAt
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.credential = credential
    }

    var effectiveDate: Date { reportedAt ?? observedAt }

    func expiringElapsedWindows(at now: Date) -> Self {
        .init(
            provider: provider,
            source: source,
            observedAt: observedAt,
            reportedAt: reportedAt,
            plan: plan,
            windows: windows.map { $0.expiringIfNeeded(at: now) },
            credits: credits,
            credential: credential
        )
    }
}

enum UnavailableReason: Codable, Hashable, Sendable {
    case executableMissing
    case executablePathInvalid
    case notSignedIn
    case unsupportedAuthMode
    case unsupportedProtocol(String)
    case adapterNotInstalled
    case noReportYet
    case noUsageData
    case hidden

    var message: String {
        switch self {
        case .executableMissing: "Codex CLI not found"
        case .executablePathInvalid: "The configured Codex path isn’t executable"
        case .notSignedIn: "Codex isn’t signed in"
        case .unsupportedAuthMode: "Usage isn’t reported for this account type"
        case .unsupportedProtocol(let detail): detail
        case .adapterNotInstalled: "Adapter not installed"
        case .noReportYet: "Waiting for Claude Code to report"
        case .noUsageData: "No rate-limit windows reported"
        case .hidden: "Hidden"
        }
    }
}

enum ProviderState: Hashable, Sendable {
    case disconnected
    case loading(previous: UsageSnapshot?)
    case connected(UsageSnapshot)
    case stale(UsageSnapshot, age: TimeInterval)
    case partial(UsageSnapshot, missing: [WindowID])
    case unavailable(reason: UnavailableReason)
    case authError(message: String)
    case credentialExpired(expiredAt: Date, previous: UsageSnapshot?)
    case networkError(previous: UsageSnapshot?, message: String)

    var snapshot: UsageSnapshot? {
        switch self {
        case .connected(let value), .stale(let value, _), .partial(let value, _): value
        case .loading(let previous), .credentialExpired(_, let previous), .networkError(let previous, _): previous
        case .disconnected, .unavailable, .authError: nil
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum ProviderStateResolver {
    static func resolve(
        snapshot: UsageSnapshot,
        now: Date,
        staleAfter: TimeInterval,
        requiredWindows: [WindowID]? = nil
    ) -> ProviderState {
        let normalized = snapshot.expiringElapsedWindows(at: now)
        if let credential = normalized.credential,
           case .expired(let date) = credential.status(at: now) {
            return .credentialExpired(expiredAt: date, previous: normalized)
        }

        let age = max(0, now.timeIntervalSince(normalized.effectiveDate))
        if age > staleAfter { return .stale(normalized, age: age) }

        if let requiredWindows {
            let available = Dictionary(uniqueKeysWithValues: normalized.windows.map { ($0.id, $0.remainingFraction) })
            let missing = requiredWindows.filter { available[$0] == nil || available[$0] == .some(nil) }
            if !missing.isEmpty { return .partial(normalized, missing: missing) }
        }
        return .connected(normalized)
    }
}

enum Thresholds {
    static let lowFraction = 0.25
    static let criticalFraction = 0.10
    static let lowCredits = Decimal(5)
    static let criticalCredits = Decimal(1)
    static let credentialWarning: TimeInterval = 7 * 24 * 60 * 60
}
