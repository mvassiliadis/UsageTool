import Foundation
import Testing
@testable import UsageTool

/// An in-memory filesystem, so discovery is exercised without depending on what happens to be
/// installed on the machine running the tests.
private struct StubFileProbe: CodexFileProbing {
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]
    var symlinks: [String: String] = [:]
    var shebangs: [String: String] = [:]

    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func subdirectoryNames(atPath path: String) -> [String] { directories[path] ?? [] }
    func resolvedSymbolicLink(atPath path: String) -> String? { symlinks[path] }
    func shebangLine(atPath path: String) -> String? { shebangs[path] }
}

/// Regression coverage for the GUI-launch discovery failure.
///
/// A menu-bar app inherits `launchd`'s `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), never a login
/// shell's. The app reported "Codex CLI not found" although `which codex` resolved fine in Terminal,
/// and — once found — an npm/nvm launcher still died because its `#!/usr/bin/env node` interpreter
/// was not reachable from the child's minimal `PATH`. Both halves are pinned here.
struct CodexDiscoveryTests {
    private static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private static let guiSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let nvmRoot = "/Users/tester/.nvm/versions/node"

    /// The real machine's layout: codex installed only under one NVM runtime, `node` beside it.
    private static func nvmProbe(
        versions: [String] = ["v20.11.1", "v22.17.1", "v22.22.3", "v24.20.0"],
        codexVersions: [String] = ["v22.22.3"]
    ) -> StubFileProbe {
        var probe = StubFileProbe()
        probe.directories[nvmRoot] = versions
        for version in versions { probe.executables.insert("\(nvmRoot)/\(version)/bin/node") }
        for version in codexVersions {
            let bin = "\(nvmRoot)/\(version)/bin"
            probe.executables.insert("\(bin)/codex")
            probe.symlinks["\(bin)/codex"] = "\(nvmRoot)/\(version)/lib/node_modules/@openai/codex/bin/codex.js"
            probe.shebangs["\(nvmRoot)/\(version)/lib/node_modules/@openai/codex/bin/codex.js"] = "#!/usr/bin/env node"
        }
        return probe
    }

    private static func locator(_ probe: StubFileProbe, path: String = guiSearchPath) -> CodexExecutableLocator {
        CodexExecutableLocator(probe: probe, homeDirectory: home, environment: ["PATH": path])
    }

    @Test func findsNVMInstallWhenTheGUIPathIsMinimal() throws {
        let resolution = try Self.locator(Self.nvmProbe()).locate(configuredPath: "").get()
        #expect(resolution.url.path == "\(Self.nvmRoot)/v22.22.3/bin/codex")
        #expect(resolution.origin == .nodeVersionManager("nvm"))
        // The launcher's own bin directory carries `node`, which is what the shebang needs.
        #expect(resolution.interpreterDirectories.first?.path == "\(Self.nvmRoot)/v22.22.3/bin")
    }

