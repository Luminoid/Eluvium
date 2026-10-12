import Synchronization

/// A fixed-capacity cache behind a `Mutex`, evicting in insertion (FIFO)
/// order. The shape every pack-string compile cache in Core shares: keys are
/// pack-authored (unbounded input), so the cache must be bounded, and
/// eviction by insertion order keeps a working set just above capacity from
/// repeatedly evicting its hottest entry (dictionary order is arbitrary).
/// Values are handed out of the lock, so `Value` must be safe to share
/// between threads; the immutable Foundation objects cached here
/// (`NSRegularExpression`, `DateFormatter`) are.
final class ELVBoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct State {
        var entries: [Key: Value] = [:]
        var order: [Key] = []
    }

    private let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The cached value for `key`, or nil on a miss.
    func value(for key: Key) -> Value? {
        state.withLock { $0.entries[key] }
    }

    /// Stores `value` under `key` unless the key is already present (the
    /// first writer wins, so the eviction order never carries a duplicate),
    /// evicting the oldest entry past capacity. Returns the value now held.
    @discardableResult
    func insert(_ value: Value, for key: Key) -> Value {
        state.withLock { state in
            if let existing = state.entries[key] { return existing }
            if state.entries.count >= capacity, !state.order.isEmpty {
                state.entries.removeValue(forKey: state.order.removeFirst())
            }
            state.entries[key] = value
            state.order.append(key)
            return value
        }
    }

    /// The value for `key`, built by `make` on a miss. `make` runs outside
    /// the lock: building the value (a regex compile, a formatter) is the
    /// expensive step, and holding the lock across it would serialize every
    /// concurrent extraction on one compile. Two threads missing the same
    /// key both build; the first insert wins and the other result is dropped.
    func value(for key: Key, orMake make: () -> Value) -> Value {
        if let hit = value(for: key) { return hit }
        return insert(make(), for: key)
    }
}
