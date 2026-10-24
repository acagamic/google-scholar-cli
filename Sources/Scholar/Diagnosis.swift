import CoreGraphics
import Foundation

/// Checked before AppKit starts, because AppKit can hang without a window-server session (for example, over SSH).
func desktopSessionFailure(
    sessionAvailable: Bool = CGSessionCopyCurrentDictionary() != nil,
    options: SearchOptions?
) -> ScholarFailure? {
    sessionAvailable ? nil : diagnosedFailure(.noDesktopSession, options: options)
}

enum FailureCause: CaseIterable {
    case browserCrashed
    case noDesktopSession
    case pageNotInspectable
    case pageUnreadable
    case outputFormatFailed
    case outputWriteFailed
    case verificationRequested
    case consentRequested
    case verificationTimedOut
    case rateLimited
    case googleError
    case loadTimedOut
    case networkFailed
    case pageNotRecognised

    var exitCode: Int32 {
        switch self {
        case .browserCrashed, .noDesktopSession, .pageNotInspectable,
             .pageUnreadable, .outputFormatFailed, .outputWriteFailed:
            return 3
        case .verificationRequested, .consentRequested, .verificationTimedOut,
             .rateLimited, .googleError, .loadTimedOut, .networkFailed:
            return 4
        case .pageNotRecognised:
            return 5
        }
    }
}

private let doctorStep = "Run `scholar doctor` to check this Mac's browser engine without contacting Google."
private let minimumVerificationTimeout = 120_000
let detailsPrefix = "Details: "

func diagnosedFailure(
    _ cause: FailureCause,
    options: SearchOptions?,
    detail: String? = nil
) -> ScholarFailure {
    let (sentence, steps) = diagnosis(for: cause, options: options)
    var lines = [sentence, "What to do:"]
    for (index, step) in steps.enumerated() {
        lines.append("\(index + 1). \(step)")
    }
    if let detail, !detail.isEmpty {
        lines.append(detailsPrefix + detail)
    }
    return ScholarFailure(message: lines.joined(separator: "\n"), exitCode: cause.exitCode)
}

func manualCheckProgress(_ cause: FailureCause) -> String {
    "\(manualCheckSentence(cause)) Finish it in the Scholar Search window before the time limit; the results appear when you are done."
}

private func manualCheckSentence(_ cause: FailureCause) -> String {
    cause == .consentRequested
        ? "Google Scholar wants you to accept its consent terms."
        : "Google Scholar wants to check that a person is searching."
}

func scholarCommand(
    for options: SearchOptions,
    format: OutputFormat? = nil,
    headed: Bool? = nil,
    timeoutMilliseconds: Int? = nil
) -> String {
    let defaults = SearchOptions(query: options.query)
    var parts = ["scholar", "search"]
    if options.limit != defaults.limit {
        parts += ["--limit", String(options.limit)]
    }
    if options.lang != defaults.lang {
        parts += ["--lang", options.lang]
    }
    let format = format ?? options.format
    if format != defaults.format {
        parts += ["--format", format.rawValue]
    }
    if headed ?? options.headed {
        parts.append("--headed")
    }
    let timeout = timeoutMilliseconds ?? milliseconds(options.timeout)
    if timeout != milliseconds(defaults.timeout) {
        parts += ["--timeout", String(timeout)]
    }
    parts += ["--", shellQuoted(options.query)]
    return parts.joined(separator: " ")
}

