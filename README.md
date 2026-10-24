# Scholar

Search Google Scholar from Terminal or an agent skill on a Mac. The `scholar` executable includes Apple Silicon and Intel support and uses the WebKit engine supplied with macOS.

Requires macOS 13 or later, an internet connection, and a logged-in desktop session. Recipients do not need a package manager, language runtime, API key, or browser download.

## Run a search

Download `scholar-0.1.0-macos-universal-dev.zip` from the [v0.1.0-dev.2 release](https://github.com/acagamic/google-scholar-cli/releases/tag/v0.1.0-dev.2). Extract it and open Terminal in the extracted folder. This preview is not notarized and may trigger Gatekeeper warnings after download.

```sh
./scholar search 'attention is all you need' --limit 5
```

Use JSON in scripts or CSV for a spreadsheet:

```sh
./scholar search 'human computer interaction' --json
./scholar search 'author:Shneiderman' --limit 20 -f csv > papers.csv
```

Run `./scholar --help` for all options. Put the executable in a directory on your PATH to use `scholar` from any folder.

The v0.1.0-dev.2 packaging release keeps CLI version 0.1.0. Test results for each release are in `docs/verification.md`.

From a source checkout, the executable is at `./dist/scholar` after a build. Use the relative path if your shell reports `scholar: command not found`:

```sh
./dist/scholar --help
```

## Install the agent skill

The full development ZIP contains `skills/scholar-search`. The release also has a smaller `scholar-search-0.1.0-macos-universal-dev.zip` with `scholar-search` at its root. Keep the entire folder together because it contains the launcher and executable.

In the full extracted archive, select its skill folder:

```sh
source_skill=./skills/scholar-search
```

In the extracted standalone skill ZIP, select this folder instead:

```sh
source_skill=./scholar-search
```

Install it for Codex by copying the folder to `~/.codex/skills`. The first command stops if a skill already exists at that path, so the copy does not replace it.

```sh
target_skill="$HOME/.codex/skills/scholar-search"
test ! -e "$target_skill" &&
  mkdir -p "$HOME/.codex/skills" &&
  cp -R "$source_skill" "$target_skill"
```

Install it for Claude Code by copying the folder to `~/.claude/skills` with the same collision check:

```sh
target_skill="$HOME/.claude/skills/scholar-search"
test ! -e "$target_skill" &&
  mkdir -p "$HOME/.claude/skills" &&
  cp -R "$source_skill" "$target_skill"
```

Open a new agent session after the copy. Codex and Claude Code can discover the skill from a natural request such as `Search Google Scholar for recent work on accessible data visualisation`. You can also invoke it by name:

```text
$scholar-search Find papers about WebKit accessibility testing
/scholar-search Find papers about WebKit accessibility testing
```

The first named form is for Codex. The second is for Claude Code. See the [Claude Code skill documentation](https://code.claude.com/docs/en/skills) for its discovery and invocation rules.

The skill returns a short source summary with paper links by default. Ask for JSON or CSV when you need structured output. Its launcher resolves the bundled executable from its own folder, so it works from any current directory. Set `SCHOLAR_BIN` to an executable path only when you want the launcher to use another compatible `scholar` build.

## If a search fails

Every failed search prints one sentence that says where the problem is, then numbered steps. Commands in those steps start with `scholar`. If the executable is not on your PATH, type `./scholar` instead.

Check this Mac's browser engine without contacting Google:

```sh
./scholar doctor
```

On a working Mac it prints a pass and exits 0. Otherwise it prints steps, your macOS version and the newest WebKit crash report from the last 7 days, and exits 3. If the steps do not help, send those two lines to the person who gave you Scholar.

Exit 3 means the problem is on your Mac, in the page Google returned, or in a place Scholar could not identify:

- The browser engine stopped while loading the page: quit apps you are not using and search again, restart your Mac if it stops again, install waiting macOS updates, then run `scholar doctor`.
- No desktop session is available: log in at the Mac itself or through Screen Sharing, run the command from Terminal in that session, then run `scholar doctor`. A remote shell such as SSH is not enough.
- Scholar could not look inside the page: search again, send the details line to the person who gave you Scholar if it fails again, then run `scholar doctor`.
- Scholar could not turn the results into the output you asked for: search again with the default table output, then run `scholar doctor`.
- Scholar could not write its output: check that the disk has free space and that you can save in the target folder, run the command again, then run `scholar doctor`.
- Scholar could not read the results on the page Google returned: wait a few minutes and search again. If it keeps failing, Google may have changed its page, so send the details line to the person who gave you Scholar.

Exit 4 means the problem is with Google or your network:

- Google wants to check that a person is searching, or wants you to accept its consent terms: run the search again with `--headed` and a timeout of at least 120000 ms, finish the check in the window, and wait before searching again if Google still blocks you.
- Google's check was not finished before the time limit: run the search again with `--headed` and more time, and finish the check as soon as the window opens.
- Google Scholar is limiting searches from your network: wait an hour or more, then run the search once. Turn off a VPN for that search.
- Google Scholar returned an error page: wait a few minutes and search again, and check that https://scholar.google.com opens in your web browser.
- Google Scholar did not finish loading before the time limit: check your internet connection, then search again with a longer `--timeout`.
- Scholar could not reach Google Scholar: check your internet connection, try without a VPN or proxy, and search again.

Exit 5 means Scholar did not recognise the page as search results before the time limit. Search again with `--headed` to see the page. If the window shows normal results, Google may have changed its page, so tell the person who gave you Scholar.

### Google verification

When Google asks for verification, the error prints the command to run with a visible window and a longer timeout. For example:

```sh
./scholar search --headed --timeout 120000 -- 'attention is all you need'
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
| 130 | Search cancelled, or the visible window was closed |
| 143 | Search terminated by a signal |

Diagnostics use stderr. JSON and CSV output use stdout.

## Build from source

Building requires Apple’s Command Line Tools or Xcode. The test script also uses `/usr/bin/python3` for the offline launcher and archive checks. These are developer requirements; recipients run the compiled executable.

```sh
git clone https://github.com/acagamic/google-scholar-cli.git
cd google-scholar-cli
./scripts/test.sh
./scripts/build.sh
```

The build creates a universal executable, both development ZIPs, and a SHA-256 file for each ZIP in `dist/`. The full CLI archive includes the portable skill. The standalone archive contains only the skill, its executable, and legal notices. Tests use synthetic pages in local WebKit instances and do not query Google.

## Share a release

The development archive is ad hoc signed. It is not notarized and can trigger Gatekeeper warnings when downloaded. It is suitable for local testing; it is not a trusted public release.

For distribution without those warnings, use a Developer ID Application certificate and an Apple notarization keychain profile. The release script signs one executable, packages both public ZIPs from those bytes, and submits both ZIPs for notarization. It publishes neither ZIP unless Apple accepts both submissions. The script documents its required environment variables in `./scripts/release.sh --help`. Apple describes the account requirements in [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/).

The executable and ZIP have no runtime dependencies beyond macOS system frameworks. Keep LICENSE and NOTICE in the archive when sharing it.

## Source and examples

The search extraction is adapted from [OpenCLI](https://github.com/jackwener/opencli), version 2.0.2, under Apache-2.0. See LICENSE and NOTICE for attribution.

The design also draws on [gscholar](https://github.com/venthur/gscholar), [scholarly_publications](https://github.com/ezefranca/scholarly_publications), and this [Scholar CLI skill example](https://mcpmarket.com/tools/skills/google-scholar-search). No code from those examples is included. Citation export, author profile crawling, and PDF downloads are outside this application’s scope.
