import Foundation
import Darwin

final class CodexChildProcessRegistry: @unchecked Sendable {
    static let shared = CodexChildProcessRegistry()

    private let lock = NSLock()
    private var processIdentifier: pid_t?

    func register(_ processIdentifier: pid_t) {
        lock.withLock { self.processIdentifier = processIdentifier }
    }

    func clear(_ processIdentifier: pid_t) {
        lock.withLock {
            if self.processIdentifier == processIdentifier { self.processIdentifier = nil }
        }
    }

    func terminateSynchronously() {
        let identifier = lock.withLock { processIdentifier }
        guard let identifier, identifier > 0 else { return }
        guard kill(identifier, SIGTERM) == 0 else {
            clear(identifier)
            return
        }

        // App termination cannot rely on an async Process termination handler.
        // Give a cooperative child 200 ms, then guarantee that it cannot outlive us.
        for _ in 0 ..< 20 {
            if kill(identifier, 0) != 0 {
                clear(identifier)
                return
            }
            usleep(10_000)
        }
        _ = kill(identifier, SIGKILL)
        clear(identifier)
    }

    var registeredProcessIdentifier: pid_t? { lock.withLock { processIdentifier } }
}

private func terminateCodexChildAtExit() {
    CodexChildProcessRegistry.shared.terminateSynchronously()
}

@discardableResult
func installCodexChildExitBackstop() -> Bool {
    struct Once {
        static let result = atexit(terminateCodexChildAtExit) == 0
    }
    return Once.result
}

enum CodexAdapterError: Error, Equatable, LocalizedError {
    case executableMissing(String)
    case processLaunch(String)
    case handshakeTimeout
    case requestTimeout(String)
    case protocolViolation(String)
    case lineTooLong
    case bufferOverflow
    case notSignedIn
    case unsupportedAuthMode(String)
    case serverError(code: Int?, message: String)
    case terminated

    var errorDescription: String? {
        switch self {
        case .executableMissing: "Codex CLI not found"
        case .processLaunch(let value): "Couldn’t launch Codex: \(value)"
        case .handshakeTimeout: "Codex app-server didn’t initialize in time"
        case .requestTimeout(let method): "Codex request timed out: \(method)"
        case .protocolViolation(let value): "Codex protocol error: \(value)"
        case .lineTooLong: "Codex sent an oversized JSON message"
        case .bufferOverflow: "Codex output buffer exceeded its limit"
        case .notSignedIn: "Codex isn’t signed in"
        case .unsupportedAuthMode: "Codex isn’t using a supported subscription account"
        case .serverError(_, let message): message
        case .terminated: "Codex app-server stopped"
        }
    }
}

struct JSONLineFramer: Sendable {
    let maximumLineBytes: Int
    let maximumBufferBytes: Int
    private(set) var buffer = Data()

    init(maximumLineBytes: Int = 1_048_576, maximumBufferBytes: Int = 2_097_152) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumBufferBytes = maximumBufferBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        guard buffer.count + data.count <= maximumBufferBytes else { throw CodexAdapterError.bufferOverflow }
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard line.count <= maximumLineBytes else { throw CodexAdapterError.lineTooLong }
            let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
            if !trimmed.isEmpty { lines.append(Data(trimmed)) }
        }
        guard buffer.count <= maximumLineBytes else { throw CodexAdapterError.lineTooLong }
        return lines
    }
}

