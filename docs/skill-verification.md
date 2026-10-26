# Skill verification

Verification date: October 23, 2026.

This release adds the `scholar-search` skill and distributable packages. The CLI remains version 0.1.0; its Swift search implementation is unchanged.

## Skill and launcher

The skill was created with Skill Creator. Its validator accepts the frontmatter, name, and completed instructions. Automatic selection is enabled, with explicit invocation through `$scholar-search` in Codex and `/scholar-search` in Claude Code.

Ten launcher tests exercise executable resolution, invalid overrides, argument preservation, exit status, stdout and stderr, paths with spaces, and execution from another working directory. They use local executable fixtures without querying Google.

An independent agent exercised the skill with synthetic paper metadata. It returned a short summary with the supplied links, treated an instruction in a paper title as data, and exported CSV to a new filename when the requested file already existed. A separate failure fixture returned exit 3. The agent reported its diagnostic and a manual command without retrying.

## Packages

Five packaging tests check archive contents, executable permissions, identical binary copies, licences, and checksums. They also check missing-input failure and the release publication sequence. A mocked notarization run accepts the first archive and rejects the second; publication does not occur.

Both development archives are built from one universal executable. The full CLI archive contains the skill, and the standalone archive contains the skill with its own executable. Each skill copy includes LICENSE and NOTICE. The tracked source skill does not contain a binary.

Archive checks cover both CPU slices, strict code-signature verification, extracted help and version commands, and launcher execution from an unrelated directory. The Intel slice is exercised through Rosetta, not on Intel hardware. macOS 13 hardware is unavailable for this verification.

## Existing browser failures

Before these changes, the core suite passed 22 of 23 tests. Its first WebKit operation exceeded five seconds. The separate browser suite passed eight of 17 tests; failures included local fixture pages exceeding their deadlines.

Live searches with the development executable, in hidden and visible modes, returned exit 3 with this diagnostic:

```text
The WebKit content process exited unexpectedly.
```

A search after rebuilding reproduced that diagnostic. No successful live Google Scholar query was obtained during this verification. The skill reports this failure; this packaging release does not repair it. The earlier successful live searches in `verification.md` describe the previous verification run.

## Distribution status

The development executable has an ad hoc signature. Gatekeeper assessment rejects it. No Developer ID signing or Apple notarization was performed.

The release script checks credentials before building, signs the executable before packaging, and requires acceptance of both ZIPs before publishing public archives. Its help and missing-credential checks pass. The two-archive notarization failure test uses local fixtures and makes no Apple requests.

## Later live result

On October 23, 2026, the same development executable completed a live search with exit 0, and the WebKit failure above did not reproduce. Failures now print a plain diagnosis with numbered steps, and the skill relays that text to the user word for word. See `docs/verification.md`.