    @Test func prefersTheNewestRuntimeThatActuallyHasCodex() throws {
        let probe = Self.nvmProbe(codexVersions: ["v20.11.1", "v22.17.1", "v22.22.3"])
        let resolution = try Self.locator(probe).locate(configuredPath: "").get()
        #expect(resolution.url.path == "\(Self.nvmRoot)/v22.22.3/bin/codex")
        #expect(CodexExecutableLocator.descendingByVersion(["v20.11.1", "v24.20.0", "v22.22.3", "v22.17.1"])
            == ["v24.20.0", "v22.22.3", "v22.17.1", "v20.11.1"])
    }

    @Test func aConfiguredPathOutranksEveryDiscoveredCandidate() throws {
        var probe = Self.nvmProbe()
        probe.executables.insert("/opt/custom/codex")
        let resolution = try Self.locator(probe).locate(configuredPath: " /opt/custom/codex ").get()
        #expect(resolution.url.path == "/opt/custom/codex")
        #expect(resolution.origin == .configured)
    }

    @Test func aTildeConfiguredPathExpandsAgainstTheHomeDirectory() throws {
        var probe = StubFileProbe()
        probe.executables.insert("/Users/tester/tools/codex")
        let resolution = try Self.locator(probe).locate(configuredPath: "~/tools/codex").get()
        #expect(resolution.url.path == "/Users/tester/tools/codex")
    }

    /// An explicit choice that is wrong is reported, never silently replaced: a typo must be visible.
    @Test func aBrokenConfiguredPathFailsInsteadOfFallingBack() {
        let result = Self.locator(Self.nvmProbe()).locate(configuredPath: "/opt/typo/codex")
        #expect(result == .failure(.configuredPathNotExecutable("/opt/typo/codex")))
    }

    /// The pre-fix build shipped `/usr/local/bin/codex` as a default nobody could edit. Treating a
    /// stored copy of it as an explicit override would pin upgrades to a path that rarely exists.
    @Test func theLegacyHardcodedDefaultStillFallsBackToDiscovery() throws {
        let probe = Self.nvmProbe()
        let resolution = try Self.locator(probe)
            .locate(configuredPath: CodexExecutableLocator.legacyDefaultConfiguredPath).get()
        #expect(resolution.url.path == "\(Self.nvmRoot)/v22.22.3/bin/codex")
    }

    @Test func searchPathEntriesAreSearchedFirst() throws {
        var probe = Self.nvmProbe()
        probe.executables.insert("/opt/homebrew/bin/codex")
        let locator = Self.locator(probe, path: "/opt/homebrew/bin:\(Self.guiSearchPath)")
        let resolution = try locator.locate(configuredPath: "").get()
        #expect(resolution.url.path == "/opt/homebrew/bin/codex")
        #expect(resolution.origin == .searchPath)
    }

    @Test func homebrewIsFoundEvenThoughTheGUIPathOmitsIt() throws {
        var probe = StubFileProbe()
        probe.executables.insert("/opt/homebrew/bin/codex")
        let resolution = try Self.locator(probe).locate(configuredPath: "").get()
        #expect(resolution.url.path == "/opt/homebrew/bin/codex")
        #expect(resolution.origin == .knownInstallLocation)
    }

    @Test func nothingInstalledAnywhereReportsNotFound() {
        #expect(Self.locator(StubFileProbe()).locate(configuredPath: "") == .failure(.notFound))
    }

    // MARK: - Interpreter directories

    @Test func anInterpreterLivingElsewhereIsAddedToTheChildPath() throws {
        var probe = Self.nvmProbe()
        probe.executables.insert("/usr/local/bin/codex")
        probe.shebangs["/usr/local/bin/codex"] = "#!/usr/bin/env node"
        let locator = Self.locator(probe, path: "/usr/local/bin:\(Self.guiSearchPath)")
        let resolution = try locator.locate(configuredPath: "").get()
        #expect(resolution.url.path == "/usr/local/bin/codex")
        #expect(resolution.interpreterDirectories.map(\.path)
            .contains("\(Self.nvmRoot)/v24.20.0/bin"))
    }

    @Test func aNativeBinaryNeedsOnlyItsOwnDirectory() throws {
        var probe = StubFileProbe()
        probe.executables.insert("/opt/homebrew/bin/codex")
        let resolution = try Self.locator(probe).locate(configuredPath: "").get()
        #expect(resolution.interpreterDirectories.map(\.path) == ["/opt/homebrew/bin"])
    }

    @Test func shebangParsingCoversEnvOptionsAndAbsoluteInterpreters() {
        #expect(CodexExecutableLocator.interpreterName(fromShebang: "#!/usr/bin/env node") == "node")
        #expect(CodexExecutableLocator.interpreterName(fromShebang: "#!/usr/bin/env -S node --enable-source-maps") == "node")
        #expect(CodexExecutableLocator.interpreterName(fromShebang: "#!/opt/homebrew/bin/node") == "/opt/homebrew/bin/node")
        #expect(CodexExecutableLocator.interpreterName(fromShebang: "ELF binary") == nil)
        #expect(CodexExecutableLocator.interpreterName(fromShebang: nil) == nil)
    }

    // MARK: - Child environment

    @Test func childEnvironmentPrependsInterpreterDirectoriesAndKeepsTheSystemPath() {
        let environment = CodexChildEnvironment.make(
            source: ["PATH": Self.guiSearchPath, "HOME": "/Users/tester"],
            prepending: [URL(fileURLWithPath: "\(Self.nvmRoot)/v22.22.3/bin")]
        )
        #expect(environment["PATH"] == "\(Self.nvmRoot)/v22.22.3/bin:\(Self.guiSearchPath)")
        #expect(environment["HOME"] == "/Users/tester")
    }

    @Test func childEnvironmentNeverInheritsUnlistedVariables() {
        let environment = CodexChildEnvironment.make(
            source: [
                "PATH": Self.guiSearchPath,
                "HOME": "/Users/tester",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "OPENAI_API_KEY": "secret",
                "SSH_AUTH_SOCK": "/private/tmp/socket",
            ],
            prepending: []
        )
        #expect(Set(environment.keys) == ["PATH", "HOME"])
    }

    @Test func childEnvironmentAlwaysSuppliesAUsableSearchPath() {
        let environment = CodexChildEnvironment.make(source: [:], prepending: [])
        #expect(environment["PATH"] == CodexChildEnvironment.systemSearchPath)
        let duplicated = CodexChildEnvironment.make(
            source: ["PATH": "/usr/bin:/bin"],
            prepending: [URL(fileURLWithPath: "/usr/bin"), URL(fileURLWithPath: "/opt/tools/bin")]
        )
        #expect(duplicated["PATH"] == "/usr/bin:/opt/tools/bin:/bin:/usr/sbin:/sbin")
    }
}

