import AppKit
import Darwin
import Foundation
import WebKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum SchemeReply {
    case html(String)
    case http(String, Int)
    case failure
    case unfinished
}

private final class FixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    let reply: (URL) -> SchemeReply

    init(reply: SchemeReply) {
        self.reply = { _ in reply }
    }

    init(reply: @escaping (URL) -> SchemeReply) {
        self.reply = reply
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        switch reply(url) {
        case let .html(html):
            let data = Data(html.utf8)
            let response = URLResponse(
                url: urlSchemeTask.request.url!,
                mimeType: "text/html",
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        case let .http(html, statusCode):
            let data = Data(html.utf8)
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        case .failure:
            urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
        case .unfinished:
            break
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class OneRequestHTTPServer {
    let url: URL
    private let listeningDescriptor: Int32

    init(statusCode: Int, reason: String, body: String) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TestFailure(description: "Could not create local HTTP socket")
        }
        listeningDescriptor = descriptor

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw TestFailure(description: "Could not bind local HTTP socket")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw TestFailure(description: "Could not read local HTTP port")
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        url = URL(string: "http://127.0.0.1:\(port)/fixture")!

        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let response = Data(headers.utf8) + bodyData
        DispatchQueue.global(qos: .userInitiated).async {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                return
            }
            var requestBuffer = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(client, &requestBuffer, requestBuffer.count)
            response.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    _ = Darwin.write(client, baseAddress, bytes.count)
                }
            }
            Darwin.close(client)
            Darwin.close(descriptor)
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) throws {
    guard condition() else {
        throw TestFailure(description: message())
    }
}

private func requireEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ context: String = ""
) throws {
    let actualValue = actual()
    let expectedValue = expected()
    guard actualValue == expectedValue else {
        let prefix = context.isEmpty ? "" : "\(context): "
        throw TestFailure(
            description: "\(prefix)expected \(expectedValue), received \(actualValue)"
        )
    }
}

private func fixtureHTML(_ name: String) throws -> String {
    let path = FileManager.default.currentDirectoryPath + "/test/fixtures/\(name)"
    return try String(contentsOfFile: path, encoding: .utf8)
}

private func fixtureConfiguration(_ reply: SchemeReply) -> WKWebViewConfiguration {
    fixtureConfiguration { _ in reply }
}

private func fixtureConfiguration(
    _ reply: @escaping (URL) -> SchemeReply
) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(
        FixtureSchemeHandler(reply: reply),
        forURLScheme: "scholar-test"
    )
    return configuration
}

private func ownedResourcesRemain() -> Bool {
    NSApplication.shared.windows.contains {
        $0.title == "Scholar Search" && ($0.isVisible || $0.contentView is WKWebView)
    }
}

private func runBrowser(
    reply: SchemeReply,
    limit: Int = 10,
    timeout: TimeInterval = 2,
    headed: Bool = false,
    action: ((ScholarBrowser) -> Void)? = nil,
    diagnostics: ((String) -> Void)? = nil
) throws -> Result<[ScholarRow], ScholarFailure> {
    let options = SearchOptions(
        query: "fixture",
        limit: limit,
        timeout: timeout,
        headed: headed
    )
    let request = URLRequest(url: URL(string: "scholar-test://fixture/page")!)
    let browser = ScholarBrowser(
        options: options,
        request: request,
        configuration: fixtureConfiguration(reply),
        diagnosticHandler: diagnostics ?? { _ in }
    )
    var result: Result<[ScholarRow], ScholarFailure>?
    browser.start { result = $0 }
    action?(browser)

    let outerDeadline = Date().addingTimeInterval(timeout + 2)
    while result == nil, Date() < outerDeadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let result else {
        throw TestFailure(description: "Browser completion exceeded its deadline")
    }

    let cleanupDeadline = Date().addingTimeInterval(1)
    while ownedResourcesRemain(), Date() < cleanupDeadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(!ownedResourcesRemain(), "Owned WebKit view or visible window remained after completion")
    return result
}

/// Runs a hidden search against a one-request local server that answers with a real HTTP status.
private func runServer(statusCode: Int, reason: String, body: String) throws -> Result<[ScholarRow], ScholarFailure> {
    let server = try OneRequestHTTPServer(statusCode: statusCode, reason: reason, body: body)
    let browser = ScholarBrowser(
        options: SearchOptions(query: "fixture", timeout: 2),
        request: URLRequest(url: server.url),
        diagnosticHandler: { _ in }
    )
    var result: Result<[ScholarRow], ScholarFailure>?
    browser.start { result = $0 }
    let deadline = Date().addingTimeInterval(3)
    while result == nil, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let result else {
        throw TestFailure(description: "HTTP status test did not complete")
    }
    return result
}

