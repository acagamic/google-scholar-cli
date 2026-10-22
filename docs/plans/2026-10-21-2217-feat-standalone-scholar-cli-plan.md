---
title: Build a standalone Scholar CLI - Plan
type: feat
date: 2026-10-21
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Build a standalone Scholar CLI - Plan

## Goal capsule

Mac users can unzip one archive and run `scholar search` from Terminal. The executable contains both Apple Silicon and Intel code and uses macOS frameworks.

Means: adapt the OpenCLI parser and use Swift with WebKit. The user’s request for minimal dependencies and Mac sharing replaces the earlier Node and Playwright design.
Authority: implement, test, and package locally. Public publication and Apple account changes are outside this request.
Stop a public release if signing credentials or service access prevent its verification. Preserve the working artifact and report the specific limit.

## Product contract

### Requirements

- R1. Provide a universal macOS executable named `scholar`, with `search <query>`, help, and version. Recipients need macOS 13 or later and a logged-in desktop session. They need no package manager, language runtime, browser download, API key, or OpenCLI installation.
- R2. Accept a nonblank query and `--limit` from 1 through 20, default 10. Fetch one Scholar search page and return at most the requested count.
- R3. Preserve `rank`, `title`, `authors`, `source`, `year`, `cited`, and `url`. Rank is numeric; the other fields are strings. Include citation-only records, grouped citation counts, and defined missing values.
- R4. Provide table, JSON, and CSV through `--format`/`-f`, with `--json` as a shortcut. JSON is an array; CSV has a header. Progress and errors use stderr.
- R5. Use the system WebKit engine with an in-memory session owned by this invocation. Support `--headed`, `--lang`, and `--timeout` in milliseconds. Defaults are a hidden window, English, and 30000 ms. Never read personal browser profiles or copy their cookies.
- R6. Recognised empty results succeed. CAPTCHA, consent, rate limits, network errors, and unknown pages have nonzero exits. Headed mode allows manual verification within the original deadline.
- R7. Close owned windows and stop navigation on success, failure, deadline, window closure, or interruption. Do not retry network requests automatically.
- R8. Include build instructions, a release archive, checksums, attribution, and licence notices. Test without live Google access and record the observed live smoke result separately.
- R9. Provide a release procedure for Developer ID signing and Apple notarization. Without those credentials, label the archive as a development build and report the missing release prerequisite. Do not claim that an ad hoc signature avoids Gatekeeper warnings.

### Acceptance examples

- AE1. An extracted archive runs `./scholar --help` without Node, Python, Homebrew, or downloaded libraries. Covers R1 and R8.
- AE2. A fixture containing 20 valid papers produces 20 ordered JSON records with `--limit 20`. Covers R2 through R4.
- AE3. An explicit empty page produces `[]`; a challenge in hidden mode produces empty stdout and an error. Covers R6.
- AE4. A headed challenge that changes to results completes before the deadline. Timeout and Ctrl-C release the owned window. Covers R5 and R7.

### Scope boundaries

Search is the supported operation. Citation export, author profiles, PDF downloads, pagination, bulk crawling, CAPTCHA solvers, and automatic retries are excluded. The requested limit is a maximum, not a guarantee of the number Google returns.

The CLI requires a desktop session because it uses AppKit and WebKit. SSH-only and Linux execution are outside this Mac release.

## Planning contract

### Technical decisions

- KTD1. Use Swift and macOS Foundation, AppKit, and WebKit. There are zero third-party dependencies. Build arm64 and x86_64 slices with the macOS 13 deployment target, combine them with `lipo`, and inspect their dynamic library links. Supports R1 and R8.
- KTD2. Use `WKWebsiteDataStore.nonPersistent()`. Cookies can support manual verification in the same invocation and are not saved between runs. Named persistent profiles require macOS 14 and are unnecessary for this request. Supports R5.
- KTD3. Keep extraction in a self-contained JavaScript function embedded in the executable. Tests run it in WebKit against the existing synthetic HTML fixtures. A classified snapshot distinguishes results, empty, challenge, consent, and unknown. Missing selectors never mean successful empty output. Supports R3 and R6.
- KTD4. Construct URLs with URLComponents/URLQueryItem, including `q`, `num`, and `hl`. Parse arguments with Foundation only. JSONEncoder and a small CSV formatter supply machine output; table cells remove terminal controls. Supports R2 and R4.
- KTD5. Create and retain NSApplication, NSWindow, and WKWebView on the main thread. Use a monotonic total deadline and an idempotent finaliser. Signal callbacks dispatch cleanup to the main thread. Clear delegates, stop loading, close the window, and release WebKit references before process exit. Supports R5 through R7.
- KTD6. Exit codes: 0 success, 2 arguments, 3 local browser/session failure, 4 service/network failure, 5 unreadable page, 130 interruption. Diagnostics go to stderr and include recovery where available. Supports R4, R6, and R7.
- KTD7. Build a ZIP with the universal executable, README, LICENSE, and NOTICE, plus a SHA-256 checksum. Ad hoc sign local builds. A separate release procedure uses a Developer ID certificate and notarization. Public release remains blocked without those credentials. Supports R8 and R9.

