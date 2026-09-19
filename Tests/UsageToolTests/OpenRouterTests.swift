import Foundation
import Testing
@testable import UsageTool

@Suite(.serialized)
struct OpenRouterTests {
    @Test func nonPrefixedManagementKeyValidatesBeforeKeychainStorageAndCreditsStayMonetary() async throws {
        let store = MemorySecretStore()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/v1/key":
                response(request, status: 200, body: #"{"data":{"is_management_key":true,"expires_at":null,"label":"ignored"}}"#)
            case "/api/v1/credits":
                response(request, status: 200, body: #"{"data":{"total_credits":100.50,"total_usage":25.25}}"#)
            default:
                response(request, status: 404, body: "{}")
            }
        }
        let service = OpenRouterService(client: client, secretStore: store)
        let snapshot = try await service.connect(key: "non-prefixed-test-management-key")
        let stored = try await store.contains()
        #expect(stored)
        #expect(snapshot.credits?.remaining == Decimal(string: "75.25"))
        #expect(snapshot.windows.isEmpty)
        #expect(UsageFormatters.percent(snapshot.windows.first?.remainingFraction) == nil)
    }

    @Test func nonManagementKeyIsRejectedBeforeStorage() async throws {
        let store = MemorySecretStore()
        let client = makeClient { request in
            response(request, status: 200, body: #"{"data":{"is_management_key":false,"expires_at":null,"label":null}}"#)
        }
        let service = OpenRouterService(client: client, secretStore: store)
        do {
            _ = try await service.connect(key: "not-a-real-key")
            Issue.record("Expected non-management key rejection")
        } catch let error as OpenRouterError {
            #expect(error == .notManagementKey)
        }
        let stored = try await store.contains()
        #expect(!stored)
    }

    @Test func expiredAndExpiringCredentialsRemainDistinct() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = makeClient { request in
            response(request, status: 200, body: #"{"data":{"is_management_key":true,"expires_at":"2027-01-15T08:00:00Z","label":null}}"#)
        }
        do {
            _ = try await expired.validate(key: "test", now: now)
            Issue.record("Expected expired credential")
        } catch let error as OpenRouterError {
            guard case .credentialExpired = error else { Issue.record("Wrong error: \(error)"); return }
        }

        let expiry = now.addingTimeInterval(3 * 86_400)
        let expiryString = ISO8601DateFormatter().string(from: expiry)
        let expiring = makeClient { request in
            response(request, status: 200, body: "{\"data\":{\"is_management_key\":true,\"expires_at\":\"\(expiryString)\",\"label\":null}}")
        }
        let credential = try await expiring.validate(key: "test", now: now)
        guard case .expiring(let date) = credential.status(at: now) else { Issue.record("Expected expiring credential"); return }
        #expect(abs(date.timeIntervalSince(expiry)) < 1)
    }

    @Test func authenticationFailuresDoNotRetryAndExpiredMessageIsClassified() async throws {
        let counter = LockedCounter()
        let client = makeClient { request in
            counter.increment()
            return response(request, status: 401, body: #"{"error":{"message":"API key expired"}}"#)
        }
        do {
            _ = try await client.validate(key: "test")
            Issue.record("Expected expired credential")
        } catch let error as OpenRouterError {
            guard case .credentialExpired = error else { Issue.record("Wrong error: \(error)"); return }
        }
        #expect(counter.value == 1)

        counter.reset()
        MockURLProtocol.handler = { request in
            counter.increment()
            return response(request, status: 403, body: "{}")
        }
        do {
            _ = try await client.validate(key: "test")
            Issue.record("Expected forbidden")
        } catch let error as OpenRouterError {
            #expect(error == .forbidden)
        }
        #expect(counter.value == 1)
    }

    @Test func automaticRefreshRemainsBlockedAfterAuthenticationFailureUntilManualAction() async throws {
        for status in [401, 403] {
            let counter = LockedCounter()
            let store = MemorySecretStore()
            await store.save(Data("test-key".utf8))
            let client = makeClient { request in
                counter.increment()
                if counter.value == 1 {
                    return response(request, status: status, body: #"{"error":{"message":"rejected"}}"#)
                }
                if request.url?.path.hasSuffix("/key") == true {
                    return response(request, status: 200, body: #"{"data":{"is_management_key":true,"expires_at":null,"label":null}}"#)
                }
                return response(request, status: 200, body: #"{"data":{"total_credits":10,"total_usage":3}}"#)
            }
            let service = OpenRouterService(client: client, secretStore: store)

            do {
                _ = try await service.refresh()
                Issue.record("Expected authentication failure")
            } catch let error as OpenRouterError {
                #expect(error == (status == 401 ? .unauthorized : .forbidden))
            }
            #expect(counter.value == 1)

            do {
                _ = try await service.refresh()
                Issue.record("Expected automatic refresh to remain blocked")
            } catch let error as OpenRouterError {
                #expect(error == .unauthorized)
            }
            #expect(counter.value == 1)

            let snapshot = try await service.refresh(manual: true)
            #expect(snapshot.credits?.remaining == 7)
            #expect(counter.value == 3)

            _ = try await service.refresh()
            #expect(counter.value == 5)
        }
    }

    @Test func retryAfterAndRetryLimitAreHonoured() async throws {
        let counter = LockedCounter()
        let delays = DurationRecorder()
        let client = makeClient(sleeper: { duration in await delays.append(duration) }) { request in
            counter.increment()
            if counter.value == 1 {
                return response(request, status: 429, headers: ["Retry-After": "2"], body: "{}")
            }
            return response(request, status: 200, body: #"{"data":{"is_management_key":true,"expires_at":null,"label":null}}"#)
        }
        _ = try await client.validate(key: "test")
        #expect(counter.value == 2)
        #expect(await delays.values == [.seconds(2)])
    }

    @Test func concurrentRefreshesAreCoalesced() async throws {
        let counter = LockedCounter()
        let gate = BlockingGate()
        let store = MemorySecretStore()
        await store.save(Data("test-key".utf8))
        let client = makeClient { request in
            counter.increment()
            if request.url?.path.hasSuffix("/key") == true {
                gate.enterAndWait()
                return response(request, status: 200, body: #"{"data":{"is_management_key":true,"expires_at":null,"label":null}}"#)
            }
            return response(request, status: 200, body: #"{"data":{"total_credits":10,"total_usage":3}}"#)
        }
        let service = OpenRouterService(client: client, secretStore: store)
        let first = Task { try await service.refresh() }
        #expect(gate.waitUntilEntered())
        let second = Task { try await service.refresh() }
        var joinedInFlight = false
        for _ in 0 ..< 10_000 {
            if await service.activeRefreshRequestCount == 2 {
                joinedInFlight = true
                break
            }
            await Task.yield()
        }
        #expect(joinedInFlight)
        gate.open()
        let values = try await [first.value, second.value]
        #expect(values[0] == values[1])
        #expect(counter.value == 2)
    }

    private func makeClient(
        sleeper: @escaping OpenRouterClient.Sleeper = { _ in },
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> OpenRouterClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.urlCache = nil
        return OpenRouterClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://openrouter.invalid/api/v1")!,
            sleeper: sleeper
        )
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.withLock { storage += 1 } }
    func reset() { lock.withLock { storage = 0 } }
    var value: Int { lock.withLock { storage } }
}

private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor DurationRecorder {
    private(set) var values: [Duration] = []
    func append(_ value: Duration) { values.append(value) }
}

private func response(
    _ request: URLRequest,
    status: Int,
    headers: [String: String]? = nil,
    body: String
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
    return (response, Data(body.utf8))
}
