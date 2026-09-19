import Foundation

// A GUI-launched app inherits `launchd`'s environment, not a login shell's. `PATH` is therefore
// `/usr/bin:/bin:/usr/sbin:/sbin` and contains no user-managed tool directory. Two separate
// failures follow from that, and this file fixes both:
//
// 1. Discovery. A `codex` installed by npm/nvm, Homebrew on Apple silicon, Volta, bun and friends
//    is invisible to a bare `PATH` lookup, so the app reported "Codex CLI not found" while the
//    user's shell resolved `codex` without trouble.
// 2. Interpretation. `@openai/codex` installs a `#!/usr/bin/env node` JavaScript launcher. Finding
//    it is not enough: unless the directory holding its `node` is on the child's `PATH`, the
//    kernel's `env` lookup fails and the process dies before the app-server handshake.

/// Where a Codex executable was found. Recorded for the diagnostics the research brief requires.
enum CodexExecutableOrigin: Equatable, Sendable {
    case configured
    case searchPath
    case knownInstallLocation
    case nodeVersionManager(String)

    var label: String {
        switch self {
        case .configured: "configured path"
        case .searchPath: "PATH"
        case .knownInstallLocation: "standard install location"
        case .nodeVersionManager(let name): name
        }
    }
}

struct CodexExecutableResolution: Equatable, Sendable {
    var url: URL
    var origin: CodexExecutableOrigin
    /// Directories to prepend to the child's `PATH` so a script launcher can reach its interpreter.
    /// Always contains the executable's own directory; for an NVM install that is also where `node`
    /// lives, which is exactly what `#!/usr/bin/env node` needs.
    var interpreterDirectories: [URL]
}

enum CodexExecutableProblem: Error, Equatable, Sendable {
    /// The user configured an explicit path that is not an executable file.
    case configuredPathNotExecutable(String)
    /// Nothing was found in any searched location.
    case notFound

    var message: String {
        switch self {
        case .configuredPathNotExecutable: "The configured path isn’t an executable file"
        case .notFound: "No codex executable found in PATH or the usual install locations"
        }
    }

    var unavailableReason: UnavailableReason {
        switch self {
        case .configuredPathNotExecutable: .executablePathInvalid
        case .notFound: .executableMissing
        }
    }
}

/// The filesystem questions the locator asks, factored out so discovery is testable without a
/// fixture tree on disk.
protocol CodexFileProbing: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    func subdirectoryNames(atPath path: String) -> [String]
    /// The fully resolved target when `path` is a symbolic link, otherwise `nil`.
    func resolvedSymbolicLink(atPath path: String) -> String?
    /// The `#!` line when `path` starts with one, otherwise `nil`.
    func shebangLine(atPath path: String) -> String?
}

struct CodexSystemFileProbe: CodexFileProbing {
    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func subdirectoryNames(atPath path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    func resolvedSymbolicLink(atPath path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == URL(fileURLWithPath: path).standardizedFileURL.path ? nil : resolved
    }

    func shebangLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256), head.starts(with: Data("#!".utf8)) else { return nil }
        let line = head.prefix(while: { $0 != 0x0A && $0 != 0x0D })
        return String(data: Data(line), encoding: .utf8)
    }
}

struct CodexExecutableLocator: Sendable {
    /// The build's original hardcoded default. A stored value equal to it was never chosen by a
    /// user — no UI existed to choose one — so it is treated as "automatic" rather than as an
    /// explicit override that must fail loudly. Automatic discovery searches `/usr/local/bin`
    /// anyway, so a genuine install there still resolves identically.
    static let legacyDefaultConfiguredPath = "/usr/local/bin/codex"
    static let executableName = "codex"

    let probe: any CodexFileProbing
    let homeDirectory: URL
    let environment: [String: String]

