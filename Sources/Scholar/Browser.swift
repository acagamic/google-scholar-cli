import AppKit
import Foundation
import WebKit

final class ScholarBrowser: NSObject, NSWindowDelegate, WKNavigationDelegate {
    typealias Completion = (Result<[ScholarRow], ScholarFailure>) -> Void
    typealias DiagnosticHandler = (String) -> Void

    private let options: SearchOptions
    private let request: URLRequest
    private var suppliedConfiguration: WKWebViewConfiguration?
    private let diagnosticHandler: DiagnosticHandler

    private var application: NSApplication?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var deadlineTimer: Timer?
    private var completion: Completion?
    private var deadlineUptime: UInt64 = 0
    private var generation: UInt64 = 0
    private var activeNavigation: WKNavigation?
    private var pageLoaded = false
    private var evaluationInFlight = false
    private var lastPageState: String?
    private var pendingHTTPFailure: ScholarFailure?
    private var pendingCancellation: ScholarFailure?
    private var showedManualDiagnostic = false
    private var started = false
    private var finished = false

    init(
        options: SearchOptions,
        request: URLRequest,
        configuration: WKWebViewConfiguration? = nil,
        diagnosticHandler: @escaping DiagnosticHandler = ScholarBrowser.writeDiagnostic
    ) {
        self.options = options
        self.request = request
        suppliedConfiguration = configuration
        self.diagnosticHandler = diagnosticHandler
        super.init()
    }

