import Foundation

/// A deliberately small JSONPath subset over `ELVRawJSON`, covering what
/// packs actually use: `$.a.b`, `[0]`, `[-1]`, `[*]`, and slices
/// `[0:12]`. No filters, no recursive descent — packs needing judgment use
/// native ops.
public struct ELVJSONPath: Sendable, Equatable {
    private enum Step: Equatable {
        case key(String)
        case index(Int)
        case slice(start: Int?, end: Int?)
        case all
    }

    private let steps: [Step]
    public let path: String
    /// Whether parsing succeeded; an invalid path evaluates to nothing.
    public let isValid: Bool

    public init(_ path: String) {
        self.path = path
        var parsed: [Step] = []
        var valid = true

        var remainder = Substring(path)
        if remainder.hasPrefix("$") { remainder.removeFirst() }
        while !remainder.isEmpty, valid {
            if remainder.hasPrefix(".") {
                remainder.removeFirst()
                let key = remainder.prefix { $0 != "." && $0 != "[" }
                if key.isEmpty {
                    valid = false
                } else {
                    parsed.append(.key(String(key)))
                    remainder = remainder.dropFirst(key.count)
                }
            } else if remainder.hasPrefix("[") {
                guard let close = remainder.firstIndex(of: "]") else {
                    valid = false
                    break
                }
                let body = remainder[remainder.index(after: remainder.startIndex) ..< close]
                if body == "*" {
                    parsed.append(.all)
                } else if body.contains(":") {
                    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        valid = false
                        break
                    }
                    let start = parts[0].isEmpty ? nil : Int(parts[0])
                    let end = parts[1].isEmpty ? nil : Int(parts[1])
                    if (!parts[0].isEmpty && start == nil) || (!parts[1].isEmpty && end == nil) {
                        valid = false
                        break
                    }
                    parsed.append(.slice(start: start, end: end))
                } else if let index = Int(body) {
                    parsed.append(.index(index))
                } else {
                    valid = false
                    break
                }
                remainder = remainder[remainder.index(after: close)...]
            } else {
                valid = false
            }
        }

        steps = parsed
        isValid = valid
    }

    /// Evaluates against `root`, returning every matched node in document
    /// order. An invalid path or a miss returns `[]`.
    public func evaluate(_ root: ELVRawJSON) -> [ELVRawJSON] {
        guard isValid else { return [] }
        var current = [root]
        for step in steps {
            var next: [ELVRawJSON] = []
            for node in current {
                switch step {
                case let .key(key):
                    if let value = node.objectValue?[key] { next.append(value) }
                case let .index(index):
                    if let array = node.arrayValue {
                        let resolved = index >= 0 ? index : array.count + index
                        if array.indices.contains(resolved) { next.append(array[resolved]) }
                    }
                case let .slice(start, end):
                    if let array = node.arrayValue {
                        let lower = max(0, start ?? 0)
                        let upper = min(array.count, end ?? array.count)
                        if lower < upper { next.append(contentsOf: array[lower ..< upper]) }
                    }
                case .all:
                    if let array = node.arrayValue { next.append(contentsOf: array) }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// The first matched node, or `nil`.
    public func first(_ root: ELVRawJSON) -> ELVRawJSON? {
        evaluate(root).first
    }
}

public extension ELVRawJSON {
    /// Builds a raw JSON tree from a `JSONSerialization` object graph.
    /// Returns `nil` for values JSON cannot represent.
    init?(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [ELVRawJSON] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = ELVRawJSON(foundation: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var object: [String: ELVRawJSON] = [:]
            object.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = ELVRawJSON(foundation: element) else { return nil }
                object[key] = value
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /// Parses JSON `data` into a raw tree, or `nil` on malformed input.
    static func parse(_ data: Data) -> ELVRawJSON? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return ELVRawJSON(foundation: object)
    }
}
