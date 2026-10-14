import EluviumCatalog
import EluviumCore
import EluviumNet
import Foundation

private let curateUsage = """
eluvium curate — emit an adopting app's compiled-in source subset

The app links only the sources it selects, not the whole catalog. Default
output is a Swift file (inline compiled-in pack); --format json emits raw
subset pack JSON for a bundle-resource adopter.

USAGE:
  eluvium curate [--ids id1,id2] [--families f1,f2] [options] [-o PATH]

OPTIONS:
  --ids LIST         Comma-separated source ids to include
  --families LIST    Comma-separated families: \(ELVCatalogFamilies.known.joined(separator: ", "))
  --pack-version V   packVersion for the subset (default: <starter>-subset)
  --enum-name NAME   Swift enum name for --format swift (default: CuratedSources)
  --format FORMAT    swift (default) or json
  -o, --output PATH  Write here (default: stdout)
  -h, --help
"""

func runCurate(_ args: [String]) throws {
    let opts = CLIOptions.parse(args, usage: curateUsage, values: ["--ids", "--families", "--pack-version", "--enum-name", "--format"])

    let familyNames = opts.list("--families")
    let unknownFamilies = familyNames.filter { !ELVCatalogFamilies.known.contains($0) }
    guard unknownFamilies.isEmpty else {
        usageError("unknown families: \(unknownFamilies.joined(separator: ", ")). Known: \(ELVCatalogFamilies.known.joined(separator: ", "))", usage: curateUsage)
    }

    var selected = Set(opts.list("--ids"))
    selected.formUnion(ELVCatalogFamilies.ids(forFamilies: familyNames))
    guard !selected.isEmpty else {
        usageError("select at least one source via --ids or --families", usage: curateUsage)
    }

    let format = opts.string("--format") ?? "swift"
    guard format == "swift" || format == "json" else {
        usageError("--format must be swift or json", usage: curateUsage)
    }

    let subsetJSON: Data
    do {
        subsetJSON = try ELVPackSubset.subset(
            fromPackJSON: ELVStarterPack.data,
            ids: selected,
            packVersion: opts.string("--pack-version")
        )
    } catch let ELVPackSubsetError.unknownSourceIds(missing) {
        usageError("unknown source ids: \(missing.joined(separator: ", "))", usage: curateUsage)
    }

    warnAboutCapabilities(subsetJSON: subsetJSON)

    let output: String = switch format {
    case "json":
        String(bytes: subsetJSON, encoding: .utf8) ?? ""
    default:
        generatedSwift(enumName: opts.string("--enum-name") ?? "CuratedSources", json: subsetJSON)
    }

    try CLIOptions.writeOutput(Data(output.utf8), to: opts.outputPath, atomic: true)
    if let path = opts.outputPath {
        note("wrote \(selected.count) sources to \(path)")
    }
}

/// Loads the subset against the capabilities an app linking Core + Net has
/// and warns about any source that still skips — one needing `dom`
/// (EluviumDOM) or a native op another module registers (EluviumPlaces' MapKit
/// ops). Net's own ops register first (`shortlink.expand`), so a redirector
/// never warns; the URL transports and archive imports are Core + Net's, so
/// those never warn either. Reuses the loader's own skip logic rather than
/// re-deriving requirements.
private func warnAboutCapabilities(subsetJSON: Data) {
    ELVNetOps.register()
    // Derived from ELVFetchModes, not a literal list: a new transport joins
    // the assumed set here the moment the engine declares it.
    let netCaps = ELVCapabilities(
        fetchModes: ELVFetchModes.urlTransports.union([ELVFetchModes.archive]),
        binaryVersion: ELVBinary.version
    )
    let loaded: ELVLoadedPack
    do {
        loaded = try ELVPackLoader.load(embedded: subsetJSON, capabilities: netCaps)
    } catch {
        // The subset was cut from the starter pack, so this should not happen;
        // when it does, say the check was skipped instead of staying silent.
        warn("capability check skipped: the subset did not load here (\(error)); sources needing EluviumDOM or an unregistered native op were not reported.")
        return
    }
    for skipped in loaded.skipped {
        let source = loaded.pack.sources.first { $0.id == skipped.id }
        let modules = source.map { providingModules(for: $0, capabilities: netCaps) } ?? []
        let hint = modules.isEmpty ? "" : " (link \(modules.joined(separator: " and ")))"
        warn("source \"\(skipped.id)\" will be skipped unless you link the module that provides it: \(skipped.reason)\(hint).")
    }
}

/// The package modules that provide what `source` lacks under `capabilities`,
/// read off the source's own requirements (never parsed from the skip reason):
/// a `dom` step needs EluviumDOM, the `place.*` / `geo.*` ops EluviumPlaces, the
/// `shortlink.*` ops EluviumNet. An op no package module provides gets no hint.
private func providingModules(for source: ELVSource, capabilities: ELVCapabilities) -> [String] {
    var modules: [String] = []
    let needsDOM = source.fetch?.requiredModes.contains(ELVFetchModes.dom) == true || source.requires.contains("fetch:\(ELVFetchModes.dom)")
    if needsDOM, !capabilities.fetchModes.contains(ELVFetchModes.dom) {
        modules.append("EluviumDOM")
    }
    let ops = source.requires.compactMap { $0.hasPrefix("native:") ? String($0.dropFirst("native:".count)) : nil }
        + (source.resolvesVia.map { [$0] } ?? [])
    for op in ops where !ELVNativeOps.isRegistered(op) {
        let module: String? = if op.hasPrefix("place.") || op.hasPrefix("geo.") {
            "EluviumPlaces"
        } else if op.hasPrefix("shortlink.") {
            "EluviumNet"
        } else {
            nil
        }
        if let module, !modules.contains(module) { modules.append(module) }
    }
    return modules
}

private func generatedSwift(enumName: String, json: Data) -> String {
    let literal = swiftStringLiteral(String(bytes: json, encoding: .utf8) ?? "")
    return """
    // Generated by `eluvium curate`. Do not edit.
    // Compiled-in source subset: this target links only these sources, not the
    // full Eluvium catalog. Load it and merge downloaded packs over it.
    // The pack is one string literal, so the linters sit this file out (a
    // pre-commit hook passes it by path, past any config `excluded` list).
    // swiftlint:disable all
    // swiftformat:disable all
    import EluviumCore
    import Foundation

    public enum \(enumName) {
        public static let json = \(literal)

        public static let data = Data(json.utf8)

        public static func load(capabilities: ELVCapabilities = .core) throws -> ELVLoadedPack {
            try ELVPackLoader.load(embedded: data, capabilities: capabilities)
        }
    }

    // swiftlint:enable all

    """
}

/// Escapes a (single-line, compact-JSON) string into a Swift string literal.
/// Compact JSON carries no raw control characters — any newline/tab in a value
/// is already a JSON `\\n`/`\\t` escape, i.e. a literal backslash the `\\` case
/// handles — so this stays a one-line literal.
private func swiftStringLiteral(_ string: String) -> String {
    var out = "\""
    for character in string {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(character)
        }
    }
    out += "\""
    return out
}