private func runDoctorForTest(_ browser: ScholarBrowser) throws -> DoctorReport {
    var report: DoctorReport?
    startDoctor(browser) { report = $0 }
    let deadline = Date().addingTimeInterval(20)
    while report == nil, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard let report else {
        throw TestFailure(description: "Doctor did not finish")
    }
    return report
}

private func requireRows(
    _ result: Result<[ScholarRow], ScholarFailure>,
    count: Int
) throws -> [ScholarRow] {
    switch result {
    case let .success(rows):
        try requireEqual(rows.count, count)
        return rows
    case let .failure(failure):
        throw TestFailure(description: "Expected rows, received \(failure.message)")
    }
}

private func requireFailure(
    _ result: Result<[ScholarRow], ScholarFailure>,
    exitCode: Int32,
    containing text: String? = nil
) throws {
    switch result {
    case .success:
        throw TestFailure(description: "Expected exit \(exitCode), received success")
    case let .failure(failure):
        try requireEqual(failure.exitCode, exitCode)
        if let text {
            try require(
                failure.message.localizedCaseInsensitiveContains(text),
                "Failure did not contain '\(text)': \(failure.message)"
            )
        }
    }
}

@main
private enum BrowserTestRunner {
    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        let tests: [(String, () throws -> Void)] = [
            ("results respect limit", {
                let result = try runBrowser(
                    reply: .html(try fixtureHTML("results.html")),
                    limit: 3
                )
                let rows = try requireRows(result, count: 3)
                try requireEqual(rows.map(\.title), ["Result 1", "Result 2", "Result 3"])
            }),
            ("explicit empty succeeds", {
                let result = try runBrowser(reply: .html(try fixtureHTML("empty-en.html")))
                _ = try requireRows(result, count: 0)
            }),
            ("hidden challenge fails with recovery", {
                let result = try runBrowser(reply: .html(try fixtureHTML("challenge.html")))
                try requireFailure(result, exitCode: 4, containing: "--headed")
                try requireFailure(result, exitCode: 4, containing: "This is on Google's side, not your Mac")
                try requireFailure(result, exitCode: 4, containing: "scholar search --headed --timeout 120000 -- 'fixture'")
                if case let .failure(failure) = result {
                    try require(failure.message.contains("120000"), "Recovery must suggest a longer timeout")
                }
            }),
            ("hidden consent fails with recovery", {
                let result = try runBrowser(reply: .html(try fixtureHTML("consent.html")))
                try requireFailure(result, exitCode: 4, containing: "--headed")
            }),
            ("headed challenge can change to results", {
                let resultHTML = try fixtureHTML("results.html")
                let escaped = resultHTML
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                let html = """
                <!doctype html><html><body>
                  <form id="captcha-form"><div class="g-recaptcha"></div></form>
                  <script>setTimeout(() => { document.open(); document.write(`\(escaped)`); document.close(); }, 150);</script>
                </body></html>
                """
                var diagnostics: [String] = []
                let result = try runBrowser(
                    reply: .html(html),
                    limit: 2,
                    timeout: 3,
                    headed: true,
                    diagnostics: { diagnostics.append($0) }
                )
                _ = try requireRows(result, count: 2)
                try requireEqual(diagnostics.count, 1)
                try require(
                    diagnostics[0].contains("Finish it in the Scholar Search window"),
                    "Progress line must use plain language: \(diagnostics[0])"
                )
            }),
            ("headed rate-limit challenge can change to results", {
                let resultHTML = try fixtureHTML("results.html")
                let escaped = resultHTML
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                let html = """
                <!doctype html><html><body>
                  <form id="captcha-form"><div class="g-recaptcha"></div></form>
                  <script>setTimeout(() => { document.open(); document.write(`\(escaped)`); document.close(); }, 150);</script>
                </body></html>
                """
                let server = try OneRequestHTTPServer(
                    statusCode: 429,
                    reason: "Too Many Requests",
                    body: html
                )
                let options = SearchOptions(
                    query: "fixture",
                    limit: 1,
                    timeout: 3,
                    headed: true
                )
                let browser = ScholarBrowser(
                    options: options,
                    request: URLRequest(url: server.url),
                    diagnosticHandler: { _ in }
                )
                var browserResult: Result<[ScholarRow], ScholarFailure>?
                browser.start { browserResult = $0 }
                let deadline = Date().addingTimeInterval(4)
                while browserResult == nil, Date() < deadline {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                guard let result = browserResult else {
                    throw TestFailure(description: "Rate-limit challenge did not complete")
                }
                _ = try requireRows(result, count: 1)
            }),
            ("other main-frame HTTP error fails", {
                let result = try runServer(statusCode: 503, reason: "Service Unavailable", body: "service unavailable")
                try requireFailure(result, exitCode: 4, containing: "Details: Google Scholar returned HTTP 503.")
                try requireFailure(result, exitCode: 4, containing: "returned an error page")
            }),
            ("rate limit on an ordinary page names the limit", {
                let result = try runServer(statusCode: 429, reason: "Too Many Requests", body: try fixtureHTML("unknown.html"))
                try requireFailure(result, exitCode: 4, containing: "limiting searches")
                try requireFailure(result, exitCode: 4, containing: "Details: Google Scholar returned HTTP 429.")
            }),
            ("rate limit on a challenge page asks for verification", {
                let result = try runServer(statusCode: 429, reason: "Too Many Requests", body: try fixtureHTML("challenge.html"))
                try requireFailure(result, exitCode: 4, containing: "check that a person is searching")
            }),
            ("browser engine crash points to doctor", {
                let result = try runBrowser(reply: .unfinished, timeout: 2, action: { browser in
                    browser.webViewWebContentProcessDidTerminate(WKWebView())
                })
                try requireFailure(result, exitCode: 3, containing: "This is a problem on your Mac, not with Google")
                try requireFailure(result, exitCode: 3, containing: "scholar doctor")
            }),
            ("unknown page expires as unreadable", {
                let result = try runBrowser(
                    reply: .html(try fixtureHTML("unknown.html")),
                    timeout: 0.2
                )
                try requireFailure(result, exitCode: 5, containing: "did not recognise it as search results")
            }),
            ("unfinished load expires as service failure", {
                let result = try runBrowser(reply: .unfinished, timeout: 0.2)
                try requireFailure(result, exitCode: 4, containing: "did not finish loading before the time limit")
            }),
            ("network failure uses service exit", {
                let result = try runBrowser(reply: .failure)
                try requireFailure(result, exitCode: 4, containing: "This is a network problem")
            }),
            ("subframe rate limit does not fail results", {
                let html = """
                <!doctype html><html><body>
                  <iframe src="scholar-test://fixture/frame"></iframe>
                  <article class="gs_r gs_or gs_scl"><div class="gs_ri">
                    <h3 class="gs_rt"><a href="https://papers.example/main">Main result</a></h3>
                  </div></article>
                </body></html>
                """
                let options = SearchOptions(query: "fixture", timeout: 2)
                let request = URLRequest(url: URL(string: "scholar-test://fixture/page")!)
                let configuration = fixtureConfiguration { url in
                    if url.path == "/frame" {
                        return .http("rate limited frame", 429)
                    }
                    return .html(html)
                }
                let browser = ScholarBrowser(
                    options: options,
                    request: request,
                    configuration: configuration,
                    diagnosticHandler: { _ in }
                )
                var result: Result<[ScholarRow], ScholarFailure>?
                browser.start { result = $0 }
                let deadline = Date().addingTimeInterval(3)
                while result == nil, Date() < deadline {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                guard let result else {
                    throw TestFailure(description: "Subframe test did not complete")
                }
                _ = try requireRows(result, count: 1)
            }),
            ("cancellation returns 130 and cleans up", {
                let result = try runBrowser(reply: .unfinished, action: { browser in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        browser.cancel()
                    }
                })
                try requireFailure(result, exitCode: 130, containing: "Interrupted")
            }),
            ("termination returns 143 and cleans up", {
                let result = try runBrowser(reply: .unfinished, action: { browser in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        browser.cancel(exitCode: 143)
                    }
                })
                try requireFailure(result, exitCode: 143, containing: "signal")
            }),
            ("cancellation before start avoids browser creation", {
                let options = SearchOptions(query: "fixture")
                let request = URLRequest(url: URL(string: "scholar-test://fixture/page")!)
                let browser = ScholarBrowser(
                    options: options,
                    request: request,
                    configuration: fixtureConfiguration(.unfinished),
                    diagnosticHandler: { _ in }
                )
                var result: Result<[ScholarRow], ScholarFailure>?
                browser.cancel()
                browser.start { result = $0 }
                guard let result else {
                    throw TestFailure(description: "Pre-start cancellation did not complete")
                }
                try requireFailure(result, exitCode: 130, containing: "Interrupted")
                try require(!ownedResourcesRemain(), "Pre-start cancellation created browser resources")
            }),
            ("invalid timeout fails before browser creation", {
                let options = SearchOptions(query: "fixture", timeout: -1)
                let request = URLRequest(url: URL(string: "scholar-test://fixture/page")!)
                let browser = ScholarBrowser(
                    options: options,
                    request: request,
                    configuration: fixtureConfiguration(.unfinished),
                    diagnosticHandler: { _ in }
                )
                var result: Result<[ScholarRow], ScholarFailure>?
                browser.start { result = $0 }
                guard let result else {
                    throw TestFailure(description: "Invalid timeout did not complete")
                }
                try requireFailure(result, exitCode: 2, containing: "Timeout")
                try require(!ownedResourcesRemain(), "Invalid options created browser resources")
            }),
            ("closing owned window returns 130", {
                let result = try runBrowser(
                    reply: .unfinished,
                    headed: true,
                    action: { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            NSApplication.shared.windows.first {
                                $0.title == "Scholar Search" && $0.isVisible
                            }?.performClose(nil)
                        }
                    }
                )
                try requireFailure(result, exitCode: 130, containing: "closed")
            }),
            ("completion wakes the AppKit run loop", {
                let options = SearchOptions(query: "fixture", timeout: 2)
                let request = URLRequest(url: URL(string: "scholar-test://fixture/page")!)
                let browser = ScholarBrowser(
                    options: options,
                    request: request,
                    configuration: fixtureConfiguration(.html(try fixtureHTML("empty-en.html"))),
                    diagnosticHandler: { _ in }
                )
                let application = NSApplication.shared
                var result: Result<[ScholarRow], ScholarFailure>?
                browser.start {
                    result = $0
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
                if result == nil {
                    application.run()
                }
                guard let result else {
                    throw TestFailure(description: "NSApplication.run did not return after completion")
                }
                _ = try requireRows(result, count: 0)
            }),
            ("doctor passes on the built-in page", {
                let report = try runDoctorForTest(makeDoctorBrowser())
                try requireEqual(report.exitCode, 0)
                try require(report.stdout.contains("browser engine works"), "Pass must be plain: \(report.stdout)")
                try require(!report.stdout.contains("Google or your network"), "Pass must not blame a side doctor never checked")
                try requireEqual(report.stderr, "")
            }),
            ("doctor fails plainly when the page cannot be read", {
                let configuration = WKWebViewConfiguration()
                configuration.setURLSchemeHandler(
                    FixtureSchemeHandler(reply: .html(try fixtureHTML("unknown.html"))),
                    forURLScheme: doctorURLScheme
                )
                let browser = makeDoctorBrowser(configuration: configuration, timeout: 0.3)
                let report = try runDoctorForTest(browser)
                try requireEqual(report.exitCode, 3)
                try requireEqual(report.stdout, "")
                try require(report.stderr.hasPrefix("This is a problem on your Mac, not with Google"), report.stderr)
                try require(report.stderr.contains("macOS: "), "Fail must print the macOS version")
                try require(report.stderr.contains("Crash report: "), "Fail must print the crash report line")
                try require(!report.stderr.contains("not your Mac"), "Fail details must not contradict the Mac verdict: \(report.stderr)")
            }),
            ("doctor picks the newest recent WebKit crash report", {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("doctor-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                try requireEqual(newestCrashReport(in: directory), nil)

                let now = Date()
                let files: [(String, TimeInterval)] = [
                    ("com.apple.WebKit.WebContent-2026-10-20.ips", -3 * 86_400),
                    ("com.apple.WebKit.WebContent-2026-10-22.ips", -86_400),
                    ("ExcUserFault_textunderstandingd-2026-10-23.ips", -60),
                    ("scholar-2026-10-01.crash", -20 * 86_400),
                ]
                for (name, age) in files {
                    let url = directory.appendingPathComponent(name)
                    try Data().write(to: url)
                    try FileManager.default.setAttributes(
                        [.modificationDate: now.addingTimeInterval(age)],
                        ofItemAtPath: url.path
                    )
                }
                try requireEqual(
                    newestCrashReport(in: directory, now: now)?.lastPathComponent,
                    "com.apple.WebKit.WebContent-2026-10-22.ips"
                )
            }),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                failures += 1
                fputs("FAIL \(name): \(error)\n", stderr)
            }
        }

        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(1)
        }
    }
}
