import Foundation

enum OpenRouterError: Error, Equatable, LocalizedError {
    case invalidKeyFormat
    case notManagementKey
    case credentialExpired(Date?)
    case unauthorized
    case forbidden
    case missingCredential
    case malformedResponse
    case httpStatus(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidKeyFormat: "Doesn’t look like an OpenRouter key"
        case .notManagementKey: "Not a management key"
        case .credentialExpired: "Management key expired"
        case .unauthorized, .forbidden: "Key rejected"
        case .missingCredential: "No management key is stored"
        case .malformedResponse: "OpenRouter returned an invalid response"
        case .httpStatus(let status): "OpenRouter returned HTTP \(status)"
        case .transport: "Couldn’t reach OpenRouter"
        }
    }
}

struct OpenRouterClient: Sendable {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let session: URLSession
    private let baseURL: URL
    private let sleeper: Sleeper
    private let maximumResponseBytes = 256 * 1_024

    init(
        session: URLSession? = nil,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
        self.sleeper = sleeper
    }

    func validate(key: String, now: Date = Date()) async throws -> CredentialInfo {
        let response: KeyEnvelope = try await get(path: "key", key: key)
        guard response.data.isManagementKey else { throw OpenRouterError.notManagementKey }
        let credential = CredentialInfo(
            isManagementKey: true,
            expiresAt: response.data.expiresAt,
            label: response.data.label
        )
        if case .expired(let date) = credential.status(at: now) {
            throw OpenRouterError.credentialExpired(date)
        }
        return credential
    }

    func fetchCredits(key: String) async throws -> CreditBalance {
        let response: CreditsEnvelope = try await get(path: "credits", key: key)
        return .init(totalCredits: response.data.totalCredits, totalUsage: response.data.totalUsage)
    }

    func fetchSnapshot(key: String, now: Date = Date()) async throws -> UsageSnapshot {
        let credential = try await validate(key: key, now: now)
        let credits = try await fetchCredits(key: key)
        return UsageSnapshot(
            provider: .openRouter,
            source: .openRouterCreditsAPI,
            observedAt: now,
            credits: credits,
            credential: credential
        )
    }

    private func get<Response: Decodable>(path: String, key: String) async throws -> Response {
        var lastError: Error?
        for attempt in 0 ..< 3 {
            do {
                var request = URLRequest(url: baseURL.appendingPathComponent(path))
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard data.count <= maximumResponseBytes else { throw OpenRouterError.malformedResponse }
                guard let http = response as? HTTPURLResponse else { throw OpenRouterError.malformedResponse }
                switch http.statusCode {
                case 200 ..< 300:
                    do { return try Self.decoder.decode(Response.self, from: data) }
                    catch { throw OpenRouterError.malformedResponse }
                case 401:
                    let message = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                    if message.contains("expired") { throw OpenRouterError.credentialExpired(nil) }
                    throw OpenRouterError.unauthorized
                case 403: throw OpenRouterError.forbidden
                case 429, 500 ... 599:
                    let delay = Self.retryDelay(response: http, attempt: attempt)
                    guard attempt < 2 else { throw OpenRouterError.httpStatus(http.statusCode) }
                    try await sleeper(delay)
                default: throw OpenRouterError.httpStatus(http.statusCode)
                }
            } catch let error as OpenRouterError {
                if !Self.retryable(error) { throw error }
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = OpenRouterError.transport(error.localizedDescription)
                if attempt < 2 { try await sleeper(.seconds(1 << attempt)) }
            }
        }
        throw lastError ?? OpenRouterError.transport("Request failed")
    }

    private static func retryable(_ error: OpenRouterError) -> Bool {
        switch error {
        case .httpStatus(let code): code == 429 || code >= 500
        case .transport: true
        default: false
        }
    }

    private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> Duration {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value), seconds.isFinite {
            return .milliseconds(Int64(min(max(seconds, 0), 60) * 1_000))
        }
        return .seconds(1 << attempt)
    }

    private struct KeyEnvelope: Decodable {
        struct KeyData: Decodable {
            let isManagementKey: Bool
            let expiresAt: Date?
            let label: String?

            enum CodingKeys: String, CodingKey {
                case isManagementKey = "is_management_key"
                case expiresAt = "expires_at"
                case label
            }
        }
        let data: KeyData
    }

    private struct CreditsEnvelope: Decodable {
        struct CreditsData: Decodable {
            let totalCredits: Decimal
            let totalUsage: Decimal
            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
        let data: CreditsData
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { throw DecodingError.valueNotFound(Date.self, .init(codingPath: decoder.codingPath, debugDescription: "null date")) }
            let string = try container.decode(String.self)
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = precise.date(from: string) { return date }
            let basic = ISO8601DateFormatter()
            guard let date = basic.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
            }
            return date
        }
        return decoder
    }()
}

actor OpenRouterService {
    private let client: OpenRouterClient
    private let secretStore: any SecretStore
    private var inFlight: Task<UsageSnapshot, Error>?
    private var coalescedRefreshWaiters = 0
    private var automaticRefreshBlocked = false

    var activeRefreshRequestCount: Int {
        (inFlight == nil ? 0 : 1) + coalescedRefreshWaiters
    }

    init(client: OpenRouterClient, secretStore: any SecretStore) {
        self.client = client
        self.secretStore = secretStore
    }

    func connect(key: String, now: Date = Date()) async throws -> UsageSnapshot {
        let snapshot = try await client.fetchSnapshot(key: key, now: now)
        guard let data = key.data(using: .utf8) else { throw OpenRouterError.invalidKeyFormat }
        try await secretStore.save(data)
        automaticRefreshBlocked = false
        return snapshot
    }

    func refresh(now: Date = Date(), manual: Bool = false) async throws -> UsageSnapshot {
        if let inFlight {
            coalescedRefreshWaiters += 1
            defer { coalescedRefreshWaiters -= 1 }
            return try await inFlight.value
        }
        if automaticRefreshBlocked, !manual { throw OpenRouterError.unauthorized }
        let task = Task<UsageSnapshot, Error> {
            guard let data = try await secretStore.load(),
                  let key = String(data: data, encoding: .utf8) else {
                throw OpenRouterError.missingCredential
            }
            return try await client.fetchSnapshot(key: key, now: now)
        }
        inFlight = task
        defer { inFlight = nil }
        do {
            let snapshot = try await task.value
            if manual { automaticRefreshBlocked = false }
            return snapshot
        }
        catch let error as OpenRouterError {
            switch error {
            case .unauthorized, .forbidden, .credentialExpired, .notManagementKey:
                automaticRefreshBlocked = true
            default: break
            }
            throw error
        }
    }

    func disconnect() async throws {
        inFlight?.cancel()
        inFlight = nil
        automaticRefreshBlocked = false
        try await secretStore.delete()
    }

    func hasCredential() async -> Bool {
        (try? await secretStore.contains()) == true
    }

    func secretBacking() async -> SecretStoreBacking? {
        await secretStore.backing()
    }
}
