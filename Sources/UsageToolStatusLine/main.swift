import Darwin
import Foundation

private let arguments = Array(CommandLine.arguments.dropFirst())

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            let remaining = max(0, 65_536 - data.count)
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
        }
    }

    func string() -> String? {
        lock.withLock { String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) }
    }
}

private func readBoundedInput() throws -> Data {
    var result = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        guard result.count + chunk.count <= ClaudeStatusLineCore.maximumInputBytes else {
            throw ClaudeStatusLineError.inputTooLarge
        }
        result.append(chunk)
    }
    return result
}

private func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func runChain(_ command: String, input: Data) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let ended = DispatchSemaphore(value: 0)
    let readerFinished = DispatchGroup()
    let output = BoundedOutput()
    process.terminationHandler = { _ in ended.signal() }
    do {
        try process.run()
        readerFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readerFinished.leave() }
            while let chunk = try? stdout.fileHandleForReading.read(upToCount: 16 * 1_024),
                  !chunk.isEmpty {
                output.append(chunk)
            }
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        if ended.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 0.5)
            }
        }
        try? stdout.fileHandleForReading.close()
        _ = readerFinished.wait(timeout: .now() + 0.5)
        return output.string()
    } catch {
        return nil
    }
}

let chain: String? = {
    if let encoded = argument(after: "--chain-base64"),
       let data = Data(base64Encoded: encoded) {
        return String(data: data, encoding: .utf8)
    }
    return argument(after: "--chain")
}()

let outputURL: URL = {
    if let path = argument(after: "--output") { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/UsageTool/claude-usage.json")
}()

let inputResult = Result { try readBoundedInput() }

do {
    let input = try inputResult.get()
    let snapshot = try ClaudeStatusLineCore.sanitize(input: input)
    if let snapshot { try ClaudeStatusLineCore.writeLastWriterWins(snapshot, to: outputURL) }
    let usageLine = ClaudeStatusLineCore.displayLine(snapshot)
    if let chain, let chainedOutput = runChain(chain, input: input), !chainedOutput.isEmpty {
        print("\(chainedOutput) · \(usageLine)")
    } else {
        print(usageLine)
    }
} catch {
    let safeInput = (try? inputResult.get()) ?? Data()
    if let chain, let chainedOutput = runChain(chain, input: safeInput), !chainedOutput.isEmpty {
        print("\(chainedOutput) · UsageTool: unavailable")
    } else {
        print("UsageTool: unavailable")
    }
}
