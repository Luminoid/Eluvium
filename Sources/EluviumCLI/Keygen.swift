import CryptoKit
import Foundation

private let keygenUsage = """
eluvium keygen — generate an Ed25519 signing keypair

Writes the private key (base64, mode 0600) to a file you keep secret, and
prints the public key to pin in your app's ELVPackKeySet. Refuses to
overwrite an existing file, and to write inside a git work tree.

USAGE:
  eluvium keygen --key-id ID [-o PATH] [--force]

OPTIONS:
  --key-id ID        Key id referenced from signed envelopes (required)
  -o, --output PATH  Private-key file
                     (default: ~/.config/eluvium/keys/<key-id>.private.key)
  --force            Write even inside a git work tree
  -h, --help
"""

func runKeygen(_ args: [String]) throws {
    let opts = CLIOptions.parse(args, usage: keygenUsage, values: ["--key-id"], flags: ["--force"])
    guard let keyId = opts.string("--key-id") else {
        usageError("--key-id is required", usage: keygenUsage)
    }

    let path: String
    if let output = opts.outputPath {
        path = output
    } else {
        // The default path is built from the key id, so the id must be a
        // plain file name, never a path that climbs out of the key folder.
        guard keyId.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            usageError("--key-id may use letters, digits, '.', '_', and '-' (or pass -o)", usage: keygenUsage)
        }
        // Outside every project by default: the private key signs packs every
        // installed app trusts, and a key in a repository is one `git add`
        // from public.
        let directory = URL.homeDirectory.appendingPathComponent(".config/eluvium/keys", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("\(keyId).private.key").path
    }
    if !opts.has("--force"), let repository = enclosingGitWorkTree(of: path) {
        fail("\(path) is inside the git work tree at \(repository); keep signing keys out of repositories (pass --force to write there anyway)")
    }

    let privateKey = Curve25519.Signing.PrivateKey()
    try createSecretFile(path, contents: Data(privateKey.rawRepresentation.base64EncodedString().utf8))
    // Report what is on disk, not what was asked for.
    let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    if mode == 0o600 {
        note("wrote private key to \(path) (mode 0600; keep it secret)")
    } else {
        warn("wrote private key to \(path), but its mode reads \(mode.map { String($0, radix: 8) } ?? "unknown"), not 600; run chmod 600 on it")
    }

    let publicBytes = privateKey.publicKey.rawRepresentation
    // A byte literal needs no decoding at runtime, so the snippet carries no
    // `Data(base64Encoded:)!` (a crash site) and no `?? Data()` (a silently
    // empty key after a paste slip): what compiles IS the key.
    var lines = [
        "Public key for \"\(keyId)\" (base64 \(publicBytes.base64EncodedString())). Pin it in your app:",
        "",
        "    let keys = ELVPackKeySet(keys: [",
        "        \"\(keyId)\": Data([",
    ]
    lines += swiftByteRows(publicBytes, indent: "            ")
    lines += ["        ]),", "    ])"]
    print(lines.joined(separator: "\n"))
}

/// Creates `path` and writes `contents` in one exclusive step: `O_EXCL` turns
/// "already exists" and "create" into a single atomic check (no gap for a
/// racing file), `O_NOFOLLOW` refuses a planted symlink, and mode 0600
/// applies at creation, so the key is never readable by others for even an
/// instant. An overwritten private key is unrecoverable and orphans every
/// envelope it ever signed, so an existing file is a hard stop.
private func createSecretFile(_ path: String, contents: Data) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
        if errno == EEXIST {
            fail("\(path) already exists; refusing to overwrite a private key (pass -o for another path)")
        }
        throw CLIOutputError.writeFailed(path)
    }
    defer { close(descriptor) }
    let written = contents.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == contents.count else { throw CLIOutputError.writeFailed(path) }
}

/// The git work tree `path` would land in, or nil: the nearest ancestor
/// directory holding a `.git` entry (a directory, or a file for worktrees
/// and submodules).
private func enclosingGitWorkTree(of path: String) -> String? {
    var directory = (URL(fileURLWithPath: path).standardizedFileURL.path as NSString).deletingLastPathComponent
    while true {
        if FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
            return directory
        }
        let parent = (directory as NSString).deletingLastPathComponent
        if parent == directory || parent.isEmpty { return nil }
        directory = parent
    }
}

/// `0x..` bytes, eight per line, every line trailing-comma'd (Swift array
/// literals allow it), indented for the snippet above.
private func swiftByteRows(_ bytes: Data, indent: String) -> [String] {
    let hex = bytes.map { String(format: "0x%02X", $0) }
    return stride(from: 0, to: hex.count, by: 8).map { start in
        indent + hex[start ..< min(start + 8, hex.count)].joined(separator: ", ") + ","
    }
}