enum CodexRateLimitDecoder {
    static func snapshot(from result: JSONValue, observedAt: Date = Date()) throws -> UsageSnapshot {
        guard let object = result.objectValue else {
            throw CodexAdapterError.protocolViolation("rate-limit result is not an object")
        }

        let selectedBuckets: [(String, JSONValue)]
        if let multiValue = object["rateLimitsByLimitId"] {
            guard case .object(let multi) = multiValue else {
                throw CodexAdapterError.protocolViolation("rateLimitsByLimitId is not an object")
            }
            if let codex = multi["codex"] { selectedBuckets = [("codex", codex)] }
            else { selectedBuckets = multi.sorted(by: { $0.key < $1.key }) }
        } else if let legacy = object["rateLimits"] {
            selectedBuckets = [("codex", legacy)]
        } else {
            throw CodexAdapterError.protocolViolation("rate limits are missing")
        }

        var windows: [UsageWindow] = []
        var plan: String?
        for (bucketID, value) in selectedBuckets {
            guard let bucket = value.objectValue else { continue }
            plan = plan ?? bucket["planType"]?.stringValue ?? object["planType"]?.stringValue
            let limitName = bucket["limitName"]?.stringValue
            for field in ["primary", "secondary"] {
                guard let raw = bucket[field], case .object(let window) = raw else { continue }
                guard let used = window["usedPercent"]?.doubleValue,
                      let durationValue = window["windowDurationMins"]?.doubleValue else { continue }
                let duration = Int(durationValue)
                let id = WindowID.from(durationMinutes: duration)
                let label = limitName.flatMap { selectedBuckets.count > 1 ? "\($0) · \(id.label)" : nil } ?? id.label
                windows.append(.fromUsedPercent(
                    used,
                    id: id,
                    label: label,
                    durationMinutes: duration,
                    resetsAt: window["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
                ))
            }
            _ = bucketID
        }
        return UsageSnapshot(
            provider: .codex,
            source: .codexAppServer,
            observedAt: observedAt,
            plan: plan,
            windows: windows
        )
    }

    /// The account's authentication mode.
    ///
    /// The shipping app-server answers `account/read` with `account.type` (`"chatgpt"` for a signed-in
    /// subscription) and carries no `authMode` key at all, so requiring `authMode` rejected a
    /// correctly signed-in account as "Codex isn’t signed in". Both documented spellings are
    /// accepted; `authMode` still wins where a build provides it.
    static func authMode(from result: JSONValue) -> String? {
        result["authMode"]?.stringValue
            ?? result["account"]?["authMode"]?.stringValue
            ?? result["account"]?["type"]?.stringValue
    }
}

actor CodexAppServerClient {
    typealias UpdateHandler = @Sendable (UsageSnapshot) async -> Void

    private let executableURL: URL
    private let interpreterDirectories: [URL]
    private let handshakeTimeout: Duration
    private let requestTimeout: Duration
    private let updateHandler: UpdateHandler?
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var chunkConsumerTask: Task<Void, Never>?
    private var framer = JSONLineFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var initialized = false

    var runningProcessIdentifier: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }

    init(
        executableURL: URL,
        interpreterDirectories: [URL] = [],
        handshakeTimeout: Duration = .seconds(5),
        requestTimeout: Duration = .seconds(8),
        updateHandler: UpdateHandler? = nil
    ) {
        self.executableURL = executableURL
        self.interpreterDirectories = interpreterDirectories
        self.handshakeTimeout = handshakeTimeout
        self.requestTimeout = requestTimeout
        self.updateHandler = updateHandler
        installCodexChildExitBackstop()
    }

    func readSnapshot() async throws -> UsageSnapshot {
        var lastError: Error?
        for _ in 0 ..< 2 {
            do {
                if !initialized { try await connect() }
                let account = try await request(method: "account/read", params: .object([:]))
                try validateAuthMode(account)
                let result = try await request(method: "account/rateLimits/read", params: .object([:]))
                return try CodexRateLimitDecoder.snapshot(from: result)
            } catch {
                lastError = error
                disconnect()
                guard Self.shouldReconnect(after: error) else { throw error }
            }
        }
        throw lastError ?? CodexAdapterError.terminated
    }

