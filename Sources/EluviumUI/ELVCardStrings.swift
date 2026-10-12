import Foundation

/// `ELVRecordCardView`'s own copy, localized from the target's resources:
/// `en.lproj/Localizable.strings` for the lines and a `.stringsdict` for the
/// item-count plural. Compiled `.lproj` strings, not a String Catalog:
/// command-line SwiftPM copies a `.xcstrings` into the bundle uncompiled,
/// and every lookup would then return its key. Field keys, values, ids, and
/// collection names are record data and pass through as they are.
enum ELVCardStrings {
    /// "source: <id>" in the meta line.
    static func source(_ sourceId: String) -> String {
        String(localized: "card.meta.source \(sourceId)", bundle: .module, comment: "Record card meta line: the source id that produced the record.")
    }

    /// "kind: <kind>" in the meta line.
    static func kind(_ kind: String) -> String {
        String(localized: "card.meta.kind \(kind)", bundle: .module, comment: "Record card meta line: the record's kind.")
    }

    /// "id: <external id>" in the meta line.
    static func id(_ externalId: String) -> String {
        String(localized: "card.meta.id \(externalId)", bundle: .module, comment: "Record card meta line: the record's external id.")
    }

    /// "identities: <namespace=value …>".
    static func identities(_ list: String) -> String {
        String(localized: "card.identities \(list)", bundle: .module, comment: "Record card line listing the record's identities as namespace=value pairs.")
    }

    /// "<collection>: <n> item(s)", pluralized per locale.
    static func collectionSummary(name: String, count: Int) -> String {
        let items = String(localized: "card.collection.itemCount \(count)", bundle: .module, comment: "Number of child records in a collection, pluralized.")
        return String(localized: "card.collection.summary \(name) \(items)", bundle: .module, comment: "A collection line: the collection's name, then its item count.")
    }
}
