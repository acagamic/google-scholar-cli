import AppKit
import Foundation
import WebKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        finished = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        finished = true
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

private func waitFor(
    timeout: TimeInterval,
    condition: () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(condition(), "WebKit operation exceeded \(timeout) seconds")
}

private func fixtureHTML(_ name: String) throws -> String {
    let path = FileManager.default.currentDirectoryPath
        + "/test/fixtures/\(name)"
    return try String(contentsOfFile: path, encoding: .utf8)
}

private func extract(
    html: String,
    limit: Int = 10,
    url: URL = URL(string: "https://scholar.google.com/scholar")!
) throws -> PageSnapshot {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    let waiter = NavigationWaiter()
    webView.navigationDelegate = waiter
    webView.loadHTMLString(html, baseURL: url)

    try waitFor(timeout: 5) { waiter.finished }
    if let error = waiter.error {
        throw error
    }

    var result: Any?
    var evaluationError: Error?
    var evaluated = false
    webView.evaluateJavaScript(scholarExtractionScript(limit: limit)) { value, error in
        result = value
        evaluationError = error
        evaluated = true
    }
    try waitFor(timeout: 5) { evaluated }
    if let evaluationError {
        throw evaluationError
    }
    guard let json = result as? String, let data = json.data(using: .utf8) else {
        throw TestFailure(description: "Extraction did not return a JSON string")
    }
    return try JSONDecoder().decode(PageSnapshot.self, from: data)
}

private func extractFixture(
    _ name: String,
    limit: Int = 10,
    url: URL = URL(string: "https://scholar.google.com/scholar")!
) throws -> PageSnapshot {
    try extract(html: fixtureHTML(name), limit: limit, url: url)
}

private func expectArgumentFailure(_ arguments: [String]) throws {
    do {
        _ = try parseArguments(arguments)
        throw TestFailure(description: "Expected argument failure for \(arguments)")
    } catch let failure as ScholarFailure {
        try requireEqual(failure.exitCode, 2)
        try require(!failure.message.isEmpty, "Argument failure must include a message")
    }
}

private let sampleRow = ScholarRow(
    rank: 1,
    title: "A \"quoted\", Unicode paper é",
    authors: "Ada\nExample",
    source: "Journal, Series A",
    year: "2024",
    cited: "1,234",
    url: "https://papers.example/item?a=1&b=2"
)