    func connect() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAdapterError.executableMissing(executableURL.path)
        }
        disconnect()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = CodexChildEnvironment.make(
            source: ProcessInfo.processInfo.environment,
            prepending: interpreterDirectories
        )
        let (chunks, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        chunkContinuation = continuation
        chunkConsumerTask = Task { [weak self] in
            for await data in chunks {
                guard !Task.isCancelled else { return }
                await self?.consume(data)
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            switch continuation.yield(data) {
            case .dropped:
                Task { await self?.streamBufferOverflowed() }
            case .enqueued, .terminated:
                break
            @unknown default:
                Task { await self?.streamBufferOverflowed() }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData.prefix(8_192)
        }
        process.terminationHandler = { [weak self] process in
            let identifier = process.processIdentifier
            Task { await self?.processTerminated(identifier: identifier) }
        }
        self.process = process
        stdoutPipe = output
        stderrPipe = errors
        stdin = input.fileHandleForWriting
        do { try process.run() }
        catch {
            disconnect()
            throw CodexAdapterError.processLaunch(error.localizedDescription)
        }
        CodexChildProcessRegistry.shared.register(process.processIdentifier)

        do {
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("UsageTool"),
                        "title": .string("UsageTool"),
                        "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"),
                    ]),
                ]),
                timeout: handshakeTimeout
            )
        } catch is CancellationError {
            throw CodexAdapterError.handshakeTimeout
        } catch let error as CodexAdapterError {
            if case .requestTimeout = error { throw CodexAdapterError.handshakeTimeout }
            throw error
        }
        try send(.object(["method": .string("initialized"), "params": .object([:])]))
        initialized = true
    }

    func disconnect() {
        initialized = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stdoutPipe = nil
        stderrPipe = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        try? stdin?.close()
        stdin = nil
        if let process {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
        failPending(with: CodexAdapterError.terminated)
        framer = JSONLineFramer()
    }

    private func request(method: String, params: JSONValue, timeout: Duration? = nil) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let timeout = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(.object([
                        "method": .string(method),
                        "id": .number(Double(id)),
                        "params": params,
                    ]))
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutRequest(id: id, method: method)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: CodexAdapterError.requestTimeout(method))
    }

    private func cancelRequest(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func send(_ value: JSONValue) throws {
        guard let stdin else { throw CodexAdapterError.terminated }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func consume(_ data: Data) async {
        do {
            for line in try framer.append(data) {
                let message = try JSONDecoder().decode(JSONValue.self, from: line)
                try await handle(message)
            }
        } catch {
            failPending(with: error)
            disconnect()
        }
    }

    private func streamBufferOverflowed() {
        failPending(with: CodexAdapterError.bufferOverflow)
        disconnect()
    }

    private func handle(_ message: JSONValue) async throws {
        // A top-level non-object cannot be a JSON-RPC response or notification. Treat it
        // as framing/protocol corruption and fail closed; a later user/wake/network refresh
        // may establish a new process, while the deterministic error never retry-loops.
        guard let object = message.objectValue else { throw CodexAdapterError.protocolViolation("message is not an object") }
        if let idValue = object["id"]?.doubleValue {
            let id = Int(idValue)
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"]?.objectValue {
                continuation.resume(throwing: CodexAdapterError.serverError(
                    code: error["code"]?.doubleValue.map(Int.init),
                    message: error["message"]?.stringValue ?? "Codex request failed"
                ))
            } else if let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexAdapterError.protocolViolation("response has no result"))
            }
            return
        }

        guard object["method"]?.stringValue == "account/rateLimits/updated",
              let params = object["params"], let updateHandler else { return }
        guard let snapshot = try? CodexRateLimitDecoder.snapshot(from: params) else { return }
        await updateHandler(snapshot)
    }

    private func validateAuthMode(_ result: JSONValue) throws {
        guard let mode = CodexRateLimitDecoder.authMode(from: result) else {
            throw CodexAdapterError.notSignedIn
        }
        switch mode {
        case "chatgpt", "personalAccessToken", "agentIdentity": return
        case "apikey", "bedrockApiKey", "chatgptAuthTokens": throw CodexAdapterError.unsupportedAuthMode(mode)
        default: throw CodexAdapterError.unsupportedAuthMode(mode)
        }
    }

    private func processTerminated(identifier: pid_t) {
        CodexChildProcessRegistry.shared.clear(identifier)
        guard process?.processIdentifier == identifier else { return }
        initialized = false
        process = nil
        stdin = nil
        failPending(with: CodexAdapterError.terminated)
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    static func shouldReconnect(after error: Error) -> Bool {
        guard let error = error as? CodexAdapterError else { return true }
        switch error {
        case .requestTimeout, .handshakeTimeout, .terminated, .processLaunch:
            return true
        case .executableMissing, .protocolViolation, .lineTooLong, .bufferOverflow,
             .notSignedIn, .unsupportedAuthMode, .serverError:
            return false
        }
    }
}
