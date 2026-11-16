import Foundation

/// Reads and writes the files of a session directory.
public struct SessionStore {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public var infoURL: URL { dir.appendingPathComponent("session.json") }
    public var stateURL: URL { dir.appendingPathComponent("state.json") }
    public var rawURL: URL { dir.appendingPathComponent("raw.mov") }
    public var maskURL: URL { dir.appendingPathComponent("mask.png") }
    public var inputURL: URL { dir.appendingPathComponent("input.jsonl") }
    public var marksURL: URL { dir.appendingPathComponent("marks.jsonl") }
    public var changesURL: URL { dir.appendingPathComponent("changes.jsonl") }
    public var cursorsDir: URL { dir.appendingPathComponent("cursors") }
    public var logURL: URL { dir.appendingPathComponent("recorder.log") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func writeInfo(_ info: SessionInfo) throws {
        try Self.encoder.encode(info).write(to: infoURL, options: .atomic)
    }

    public func readInfo() throws -> SessionInfo {
        guard let data = try? Data(contentsOf: infoURL) else {
            throw IrisError("not a recording session: \(dir.path)")
        }
        return try Self.decoder.decode(SessionInfo.self, from: data)
    }

    public func writeState(_ state: RecorderState) {
        if let data = try? Self.encoder.encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    public func readState() -> RecorderState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? Self.decoder.decode(RecorderState.self, from: data)
    }

    public func appendMark(_ mark: Mark) throws {
        try Self.appendLine(mark, to: marksURL)
    }

    public func readMarks() -> [Mark] { Self.readLines(marksURL) }
    public func readInput() -> [InputEvent] { Self.readLines(inputURL) }
    /// Nil for a recording made before changes were noted.
    public func readChanges() -> [ChangeEvent]? {
        FileManager.default.fileExists(atPath: changesURL.path) ? Self.readLines(changesURL) : nil
    }

    static func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try lineEncoder.encode(value)
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    static func readLines<T: Decodable>(_ url: URL) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(T.self, from: Data(line.utf8))
        }
    }

    // MARK: Locating sessions

    /// Where sessions go when the caller names no directory.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Iris")
    }

    static var pointerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iris/current")
    }

    /// Remembers the session that `mark`, `stop` and `render` act on when given no path.
    public static func setCurrent(_ dir: URL) {
        try? FileManager.default.createDirectory(at: pointerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? dir.path.write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    public static func current() -> SessionStore? {
        guard let path = try? String(contentsOf: pointerURL, encoding: .utf8) else { return nil }
        let dir = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path) else { return nil }
        return SessionStore(dir: dir)
    }

    public static func resolve(_ path: String?) throws -> SessionStore {
        // `iris run` names its session to the command it runs.
        if let path = path ?? ProcessInfo.processInfo.environment["IRIS_SESSION"].flatMap({ $0.isEmpty ? nil : $0 }) {
            let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path) else {
                throw IrisError("not a recording session: \(dir.path)")
            }
            return SessionStore(dir: dir)
        }
        guard let store = current() else {
            throw IrisError("no recording session yet; run `iris start` first or pass a session directory")
        }
        return store
    }
}