@main
private enum CoreTestRunner {
    static func main() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)

        let tests: [(String, () throws -> Void)] = [
            ("extract limit 1", {
                let snapshot = try extractFixture("results.html", limit: 1)
                try requireEqual(snapshot.state, "results")
                try requireEqual(snapshot.resultCount, 20)
                try requireEqual(snapshot.items.map(\.rank), [1])
                try requireEqual(snapshot.items.last?.title, "Result 1")
            }),
            ("extract limit 10", {
                let snapshot = try extractFixture("results.html", limit: 10)
                try requireEqual(snapshot.items.count, 10)
                try requireEqual(snapshot.items.map(\.rank), Array(1...10))
                try requireEqual(snapshot.items.last?.title, "Result 10")
            }),
            ("extract limit 20", {
                let snapshot = try extractFixture("results.html", limit: 20)
                try requireEqual(snapshot.items.count, 20)
                try requireEqual(snapshot.items.map(\.rank), Array(1...20))
                try requireEqual(snapshot.items.last?.title, "Result 20")
            }),
            ("extract mixed records", {
                let snapshot = try extractFixture("mixed-results.html", limit: 20)
                try requireEqual(snapshot.state, "results")
                try requireEqual(snapshot.resultCount, 6)
                try requireEqual(snapshot.items.count, 4)
                try requireEqual(snapshot.items.map(\.rank), [1, 2, 3, 4])
                try requireEqual(snapshot.items[0], ScholarRow(
                    rank: 1,
                    title: "Comma source paper",
                    authors: "Ada Example, Bo Researcher",
                    source: "Journal of Tests, Series A, Volume 7",
                    year: "2024",
                    cited: "1234",
                    url: "https://papers.example/commas"
                ))
                try requireEqual(snapshot.items[1], ScholarRow(
                    rank: 2,
                    title: "Unlinked conference note",
                    authors: "Chen Wei",
                    source: "Proceedings 2021",
                    year: "2023",
                    cited: "0",
                    url: ""
                ))
                try requireEqual(snapshot.items[2], ScholarRow(
                    rank: 3,
                    title: "Metadata-free book",
                    authors: "",
                    source: "",
                    year: "",
                    cited: "0",
                    url: ""
                ))
                try requireEqual(snapshot.items[3].url, "https://scholar.google.com/relative-paper")
            }),
            ("extract explicit empty English", {
                let snapshot = try extractFixture("empty-en.html")
                try requireEqual(snapshot.state, "empty")
                try requireEqual(snapshot.items, [])
                try requireEqual(snapshot.resultCount, 0)
            }),
            ("extract explicit empty Chinese", {
                let snapshot = try extractFixture("empty-zh-CN.html")
                try requireEqual(snapshot.state, "empty")
                try requireEqual(snapshot.items, [])
                try requireEqual(snapshot.resultCount, 0)
            }),
            ("extract challenge evidence", {
                let byURL = try extractFixture(
                    "unknown.html",
                    url: URL(string: "https://scholar.google.com/sorry/index?continue=scholar")!
                )
                try requireEqual(byURL.state, "challenge")
                let bySelector = try extractFixture("challenge-selector.html")
                let byText = try extractFixture("challenge.html")
                try requireEqual(bySelector.state, "challenge")
                try requireEqual(byText.state, "challenge")
            }),
            ("extract consent evidence", {
                let byHost = try extractFixture(
                    "unknown.html",
                    url: URL(string: "https://consent.google.com/m")!
                )
                try requireEqual(byHost.state, "consent")
                let byForm = try extractFixture("consent.html")
                try requireEqual(byForm.state, "consent")
            }),
            ("extract unknown and malformed pages", {
                let unknown = try extractFixture("unknown.html")
                try requireEqual(unknown.state, "unknown")
                try requireEqual(unknown.resultCount, 0)
                let malformed = try extractFixture("malformed-cards.html")
                try requireEqual(malformed.state, "unknown")
                try requireEqual(malformed.resultCount, 2)
            }),
            ("malformed card text is not empty evidence", {
                let html = """
                <main id="gs_res_ccl_mid">
                  <article class="gs_r gs_or gs_scl">did not match any articles</article>
                </main>
                """
                let snapshot = try extract(html: html)
                try requireEqual(snapshot.state, "unknown")
            }),
            ("challenge text cannot override valid cards", {
                let html = """
                <p>Our systems have detected unusual traffic from your computer network.</p>
                <article class="gs_r gs_or gs_scl"><div class="gs_ri">
                  <h3 class="gs_rt"><a href="https://papers.example/valid">Valid result</a></h3>
                </div></article>
                """
                let snapshot = try extract(html: html)
                try requireEqual(snapshot.state, "results")
                try requireEqual(snapshot.items.first?.title, "Valid result")
            }),
            ("metadata truncation preserves Unicode scalars", {
                let authors = String(repeating: "A", count: 79) + "🧠"
                let source = String(repeating: "B", count: 59) + "🧪"
                let html = """
                <article class="gs_r gs_or gs_scl"><div class="gs_ri">
                  <h3 class="gs_rt"><a href="https://papers.example/unicode">Unicode boundaries</a></h3>
                  <div class="gs_a">\(authors) overflow - \(source), 2024</div>
                </div></article>
                """
                let snapshot = try extract(html: html)
                try requireEqual(snapshot.state, "results")
                try requireEqual(snapshot.items.first?.authors, authors)
                try requireEqual(snapshot.items.first?.source, source)
                try requireEqual(snapshot.items.first?.year, "2024")
            }),
            ("search URL encodes Unicode query", {
                let options = SearchOptions(query: "café neural networks", limit: 20, lang: "fr-CA")
                let components = try requireURLComponents(try options.searchURL)
                let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
                try requireEqual(components.scheme, "https")
                try requireEqual(components.host, "scholar.google.com")
                try requireEqual(components.path, "/scholar")
                try requireEqual(values, ["q": "café neural networks", "num": "20", "hl": "fr-CA"])
            }),
            ("search URL percent-encodes literal plus", {
                let url = try SearchOptions(query: "C++ language").searchURL
                try require(
                    url.absoluteString.contains("q=C%2B%2B%20language"),
                    "Literal plus signs must be encoded as %2B: \(url.absoluteString)"
                )
            }),
            ("parse default search", {
                guard case let .search(options) = try parseArguments(["search", "graph theory"]) else {
                    throw TestFailure(description: "Expected a search action")
                }
                try requireEqual(options.query, "graph theory")
                try requireEqual(options.limit, 10)
                try requireEqual(options.format, .table)
                try requireEqual(options.lang, "en")
                try requireEqual(options.timeout, 30)
                try requireEqual(options.headed, false)
            }),
            ("parse flags around query", {
                guard case let .search(options) = try parseArguments([
                    "search", "--limit", "7", "--lang=de", "signal processing",
                    "-f", "csv", "--timeout", "1250", "--headed",
                ]) else {
                    throw TestFailure(description: "Expected a search action")
                }
                try requireEqual(options.limit, 7)
                try requireEqual(options.lang, "de")
                try requireEqual(options.format, .csv)
                try requireEqual(options.timeout, 1.25)
                try requireEqual(options.headed, true)
            }),
            ("parse JSON shortcut and terminator", {
                guard case let .search(options) = try parseArguments([
                    "search", "--json", "--", "--literal query",
                ]) else {
                    throw TestFailure(description: "Expected a search action")
                }
                try requireEqual(options.query, "--literal query")
                try requireEqual(options.format, .json)
            }),
            ("parse help and version", {
                guard case .help = try parseArguments(["--help"]) else {
                    throw TestFailure(description: "Expected help")
                }
                guard case .version = try parseArguments(["-V"]) else {
                    throw TestFailure(description: "Expected version")
                }
                try requireEqual(scholarVersion, "0.1.0")
                try require(scholarHelp.contains("ephemeral"), "Help must explain the session")
                try require(scholarHelp.contains("--headed"), "Help must document headed mode")
                try require(scholarHelp.contains("Exit codes"), "Help must document exit codes")
                try require(scholarHelp.contains("No browser setup"), "Help must explain setup")
            }),
            ("reject invalid arguments", {
                let invalid: [[String]] = [
                    [], ["other"], ["search"], ["search", "   "],
                    ["search", "query", "extra"], ["search", "--unknown", "query"],
                    ["search", "--limit", "0", "query"],
                    ["search", "--limit=21", "query"],
                    ["search", "--limit", "1.5", "query"],
                    ["search", "--format", "xml", "query"],
                    ["search", "--timeout", "0", "query"],
                    ["search", "--timeout", "2147483648", "query"],
                    ["search", "--timeout", "2.5", "query"],
                    ["search", "--lang", "bad_lang", "query"],
                    ["search", "--json", "--format", "csv", "query"],
                ]
                for arguments in invalid {
                    try expectArgumentFailure(arguments)
                }
            }),
            ("validate direct search options", {
                let invalid = [
                    SearchOptions(query: ""),
                    SearchOptions(query: "query", limit: 0),
                    SearchOptions(query: "query", lang: "bad_lang"),
                    SearchOptions(query: "query", timeout: 0),
                ]
                for options in invalid {
                    do {
                        _ = try options.searchURL
                        throw TestFailure(description: "Expected search URL validation failure")
                    } catch is ScholarFailure {
                        continue
                    }
                }
            }),
            ("format JSON losslessly", {
                let emptyData = try formatRows([], as: .json)
                try requireEqual(String(data: emptyData, encoding: .utf8), "[]\n")
                let data = try formatRows([sampleRow], as: .json)
                let decoded = try JSONDecoder().decode([ScholarRow].self, from: data)
                try requireEqual(decoded, [sampleRow])
                try requireEqual(data.last, Character("\n").asciiValue)
            }),
            ("format CSV with header and escaping", {
                let emptyData = try formatRows([], as: .csv)
                try requireEqual(
                    String(data: emptyData, encoding: .utf8),
                    "rank,title,authors,source,year,cited,url\n"
                )
                let csv = String(data: try formatRows([sampleRow], as: .csv), encoding: .utf8) ?? ""
                try require(csv.contains("\"A \"\"quoted\"\", Unicode paper é\""), "CSV must quote commas and quotes")
                try require(csv.contains("\"Ada\nExample\""), "CSV must preserve embedded newlines")
                try require(csv.hasSuffix("\n"), "CSV must end with a newline")
            }),
            ("format table removes terminal controls", {
                let row = ScholarRow(
                    rank: 1,
                    title: "\u{001B}[31mRed\u{001B}[0m\u{0000}",
                    authors: "Ada\nExample",
                    source: "Journal\tA",
                    year: "2024",
                    cited: "1",
                    url: "https://example.test"
                )
                let table = String(data: try formatRows([row], as: .table), encoding: .utf8) ?? ""
                try require(!table.contains("\u{001B}"), "Table must strip ANSI escapes")
                try require(!table.contains("\u{0000}"), "Table must strip terminal controls")
                try require(table.contains("Red"), "Table must retain visible text")
                try require(table.contains("Ada Example"), "Table must flatten line breaks")
                try require(table.contains("Journal A"), "Table must flatten tabs")
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

    private static func requireURLComponents(_ url: URL) throws -> URLComponents {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TestFailure(description: "Could not parse search URL")
        }
        return components
    }
}
