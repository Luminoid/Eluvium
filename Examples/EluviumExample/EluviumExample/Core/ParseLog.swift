import EluviumCore
import EluviumNet
import Foundation
import LumiKitCore

/// The app's own log lines: events only the UI knows about. The framework
/// logs every resolve, walk, import, and pack load itself under the
/// `dev.luminoid.eluvium` subsystem (one outcome line per run, rendered from
/// the run's trace), so nothing here repeats those. What stays:
/// - the corpus verdict when an example runs from the Examples screen or a
///   pushed record page, through the same `ELVExample.unmetExpectations`
///   check the screen's status line shows;
/// - files the picker refused before any import ran.
///
/// `LMKLogger` writes the message text publicly (user data belongs in its
/// `private:` detail), so lines carry hosts, source ids, and pack text
/// only, never a full URL: share tokens live in paths and query strings.
enum ParseLog {
    /// A corpus run's outcome against its declared expectations.
    struct Verdict: Equatable {
        var passed: Bool
        var message: String
    }

    // MARK: - Corpus verdicts

    /// The verdict line for `example`'s run, nil for a cancelled run (a
    /// user action, not a failed example).
    static func verdict(example: ELVExample, result: ELVPipelineResult, host: String?) -> Verdict? {
        let host = host ?? "-"
        switch result {
        case let .record(record):
            let unmet = example.unmetExpectations(for: record)
            if unmet.isEmpty {
                return Verdict(passed: true, message: "Example passed host=\(host) source=\(record.sourceId)")
            }
            return Verdict(passed: false, message: "Example unmet host=\(host) source=\(record.sourceId): \(unmet.joined(separator: "; "))")
        case .unrecognized:
            return Verdict(passed: false, message: "Example failed host=\(host): no source matched")
        case let .failed(failure, sourceId):
            guard failure != ELVPipeline.cancelledMarker else { return nil }
            return Verdict(passed: false, message: "Example failed host=\(host) source=\(sourceId ?? "-"): \(failure)")
        }
    }

    /// Logs `example`'s verdict: info when it passed, warning otherwise.
    static func log(example: ELVExample, result: ELVPipelineResult, url: URL) {
        guard let verdict = verdict(example: example, result: result, host: url.host) else { return }
        if verdict.passed {
            LMKLogger.info(verdict.message, category: .data)
        } else {
            LMKLogger.warning(verdict.message, category: .data)
        }
    }

    // MARK: - Picker

    /// A picked file refused before parsing (too large, unreadable): no
    /// import ran, so the framework never saw it. The file name is the
    /// user's own and stays out of the line.
    static func log(importSkipped reason: String, fileExtension: String) {
        LMKLogger.warning("Import skipped for a .\(fileExtension.isEmpty ? "?" : fileExtension) file: \(reason)", category: .data)
    }
}
