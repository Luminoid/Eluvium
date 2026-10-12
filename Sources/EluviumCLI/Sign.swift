import CryptoKit
import EluviumCore
import EluviumNet
import Foundation

private let signUsage = """
eluvium sign — sign a pack into a distributable envelope

Produces an ELVPackEnvelope JSON (keyId, Ed25519 signature over the payload
as-authored, payload) that a client verifies with ELVPackVerifier before
loading. There is no canonicalization step: the signature covers the pack
bytes exactly as given.

The pack must load first: a pack that does not decode, or that loads with
authoring diagnostics, is refused (--force signs it anyway), and the pack
version and source ids are printed for review before anything is signed.

USAGE:
  eluvium sign --key PATH --key-id ID --pack PATH [-o PATH] [--force]

OPTIONS:
  --key PATH         Base64 private-key file from `eluvium keygen` (required)
  --key-id ID        Key id, must match a pinned key (required)
  --pack PATH        Pack JSON to sign (required)
  -o, --output PATH  Envelope JSON (default: stdout)
  --force            Sign despite pack diagnostics
  -h, --help
"""

func runSign(_ args: [String]) throws {
    let opts = CLIOptions.parse(args, usage: signUsage, values: ["--key", "--key-id", "--pack"], flags: ["--force"])
    guard let keyPath = opts.string("--key") else { usageError("--key is required", usage: signUsage) }
    guard let keyId = opts.string("--key-id") else { usageError("--key-id is required", usage: signUsage) }
    guard let packPath = opts.string("--pack") else { usageError("--pack is required", usage: signUsage) }

    let privateB64 = try String(contentsOfFile: keyPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let privateData = Data(base64Encoded: privateB64),
          let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    else {
        fail("could not read a private key from \(keyPath)")
    }

    let payload = try Data(contentsOf: URL(fileURLWithPath: packPath))
    reviewPack(payload, path: packPath, force: opts.has("--force"))
    let signature = try privateKey.signature(for: payload)
    let envelope = ELVPackEnvelope(keyId: keyId, signature: signature, payload: payload)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(envelope)

    // Atomic: a half-written envelope fails verification with a confusing
    // signature error, where a missing file would have said what happened.
    try CLIOptions.writeOutput(data, to: opts.outputPath, atomic: true)
    if let out = opts.outputPath {
        note("wrote envelope to \(out)")
    }
}

/// Signing is the last checkpoint before every installed app trusts these
/// bytes, so the pack must load as an app would load it: undecodable bytes
/// stop here, authoring diagnostics stop here unless forced, and the version
/// and source ids go to stderr so the signer sees what they vouch for. A
/// source skipped only for a native op this tool does not link (EluviumPlaces'
/// MapKit ops) is a note, not a refusal.
private func reviewPack(_ payload: Data, path: String, force: Bool) {
    ELVNetOps.register()
    let capabilities = ELVCapabilities(
        fetchModes: ELVFetchModes.urlTransports.union([ELVFetchModes.none, ELVFetchModes.dom, ELVFetchModes.archive]),
        binaryVersion: ELVBinary.version
    )
    let loaded: ELVLoadedPack
    do {
        loaded = try ELVPackLoader.load(embedded: payload, capabilities: capabilities)
    } catch {
        fail("\(path) does not load as a pack (\(error)); nothing signed")
    }
    for diagnostic in loaded.diagnostics {
        warn(diagnostic.description)
    }
    if !loaded.diagnostics.isEmpty, !force {
        fail("\(loaded.diagnostics.count) pack diagnostic(s) above; fix them or pass --force to sign anyway")
    }
    for skipped in loaded.skipped {
        note("source \"\(skipped.id)\" skips in this tool: \(skipped.reason)")
    }
    note("signing pack \(loaded.pack.packVersion): \(loaded.pack.sources.count) sources (\(loaded.pack.sources.map(\.id).joined(separator: ", ")))")
}
