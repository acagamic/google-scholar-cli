import AppKit
import Darwin
import Foundation

private enum DescriptorWriteResult {
    case written
    case brokenPipe
    case failed(Int32)
}

private enum ScholarCLI {
    static func run() -> Int32 {
        Darwin.signal(SIGPIPE, SIG_IGN)

        let action: CLIAction
        do {
            action = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        } catch let failure as ScholarFailure {
            writeDiagnostic(failure.message)
            return failure.exitCode
        } catch {
            writeDiagnostic("Could not parse arguments: \(error.localizedDescription)")
            return 2
        }

        switch action {
        case .help:
            let desktopNote = """

            Runtime:
              Requires a logged-in macOS desktop session with an AppKit run loop.
            """
            return writeOutput(Data((scholarHelp + desktopNote + "\n").utf8))
        case .version:
            return writeOutput(Data("scholar \(scholarVersion)\n".utf8))
        case .doctor:
            return runDoctor()
        case let .search(options):
            return runSearch(options)
        }
    }

    private static func runSearch(_ options: SearchOptions) -> Int32 {
        let request: URLRequest
        do {
            request = URLRequest(url: try options.searchURL)
        } catch let failure as ScholarFailure {
            writeDiagnostic(failure.message)
            return failure.exitCode
        } catch {
            writeDiagnostic("Could not create the search request: \(error.localizedDescription)")
            return 2
        }
        if let failure = desktopSessionFailure(options: options) {
            writeDiagnostic(failure.message)
            return failure.exitCode
        }

        let browser = ScholarBrowser(options: options, request: request)
        var exitCode: Int32 = 3
        runUntilFinished(browser, activation: options.headed ? .accessory : .prohibited) { finish in
            browser.start { result in
                switch result {
                case let .success(rows):
                    do {
                        exitCode = writeOutput(try formatRows(rows, as: options.format), options: options)
                    } catch {
                        let failure = diagnosedFailure(
                            .outputFormatFailed,
                            options: options,
                            detail: "Could not format output: \(error.localizedDescription)"
                        )
                        writeDiagnostic(failure.message)
                        exitCode = failure.exitCode
                    }
                case let .failure(failure):
                    writeDiagnostic(failure.message)
                    exitCode = failure.exitCode
                }
                finish()
            }
        }
        return exitCode
    }

    private static func runDoctor() -> Int32 {
        if let failure = desktopSessionFailure(options: nil) {
            return writeReport(doctorSessionReport(failure))
        }
        let browser = makeDoctorBrowser()
        var exitCode: Int32 = 3
        runUntilFinished(browser, activation: .prohibited) { finish in
            startDoctor(browser) { report in
                exitCode = writeReport(report)
                finish()
            }
        }
        return exitCode
    }

    private static func writeReport(_ report: DoctorReport) -> Int32 {
        if !report.stderr.isEmpty {
            _ = write(Data(report.stderr.utf8), to: STDERR_FILENO)
        }
        guard !report.stdout.isEmpty else {
            return report.exitCode
        }
        let written = writeOutput(Data(report.stdout.utf8))
        return written == 0 ? report.exitCode : written
    }

    /// Runs the AppKit loop until `start` calls its finish callback; SIGINT and SIGTERM cancel the browser.
    private static func runUntilFinished(
        _ browser: ScholarBrowser,
        activation: NSApplication.ActivationPolicy,
        start: (_ finish: @escaping () -> Void) -> Void
    ) {
        let application = NSApplication.shared
        application.setActivationPolicy(activation)
        var completed = false

        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interruptSource.setEventHandler {
            browser.cancel(exitCode: 130)
        }
        terminateSource.setEventHandler {
            browser.cancel(exitCode: 143)
        }
        interruptSource.resume()
        terminateSource.resume()

        start {
            completed = true
            application.stop(nil)
            if let wakeEvent = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) {
                application.postEvent(wakeEvent, atStart: false)
            }
        }

        if !completed {
            application.run()
        }
        interruptSource.cancel()
        terminateSource.cancel()
    }

    private static func writeOutput(_ data: Data, options: SearchOptions? = nil) -> Int32 {
        switch write(data, to: STDOUT_FILENO) {
        case .written, .brokenPipe:
            return 0
        case let .failed(errorNumber):
            let failure = diagnosedFailure(
                .outputWriteFailed,
                options: options,
                detail: "Could not write output: \(String(cString: strerror(errorNumber)))"
            )
            writeDiagnostic(failure.message)
            return failure.exitCode
        }
    }

    private static func writeDiagnostic(_ message: String) {
        _ = write(Data((message + "\n").utf8), to: STDERR_FILENO)
    }

    private static func write(_ data: Data, to descriptor: Int32) -> DescriptorWriteResult {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return .written
            }

            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count == -1, errno == EINTR {
                    continue
                }
                if count == -1, errno == EPIPE {
                    return .brokenPipe
                }
                return .failed(errno)
            }
            return .written
        }
    }
}

exit(ScholarCLI.run())