private func milliseconds(_ seconds: TimeInterval) -> Int {
    Int((seconds * 1_000).rounded())
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func step(_ text: String, command: String?) -> String {
    guard let command else {
        return text
    }
    return "\(text)\n   \(command)"
}

private func diagnosis(for cause: FailureCause, options: SearchOptions?) -> (String, [String]) {
    let again = options.map { scholarCommand(for: $0) }
    let ownTimeout = options.map { milliseconds($0.timeout) } ?? 0

    switch cause {
    case .browserCrashed:
        return (
            "This is a problem on your Mac, not with Google: the browser engine Scholar uses stopped while loading the page.",
            [
                step("Quit apps you are not using, then run the same search again:", command: again),
                "If it stops again, restart your Mac and try once more.",
                "Install any waiting macOS updates in System Settings > General > Software Update.",
                doctorStep,
            ]
        )
    case .noDesktopSession:
        return (
            "This is a problem on your Mac, not with Google: Scholar needs someone logged in at this Mac's desktop, and no desktop session is available.",
            [
                "Log in at the Mac itself, or through Screen Sharing; a remote shell such as SSH is not enough.",
                step("Open Terminal in that desktop session and run the same command again:", command: again),
                doctorStep,
            ]
        )
    case .pageNotInspectable:
        return (
            "Scholar could not tell whether this is a problem on your Mac or with Google: it could not look inside the page that loaded.",
            [
                step("Run the same search again:", command: again),
                "If it fails again, send the details line below to the person who gave you Scholar.",
                doctorStep,
            ]
        )
    case .pageUnreadable:
        return (
            "This is a problem with the page Google returned, not your Mac: Scholar could not read the results on it.",
            [
                step("Wait a few minutes, then run the same search again:", command: again),
                "If it keeps failing, Google may have changed its page. Send the details line below to the person who gave you Scholar.",
            ]
        )
    case .outputFormatFailed:
        return (
            "This is a problem on your Mac, not with Google: Scholar found results but could not turn them into the output you asked for.",
            [
                step(
                    "Run the same search with the default table output:",
                    command: options.map { scholarCommand(for: $0, format: .table) }
                ),
                doctorStep,
            ]
        )
    case .outputWriteFailed:
        return (
            "This is a problem on your Mac, not with Google: Scholar could not write its output.",
            [
                "If you sent the output to a file, check that the disk has free space and that you can save in that folder.",
                step("Run the same command again:", command: again),
                doctorStep,
            ]
        )
    case .verificationRequested, .consentRequested:
        let visible = options.map {
            scholarCommand(for: $0, headed: true, timeoutMilliseconds: max(minimumVerificationTimeout, ownTimeout))
        }
        return (
            "This is on Google's side, not your Mac: \(manualCheckSentence(cause))",
            [
                step("Run the search again with a visible window:", command: visible),
                "Finish Google's check in the window that opens. Scholar reads the results as soon as they appear.",
                "If Google still blocks the search, wait before searching again. Scholar does not retry for you.",
            ]
        )
    case .verificationTimedOut:
        let longer = options.map {
            scholarCommand(for: $0, headed: true, timeoutMilliseconds: max(minimumVerificationTimeout, ownTimeout * 2))
        }
        return (
            "This is on Google's side, not your Mac: Google's check was not finished before the time limit.",
            [
                step("Run the search again with more time:", command: longer),
                "Finish the check in the Scholar Search window as soon as it opens.",
                "If Google keeps asking, wait before searching again. Scholar does not retry for you.",
            ]
        )
    case .rateLimited:
        return (
            "This is on Google's side, not your Mac: Google Scholar is limiting searches from your network right now.",
            [
                "Wait an hour or more before searching again. Scholar does not retry for you.",
                step("Then run the same search once:", command: again),
                "If you use a VPN, turn it off for that search.",
            ]
        )
    case .googleError:
        return (
            "This is on Google's side, not your Mac: Google Scholar returned an error page.",
            [
                step("Wait a few minutes, then run the same search again:", command: again),
                "Check that https://scholar.google.com opens in your web browser.",
            ]
        )
    case .loadTimedOut:
        let longer = options.map {
            scholarCommand(for: $0, timeoutMilliseconds: max(60_000, ownTimeout * 2))
        }
        return (
            "This is a problem with Google or your network, not your Mac: Google Scholar did not finish loading before the time limit.",
            [
                "Check that your internet connection works and that https://scholar.google.com opens in your web browser.",
                step("Run the search again with more time:", command: longer),
            ]
        )
    case .networkFailed:
        return (
            "This is a network problem, not your Mac's browser engine: Scholar could not reach Google Scholar.",
            [
                "Check that your internet connection works and that https://scholar.google.com opens in your web browser.",
                "If you use a VPN or proxy, try without it.",
                step("Run the same search again:", command: again),
            ]
        )
    case .pageNotRecognised:
        return (
            "This is a problem with the page Google returned, not your Mac: Scholar did not recognise it as search results before the time limit.",
            [
                step(
                    "Run the search again with a visible window to see the page:",
                    command: options.map { scholarCommand(for: $0, headed: true) }
                ),
                "If the window shows normal results, Google may have changed its page. Tell the person who gave you Scholar.",
            ]
        )
    }
}
