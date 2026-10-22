# scholar

Search Google Scholar from Terminal on a Mac. The `scholar` executable includes Apple Silicon and Intel support and uses the WebKit engine supplied with macOS.

Requires macOS 13 or later, an internet connection, and a logged-in desktop session. Recipients do not need a package manager, language runtime, API key, or browser download.

## Run a search

Extract the release ZIP and open Terminal in the extracted folder:

```sh
./scholar search 'attention is all you need' --limit 5
```

Use JSON in scripts or CSV for a spreadsheet:

```sh
./scholar search 'human computer interaction' --json
./scholar search 'author:Shneiderman' --limit 20 -f csv > papers.csv
```

Run `./scholar --help` for all options. Put the executable in a directory on your PATH to use `scholar` from any folder.

## Google verification

If Google asks for verification, rerun with a visible window and a longer timeout:

```sh
./scholar search 'attention is all you need' --headed --timeout 120000
```

Complete verification in that window. The command reads results when they appear. The timeout includes page loading and verification. Ctrl-C cancels the search and closes the window.

Each search has a separate in-memory browser session. Cookies are kept only for that invocation. The CLI does not read Safari or Chrome profiles.

Google may block a search even in the visible window. The CLI reports that error; it does not solve CAPTCHA or retry requests automatically. Scholar does not provide bulk access. See [Google Scholar help](https://scholar.google.com/intl/en/scholar/help.html).

## Output

Results contain `rank`, `title`, `authors`, `source`, `year`, `cited`, and `url`. Rank is a number. The other fields are strings.

Missing text is an empty string; a missing citation count is `"0"`. An unlinked citation can have a title and an empty URL. Authors are limited to 80 Unicode code points and sources to 60. Google can provide incomplete metadata.

`--limit` accepts 1 through 20 and defaults to 10. It limits one page; Google may return fewer papers. `--lang zh-CN` changes the search language from the default English.

JSON is an array. CSV has a header, including when there are no results. Import CSV text columns as text: scraped titles can begin with spreadsheet formula characters.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, including a recognised empty search |
| 2 | Invalid arguments |
| 3 | Local browser or desktop session failure |
| 4 | Google verification, consent, restriction, or network failure |
| 5 | The page could not be read as search results |
| 130 | Search cancelled |

Diagnostics use stderr. JSON and CSV output use stdout.

## Build from source

Building requires Apple’s Command Line Tools or Xcode. This is a developer requirement; recipients run the compiled executable.

```sh
./scripts/test.sh
./scripts/build.sh
```

The build creates a universal executable and a development ZIP in `dist/`. Tests use synthetic pages in local WebKit instances and do not query Google.

## Share a release

The development archive is ad hoc signed. It is not notarized and can trigger Gatekeeper warnings when downloaded. It is suitable for local testing; it is not a trusted public release.

For distribution without those warnings, use a Developer ID Application certificate and an Apple notarization keychain profile. The release script documents its required environment variables in `./scripts/release.sh --help`. Apple describes the account requirements in [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/).

The executable and ZIP have no runtime dependencies beyond macOS system frameworks. Keep LICENSE and NOTICE in the archive when sharing it.

## Source and examples

The search extraction is adapted from [OpenCLI](https://github.com/jackwener/opencli), version 2.0.2, under Apache-2.0. See LICENSE and NOTICE for attribution.

The design also draws on [gscholar](https://github.com/venthur/gscholar), [scholarly_publications](https://github.com/ezefranca/scholarly_publications), and this [Scholar CLI skill example](https://mcpmarket.com/tools/skills/google-scholar-search). No code from those examples is included. Citation export, author profile crawling, and PDF downloads are outside this application’s scope.
