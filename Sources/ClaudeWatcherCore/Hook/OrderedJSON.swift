import Foundation

/// Minimal order-preserving JSON value, used to edit `~/.claude/settings.json` with a
/// minimal diff. `JSONSerialization` would reorder keys (or sort them) and reformat
/// (`"key" : value`); this keeps key order and number literals as written and prints in
/// the `JSON.stringify(value, null, 2)` style Claude Code itself uses.
/// Tradeoff: string escapes are normalized (e.g. `\/` or `\u00e9` in the source come back
/// as `/` and `é`), and whitespace is normalized to 2-space indentation.
/// Content that cannot be represented faithfully is refused instead of being altered:
/// invalid UTF-8 inside a string and unpaired surrogate escapes (a lone `\uD83D`) are parse
/// errors, so the installer never rewrites such a file. A leading UTF-8 BOM is skipped here;
/// `HookInstaller.transformedSettings` re-adds it when printing the file back.
indirect enum OrderedJSON: Equatable, Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case number(String)   // raw literal, preserved verbatim
    case bool(Bool)
    case null

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    // MARK: Access helpers

    subscript(key: String) -> OrderedJSON? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// Sets `key` in place when present (keeping its position), else appends it.
    /// No-op on non-objects.
    mutating func set(_ key: String, _ value: OrderedJSON) {
        guard case var .object(pairs) = self else { return }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[i].1 = value
        } else {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    mutating func remove(_ key: String) {
        guard case var .object(pairs) = self else { return }
        pairs.removeAll { $0.0 == key }
        self = .object(pairs)
    }

    // MARK: Parsing

    struct ParseError: Error, CustomStringConvertible {
        var offset: Int
        var message: String
        var description: String { "JSON parse error at byte \(offset): \(message)" }
    }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw ParseError(offset: parser.index, message: "trailing characters")
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // Skip a UTF-8 BOM if present.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(offset: index, message: message) }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard index + lit.count <= bytes.count, Array(bytes[index..<index + lit.count]) == lit else {
                throw fail("expected \(literal)")
            }
            index += lit.count
        }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < 512 else { throw fail("nesting too deep") }
            guard index < bytes.count else { throw fail("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var pairs: [(String, OrderedJSON)] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                while true {
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected key") }
                    let key = try parseString()
                    skipWhitespace()
                    try expect(":")
                    skipWhitespace()
                    pairs.append((key, try parseValue(depth: depth + 1)))
                    skipWhitespace()
                    guard index < bytes.count else { throw fail("unterminated object") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                    throw fail("expected , or }")
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try parseValue(depth: depth + 1))
                    skipWhitespace()
                    guard index < bytes.count else { throw fail("unterminated array") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    throw fail("expected , or ]")
                }
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default:
                return .number(try parseNumber())
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid value") }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func parseHex4() throws -> UInt16 {
            guard index + 4 <= bytes.count,
                  let v = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw fail("invalid \\u escape")
            }
            index += 4
            return v
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var units: [UInt8] = []
            while true {
                guard index < bytes.count else { throw fail("unterminated string") }
                let b = bytes[index]
                index += 1
                switch b {
                case UInt8(ascii: "\""):
                    // Refuse rather than substitute U+FFFD for invalid UTF-8.
                    guard let string = String(bytes: units, encoding: .utf8) else {
                        throw fail("invalid UTF-8 in string")
                    }
                    return string
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw fail("unterminated escape") }
                    let e = bytes[index]
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        // An unpaired surrogate has no UTF-8 form: refuse rather than
                        // substitute U+FFFD.
                        let first = try parseHex4()
                        var value = UInt32(first)
                        if (0xD800..<0xDC00).contains(first) {
                            guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else {
                                throw fail("unpaired surrogate escape")
                            }
                            index += 2
                            let low = try parseHex4()
                            guard (0xDC00..<0xE000).contains(low) else { throw fail("unpaired surrogate escape") }
                            value = 0x10000 + ((value - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                        }
                        // nil for a lone low surrogate.
                        guard let scalar = Unicode.Scalar(value) else { throw fail("unpaired surrogate escape") }
                        units.append(contentsOf: Array(String(scalar).utf8))
                    default:
                        throw fail("invalid escape")
                    }
                default:
                    guard b >= 0x20 else { throw fail("control character in string") }
                    units.append(b)
                }
            }
        }
    }

    // MARK: Printing (JSON.stringify(value, null, 2) style)

    func serialized(indent: String = "  ") -> String {
        var out = ""
        write(to: &out, level: 0, indent: indent)
        return out
    }

    private func write(to out: inout String, level: Int, indent: String) {
        let pad = String(repeating: indent, count: level + 1)
        let closePad = String(repeating: indent, count: level)
        switch self {
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, (key, value)) in pairs.enumerated() {
                out += pad
                OrderedJSON.writeString(key, to: &out)
                out += ": "
                value.write(to: &out, level: level + 1, indent: indent)
                out += i == pairs.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, value) in items.enumerated() {
                out += pad
                value.write(to: &out, level: level + 1, indent: indent)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case let .string(s): OrderedJSON.writeString(s, to: &out)
        case let .number(n): out += n
        case let .bool(b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
