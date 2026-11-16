import Foundation
import CoreGraphics

/// A small command line reader: `--name value`, `--name=value`, bare `--flag`, positionals.
public struct Args {
    public private(set) var positionals: [String] = []
    private var values: [String: String] = [:]
    private var used = Set<String>()

    public init(_ raw: [String], flags: Set<String> = []) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            index += 1
            guard token.hasPrefix("--"), token.count > 2 else {
                positionals.append(token)
                continue
            }
            let body = String(token.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                values[String(body[..<eq])] = String(body[body.index(after: eq)...])
            } else if flags.contains(body) || index >= raw.count {
                values[body] = "true"
            } else {
                values[body] = raw[index]
                index += 1
            }
        }
    }

    public mutating func string(_ name: String) -> String? {
        used.insert(name)
        return values[name]
    }

    public mutating func flag(_ name: String) -> Bool {
        used.insert(name)
        return values[name] != nil && values[name] != "false"
    }

    public mutating func double(_ name: String) throws -> Double? {
        guard let text = string(name) else { return nil }
        guard let value = Double(text) else { throw IrisError("--\(name) expects a number, got \"\(text)\"") }
        return value
    }

    public mutating func int(_ name: String) throws -> Int? {
        guard let text = string(name) else { return nil }
        guard let value = Int(text) else { throw IrisError("--\(name) expects a whole number, got \"\(text)\"") }
        return value
    }

    /// Reads `a,b,c,d` or `axb` style lists of numbers.
    public mutating func numbers(_ name: String, count: Int) throws -> [Double]? {
        guard let text = string(name) else { return nil }
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "x" || $0 == ":" }).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == count, !parts.contains(where: { $0 == nil }) else {
            throw IrisError("--\(name) expects \(count) numbers, got \"\(text)\"")
        }
        return parts.map { $0! }
    }

    public mutating func rect(_ name: String) throws -> CGRect? {
        guard let n = try numbers(name, count: 4) else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// Fails on options nobody asked about, so a typo never passes silently.
    public func finish() throws {
        let unknown = values.keys.filter { !used.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw IrisError("unknown option\(unknown.count > 1 ? "s" : ""): " + unknown.map { "--\($0)" }.joined(separator: ", "))
        }
    }
}
