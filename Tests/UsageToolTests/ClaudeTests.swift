import Foundation
import Testing
@testable import UsageTool

struct ClaudeTests {
    @Test func sanitizerDropsEverythingExceptFinalContract() throws {
        let input = Data(#"""
        {
          "session_id":"must-not-survive",
          "cwd":"/private/path",
          "cost":{"total_cost_usd":99},
          "model":{"display_name":"secret-model"},
          "context_window":{"remaining_percentage":88},
          "rate_limits":{
            "five_hour":{"used_percentage":58,"resets_at":1800000000},
            "seven_day":{"used_percentage":120,"resets_at":1800500000},
            "spend_limit":{"used_percentage":500,"resets_at":1800600000}
          }
        }
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sanitized = try ClaudeStatusLineCore.sanitize(input: input, reportedAt: now)
        let snapshot = try #require(sanitized)
        #expect(snapshot.windows.map(\.id) == ["5h", "7d"])
        #expect(abs(snapshot.windows[0].remainingFraction - 0.42) < 0.000_001)
        #expect(snapshot.windows[1].remainingFraction == 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == Set(["schema", "reportedAt", "windows"]))
    }

    @Test func noRateLimitsDoesNotOverwriteSnapshot() throws {
        #expect(try ClaudeStatusLineCore.sanitize(input: Data(#"{"session_id":"x"}"#.utf8)) == nil)
    }

    @Test func atomicWriterAndReaderUseTimestampLastWriterWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-usage.json")
        let newer = ClaudeSanitizedSnapshot(schema: 1, reportedAt: Date(timeIntervalSince1970: 200), windows: [.init(id: "5h", remainingFraction: 0.4, resetsAt: nil)])
        let older = ClaudeSanitizedSnapshot(schema: 1, reportedAt: Date(timeIntervalSince1970: 100), windows: [.init(id: "5h", remainingFraction: 0.9, resetsAt: nil)])
        try ClaudeStatusLineCore.writeLastWriterWins(newer, to: url)
        try ClaudeStatusLineCore.writeLastWriterWins(older, to: url)
        let decoded = try ClaudeStatusLineCore.decodeSnapshot(Data(contentsOf: url))
        #expect(decoded == newer)

        let reader = ClaudeSnapshotReader()
        let first = await reader.read(from: url)
        try Data("{".utf8).write(to: url)
        let retained = await reader.read(from: url)
        #expect(retained == first)
    }

    @Test func installerMergesChainsBacksUpAndRestoresUsingTemporaryHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = root.appendingPathComponent("support")
        let helper = root.appendingPathComponent("bundled-helper")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let original = #"{"theme":"dark","statusLine":{"type":"command","command":"~/.config/status.sh"}}"#
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try Data(original.utf8).write(to: settingsURL)
        let installer = ClaudeAdapterInstaller(homeURL: home, applicationSupportURL: support, bundledHelperURL: helper)
        let status = try await installer.install()
        #expect(status.kind == .installed(chained: true))
        let reinstalled = try await installer.install()
        #expect(reinstalled.kind == .installed(chained: true))
        let installed = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(installed.contains("\"theme\" : \"dark\""))
        #expect(installed.contains("--chain-base64"))
        #expect(!installed.contains("sessionId"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path)
        #expect(backups.filter { $0.hasPrefix("settings.json.usagetool-backup-") }.count == 1)
        try await installer.remove()
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
        #expect(restored["theme"]?.stringValue == "dark")
        #expect(restored["statusLine"]?["command"]?.stringValue == "~/.config/status.sh")
    }

    @Test func installerTreatsValidSettingsWithoutStatusLineAsNotInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let installer = ClaudeAdapterInstaller(homeURL: home, applicationSupportURL: root.appendingPathComponent("support"), bundledHelperURL: helper)
        #expect(await installer.inspect().kind == .notInstalled)
    }

    @Test func removalRecoversFromBackupWhenManifestIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = root.appendingPathComponent("support")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let settings = home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"original-status"}}"#.utf8).write(to: settings)
        let installer = ClaudeAdapterInstaller(homeURL: home, applicationSupportURL: support, bundledHelperURL: helper)
        try await installer.install()
        try FileManager.default.removeItem(at: support.appendingPathComponent("claude-adapter-install.json"))
        try await installer.remove()
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settings))
        #expect(restored["statusLine"]?["command"]?.stringValue == "original-status")
    }

    @Test func reinstallWithoutOriginalSettingsDoesNotBackUpOrRestoreOwnCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = root.appendingPathComponent("support")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let installer = ClaudeAdapterInstaller(homeURL: home, applicationSupportURL: support, bundledHelperURL: helper)
        try await installer.install()
        try await installer.install()
        try await installer.remove()
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent(".claude/settings.json")))
        #expect(settings["statusLine"] == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
        #expect(!files.contains(where: { $0.hasPrefix("settings.json.usagetool-backup-") }))
    }

    @Test func reinstallWithoutManifestPreservesEntireOriginalStatusLineObject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = root.appendingPathComponent("support")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"original-status","refreshInterval":37,"padding":4}}"#.utf8).write(to: settingsURL)
        let installer = ClaudeAdapterInstaller(homeURL: home, applicationSupportURL: support, bundledHelperURL: helper)

        try await installer.install()
        try FileManager.default.removeItem(at: support.appendingPathComponent("claude-adapter-install.json"))
        try await installer.install()
        try await installer.remove()

        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
        #expect(restored["statusLine"]?["command"]?.stringValue == "original-status")
        #expect(restored["statusLine"]?["refreshInterval"]?.doubleValue == 37)
        #expect(restored["statusLine"]?["padding"]?.doubleValue == 4)
    }

    @Test func manualSnippetIsValidEscapedJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installer = ClaudeAdapterInstaller(
            homeURL: root,
            applicationSupportURL: root.appendingPathComponent("support with spaces"),
            bundledHelperURL: root.appendingPathComponent("helper")
        )
        let snippet = await installer.manualSnippet(existingCommand: "printf 'quoted'", refreshInterval: 180)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(snippet.utf8))
        #expect(decoded["statusLine"]?["refreshInterval"]?.doubleValue == 180)
        #expect(decoded["statusLine"]?["command"]?.stringValue?.contains("--chain-base64") == true)
    }

    @Test func bundledHelperComposesChainAndDrainsLargeOutputWithoutTimeout() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/usagetool-statusline")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = directory.appendingPathComponent("snapshot.json")
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":58,"resets_at":1800000000},"seven_day":{"used_percentage":10,"resets_at":1800500000}}}"#.utf8)
        let command = "yes x | head -c 200000"
        let encoded = Data(command.utf8).base64EncodedString()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--output", snapshot.path, "--chain-base64", encoded]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(Date().timeIntervalSince(started) < 2)
        let text = try #require(String(data: output, encoding: .utf8))
        #expect(text.contains("5h 42% · 7d 90%"))
        #expect(text.hasPrefix("x"))
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
    }
}
