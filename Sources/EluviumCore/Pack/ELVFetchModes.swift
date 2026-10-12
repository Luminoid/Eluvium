import Foundation

/// The fetch-mode vocabulary the engine executes. Deliberately open strings,
/// not an enum: capability gating must let a binary skip sources declaring
/// modes it has never heard of, so unknown modes stay representable.
/// New modes and their membership sets land here, nowhere else.
public enum ELVFetchModes {
    public static let none = "none"
    public static let http = "http"
    public static let json = "json"
    public static let feed = "feed"
    public static let dom = "dom"
    public static let archive = "archive"
    public static let composite = "composite"

    /// The mode a plan or step decodes to when it declares none. No binary
    /// provides it as a capability, so the gate skips the source (with a
    /// reason naming the missing mode) and the validator names the step;
    /// a plan without a transport must never silently become an http fetch.
    public static let unsupported = "unsupported"

    /// The URL transports: the modes the floor pass parses and the
    /// pipeline builds fetch-response documents for.
    public static let urlTransports: Set<String> = [http, json, feed]

    /// What the pure pipeline runs without an injected DOM renderer.
    public static let coreExecutable: Set<String> = [none, http, json, feed]
}
