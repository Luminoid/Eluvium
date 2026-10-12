import Foundation

/// A declared field that no candidate filled, with the candidates that were
/// tried. Provenance records which candidate won a field; a miss
/// records what the pack looked for when nothing did, so a thin record names
/// its gaps instead of only having them.
public struct ELVFieldMiss: Sendable, Equatable {
    /// The field name as the pack declares it.
    public var field: String
    /// Each candidate's selector tag (`meta:og:title`, `jsonld:Product.name`),
    /// in evaluation order. Pack text only, never page content.
    public var candidates: [String]

    public init(field: String, candidates: [String]) {
        self.field = field
        self.candidates = candidates
    }
}

/// An async native op (a MapKit lookup, a short-link chase) that threw
/// instead of answering. The candidate still yields no value, exactly like
/// an op that ran and found nothing; this keeps the two distinguishable.
public struct ELVNativeOpFailure: Sendable, Equatable {
    /// The field whose candidate called the op.
    public var field: String
    /// The op reference as the pack wrote it (`place.mapKitLookup`).
    public var op: String
    /// The error's public summary: type and case, or domain and code
    /// (`ELVLog.describe`). The full description goes only to private log
    /// detail, since an op error can carry user input.
    public var error: String

    public init(field: String, op: String, error: String) {
        self.field = field
        self.op = op
        self.error = error
    }
}
