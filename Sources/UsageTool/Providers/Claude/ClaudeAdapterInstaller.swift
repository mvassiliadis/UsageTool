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

    var errorDescription: String? {
        switch self {
        case .helperMissing: "The bundled Claude adapter helper is missing"
        case .invalidSettings: "Claude settings.json could not be parsed"
        case .incompatibleStatusLine: "The existing status line must be configured manually"
        case .currentConfigurationChanged: "Claude settings changed since the adapter was installed"
        }
    }
}

actor ClaudeAdapterInstaller {
    let settingsURL: URL
    let installedHelperURL: URL
    let snapshotURL: URL
    private let bundledHelperURL: URL
    private let manifestURL: URL
    private let fileManager: FileManager

    init(
        homeURL: URL,
        applicationSupportURL: URL,
        bundledHelperURL: URL,
        fileManager: FileManager = .default
    ) {
        settingsURL = homeURL.appendingPathComponent(".claude/settings.json")
        installedHelperURL = applicationSupportURL.appendingPathComponent("bin/usagetool-statusline")
        snapshotURL = applicationSupportURL.appendingPathComponent("claude-usage.json")
        manifestURL = applicationSupportURL.appendingPathComponent("claude-adapter-install.json")
        self.bundledHelperURL = bundledHelperURL
        self.fileManager = fileManager
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

        try fileManager.createDirectory(at: installedHelperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installedHelperURL.path) { try fileManager.removeItem(at: installedHelperURL) }
        try fileManager.copyItem(at: bundledHelperURL, to: installedHelperURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installedHelperURL.path)

        let backupURL: URL?
        if let preservedBackupPath { backupURL = URL(fileURLWithPath: preservedBackupPath) }
        else if reinstallingOwnedCommand { backupURL = nil }
        else { backupURL = try backupSettingsIfPresent() }
        let command = installedCommand(chaining: existingCommand)
        root["statusLine"] = .object([
            "type": .string("command"),
            "command": .string(command),
            "refreshInterval": .number(Double(refreshInterval)),
        ])
        try writeSettings(root)
        let manifest = ClaudeAdapterManifest(
            previousStatusLine: preservedPrevious,
            backupPath: backupURL?.path,
            installedCommand: command
        )
        try writeJSON(manifest, to: manifestURL)
        return .init(kind: .installed(chained: existingCommand != nil))
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
        try data.write(to: url, options: .atomic)
    }
}
