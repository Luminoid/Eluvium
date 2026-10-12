import Foundation

/// A tiny hand-rolled option parser: enough for the three subcommands, no
/// external dependency (the package keeps its non-UI targets dependency-free). Each command
/// declares its value options (`--key value` or `--key=value`) and flags up
/// front; anything undeclared — a misspelled option, a stray positional — is a
/// usage error (exit 2), never silently accepted: `--familes travel` used to
/// parse as nothing and curate carried on without a word. `-h`/`--help` and
/// `-o`/`--output` are shared by every command and handled here.
struct CLIOptions {
    private var named: [String: String] = [:]
    private var flags: Set<String> = []

    /// Parses `args` against the declared option set. `-h`/`--help` prints
    /// `usage` to stdout and exits 0; anything undeclared prints the error
    /// plus `usage` to stderr and exits 2.
    static func parse(_ args: [String], usage: String, values: Set<String>, flags: Set<String> = []) -> Self {
        let knownValues = values.union(["-o", "--output"])
        let knownFlags = flags.union(["-h", "--help"])
        var options = Self()
        var index = 0
        while index < args.count {
            var arg = args[index]
            index += 1
            var inlineValue: String?
            if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                inlineValue = String(arg[arg.index(after: equals)...])
                arg = String(arg[..<equals])
            }
            if knownFlags.contains(arg) {
                guard inlineValue == nil else { usageError("\(arg) takes no value", usage: usage) }
                options.flags.insert(arg)
            } else if knownValues.contains(arg) {
                if let inlineValue {
                    options.named[arg] = inlineValue
                } else if index < args.count {
                    options.named[arg] = args[index]
                    index += 1
                } else {
                    usageError("\(arg) needs a value", usage: usage)
                }
            } else if arg.hasPrefix("-") {
                usageError("unknown option \(arg)", usage: usage)
            } else {
                usageError("unexpected argument \"\(arg)\"", usage: usage)
            }
        }
        if options.has("-h", "--help") {
            print(usage)
            exit(0)
        }
        return options
    }

    func string(_ keys: String...) -> String? {
        keys.lazy.compactMap { named[$0] }.first
    }

    /// A comma-separated value split into trimmed, non-empty parts.
    func list(_ keys: String...) -> [String] {
        guard let raw = keys.lazy.compactMap({ named[$0] }).first else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func has(_ keys: String...) -> Bool {
        keys.contains { flags.contains($0) }
    }

    /// `-o PATH` / `--output PATH`, shared by every command; nil means stdout.
    var outputPath: String? {
        string("-o", "--output")
    }

    /// Writes `data` to `path`, or to stdout when `path` is nil. `atomic: true`
    /// goes through a temp file + rename, so a crash mid-write never leaves a
    /// truncated envelope or pack behind. `atomic: false` creates the file in
    /// place with `attributes` applied at creation — keygen's mode 0600,
    /// which a rename-based write cannot promise for the temp file's first
    /// instant.
    static func writeOutput(_ data: Data, to path: String?, atomic: Bool, attributes: [FileAttributeKey: Any] = [:]) throws {
        guard let path else {
            print(String(bytes: data, encoding: .utf8) ?? "")
            return
        }
        if atomic {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else if !FileManager.default.createFile(atPath: path, contents: data, attributes: attributes) {
            throw CLIOutputError.writeFailed(path)
        }
    }
}

enum CLIOutputError: Error, CustomStringConvertible {
    /// `FileManager.createFile` answered false: an unwritable directory, a
    /// path that is a directory, a full disk. The path names the culprit.
    case writeFailed(String)

    var description: String {
        switch self {
        case let .writeFailed(path): "could not write \(path)"
        }
    }
}
