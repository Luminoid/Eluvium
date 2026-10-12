//
//  ELVLogTests.swift
//  EluviumCoreTests
//
//  Tests for the logging core in ELVLog.swift.
//

import Foundation
import os
import Testing
@testable import EluviumCore

@Suite("ELVLog core", .serialized)
struct ELVLogTests {
    enum SampleError: Error {
        case timeout
        case failed(String)
        case wrapped(any Error)
        case labeled(underlying: any Error)
        case pair(String, underlying: any Error)
    }

    private final class Capture: Sendable {
        private let entries = OSAllocatedUnfairLock<[ELVLogEntry]>(initialState: [])

        func append(_ entry: ELVLogEntry) {
            entries.withLock { $0.append(entry) }
        }

        var all: [ELVLogEntry] {
            entries.withLock { $0 }.filter { $0.category == ELVLogTests.category.name }
        }

        /// Appends to this capture, for passing to `withScopedConfiguration` directly.
        var handler: @Sendable (ELVLogEntry) -> Void {
            { self.append($0) }
        }
    }

    static let category = ELVLog.Category("LogCoreTests")

    /// Runs `body` with a capturing handler at `level`, scoped to this task. The process-wide
    /// configuration is never changed here: other suites log in parallel and rely on it.
    private func capturing(at level: ELVLogLevel = .info, _ body: () -> Void) -> [ELVLogEntry] {
        let capture = Capture()
        ELVLog.withScopedConfiguration(minimumLevel: level, handler: { capture.append($0) }, body)
        return capture.all
    }

    @Test
    func `levels are ordered and map to unified-logging types like os.Logger's methods`() {
        #expect(ELVLogLevel.allCases.sorted() == ELVLogLevel.allCases)
        #expect(ELVLogLevel.debug.osLogType == .debug)
        #expect(ELVLogLevel.info.osLogType == .info)
        #expect(ELVLogLevel.notice.osLogType == .default)
        #expect(ELVLogLevel.warning.osLogType == .error)
        #expect(ELVLogLevel.error.osLogType == .error)
        #expect(ELVLogLevel.fault.osLogType == .fault)
    }

    @Test
    func `the default threshold is info, and filtered lines are never built`() {
        #expect(ELVLog.minimumLevel == .info)
        var evaluated = false
        let entries = capturing {
            ELVLog.debug(Self.category, {
                evaluated = true
                return "hidden"
            }())
            ELVLog.info(Self.category, "shown")
        }
        #expect(!evaluated)
        #expect(entries.map(\.message) == ["shown"])
        #expect(entries.first?.file == "ELVLogTests.swift")
    }

    @Test
    func `the threshold clamps at error, so errors and faults always come through`() {
        let entries = capturing(at: .fault) {
            #expect(!ELVLog.isLogging(.warning))
            #expect(ELVLog.isLogging(.error))
            ELVLog.warning(Self.category, "dropped")
            ELVLog.error(Self.category, "kept")
            ELVLog.fault(Self.category, "kept too")
        }
        #expect(entries.map(\.level) == [.error, .fault])
    }

    @Test
    func `a scoped configuration leaves the process-wide settings alone`() {
        let entries = ELVLog.withScopedConfiguration(minimumLevel: .debug, handler: nil) {
            #expect(ELVLog.isLogging(.debug))
            #expect(ELVLog.minimumLevel == .info)
            return capturing(at: .warning) {
                ELVLog.notice(Self.category, "inner scope wins")
            }
        }
        #expect(entries.isEmpty)
        #expect(!ELVLog.isLogging(.debug))
    }

    @Test
    func `debug lines are written once the threshold is lowered`() {
        let entries = capturing(at: .debug) {
            ELVLog.debug(Self.category, "trace")
        }
        #expect(entries.map(\.level) == [.debug])
    }

    @Test
    func `an async scope records debug lines from its body and child tasks, leaving the process-wide settings alone`() async {
        let capture = Capture()
        await ELVLog.withScopedConfiguration(minimumLevel: .debug, handler: capture.handler) {
            #expect(ELVLog.minimumLevel == .info)
            #expect(ELVLog.handler == nil)
            await Task.yield()
            ELVLog.debug(Self.category, "after a suspension")
            async let child: Void = ELVLog.debug(Self.category, "child task")
            await child
            let unstructured = Task { ELVLog.debug(Self.category, "unstructured task") }
            await unstructured.value
        }
        #expect(capture.all.map(\.message) == ["after a suspension", "child task", "unstructured task"])
        #expect(!ELVLog.isLogging(.debug))
    }

