import Foundation

actor ClaudeSnapshotReader {
    private var newestReportedAt: Date?
    private var latest: UsageSnapshot?

    func read(from url: URL, observedAt: Date = Date()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? ClaudeStatusLineCore.decodeSnapshot(data),
              newestReportedAt.map({ snapshot.reportedAt >= $0 }) ?? true else {
            return latest
        }

        let windows = snapshot.windows.compactMap { value -> UsageWindow? in
            let id: WindowID
            switch value.id {
            case "5h": id = .fiveHour
            case "7d": id = .sevenDay
            default: return nil
            }
            return UsageWindow(
                id: id,
                usedPercent: (1 - value.remainingFraction) * 100,
                remainingFraction: value.remainingFraction,
                resetsAt: value.resetsAt
            )
        }
        let normalized = UsageSnapshot(
            provider: .claude,
            source: .claudeCodeStatusLine,
            observedAt: observedAt,
            reportedAt: snapshot.reportedAt,
            windows: windows
        )
        newestReportedAt = snapshot.reportedAt
        latest = normalized
        return normalized
    }
}

@MainActor
final class ClaudeSnapshotWatcher {
    private let url: URL
    private let reader: ClaudeSnapshotReader
    private var source: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var descriptor: Int32 = -1
    private let onSnapshot: @MainActor (UsageSnapshot) -> Void

    init(url: URL, reader: ClaudeSnapshotReader = ClaudeSnapshotReader(), onSnapshot: @escaping @MainActor (UsageSnapshot) -> Void) {
        self.url = url
        self.reader = reader
        self.onSnapshot = onSnapshot
    }

    func start() {
        stop()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedLoad()
                }
            }
            source.setCancelHandler { @Sendable [descriptor] in close(descriptor) }
            source.resume()
            self.source = source
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.load() }
        }
        Task { await load() }
    }

    func stop() {
        source?.cancel()
        source = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        debounceTask?.cancel()
        debounceTask = nil
        if descriptor >= 0, source == nil { descriptor = -1 }
    }

    private func load() async {
        if let snapshot = await reader.read(from: url) { onSnapshot(snapshot) }
    }

    private func scheduleDebouncedLoad() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

}
