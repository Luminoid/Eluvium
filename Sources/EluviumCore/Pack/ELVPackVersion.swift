import Foundation

/// Orders pack version strings ("the newer of bundled and downloaded
/// wins"). Packs version as `<dotted date>-<label>.<build>`
/// (`2026.10.10-starter.1`, `2026.09.10-starter.2`): the leading dotted
/// numbers compare component-wise (a missing component is 0), then the
/// trailing integer after the label (0 when there is none); the label
/// itself is ignored, so a `remote` build and a `starter` build of one day
/// order by build number alone. A string without a leading number, or with
/// a component too large for `Int`, cannot be ordered that way: when either
/// side is unparseable the two compare as plain strings.
///
/// One ordering for every place that must pick the newer pack: the merge
/// (`ELVLoadedPack.merging`), and the remote store and service refusing a
/// rollback.
public enum ELVPackVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parse(lhs), let right = parse(rhs) else {
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
        for index in 0 ..< max(left.date.count, right.date.count) {
            let leftComponent = index < left.date.count ? left.date[index] : 0
            let rightComponent = index < right.date.count ? right.date[index] : 0
            if leftComponent != rightComponent { return leftComponent < rightComponent ? .orderedAscending : .orderedDescending }
        }
        if left.build != right.build { return left.build < right.build ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// The leading dotted numbers and the trailing build integer, or nil
    /// when the string does not start with a number or a number overflows.
    private static func parse(_ version: String) -> (date: [Int], build: Int)? {
        let datePart = version.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let components = datePart.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = components.first, !first.isEmpty else { return nil }
        var date: [Int] = []
        for component in components where !component.isEmpty {
            guard let number = Int(component) else { return nil }
            date.append(number)
        }
        // The build is the label's trailing integer: digits after the date
        // only, so a bare `2026.10.10` has build 0, not 10.
        let label = version.dropFirst(datePart.count)
        let trailing = String(label.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        guard !trailing.isEmpty else { return (date, 0) }
        guard let build = Int(trailing) else { return nil }
        return (date, build)
    }
}