    @Test
    func `a task outside an async scope keeps the process-wide settings while the scope is active`() async {
        let capture = Capture()
        let outsideWasLoggingDebug = await ELVLog.withScopedConfiguration(minimumLevel: .debug, handler: capture.handler) {
            // A detached task inherits no task-locals: it runs beside the scope, not in it.
            let outside = Task.detached {
                ELVLog.notice(Self.category, "outside")
                return ELVLog.isLogging(.debug)
            }
            let wasLoggingDebug = await outside.value
            ELVLog.debug(Self.category, "inside")
            return wasLoggingDebug
        }
        #expect(!outsideWasLoggingDebug)
        #expect(capture.all.map(\.message) == ["inside"])
    }

    @Test
    func `an async scope stops delivering once it returns`() async {
        let capture = Capture()
        await ELVLog.withScopedConfiguration(minimumLevel: .debug, handler: capture.handler) {
            await Task.yield()
            ELVLog.debug(Self.category, "inside")
        }
        ELVLog.debug(Self.category, "after, below the process-wide threshold")
        ELVLog.notice(Self.category, "after")
        #expect(capture.all.map(\.message) == ["inside"])
    }

    @Test
    func `private detail stays out of the public message`() {
        let entries = capturing {
            ELVLog.notice(Self.category, "Fetched page", private: "https://example.com/?token=secret")
        }
        #expect(entries.first?.message == "Fetched page")
        #expect(entries.first?.privateDetail == "https://example.com/?token=secret")
    }

    @Test
    func `an attached error adds its summary to the message and its description to the private detail`() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 60)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSUnderlyingErrorKey: underlying])
        let entries = capturing {
            ELVLog.error(Self.category, "Request failed", error: error)
        }
        #expect(entries.first?.message == "Request failed [NSURLErrorDomain -1001 <- NSPOSIXErrorDomain 60]")
        #expect(entries.first?.privateDetail?.contains("NSURLErrorDomain") == true)
    }

    @Test
    func `Swift enum errors summarize as type and case, keeping payloads private`() {
        let failed = ELVLog.describe(SampleError.failed("user text"))
        #expect(failed.summary.hasSuffix("SampleError.failed"))
        #expect(!failed.summary.contains("user text"))
        #expect(failed.detail?.contains("user text") == true)

        let timeout = ELVLog.describe(SampleError.timeout)
        #expect(timeout.summary.hasSuffix("SampleError.timeout"))
        #expect(timeout.detail == nil)

        let wrapped = ELVLog.describe(SampleError.wrapped(URLError(.timedOut)))
        #expect(wrapped.summary.hasSuffix("SampleError.wrapped <- NSURLErrorDomain -1001"))

        let labeled = ELVLog.describe(SampleError.labeled(underlying: URLError(.timedOut)))
        #expect(labeled.summary.hasSuffix("SampleError.labeled <- NSURLErrorDomain -1001"))

        let pair = ELVLog.describe(SampleError.pair("stage", underlying: URLError(.timedOut)))
        #expect(pair.summary.hasSuffix("SampleError.pair <- NSURLErrorDomain -1001"))
        #expect(!pair.summary.contains("stage"))
    }

    @Test
    func `once writes a key a single time until it is reset`() {
        let entries = capturing {
            for _ in 0 ..< 3 {
                ELVLog.once("test.flood", .error, Self.category, "Pool exhausted")
            }
            ELVLog.resetOnce("test.flood")
            ELVLog.once("test.flood", .error, Self.category, "Pool exhausted")
        }
        ELVLog.resetOnce("test.flood")
        #expect(entries.count == 2)
    }

    @Test
    func `formattedMessage prefixes the call site`() {
        let entry = ELVLogEntry(level: .info, category: "Test", message: "hello", file: "File.swift", line: 12)
        #expect(entry.formattedMessage == "[File.swift:12] hello")
        #expect(ELVLogEntry(level: .info, category: "Test", message: "hello").formattedMessage == "hello")
    }
}