    init(
        probe: any CodexFileProbing = CodexSystemFileProbe(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.probe = probe
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func locate(configuredPath: String) -> Result<CodexExecutableResolution, CodexExecutableProblem> {
        if let configured = Self.explicitPath(configuredPath, homeDirectory: homeDirectory) {
            // An explicit choice is never silently replaced by a different binary: a typo must be
            // reported, not worked around.
            guard probe.isExecutableFile(atPath: configured) else {
                return .failure(.configuredPathNotExecutable(configured))
            }
            return .success(resolution(URL(fileURLWithPath: configured), origin: .configured))
        }
        for candidate in searchCandidates() where probe.isExecutableFile(atPath: candidate.url.path) {
            return .success(resolution(candidate.url, origin: candidate.origin))
        }
        return .failure(.notFound)
    }

    /// The configured path an explicit user override represents, or `nil` for automatic discovery.
    static func explicitPath(_ configuredPath: String, homeDirectory: URL) -> String? {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != legacyDefaultConfiguredPath else { return nil }
        let expanded = trimmed.hasPrefix("~")
            ? homeDirectory.path + String(trimmed.dropFirst())
            : trimmed
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: - Candidate locations

    func searchCandidates() -> [(url: URL, origin: CodexExecutableOrigin)] {
        var seen = Set<String>()
        var candidates: [(url: URL, origin: CodexExecutableOrigin)] = []
        for (directory, origin) in searchDirectories() {
            let url = directory.appendingPathComponent(Self.executableName)
            guard seen.insert(url.path).inserted else { continue }
            candidates.append((url, origin))
        }
        return candidates
    }

    private func searchDirectories() -> [(URL, CodexExecutableOrigin)] {
        var directories: [(URL, CodexExecutableOrigin)] = []
        directories += searchPathDirectories().map { ($0, .searchPath) }
        directories += knownInstallDirectories().map { ($0, .knownInstallLocation) }
        directories += nodeVersionManagerDirectories().map { ($1, .nodeVersionManager($0)) }
        return directories
    }

    private func searchPathDirectories() -> [URL] {
        (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private func knownInstallDirectories() -> [URL] {
        let absolute = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let relativeToHome = [
            ".local/bin", "bin", ".codex/bin", ".bun/bin", ".deno/bin",
            ".cargo/bin", ".npm-global/bin", "Library/pnpm",
        ]
        return absolute.map { URL(fileURLWithPath: $0, isDirectory: true) }
            + relativeToHome.map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    /// Bin directories published by the common Node version managers, newest runtime first.
    private func nodeVersionManagerDirectories() -> [(String, URL)] {
        var directories: [(String, URL)] = []

        let nvmRoot = environment["NVM_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".nvm", isDirectory: true)
        directories += versionedDirectories(
            in: nvmRoot.appendingPathComponent("versions/node", isDirectory: true),
            suffix: "bin"
        ).map { ("nvm", $0) }

        let fnmRoots = [environment["FNM_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                        homeDirectory.appendingPathComponent("Library/Application Support/fnm", isDirectory: true),
                        homeDirectory.appendingPathComponent(".fnm", isDirectory: true)].compactMap { $0 }
        for root in fnmRoots {
            directories += versionedDirectories(
                in: root.appendingPathComponent("node-versions", isDirectory: true),
                suffix: "installation/bin"
            ).map { ("fnm", $0) }
        }

        let voltaBin = homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true)
        directories.append(("volta", voltaBin))

        let nodenvRoot = homeDirectory.appendingPathComponent(".nodenv", isDirectory: true)
        directories.append(("nodenv", nodenvRoot.appendingPathComponent("shims", isDirectory: true)))
        directories += versionedDirectories(
            in: nodenvRoot.appendingPathComponent("versions", isDirectory: true),
            suffix: "bin"
        ).map { ("nodenv", $0) }

        let asdfRoot = homeDirectory.appendingPathComponent(".asdf", isDirectory: true)
        directories.append(("asdf", asdfRoot.appendingPathComponent("shims", isDirectory: true)))
        directories += versionedDirectories(
            in: asdfRoot.appendingPathComponent("installs/nodejs", isDirectory: true),
            suffix: "bin"
        ).map { ("asdf", $0) }

        for root in ["/usr/local/n/versions/node", homeDirectory.appendingPathComponent("n/versions/node").path] {
            directories += versionedDirectories(
                in: URL(fileURLWithPath: root, isDirectory: true),
                suffix: "bin"
            ).map { ("n", $0) }
        }

        return directories
    }

    private func versionedDirectories(in root: URL, suffix: String) -> [URL] {
        Self.descendingByVersion(probe.subdirectoryNames(atPath: root.path)).map {
            root.appendingPathComponent($0, isDirectory: true).appendingPathComponent(suffix, isDirectory: true)
        }
    }

    /// Orders `v22.22.3`-style names newest first so an up-to-date runtime wins over a stale one.
    static func descendingByVersion(_ names: [String]) -> [String] {
        names.sorted { lhs, rhs in
            let left = versionComponents(lhs)
            let right = versionComponents(rhs)
            for (a, b) in zip(left, right) where a != b { return a > b }
            if left.count != right.count { return left.count > right.count }
            return lhs > rhs
        }
    }

    private static func versionComponents(_ name: String) -> [Int] {
        name.drop(while: { !$0.isNumber })
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: - Interpreter directories

    private func resolution(_ url: URL, origin: CodexExecutableOrigin) -> CodexExecutableResolution {
        CodexExecutableResolution(
            url: url,
            origin: origin,
            interpreterDirectories: interpreterDirectories(for: url)
        )
    }

    func interpreterDirectories(for url: URL) -> [URL] {
        var seen = Set<String>()
        var directories: [URL] = []
        func add(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            directories.append(standardized)
        }

        add(url.deletingLastPathComponent())
        let target = probe.resolvedSymbolicLink(atPath: url.path)
        if let target { add(URL(fileURLWithPath: target).deletingLastPathComponent()) }

        guard var interpreter = Self.interpreterName(fromShebang: probe.shebangLine(atPath: target ?? url.path)) else {
            return directories
        }
        if interpreter.hasPrefix("/") {
            guard !probe.isExecutableFile(atPath: interpreter) else { return directories }
            interpreter = URL(fileURLWithPath: interpreter).lastPathComponent
        }
        let alreadyReachable = directories.contains {
            probe.isExecutableFile(atPath: $0.appendingPathComponent(interpreter).path)
        }
        guard !alreadyReachable else { return directories }
        for (directory, _) in searchDirectories()
        where probe.isExecutableFile(atPath: directory.appendingPathComponent(interpreter).path) {
            add(directory)
            break
        }
        return directories
    }

    /// The interpreter a `#!` line names: the argument for `env`, otherwise the path itself.
    static func interpreterName(fromShebang line: String?) -> String? {
        guard let line, line.hasPrefix("#!") else { return nil }
        let tokens = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return nil }
        guard URL(fileURLWithPath: first).lastPathComponent == "env" else { return first }
        // `env` may carry options such as `-S` or `-i` before the command name.
        return tokens.dropFirst().first { !$0.hasPrefix("-") }
    }
}

/// Builds the child's environment.
///
/// The research brief forbids handing the child the app's full environment. It stays an explicit
/// allow-list; the only addition is that `PATH` is *composed* rather than copied, so a script
/// launcher can reach its interpreter without the app leaking anything else.
enum CodexChildEnvironment {
    static let inheritedKeys = ["HOME", "PATH", "TMPDIR", "LANG", "LC_CTYPE", "CODEX_HOME"]
    static let systemSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func make(source: [String: String], prepending directories: [URL]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in inheritedKeys {
            if let value = source[key], !value.isEmpty { environment[key] = value }
        }
        var seen = Set<String>()
        var entries: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            entries.append(path)
        }
        for directory in directories { append(directory.standardizedFileURL.path) }
        for entry in (environment["PATH"] ?? "").split(separator: ":") { append(String(entry)) }
        // A GUI process always has a usable PATH, but never depend on it: the child must be able to
        // reach /usr/bin/env whatever the app inherited.
        for entry in systemSearchPath.split(separator: ":") { append(String(entry)) }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }
}
