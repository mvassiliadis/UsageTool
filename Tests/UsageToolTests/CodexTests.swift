import Foundation
import Testing
@testable import UsageTool

struct CodexTests {
    @Test func framerHandlesSplitAndMultipleLines() throws {
        var framer = JSONLineFramer(maximumLineBytes: 100, maximumBufferBytes: 200)
        #expect(try framer.append(Data("{\"id\":1".utf8)).isEmpty)
        let lines = try framer.append(Data("}\n{\"id\":2}\r\n".utf8))
        #expect(lines.count == 2)
        #expect(String(data: lines[0], encoding: .utf8) == "{\"id\":1}")
        #expect(String(data: lines[1], encoding: .utf8) == "{\"id\":2}")
    }

    @Test func framerRejectsOversizedInput() {
        var framer = JSONLineFramer(maximumLineBytes: 4, maximumBufferBytes: 8)
        #expect(throws: CodexAdapterError.lineTooLong) { try framer.append(Data("12345".utf8)) }
    }

    @Test func multiBucketExclusivelyOverridesLegacy() throws {
        let result = try fixture("codex-multi")
        let snapshot = try CodexRateLimitDecoder.snapshot(from: result, observedAt: .distantPast)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first(where: { $0.id == .fiveHour })?.remainingFraction == 0.73)
        let weekly = try #require(snapshot.windows.first(where: { $0.id == .sevenDay })?.remainingFraction)
        #expect(abs(weekly - 0.58) < 0.000_001)
    }

    @Test func legacyAllowsNullSecondaryAndDerivesUnknownDuration() throws {
        let snapshot = try CodexRateLimitDecoder.snapshot(from: fixture("codex-legacy"))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == .other(minutes: 60))
        #expect(snapshot.windows[0].label == "1-hour")
        #expect(snapshot.windows[0].remainingFraction == 0.8)
    }

    @Test func missingResetKeepsUsableWindowAndEmptyWindowsAreTolerated() throws {
        let withoutReset: JSONValue = .object([
            "rateLimits": .object([
                "primary": .object([
                    "usedPercent": .number(25),
                    "windowDurationMins": .number(300),
                ]),
                "secondary": .null,
            ]),
        ])
        let snapshot = try CodexRateLimitDecoder.snapshot(from: withoutReset)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].remainingFraction == 0.75)
        #expect(snapshot.windows[0].resetsAt == nil)

        let empty = try CodexRateLimitDecoder.snapshot(from: .object([
            "rateLimits": .object(["primary": .null, "secondary": .null]),
        ]))
        #expect(empty.windows.isEmpty)
    }

    @Test func deterministicFailuresDoNotReconnect() {
        #expect(!CodexAppServerClient.shouldReconnect(after: CodexAdapterError.notSignedIn))
        #expect(!CodexAppServerClient.shouldReconnect(after: CodexAdapterError.unsupportedAuthMode("apikey")))
        #expect(!CodexAppServerClient.shouldReconnect(after: CodexAdapterError.executableMissing("missing")))
        #expect(!CodexAppServerClient.shouldReconnect(after: CodexAdapterError.protocolViolation("non-object JSONL message")))
        #expect(CodexAppServerClient.shouldReconnect(after: CodexAdapterError.terminated))
        #expect(CodexAppServerClient.shouldReconnect(after: CodexAdapterError.requestTimeout("method")))
    }

    @Test func clientPreservesChunkOrderIgnoresMalformedNotificationAndDisconnectsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s' '{"id":1,"res'
              printf '%s\n' 'ult":{}}'
              ;;
            2) ;;
            3)
              printf '%s\n' '{"id":2,"result":{"authMode":"chatgpt"}}'
              ;;
            4)
              printf '%s\n' '{"method":"account/rateLimits/updated","params":{"malformed":true}}'
              printf '%s\n' '{"id":3,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1800000000},"secondary":null}}}'
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let client = CodexAppServerClient(executableURL: executable)
        let snapshot = try await client.readSnapshot()
        #expect(snapshot.plan == "plus")
        #expect(snapshot.windows.first?.remainingFraction == 0.8)
        #expect(await client.runningProcessIdentifier != nil)
        await client.disconnect()
        #expect(await client.runningProcessIdentifier == nil)
    }

    @Test func synchronousRegistryTerminationSignalsRegisteredChild() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf r; while :; do :; done"]
        process.standardOutput = output
        try process.run()
        #expect(try output.fileHandleForReading.read(upToCount: 1) == Data("r".utf8))
        let registry = CodexChildProcessRegistry()
        registry.register(process.processIdentifier)
        #expect(registry.registeredProcessIdentifier == process.processIdentifier)
        registry.terminateSynchronously()
        process.waitUntilExit()
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(registry.registeredProcessIdentifier == nil)
    }

    /// The shipping app-server reports the account mode as `account.type`, with no `authMode` key.
    /// Requiring `authMode` made a signed-in ChatGPT subscription read as "Codex isn’t signed in".
    @Test func authModeIsReadFromEitherDocumentedSpelling() {
        let shipping: JSONValue = .object([
            "account": .object([
                "email": .string("redacted@example.invalid"),
                "planType": .string("prolite"),
                "type": .string("chatgpt"),
            ]),
            "requiresOpenaiAuth": .bool(true),
        ])
        #expect(CodexRateLimitDecoder.authMode(from: shipping) == "chatgpt")
        #expect(CodexRateLimitDecoder.authMode(from: .object(["authMode": .string("chatgpt")])) == "chatgpt")
        #expect(CodexRateLimitDecoder.authMode(from: .object(["account": .object(["authMode": .string("apikey")])])) == "apikey")
        // An explicit authMode still outranks the nested account type.
        #expect(CodexRateLimitDecoder.authMode(from: .object([
            "authMode": .string("personalAccessToken"),
            "account": .object(["type": .string("chatgpt")]),
        ])) == "personalAccessToken")
        #expect(CodexRateLimitDecoder.authMode(from: .object(["account": .null])) == nil)
        #expect(CodexRateLimitDecoder.authMode(from: .object([:])) == nil)
    }

    /// The live `account/rateLimits/read` payload, reduced to its structure: a single `codex` bucket
    /// with a null `limitName`, a null `secondary`, and sibling fields the decoder must ignore.
    @Test func decodesTheShippingRateLimitPayload() throws {
        let result: JSONValue = .object([
            "accountId": .string("redacted"),
            "ordinaryUsageAllowed": .bool(true),
            "rateLimitUpsell": .null,
            "rateLimits": .object([
                "planType": .string("prolite"),
                "primary": .object([
                    "resetsAt": .number(1_789_894_790),
                    "usedPercent": .number(85),
                    "windowDurationMins": .number(10_080),
                ]),
                "secondary": .null,
            ]),
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "credits": .object(["hasCredits": .bool(false), "unlimited": .bool(false)]),
                    "individualLimit": .null,
                    "limitName": .null,
                    "planType": .string("prolite"),
                    "primary": .object([
                        "resetsAt": .number(1_789_894_790),
                        "usedPercent": .number(85),
                        "windowDurationMins": .number(10_080),
                    ]),
                    "secondary": .null,
                    "spendControlReached": .bool(false),
                ]),
            ]),
        ])
        let snapshot = try CodexRateLimitDecoder.snapshot(from: result, observedAt: .distantPast)
        #expect(snapshot.plan == "prolite")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == .sevenDay)
        #expect(snapshot.windows[0].label == "7-day")
        let remaining = try #require(snapshot.windows[0].remainingFraction)
        #expect(abs(remaining - 0.15) < 0.000_001)
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_894_790))
    }

    /// End-to-end proof for the reported defect, against a real on-disk tree shaped like an NVM
    /// install: `bin/codex` is a symlink to a JavaScript file whose only interpreter is a `node`
    /// sitting beside the symlink, exactly as `@openai/codex` installs it.
    ///
    /// Discovery, the composed child `PATH`, and the app-server handshake are exercised together,
    /// because each was individually plausible and the app still failed.
    @Test func nvmStyleLauncherIsDiscoveredAndReachesTheHandshake() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".nvm/versions/node/v22.22.3/bin", isDirectory: true)
        let package = home.appendingPathComponent(
            ".nvm/versions/node/v22.22.3/lib/node_modules/@openai/codex/bin",
            isDirectory: true
        )
        // A stale older runtime must lose to the newer one even though it also carries an install.
        let olderBinary = home.appendingPathComponent(".nvm/versions/node/v20.11.1/bin", isDirectory: true)
        for directory in [binary, package, olderBinary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Stands in for `node`: reached only through the shebang, and only if its directory is on
        // the child's PATH. Its own name is unique so a real node on the machine cannot satisfy it.
        let interpreterName = "usagetool-test-node"
        let responder = #"""
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\n' '{"id":1,"result":{}}' ;;
            3) printf '%s\n' '{"id":2,"result":{"account":{"planType":"pro","type":"chatgpt"},"requiresOpenaiAuth":true}}' ;;
            4) printf '%s\n' '{"id":3,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":30,"windowDurationMins":300},"secondary":null}}}' ;;
          esac
        done
        """#
        for directory in [binary, olderBinary] {
            let interpreter = directory.appendingPathComponent(interpreterName)
            try Data(responder.utf8).write(to: interpreter)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
        }
        let launcher = package.appendingPathComponent("codex.js")
        try Data("#!/usr/bin/env \(interpreterName)\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        for directory in [binary, olderBinary] {
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent("codex"),
                withDestinationURL: launcher
            )
        }

        let locator = CodexExecutableLocator(
            homeDirectory: home,
            environment: ["PATH": CodexChildEnvironment.systemSearchPath]
        )
        let resolution = try locator.locate(configuredPath: "").get()
        #expect(resolution.url.path == binary.appendingPathComponent("codex").path)
        #expect(resolution.origin == .nodeVersionManager("nvm"))

        // The minimal GUI environment alone cannot run this launcher…
        #expect(try Self.launchExitStatus(resolution.url, interpreterDirectories: []) != 0)
        // …and the resolution's interpreter directory is exactly what makes it run.
        #expect(try Self.launchExitStatus(resolution.url, interpreterDirectories: resolution.interpreterDirectories) == 0)

        let client = CodexAppServerClient(
            executableURL: resolution.url,
            interpreterDirectories: resolution.interpreterDirectories
        )
        let snapshot = try await client.readSnapshot()
        #expect(snapshot.plan == "pro")
        #expect(snapshot.windows.first?.remainingFraction == 0.7)
        await client.disconnect()
    }

    /// Runs the launcher with a closed stdin under the same environment the adapter composes, and
    /// reports the exit status. A missing interpreter makes `env` fail before any output.
    private static func launchExitStatus(_ url: URL, interpreterDirectories: [URL]) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = CodexChildEnvironment.make(
            source: ["PATH": CodexChildEnvironment.systemSearchPath],
            prepending: interpreterDirectories
        )
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func fixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
}

private final class FixtureToken {}
