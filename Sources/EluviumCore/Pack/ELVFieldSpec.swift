import Foundation

/// One candidate in a field's ordered list: a selector, optional pipes, an
/// optional coercion.
public struct ELVCandidate: Sendable, Decodable, Equatable {
    public var from: ELVSelector
    public var pipes: [ELVPipe]
    public var coercion: ELVCoercion?
    /// For multi-output native ops: which named output feeds this field.
    public var select: String?

    public init(from: ELVSelector, pipes: [ELVPipe] = [], coercion: ELVCoercion? = nil, select: String? = nil) {
        self.from = from
        self.pipes = pipes
        self.coercion = coercion
        self.select = select
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case pipes = "pipe"
        case kind = "as"
        case format
        case currency
        case currencyFrom
        case scale
        case select
    }

    private struct Scale: Decodable {
        var min: Double
        var max: Double
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(ELVSelector.self, forKey: .from)
        // `pipe` is always a list. Anything else (a bare string, an object)
        // decodes as one unsupported pipe, so the candidate is invalidated
        // and the validator names it; the source is untouched.
        if container.contains(.pipes) {
            pipes = (try? container.decode([ELVPipe].self, forKey: .pipes)) ?? [.unsupported(name: "(malformed)")]
        } else {
            pipes = []
        }
        select = try container.decodeIfPresent(String.self, forKey: .select)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            let scale = try container.decodeIfPresent(Scale.self, forKey: .scale)
            coercion = try ELVCoercion(
                kind: kind,
                format: container.decodeIfPresent(String.self, forKey: .format),
                currency: container.decodeIfPresent(String.self, forKey: .currency),
                currencyFrom: container.decodeIfPresent(ELVSelector.self, forKey: .currencyFrom),
                scaleMin: scale?.min,
                scaleMax: scale?.max
            )
        } else {
            coercion = nil
        }
    }
}

/// A field with its ordered candidate list. Fields are an array, not a
/// dictionary: pack order is the evaluation order, deterministically.
public struct ELVFieldSpec: Sendable, Decodable, Equatable {
    public var name: String
    public var candidates: [ELVCandidate]

    public init(name: String, candidates: [ELVCandidate]) {
        self.name = name
        self.candidates = candidates
    }

    /// Lenient decode: a field missing its `candidates` key degrades
    /// to an empty list — the field simply never produces, and the pack
    /// validator reports it — instead of a decode error killing the source.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        candidates = try container.decodeIfPresent([ELVCandidate].self, forKey: .candidates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case candidates
    }
}
