/// A stable, process-independent FNV-1a hash: the same input keys identically
/// across launches and devices (Swift's `Hasher` is seeded per process).
/// Used for feed-item identity fallbacks and the generic-floor record key.
enum ELVStableHash {
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
