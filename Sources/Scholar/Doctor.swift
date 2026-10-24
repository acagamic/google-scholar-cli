import Foundation
import WebKit

/// The URL scheme `scholar doctor` loads its built-in page from, so the check never touches the network.
let doctorURLScheme = "scholar-doctor"

private let doctorResultTitle = "Scholar doctor check"
private let doctorPageHTML = """
<!doctype html><html><body>
  <article class="gs_r gs_or gs_scl"><div class="gs_ri">
    <h3 class="gs_rt"><a href="https://scholar.google.com/">\(doctorResultTitle)</a></h3>
    <div class="gs_a">Scholar - Built-in page, 2026 - scholar doctor</div>
  </div></article>
</body></html>
"""

struct DoctorReport {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private final class DoctorSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let data = Data(doctorPageHTML.utf8)
        urlSchemeTask.didReceive(URLResponse(
            url: urlSchemeTask.request.url!,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        ))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

func doctorConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(DoctorSchemeHandler(), forURLScheme: doctorURLScheme)
    return configuration
}

/// A browser that loads the built-in page through the same navigation and extraction path a search uses.
func makeDoctorBrowser(
    configuration: WKWebViewConfiguration = doctorConfiguration(),
    timeout: TimeInterval = 15
) -> ScholarBrowser {
    ScholarBrowser(
        options: SearchOptions(query: "scholar doctor", limit: 1, timeout: timeout),
        request: URLRequest(url: URL(string: "\(doctorURLScheme)://check/page")!),
        configuration: configuration,
        diagnosticHandler: { _ in }
    )
}

func startDoctor(
    _ browser: ScholarBrowser,
    reportsDirectory: URL = defaultCrashReportsDirectory,
    completion: @escaping (DoctorReport) -> Void
) {
    browser.start { result in
        completion(doctorReport(for: result, reportsDirectory: reportsDirectory))
    }
}

func doctorSessionReport(_ failure: ScholarFailure) -> DoctorReport {
    DoctorReport(exitCode: failure.exitCode, stdout: "", stderr: "\(failure.message)\nmacOS: \(macOSVersion)\n")
}

private func doctorReport(
    for result: Result<[ScholarRow], ScholarFailure>,
    reportsDirectory: URL
) -> DoctorReport {
    let failureDetail: String
    switch result {
    case let .success(rows) where rows.first?.title == doctorResultTitle:
        return DoctorReport(
            exitCode: 0,
            stdout: """
            Your Mac's browser engine works: Scholar loaded and read its built-in test page without contacting Google.
            If a search still fails, follow the steps printed with that error; the cause is with Google or your network.

            """,
            stderr: ""
        )
    case .success:
        failureDetail = "The built-in test page loaded, but Scholar could not read its test result."
    case let .failure(failure) where failure.exitCode == 130 || failure.exitCode == 143:
        return DoctorReport(exitCode: failure.exitCode, stdout: "", stderr: failure.message + "\n")
    case let .failure(failure):
        let lines = failure.message.components(separatedBy: "\n")
        failureDetail = lines.last { $0.hasPrefix(detailsPrefix) }.map { String($0.dropFirst(detailsPrefix.count)) } ?? lines[0]
    }

    let crashReport = newestCrashReport(in: reportsDirectory)?.path ?? "none found"
    let message = """
    This is a problem on your Mac, not with Google: Scholar's browser engine could not load and read a built-in test page.
    What to do:
    1. Quit apps you are not using, then run `scholar doctor` again.
    2. If it still fails, restart your Mac and run `scholar doctor` once more.
    3. Install any waiting macOS updates in System Settings > General > Software Update.
    4. If it keeps failing, send the macOS version and crash report lines below to the person who gave you Scholar.
    macOS: \(macOSVersion)
    Crash report: \(crashReport)
    Details: \(failureDetail)

    """
    return DoctorReport(exitCode: 3, stdout: "", stderr: message)
}

private var macOSVersion: String {
    ProcessInfo.processInfo.operatingSystemVersionString
}

let defaultCrashReportsDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DiagnosticReports")

func newestCrashReport(in directory: URL, now: Date = Date()) -> URL? {
    let prefixes = ["com.apple.WebKit", "WebContent", "scholar"]
    let oldest = now.addingTimeInterval(-7 * 86_400)
    let files = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    return files
        .filter { url in
            ["ips", "crash"].contains(url.pathExtension)
                && prefixes.contains { url.lastPathComponent.hasPrefix($0) }
        }
        .compactMap { url -> (URL, Date)? in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified >= oldest else {
                return nil
            }
            return (url, modified)
        }
        .max { $0.1 < $1.1 }?
        .0
}
