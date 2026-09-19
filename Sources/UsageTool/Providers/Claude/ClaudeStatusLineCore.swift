import Darwin
import Foundation

struct ClaudeSanitizedSnapshot: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let id: String
        let remainingFraction: Double
        let resetsAt: Date?
    }

    let schema: Int
    let reportedAt: Date
    let windows: [Window]
}

enum ClaudeStatusLineError: Error, Equatable, LocalizedError {
    case inputTooLarge
    case invalidInput
    case unsupportedSnapshot
    case lockFailed

    var errorDescription: String? {
        switch self {
        case .inputTooLarge: "Claude status input exceeded the safe size limit"
        case .invalidInput: "Claude status input was not valid JSON"
        case .unsupportedSnapshot: "Claude snapshot uses an unsupported schema"
        case .lockFailed: "Claude snapshot could not be locked for writing"
        }
    }
}

enum ClaudeStatusLineCore {
    static let maximumInputBytes = 1_048_576

    private struct Input: Decodable {
        struct RateLimits: Decodable {
            let fiveHour: Limit?
            let sevenDay: Limit?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct Limit: Decodable {
            let usedPercentage: Double
            let resetsAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }

        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    static func sanitize(input data: Data, reportedAt: Date = Date()) throws -> ClaudeSanitizedSnapshot? {
        guard data.count <= maximumInputBytes else { throw ClaudeStatusLineError.inputTooLarge }
        guard let input = try? JSONDecoder().decode(Input.self, from: data) else {
            throw ClaudeStatusLineError.invalidInput
        }
        guard let limits = input.rateLimits,
              limits.fiveHour != nil || limits.sevenDay != nil else { return nil }

        var windows: [ClaudeSanitizedSnapshot.Window] = []
        if let window = limits.fiveHour {
            windows.append(sanitize(window, id: "5h"))
        }
        if let window = limits.sevenDay {
            windows.append(sanitize(window, id: "7d"))
        }
        return .init(schema: 1, reportedAt: reportedAt, windows: windows)
    }

    static func writeLastWriterWins(_ snapshot: ClaudeSanitizedSnapshot, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = destination.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ClaudeStatusLineError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ClaudeStatusLineError.lockFailed }
        defer { flock(descriptor, LOCK_UN) }

        if let existing = try? Data(contentsOf: destination),
           let decoded = try? decoder.decode(ClaudeSanitizedSnapshot.self, from: existing),
           decoded.reportedAt > snapshot.reportedAt {
            return
        }

        let data = try encoder.encode(snapshot)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        do {
            if rename(temporary.path, destination.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func decodeSnapshot(_ data: Data) throws -> ClaudeSanitizedSnapshot {
        guard data.count <= maximumInputBytes, !data.isEmpty else { throw ClaudeStatusLineError.invalidInput }
        let snapshot = try decoder.decode(ClaudeSanitizedSnapshot.self, from: data)
        guard snapshot.schema == 1,
              Set(snapshot.windows.map(\.id)).count == snapshot.windows.count,
              snapshot.windows.allSatisfy({
                  ($0.id == "5h" || $0.id == "7d") &&
                  $0.remainingFraction.isFinite &&
                  (0 ... 1).contains($0.remainingFraction)
              }) else { throw ClaudeStatusLineError.unsupportedSnapshot }
        return snapshot
    }

    static func displayLine(_ snapshot: ClaudeSanitizedSnapshot?) -> String {
        guard let snapshot else { return "UsageTool: waiting for rate limits" }
        let values = snapshot.windows.map { "\($0.id) \(Int(($0.remainingFraction * 100).rounded()))%" }
        return values.isEmpty ? "UsageTool: waiting for rate limits" : values.joined(separator: " · ")
    }

    private static func sanitize(_ limit: Input.Limit, id: String) -> ClaudeSanitizedSnapshot.Window {
        let clamped = min(max(1 - limit.usedPercentage / 100, 0), 1)
        let remaining = (clamped * 1_000_000).rounded() / 1_000_000
        let reset = limit.resetsAt.map { Date(timeIntervalSince1970: $0) }
        return .init(id: id, remainingFraction: remaining, resetsAt: reset)
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }()
}