    func start(completion: @escaping Completion) {
        precondition(Thread.isMainThread, "ScholarBrowser must start on the main thread")
        precondition(!started, "ScholarBrowser can only start once")

        let startUptime = DispatchTime.now().uptimeNanoseconds
        started = true
        self.completion = completion

        if let pendingCancellation {
            finalize(.failure(pendingCancellation))
            return
        }

        do {
            try options.validate()
        } catch let failure as ScholarFailure {
            finalize(.failure(failure))
            return
        } catch {
            finalize(.failure(localFailure("Could not validate the browser session.")))
            return
        }
        let timeoutNanoseconds = UInt64(options.timeout * 1_000_000_000)
        deadlineUptime = startUptime.addingReportingOverflow(timeoutNanoseconds).partialValue

        application = NSApplication.shared
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let contentRect = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let createdWindow = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        createdWindow.title = "Scholar Search"
        createdWindow.isReleasedWhenClosed = false
        createdWindow.delegate = self

        let createdWebView = WKWebView(frame: contentRect, configuration: configuration)
        suppliedConfiguration = nil
        createdWebView.navigationDelegate = self
        createdWindow.contentView = createdWebView
        window = createdWindow
        webView = createdWebView

        if options.headed {
            createdWindow.center()
            createdWindow.makeKeyAndOrderFront(nil)
            application?.activate(ignoringOtherApps: true)
        } else {
            createdWindow.orderOut(nil)
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.timerTick()
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        if DispatchTime.now().uptimeNanoseconds >= deadlineUptime {
            finishForDeadline()
            return
        }
        createdWebView.load(request)
    }

    func cancel(exitCode: Int32 = 130) {
        precondition(Thread.isMainThread, "ScholarBrowser cancellation must run on the main thread")
        let message = exitCode == 130
            ? "Interrupted."
            : "Terminated by signal."
        let failure = ScholarFailure(message: message, exitCode: exitCode)
        guard started else {
            if pendingCancellation == nil {
                pendingCancellation = failure
            }
            return
        }
        finalize(.failure(failure))
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else {
            return
        }
        finalize(.failure(ScholarFailure(
            message: "The Scholar Search window was closed.",
            exitCode: 130
        )))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation &+= 1
        activeNavigation = navigation
        pageLoaded = false
        evaluationInFlight = false
        lastPageState = nil
        pendingHTTPFailure = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              response.statusCode >= 400 else {
            decisionHandler(.allow)
            return
        }

        let failure = ScholarFailure(
            message: "Google Scholar returned HTTP \(response.statusCode).",
            exitCode: 4
        )
        if response.statusCode == 403 || response.statusCode == 429 {
            pendingHTTPFailure = failure
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            finalize(.failure(failure))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else {
            return
        }
        pageLoaded = true
        pollPage()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finalize(.failure(localFailure("The WebKit content process exited unexpectedly.")))
    }

    private func timerTick() {
        guard !finished else {
            return
        }
        if DispatchTime.now().uptimeNanoseconds >= deadlineUptime {
            finishForDeadline()
            return
        }
        pollPage()
    }

    private func pollPage() {
        guard pageLoaded, !evaluationInFlight, !finished, let webView else {
            return
        }
        if DispatchTime.now().uptimeNanoseconds >= deadlineUptime {
            finishForDeadline()
            return
        }

        evaluationInFlight = true
        let evaluationGeneration = generation
        webView.evaluateJavaScript(scholarExtractionScript(limit: options.limit)) {
            [weak self] value, error in
            guard let self,
                  !self.finished,
                  self.generation == evaluationGeneration else {
                return
            }
            self.evaluationInFlight = false

            if DispatchTime.now().uptimeNanoseconds >= self.deadlineUptime {
                self.finishForDeadline()
                return
            }

            if let error {
                self.finalize(.failure(self.localFailure(
                    "Could not inspect the loaded page: \(error.localizedDescription)"
                )))
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8) else {
                self.finalize(.failure(self.localFailure(
                    "The loaded page returned an invalid extraction result."
                )))
                return
            }

            do {
                let snapshot = try JSONDecoder().decode(PageSnapshot.self, from: data)
                self.handle(snapshot)
            } catch {
                self.finalize(.failure(self.localFailure(
                    "Could not decode the loaded page: \(error.localizedDescription)"
                )))
            }
        }
    }

    private func handle(_ snapshot: PageSnapshot) {
        lastPageState = snapshot.state

        if let pendingHTTPFailure {
            if (snapshot.state == "challenge" || snapshot.state == "consent"), options.headed {
                self.pendingHTTPFailure = nil
            } else if snapshot.state != "challenge" && snapshot.state != "consent" {
                finalize(.failure(pendingHTTPFailure))
                return
            }
        }

        switch snapshot.state {
        case "results":
            finalize(.success(Array(snapshot.items.prefix(options.limit))))
        case "empty":
            finalize(.success([]))
        case "challenge":
            handleManualPage(kind: "verification")
        case "consent":
            handleManualPage(kind: "consent")
        case "unknown":
            break
        default:
            lastPageState = "unknown"
        }
    }

    private func handleManualPage(kind: String) {
        guard options.headed else {
            finalize(.failure(ScholarFailure(
                message: "Google Scholar requested \(kind). Run again with --headed --timeout 120000 to complete it manually.",
                exitCode: 4
            )))
            return
        }

        if !showedManualDiagnostic {
            showedManualDiagnostic = true
            diagnosticHandler(
                "Google Scholar requested \(kind). Complete it in the Scholar Search window before the deadline."
            )
        }
    }

    private func finishForDeadline() {
        switch lastPageState {
        case "challenge", "consent":
            finalize(.failure(ScholarFailure(
                message: "Google Scholar verification or consent was not completed before the deadline.",
                exitCode: 4
            )))
        case nil:
            finalize(.failure(ScholarFailure(
                message: "Google Scholar did not finish loading before the deadline.",
                exitCode: 4
            )))
        default:
            finalize(.failure(ScholarFailure(
                message: "Could not recognise the Google Scholar page before the deadline.",
                exitCode: 5
            )))
        }
    }

    private func handleNavigationFailure(_ error: Error) {
        guard !finished else {
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return
        }
        finalize(.failure(ScholarFailure(
            message: "Google Scholar network request failed: \(error.localizedDescription)",
            exitCode: 4
        )))
    }

    private func localFailure(_ message: String) -> ScholarFailure {
        ScholarFailure(message: message, exitCode: 3)
    }

    private func finalize(_ result: Result<[ScholarRow], ScholarFailure>) {
        guard !finished else {
            return
        }
        finished = true
        generation &+= 1
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        activeNavigation = nil

        let callback = completion
        completion = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        application = nil
        suppliedConfiguration = nil

        callback?(result)
    }

    private static func writeDiagnostic(_ message: String) {
        let data = Data((message + "\n").utf8)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
