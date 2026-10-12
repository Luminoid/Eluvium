import Foundation

// Entry point for the `eluvium` tool. Dispatches to a subcommand; each command
// lives in its own file and parses its own options via CLIOptions.

/// A failed run (I/O, signing, a bad pack): the message to stderr, exit 1.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// A bad invocation (an unknown option or command, a missing required
/// option): the message plus the relevant usage to stderr, exit 2 — the
/// conventional usage-error code, distinct from 1 so a script can tell a
/// typo from a run that failed.
func usageError(_ message: String, usage: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

/// Progress/confirmation lines go to stderr so stdout stays clean when a
/// command's real output is piped.
func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let usage = """
eluvium — Eluvium catalog + pack tooling

USAGE:
  eluvium curate  [options]   Emit an adopting app's compiled-in source subset
  eluvium keygen  [options]   Generate an Ed25519 signing keypair
  eluvium sign    [options]   Sign a pack into a distributable envelope

Run `eluvium <command> --help` for command options.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    print(usage)
    exit(0)
}

do {
    let rest = Array(arguments.dropFirst())
    switch command {
    case "curate":
        try runCurate(rest)
    case "keygen":
        try runKeygen(rest)
    case "sign":
        try runSign(rest)
    case "-h", "--help", "help":
        print(usage)
    default:
        usageError("unknown command \"\(command)\"", usage: usage)
    }
} catch {
    fail(String(describing: error))
}
