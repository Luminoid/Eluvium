import EluviumCore
import EluviumNet
import Foundation
import LumiKitUI

/// The one resolve → present funnel behind every screen that runs the
/// pipeline. Paste, the examples browser, the pushed record page, the
/// item browser's next-page chase, and the Catalogs seed lists had each
/// hand-rolled the same block — run, guard cancellation, switch, show
/// `FailureCopy` — and the copies had drifted (a lost URL prefix, an ad-hoc
/// no-match string). One funnel keeps the outcomes and their copy identical
/// everywhere; per-screen behavior (busy toggles, bookkeeping, ParseLog
/// verdicts) stays at the call sites.
@MainActor
enum ResolveFlow {
    /// What to resolve: a URL through recognition, a paste (the link plus
    /// the share text around it), or a pack-authored seed (browse, where
    /// recognition is skipped).
    enum Input {
        case url(URL, example: ELVExample?)
        case paste(ELVPastedInput)
        case seed(ELVSource)

        /// The host `FailureCopy.unrecognized` names.
        var host: String? {
            switch self {
            case let .url(url, _): url.host
            case let .paste(input): input.url.host
            case let .seed(source): source.seed.flatMap(URL.init(string:))?.host
            }
        }
    }

    /// Runs one resolve. Stage progress (while `showsStages`) and the shared
    /// failure copy land on `status`; a produced record reaches `onRecord`;
    /// `completion` runs last with every outcome, for per-screen busy state
    /// and bookkeeping. `messagePrefix` keeps the examples browser's
    /// URL-over-status two-line format on all three outcomes.
    ///
    /// VoiceOver hears the outcome only: stage lines update the label
    /// silently, and the record or the failure copy is announced once.
    ///
    /// Returns the task — callers store it and cancel in `deinit` (an unstored
    /// `Task` cannot be cancelled when its screen goes away). Stage lines hop to the MainActor and re-check
    /// that task's cancellation on arrival, so a cancelled resolve's queued
    /// stage can never overwrite the next resolve's status.
    static func run(
        _ input: Input,
        status: LMKStatusLabel,
        messagePrefix: String? = nil,
        showsStages: Bool = true,
        onRecord: @escaping @MainActor (ELVRecord) -> Void,
        completion: (@MainActor (ELVPipelineResult) -> Void)? = nil
    ) -> Task<Void, Never> {
        if showsStages {
            status.show(prefixed("Recognizing…", with: messagePrefix), status: .neutral)
        }
        let handle = TaskHandle()
        let statusBox = StatusBox(label: status)
        let task = Task {
            let result = await resolve(input, showsStages: showsStages, handle: handle, statusBox: statusBox, messagePrefix: messagePrefix)
            guard !Task.isCancelled else { return }
            switch result {
            case let .record(record):
                LMKStatusLabel.announce(record.displayTitle.map { "Loaded \($0)." } ?? "Loaded the \(record.kind) record.")
                onRecord(record)
            case .unrecognized:
                statusBox.label?.showOutcome(prefixed(FailureCopy.unrecognized(host: input.host), with: messagePrefix), status: .warning)
            case let .failed(failure, _):
                statusBox.label?.showOutcome(prefixed(FailureCopy.message(for: failure), with: messagePrefix), status: .error)
            }
            completion?(result)
        }
        handle.bind(task)
        return task
    }

    // MARK: - Helpers

    private static func resolve(
        _ input: Input,
        showsStages: Bool,
        handle: TaskHandle,
        statusBox: StatusBox,
        messagePrefix: String?
    ) async -> ELVPipelineResult {
        let progress: @Sendable (ELVPipelineStage) -> Void = { stage in
            // Emitted synchronously inside the awaited pipeline run, so
            // `Task.isCancelled` here is the owning task's flag.
            guard showsStages, !Task.isCancelled else { return }
            Task { @MainActor in
                guard !handle.isCancelled else { return }
                statusBox.label?.show(prefixed("\(stage.rawValue.capitalized)…", with: messagePrefix), status: .neutral)
            }
        }
        return switch input {
        case let .url(url, example):
            await ExampleStore.shared.resolve(url: url, example: example, progress: progress)
        case let .paste(input):
            await ExampleStore.shared.resolve(input: input, progress: progress)
        case let .seed(source):
            await ExampleStore.shared.resolveSeed(sourceId: source.id)
        }
    }

    private static func prefixed(_ message: String, with prefix: String?) -> String {
        guard let prefix else { return message }
        return "\(prefix)\n\(message)"
    }

    /// Carries a weak status-label reference through the sendable stage
    /// closure; the label is only ever touched back on the MainActor.
    private struct StatusBox: @unchecked Sendable {
        weak var label: LMKStatusLabel?
    }

    /// Bridges the owning task's cancellation into the sendable stage
    /// closure, which is created before the task exists.
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func bind(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return task?.isCancelled ?? false
        }
    }
}
