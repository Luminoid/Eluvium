import EluviumCore
import Foundation

/// Source packs shipped alongside the starter pack but deliberately kept out
/// of `ELVStarterPack`, so nothing loads them by default. A hosting app opts
/// in explicitly, only for targets it has decided it may fetch (see
/// `LEGAL.md`). These carry the same embedded trust as the starter: they are
/// bundle resources, code-signed with the binary, loaded through
/// `ELVPackLoader.load(embedded:)` (network-delivered packs still go through
/// `ELVPackVerifier`).
public enum ELVOptInPacks {
    /// Retailer product pages (Amazon, Chewy). Split out because those sites'
    /// terms restrict automated access and the sources escalate to a headless
    /// browser past bot protections; a host that loads this pack is asserting
    /// it may fetch those targets. The Petfolio parity suite loads it to prove
    /// field-level agreement with Petfolio's LinkAutofill.
    public static func commerce(capabilities: ELVCapabilities) throws -> ELVLoadedPack {
        try load(resource: "CommerceOptInPack", capabilities: capabilities)
    }

    /// The raw bytes of a bundled opt-in pack. Private: bundled resources are
    /// embedded-trust and reach the loader only through `load(resource:)`;
    /// nothing outside this type has a use for the bytes (a host that wants
    /// to re-sign a pack works from the authored JSON, not the bundle).
    private static func data(forResource resource: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw ELVOptInPackError.resourceMissing(resource)
        }
        return try Data(contentsOf: url)
    }

    private static func load(resource: String, capabilities: ELVCapabilities) throws -> ELVLoadedPack {
        try ELVPackLoader.load(embedded: data(forResource: resource), capabilities: capabilities)
    }
}

public enum ELVOptInPackError: Error, Equatable {
    /// The named opt-in resource is not in the bundle: a build/packaging bug,
    /// never a runtime condition.
    case resourceMissing(String)
}