### Risks and evidence

A direct HTTP probe returned 403 on this network. WebKit retains the browser workflow without an added browser installation. It cannot guarantee Google access. Google controls Scholar markup and may restrict automation; report the observed outcome without bypassing verification.

Only a local development signing identity is available. It cannot satisfy Apple’s public Developer ID requirement. macOS 13 compatibility and Intel execution require distinct evidence; cross-compilation alone is not a test on either platform.

The source is OpenCLI 2.0.2, `clis/google-scholar/search.js`, under Apache-2.0. Preserve its attribution and licence. The user’s examples inform the `--json` shortcut and separation of search from output; no code from them is copied.

- [OpenCLI](https://github.com/jackwener/opencli)
- [gscholar](https://github.com/venthur/gscholar)
- [scholarly_publications](https://github.com/ezefranca/scholarly_publications)
- [Scholar skill example](https://mcpmarket.com/tools/skills/google-scholar-search)
- [WebKit data stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [WebKit profile support](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/)
- [Apple notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Google Scholar help](https://scholar.google.com/intl/en/scholar/help.html)

## Implementation units

### U1. Native core and extraction

Goal: replace the Node prototype with Swift models, arguments, output, and embedded extraction. Covers R1 through R4 and R6. Dependencies: none.
Files: `Sources/Scholar/Models.swift`, `Options.swift`, `Output.swift`, `Parser.swift`, `Tests/CoreTests.swift`, `test/fixtures/*.html`, and native build/test configuration.
Approach: preserve useful parser cases, remove Node dependencies, and compile with system frameworks only. Tests cover Unicode query encoding, limits, missing metadata, grouped citations, unlinked records, page states, CSV escaping, terminal controls, and argument errors.
Verification: native core tests pass. The build has no third-party dependency or external resource requirement.

### U2. WebKit lifecycle and executable

Goal: load and classify the page with bounded lifetime. Covers R1, R5, R6, and R7. Depends on U1.
Files: `Sources/Scholar/Browser.swift`, `Sources/Scholar/main.swift`, `Tests/BrowserTests.swift`, and test runner configuration.
Approach: implement KTD2 and KTD5. Poll the loaded document without issuing another request. Allow headed verification, reject hidden verification, and clean up on every terminal path.
Verification: real WebKit fixtures prove results, empty, challenge, consent, unknown, timeout, navigation failure, and cancellation. The executable proves help/version without browser creation, stderr-only errors, and clean pipe closure.

### U3. Build and share

Goal: produce the archive and document recipient steps. Covers R1, R8, and R9. Depends on U2.
Files: `scripts/build.sh`, `scripts/release.sh`, `README.md`, `docs/verification.md`, `LICENSE`, and `NOTICE`.
Approach: compile each architecture, combine, sign locally, and package only runtime artifacts and notices. Add an opt-in Developer ID signing/notarization procedure that fails before publication if credentials are missing.
Verification: inspect `lipo -archs`, `otool -L`, deployment targets, signature, archive contents, and checksum. Extract into a temporary directory and run help/version with a minimal PATH. Run the Intel slice when the host supports it. Record hardware and OS limits. Run one bounded live WebKit search.

## Verification contract

Compile with warnings treated as errors where SDK compatibility permits. Run all native tests, then package and test the extracted binary. Inspect both architectures and system-only dynamic links. Record live access separately from fixture correctness. Run the writing checker on authored documentation. Obtain a clean-context advisor review of the verified working tree.

## Definition of done

The native CLI and local development archive work without recipient dependencies. All available checks pass and untested platform claims are identified. A trusted public release requires Developer ID signing and notarization; if unavailable, the release script and precise prerequisite are delivered with the local build.
