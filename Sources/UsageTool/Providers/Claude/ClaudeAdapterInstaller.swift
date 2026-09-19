import Foundation

struct ClaudeAdapterStatus: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case notInstalled
        case installed(chained: Bool)
        case configuredElsewhere(command: String)
        case invalidSettings
    }
    let kind: Kind
}

struct ClaudeAdapterManifest: Codable, Sendable {
    let previousStatusLine: JSONValue?
    let backupPath: String?
    let installedCommand: String
}

enum ClaudeAdapterInstallerError: Error, Equatable, LocalizedError {
    case helperMissing
    case invalidSettings
    case incompatibleStatusLine
    case currentConfigurationChanged
    case rollbackFailed(originalError: String, backupPath: String?)

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "The bundled Claude adapter helper is missing"
        case .invalidSettings: return "Claude settings.json could not be parsed"
        case .incompatibleStatusLine: return "The existing status line must be configured manually"
        case .currentConfigurationChanged: return "Claude settings changed since the adapter was installed"
        case .rollbackFailed(let originalError, let backupPath):
            let recovery = backupPath.map { " A settings backup remains at \($0)." } ?? ""
            return "The adapter installation failed (\(originalError)) and its previous files could not be fully restored.\(recovery)"
        }
    }
}

actor ClaudeAdapterInstaller {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    let settingsURL: URL
    let installedHelperURL: URL
    let snapshotURL: URL
    private let bundledHelperURL: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let atomicWriter: AtomicWriter

    init(
        homeURL: URL,
        applicationSupportURL: URL,
        bundledHelperURL: URL,
        fileManager: FileManager = .default,
        atomicWriter: @escaping AtomicWriter = ClaudeAdapterInstaller.writeAtomically
    ) {
        settingsURL = homeURL.appendingPathComponent(".claude/settings.json")
        installedHelperURL = applicationSupportURL.appendingPathComponent("bin/usagetool-statusline")
        snapshotURL = applicationSupportURL.appendingPathComponent("claude-usage.json")
        manifestURL = applicationSupportURL.appendingPathComponent("claude-adapter-install.json")
        self.bundledHelperURL = bundledHelperURL
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
    }

    func inspect() -> ClaudeAdapterStatus {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .init(kind: .notInstalled)
        }
        guard let root = try? readSettings() else {
            return .init(kind: .invalidSettings)
        }
        guard let statusLine = root["statusLine"] else { return .init(kind: .notInstalled) }
        guard case .object(let object) = statusLine,
              object["type"]?.stringValue == "command",
              let command = object["command"]?.stringValue else {
            return .init(kind: .configuredElsewhere(command: "Unsupported statusLine type"))
        }
        if command.contains(installedHelperURL.path) {
            return .init(kind: .installed(chained: command.contains("--chain-base64")))
        }
        return .init(kind: .configuredElsewhere(command: command))
    }

    @discardableResult
    func install(refreshInterval: Int = 120) throws -> ClaudeAdapterStatus {
        guard fileManager.isExecutableFile(atPath: bundledHelperURL.path) else {
            throw ClaudeAdapterInstallerError.helperMissing
        }
        guard (60 ... 300).contains(refreshInterval) else {
            throw ClaudeAdapterInstallerError.incompatibleStatusLine
        }

        var root = try readSettingsAllowingMissing()
        let previous = root["statusLine"]
        let existingManifest = readManifest()
        let existingCommand: String?
        let preservedPrevious: JSONValue?
        let preservedBackupPath: String?
        let reinstallingOwnedCommand: Bool
        if let previous {
            guard case .object(let object) = previous,
                  object["type"]?.stringValue == "command",
                  let command = object["command"]?.stringValue else {
                throw ClaudeAdapterInstallerError.incompatibleStatusLine
            }
            if command.contains(installedHelperURL.path) {
                reinstallingOwnedCommand = true
                existingCommand = decodedChainedCommand(from: command)
                let fallbackBackup = existingManifest == nil ? latestBackup() : nil
                preservedPrevious = existingManifest?.previousStatusLine
                    ?? fallbackBackup?.statusLine
                    ?? existingCommand.map(Self.commandStatusLine)
                preservedBackupPath = existingManifest?.backupPath ?? fallbackBackup?.url.path
            } else {
                reinstallingOwnedCommand = false
                existingCommand = command
                preservedPrevious = previous
                preservedBackupPath = nil
            }
        } else {
            reinstallingOwnedCommand = false
            existingCommand = nil
            preservedPrevious = existingManifest?.previousStatusLine
            preservedBackupPath = existingManifest?.backupPath
        }

        let command = installedCommand(chaining: existingCommand)
        root["statusLine"] = .object([
            "type": .string("command"),
            "command": .string(command),
            "refreshInterval": .number(Double(refreshInterval)),
        ])

        let originalSettingsData = try dataIfPresent(at: settingsURL)
        let originalManifestData = try dataIfPresent(at: manifestURL)
        let helperDirectory = installedHelperURL.deletingLastPathComponent()
        let transactionID = UUID().uuidString
        let stagedHelperURL = helperDirectory.appendingPathComponent(".usagetool-statusline.stage-\(transactionID)")
        let previousHelperURL = helperDirectory.appendingPathComponent(".usagetool-statusline.rollback-\(transactionID)")
        var createdBackupURL: URL?
        var previousHelperMoved = false
        var stagedHelperInstalled = false
        var settingsWriteAttempted = false
        var manifestWriteAttempted = false

        do {
            try fileManager.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundledHelperURL, to: stagedHelperURL)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedHelperURL.path)

            let backupURL: URL?
            if let preservedBackupPath {
                backupURL = URL(fileURLWithPath: preservedBackupPath)
            } else if reinstallingOwnedCommand {
                backupURL = nil
            } else {
                createdBackupURL = try backupSettingsIfPresent()
                backupURL = createdBackupURL
            }

            if fileManager.fileExists(atPath: installedHelperURL.path) {
                try fileManager.moveItem(at: installedHelperURL, to: previousHelperURL)
                previousHelperMoved = true
            }
            try fileManager.moveItem(at: stagedHelperURL, to: installedHelperURL)
            stagedHelperInstalled = true

            settingsWriteAttempted = true
            try writeSettings(root)
            let manifest = ClaudeAdapterManifest(
                previousStatusLine: preservedPrevious,
                backupPath: backupURL?.path,
                installedCommand: command
            )
            manifestWriteAttempted = true
            try writeJSON(manifest, to: manifestURL)

            if fileManager.fileExists(atPath: previousHelperURL.path) {
                try? fileManager.removeItem(at: previousHelperURL)
            }
            return .init(kind: .installed(chained: existingCommand != nil))
        } catch {
            let rolledBack = rollbackInstall(
                originalSettingsData: originalSettingsData,
                settingsWriteAttempted: settingsWriteAttempted,
                originalManifestData: originalManifestData,
                manifestWriteAttempted: manifestWriteAttempted,
                stagedHelperURL: stagedHelperURL,
                previousHelperURL: previousHelperURL,
                previousHelperMoved: previousHelperMoved,
                stagedHelperInstalled: stagedHelperInstalled,
                createdBackupURL: createdBackupURL
            )
            guard rolledBack else {
                let backupPath = [createdBackupURL?.path, preservedBackupPath]
                    .compactMap { $0 }
                    .first(where: fileManager.fileExists(atPath:))
                throw ClaudeAdapterInstallerError.rollbackFailed(
                    originalError: error.localizedDescription,
                    backupPath: backupPath
                )
            }
            throw error
        }
    }

    func remove() throws {
        var root = try readSettings()
        guard case .object(let current)? = root["statusLine"],
              let currentCommand = current["command"]?.stringValue,
              currentCommand.contains(installedHelperURL.path) else {
            throw ClaudeAdapterInstallerError.currentConfigurationChanged
        }

        let manifest = readManifest()
        if let manifest, currentCommand != manifest.installedCommand {
            throw ClaudeAdapterInstallerError.currentConfigurationChanged
        }
        let backupStatusLine = manifest?.backupPath
            .flatMap { try? statusLineFromBackup(at: URL(fileURLWithPath: $0)) }
            ?? latestBackup()?.statusLine
        let recoveredChain = decodedChainedCommand(from: currentCommand).map(Self.commandStatusLine)
        let previous: JSONValue?
        if let manifest { previous = manifest.previousStatusLine ?? backupStatusLine }
        else { previous = recoveredChain ?? backupStatusLine }
        if let previous { root["statusLine"] = previous }
        else { root.removeValue(forKey: "statusLine") }
        try writeSettings(root)
        if fileManager.fileExists(atPath: installedHelperURL.path) { try fileManager.removeItem(at: installedHelperURL) }
        if fileManager.fileExists(atPath: manifestURL.path) { try fileManager.removeItem(at: manifestURL) }
        if let backupPath = manifest?.backupPath, fileManager.fileExists(atPath: backupPath) {
            try? fileManager.removeItem(atPath: backupPath)
        }
    }

    func manualSnippet(existingCommand: String? = nil, refreshInterval: Int = 120) -> String {
        let command = installedCommand(chaining: existingCommand)
        let snippet = JSONValue.object([
            "statusLine": .object([
                "type": .string("command"),
                "command": .string(command),
                "refreshInterval": .number(Double(refreshInterval)),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(snippet), as: UTF8.self)) ?? ""
    }

    private func installedCommand(chaining command: String?) -> String {
        let escapedPath = shellQuote(installedHelperURL.path)
        guard let command, let encoded = command.data(using: .utf8)?.base64EncodedString() else { return escapedPath }
        return "\(escapedPath) --chain-base64 \(shellQuote(encoded))"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func decodedChainedCommand(from installedCommand: String) -> String? {
        guard let range = installedCommand.range(of: "--chain-base64") else { return nil }
        var token = installedCommand[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("'"), token.hasSuffix("'"), token.count >= 2 {
            token.removeFirst()
            token.removeLast()
        }
        guard let data = Data(base64Encoded: token) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func commandStatusLine(_ command: String) -> JSONValue {
        .object(["type": .string("command"), "command": .string(command)])
    }

    private func readManifest() -> ClaudeAdapterManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeAdapterManifest.self, from: data)
    }

    private func statusLineFromBackup(at url: URL) throws -> JSONValue? {
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let root) = value else { return nil }
        return root["statusLine"]
    }

    private func latestBackup() -> (url: URL, statusLine: JSONValue)? {
        let directory = settingsURL.deletingLastPathComponent()
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("settings.json.usagetool-backup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .lazy
            .compactMap { url in
                do {
                    guard let statusLine = try self.statusLineFromBackup(at: url) else { return nil }
                    return (url: url, statusLine: statusLine)
                } catch {
                    return nil
                }
            }
            .first
    }

    private func readSettingsAllowingMissing() throws -> [String: JSONValue] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        return try readSettings()
    }

    private func readSettings() throws -> [String: JSONValue] {
        do {
            let data = try Data(contentsOf: settingsURL)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let root) = value else { throw ClaudeAdapterInstallerError.invalidSettings }
            return root
        } catch let error as ClaudeAdapterInstallerError {
            throw error
        } catch {
            throw ClaudeAdapterInstallerError.invalidSettings
        }
    }

    private func backupSettingsIfPresent() throws -> URL? {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.usagetool-backup-\(formatter.string(from: Date()))")
        try fileManager.copyItem(at: settingsURL, to: backup)
        return backup
    }

    private func writeSettings(_ root: [String: JSONValue]) throws {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJSON(JSONValue.object(root), to: settingsURL)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWriter(data, url)
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func rollbackInstall(
        originalSettingsData: Data?,
        settingsWriteAttempted: Bool,
        originalManifestData: Data?,
        manifestWriteAttempted: Bool,
        stagedHelperURL: URL,
        previousHelperURL: URL,
        previousHelperMoved: Bool,
        stagedHelperInstalled: Bool,
        createdBackupURL: URL?
    ) -> Bool {
        var succeeded = true
        var settingsRestored = true

        if previousHelperMoved, fileManager.fileExists(atPath: previousHelperURL.path) {
            if fileManager.fileExists(atPath: installedHelperURL.path) {
                do { try fileManager.removeItem(at: installedHelperURL) }
                catch { succeeded = false }
            }
            do { try fileManager.moveItem(at: previousHelperURL, to: installedHelperURL) }
            catch { succeeded = false }
        } else if stagedHelperInstalled, fileManager.fileExists(atPath: installedHelperURL.path) {
            do { try fileManager.removeItem(at: installedHelperURL) }
            catch { succeeded = false }
        }

        if fileManager.fileExists(atPath: stagedHelperURL.path) {
            do { try fileManager.removeItem(at: stagedHelperURL) }
            catch { succeeded = false }
        }

        if settingsWriteAttempted {
            do { try restore(originalSettingsData, to: settingsURL) }
            catch {
                settingsRestored = false
                succeeded = false
            }
        }
        if manifestWriteAttempted {
            do { try restore(originalManifestData, to: manifestURL) }
            catch { succeeded = false }
        }
        if settingsRestored,
           let createdBackupURL,
           fileManager.fileExists(atPath: createdBackupURL.path) {
            do { try fileManager.removeItem(at: createdBackupURL) }
            catch { succeeded = false }
        }
        return succeeded
    }

    private func restore(_ data: Data?, to url: URL) throws {
        if let data {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try atomicWriter(data, url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private nonisolated static func writeAtomically(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
