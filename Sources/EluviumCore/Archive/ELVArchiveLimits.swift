import Foundation

/// The ceilings every archive surface shares. A user-provided file is
/// hostile input like any other: a pathological archive must fail with a
/// typed reason, never grow one in-memory array without bound or decode a
/// multi-hundred-MB file just to read its header.
public enum ELVArchiveLimits {
    /// Ceiling on items materialized from one import (CSV rows, shard items,
    /// OPML outlines, single-document arrays). Items past the cap are
    /// dropped, not an error; shards wholly past it are not parsed at all.
    public static let maxTotalItems = 10000

    /// Byte ceiling for one import; larger files are refused up front with
    /// `ELVArchiveImporter.Failure.tooLarge`.
    public static let maxImportBytes = 50 * 1024 * 1024

    /// How many leading bytes recognition and the importer's own probe
    /// decode: enough for any CSV header record or XML prolog plus root
    /// element, cheap on a multi-MB archive.
    public static let probeBytes = 65536
}
