import Foundation

/// Evaluates selectors against a context. Pure.
enum ELVSelectorEngine {
    static func evaluate(_ selector: ELVSelector, context: ELVExtractionContext) -> ELVExtractedValue? {
        switch selector {
        case let .const(value):
            return .string(value)
        case let .urlParam(name):
            return context.params[name].map { .string($0) }
        case let .urlQuery(name):
            guard let url = context.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let item = components.queryItems?.first(where: { $0.name == name }),
                  let value = item.value else { return nil }
            return .string(value)
        case let .urlRegex(pattern):
            guard let url = context.url else { return nil }
            return matchRegex(pattern, in: ELVRegexCache.boundedInput(url.absoluteString) as NSString)
        case let .meta(name):
            return context.document.metas[name].map { .string($0) }
        case let .jsonld(path):
            return evaluateJSONLD(path, nodes: context.document.jsonLDNodes)
        case let .json(path):
            guard let root = context.document.json else { return nil }
            let results = ELVJSONPath(path).evaluate(root)
            guard let first = results.first else { return nil }
            return results.count == 1 ? .json(first) : .list(results.compactMap { ELVExtractedValue.json($0).singleString })
        case let .css(selector, attr):
            let key = attr.map { "\(selector)@\($0)" } ?? selector
            return (context.document.cssResults[key] ?? context.document.cssResults[selector]).map { .string($0) }
        case let .textRegex(pattern, after):
            return evaluateTextRegex(pattern, after: after, document: context.document)
        case let .column(name):
            return context.document.row[name].map { .string($0) }
        case let .field(name):
            guard let value = context.fields[name] else { return nil }
            return stringForm(of: value)
        case let .paste(key):
            return context.paste?.value(key).map { .string($0) }
        case .regexRows:
            // A collection driver, not a value selector: a single candidate
            // has no row to bind, so it simply doesn't produce.
            return nil
        case .native:
            // Native ops are registered by the pack layer; without a
            // registry entry the candidate simply doesn't produce.
            return nil
        case .unsupported:
            return nil
        }
    }

    /// Rendered text when a DOM pass produced it;
    /// otherwise the raw fetched HTML, so markup-shaped candidates (Amazon's
    /// title span, image-gallery JSON) work over plain http. Bounded once
    /// per document (`ELVDocument.regexText`); an `after` anchor moves the
    /// capped window to the anchor's first occurrence (a Six Flags ride's
    /// data blob sits ~640 KB into a page, past the cap), never how long
    /// the window is. Cut before copying: the tail past the anchor can be
    /// hundreds of KB.
    private static func evaluateTextRegex(_ pattern: String, after: String?, document: ELVDocument) -> ELVExtractedValue? {
        if let after {
            guard !after.isEmpty, let whole = document.text ?? document.html,
                  let anchor = whole.range(of: after) else { return nil }
            return matchRegex(pattern, in: String(whole[anchor.lowerBound...].prefix(ELVRegexCache.inputCap)) as NSString)
        }
        guard let text = document.regexText else { return nil }
        return matchRegex(pattern, in: text)
    }

    /// `Type.key.path` — filter nodes by `@type` (`*` = any), then walk the
    /// keypath in the first matching node that yields a value.
    private static func evaluateJSONLD(_ path: String, nodes: [ELVRawJSON]) -> ELVExtractedValue? {
        let components = path.split(separator: ".").map(String.init)
        guard let typeFilter = components.first else { return nil }
        let keyPath = Array(components.dropFirst())
        for node in nodes where nodeMatchesType(node, filter: typeFilter) {
            var current: ELVRawJSON? = node
            for key in keyPath {
                // Arrays step into their first element ("offers" is object or array in the wild).
                if let array = current?.arrayValue { current = array.first }
                current = current?.objectValue?[key]
            }
            if let array = current?.arrayValue { current = array.first }
            if let value = current, value != .null {
                return .json(value)
            }
        }
        return nil
    }

    private static func nodeMatchesType(_ node: ELVRawJSON, filter: String) -> Bool {
        guard filter != "*" else { return true }
        guard let typeValue = node["@type"] else { return false }
        let types: [String] = typeValue.stringValue.map { [$0] } ?? (typeValue.arrayValue?.compactMap(\.stringValue) ?? [])
        return types.contains { $0.caseInsensitiveCompare(filter) == .orderedSame }
    }

    /// `nsString` arrives already cut to `ELVRegexCache.inputCap`, like
    /// every pack-regex input.
    private static func matchRegex(_ pattern: String, in nsString: NSString) -> ELVExtractedValue? {
        // Pack patterns run per candidate per field per record, so the
        // compile goes through the bounded cache; the `(?i)` prefix is how
        // URL and text regexes are case-insensitive through its option-less
        // API.
        guard let regex = ELVRegexCache.regex("(?i)" + pattern) else { return nil }
        // Under the evaluation budget: a backtracking pattern over a hostile
        // page body is a miss, not a hang.
        guard let match = ELVRegexCache.boundedMatches(of: regex, in: nsString as String, limit: 1)?.first else { return nil }
        let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
        return .string(nsString.substring(with: range))
    }

    static func stringForm(of value: ELVValue) -> ELVExtractedValue? {
        switch value {
        case let .text(string): .string(string)
        case let .number(number): .string(ELVNumberFormat.compactString(number))
        case let .url(url): .string(url.absoluteString)
        case let .phone(phone): .string(phone)
        case let .tags(tags): .list(tags)
        default: nil
        }
    }
}
