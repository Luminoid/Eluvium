import Foundation

/// Stage ① for file inputs: match on filename glob plus content
/// probe (CSV header row, `contains` tokens), never on extension alone.
/// Probes read a bounded head of the file (`ELVArchiveLimits.probeBytes`):
/// recognizing a multi-hundred-MB export must never decode it whole.
public enum ELVFileRecognizer {
    public static func recognize(fileName: String, data: Data, sources: [ELVSource]) -> ELVSource? {
        // Decoded lazily and once: most sources fail the name glob first,
        // and the head is the same for every probe.
        var head: String??
        for source in sources {
            guard let rule = source.match?.file, rule.matchesName(fileName) else { continue }
            if head == nil { head = .some(probeHead(of: data)) }
            guard probeFailure(rule, head: head ?? nil) == nil else { continue }
            return source
        }
        return nil
    }

    /// The bounded, lossily decoded file head every content probe reads.
    static func probeHead(of data: Data) -> String? {
        decode(data.prefix(ELVArchiveLimits.probeBytes))
    }

    /// The expectation `head` fails to meet, or nil when it passes every
    /// probe `rule` declares: every `csvHeader` name present in the first
    /// record, every `contains` token present. A rule with no probe accepts
    /// any bytes. Shared by recognition and the importer's own gate so the
    /// two can never disagree about what a source's file looks like.
    static func probeFailure(_ rule: ELVFileMatchRule, head: String?) -> String? {
        if !rule.csvHeader.isEmpty {
            let headers = head.flatMap(ELVCSVReader.parseHeaders) ?? []
            guard rule.csvHeader.allSatisfy(headers.contains) else { return rule.csvHeader.joined(separator: ", ") }
        }
        if !rule.contains.isEmpty {
            guard let head, rule.matchesContent(head) else { return rule.contains.joined(separator: ", ") }
        }
        return nil
    }

    /// Lossy UTF-8: a byte cap can land mid-character; a failable
    /// decode would throw whole bodies away, so the replacement-character
    /// initializer is the deliberate choice here.
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