/// Store-level behaviour for the configured executable path: precedence, the distinct unavailable
/// states, and the reconnect that must happen when the user points the app at a different binary.
@MainActor
struct CodexExecutablePathStoreTests {
    private func makeStore(_ locator: CodexExecutableLocator) -> UsageStore {
        let settings = AppSettings(defaults: nil, systemIntegrationEnabled: false)
        settings.preferences.refreshCadence = .manual
        settings.preferences.refreshOnOpen = false
        return UsageStore(
            settings: settings,
            openRouter: OpenRouterService(
                client: OpenRouterClient(baseURL: URL(string: "https://tests.invalid/api/v1")!),
                secretStore: MemorySecretStore()
            ),
            claudeSnapshotURL: URL(fileURLWithPath: "/nonexistent/usagetool-tests/claude-usage.json"),
            claudeHomeURL: URL(fileURLWithPath: "/nonexistent/usagetool-tests/home"),
            codexLocator: locator,
            monitoringEnabled: false,
            initialRefreshEnabled: false,
            snapshotWatchingEnabled: false
        )
    }

    /// Writes a stub app-server that reports `plan` and then exits when its stdin closes.
    private func writeStubCodex(_ directory: URL, plan: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\\n' '{"id":1,"result":{}}' ;;
            3) printf '%s\\n' '{"id":2,"result":{"authMode":"chatgpt"}}' ;;
            4) printf '%s\\n' '{"id":3,"result":{"rateLimits":{"planType":"\(plan)","primary":{"usedPercent":10,"windowDurationMins":300},"secondary":null}}}' ;;
          esac
        done
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func changingTheConfiguredPathReconnectsToTheNewExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeStubCodex(root.appendingPathComponent("first"), plan: "plus")
        let second = try writeStubCodex(root.appendingPathComponent("second"), plan: "pro")

        let store = makeStore(CodexExecutableLocator(homeDirectory: root, environment: ["PATH": ""]))
        store.settings.preferences.codexExecutablePath = first.path
        await store.refresh(.codex)
        #expect(store.resolvedCodexExecutablePath == first.path)
        #expect(store.snapshot(for: .codex)?.plan == "plus")

        store.settings.preferences.codexExecutablePath = second.path
        await store.refresh(.codex)
        #expect(store.resolvedCodexExecutablePath == second.path)
        // A stale child would keep answering "plus"; the new plan proves the client was replaced.
        #expect(store.snapshot(for: .codex)?.plan == "pro")
    }

    @Test func aBrokenConfiguredPathIsReportedDistinctlyFromNothingInstalled() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = makeStore(CodexExecutableLocator(homeDirectory: root, environment: ["PATH": ""]))
        store.settings.preferences.codexExecutablePath = root.appendingPathComponent("codex").path
        await store.refresh(.codex)
        #expect(store.resolvedCodexExecutablePath == nil)
        #expect(store.codexExecutableProblem == .configuredPathNotExecutable(root.appendingPathComponent("codex").path))
        #expect(store.states[.codex] == .unavailable(reason: .executablePathInvalid))
    }

    @Test func resolutionIsPublishedWithoutLaunchingAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = try writeStubCodex(root.appendingPathComponent("bin"), plan: "plus")
        let store = makeStore(CodexExecutableLocator(homeDirectory: root, environment: ["PATH": ""]))
        store.settings.preferences.codexExecutablePath = codex.path
        #expect(store.resolveCodexExecutable()?.url.path == codex.path)
        #expect(store.codexExecutableProblem == nil)
        #expect(store.states[.codex] == .disconnected)
    }
}

/// The stored default from the pre-discovery build must not survive as an explicit override.
@MainActor
struct CodexExecutablePathMigrationTests {
    private final class MemoryPreferences: AppPreferencesPersistence {
        var values: [String: Data] = [:]
        func usageToolData(forKey key: String) -> Data? { values[key] }
        func setUsageToolData(_ data: Data, forKey key: String) { values[key] = data }
    }

    private func seeded(_ path: String) throws -> MemoryPreferences {
        var preferences = AppPreferences()
        preferences.codexExecutablePath = path
        let store = MemoryPreferences()
        store.values["UsageTool.preferences.v1"] = try JSONEncoder().encode(preferences)
        return store
    }

    @Test func theLegacyDefaultIsMigratedToAutomaticAndPersisted() throws {
        let store = try seeded(CodexExecutableLocator.legacyDefaultConfiguredPath)
        let settings = AppSettings(defaults: store, systemIntegrationEnabled: false)
        #expect(settings.preferences.codexExecutablePath == "")
        let persisted = try #require(store.values["UsageTool.preferences.v1"])
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: persisted)
        #expect(decoded.codexExecutablePath == "")
    }

    @Test func aRealUserChoiceIsPreserved() throws {
        let store = try seeded("/opt/custom/codex")
        let settings = AppSettings(defaults: store, systemIntegrationEnabled: false)
        #expect(settings.preferences.codexExecutablePath == "/opt/custom/codex")
    }

    @Test func aFreshInstallDefaultsToAutomaticDiscovery() {
        #expect(AppPreferences().codexExecutablePath == "")
    }
}
