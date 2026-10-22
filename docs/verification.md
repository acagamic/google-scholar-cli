# Verification

Verification runs use macOS 27.0.1 on Apple Silicon with Apple Swift 6.4. Both release slices target macOS 13.

## Core tests

`./scripts/test-core.sh` passes 23 tests with compiler warnings treated as errors. The tests exercise the embedded parser in real, nonpersistent WebKit sessions against synthetic HTML.

Coverage includes linked and unlinked records, grouped citation counts, absent metadata, English and Chinese empty pages, verification pages, malformed cards, and unsafe links. Argument and output tests cover query encoding, limit validation, JSON, CSV, and terminal controls.

The regression checks caught literal plus signs in queries and split Unicode surrogate pairs in truncated metadata. Both failed before their fixes and pass afterward.

A separately compiled Intel core test binary also passes all 23 tests under Rosetta. This verifies execution of the Intel slice on this host. It does not prove execution on Intel hardware or macOS 13.

## Planning and source

`ce-plan` preceded implementation. The plan was updated after the user required a shareable Mac executable with minimal dependencies. A read-only architecture advisor reviewed the Swift and WebKit approach.

OpenCLI’s Apache-2.0 licence is included unchanged. NOTICE identifies the adapted source and its hash. No third-party packages are required by the native build or executable.

## Browser and command tests

`./scripts/test.sh` passes 23 core tests, 17 browser tests, and command smoke checks. The browser tests use real WebKit instances, synthetic pages, and a local HTTP server. They cover hidden verification failures, headed verification recovery, HTTP errors, deadlines, cancellation, window closure, and cleanup.

The command smoke checks cover help, version, invalid arguments, and a closed output pipe. The browser run-loop test supplies its own completion callback; the live subprocess check below verifies the real executable’s completion path. A full search subprocess signal test is not part of the offline suite. Browser-level cancellation and termination are tested.

## Live search

The development executable ran this command with a 25-second external process limit:

```sh
./dist/scholar search 'attention is all you need' --limit 3 --json --timeout 15000
```

It exited with code 0 in 0.87 seconds, returned three records as valid JSON, and produced no stderr output. The first title was “Attention is all you need.” This is evidence of one successful live request, not a guarantee of future Google access.

## Archive and platform checks

The universal binary contains `arm64` and `x86_64` slices. Both have a macOS 13.0 deployment target. `otool -L` lists only macOS frameworks and system libraries. The executable is about 377 KiB; the compressed development archive is about 118 KiB.

The archive was extracted into a fresh temporary directory. With PATH restricted to `/usr/bin:/bin`, help and version succeeded for both slices, with no stderr. The Intel slice ran through Rosetta. The moved archive passed its SHA-256 check, and `codesign --verify --strict` accepted the ad hoc signature.

The Intel linker reported that this host’s Swift compatibility-packs archive contains only arm64 slices. Linking succeeded and the Intel executable ran. No Intel hardware or macOS 13 host was available for testing; those platforms remain release checks.

## Public release prerequisite

Only a local development signing identity is available. The archive is ad hoc signed and is not notarized. It can trigger Gatekeeper warnings after download.

`scripts/release.sh` checks for a Developer ID Application certificate and a notarization keychain profile before building or uploading. Its help and missing-credential checks pass. No Apple upload was performed. A signed, notarized ZIP remains a public release step and requires an online Gatekeeper ticket lookup.

## Final artifact check

After the code cleanup, the full suite passed again and the archive was rebuilt. The extracted final executable passed help, version, and a deterministic broken-pipe check on both slices. That check closes the pipe’s read end before launching the process, so the writer must handle EPIPE.

The final Intel slice then ran the same live query under Rosetta, from the extracted archive with the restricted PATH. It returned three valid records, exited with code 0 in 2.22 seconds, and produced no stderr. The final executable is 386080 bytes.

The code simplification pass retained all proof tests. It removed duplicate language validation and a stored application reference, and deferred a full-page text read until needed for challenge detection.

A clean-context advisor returned SHIP after reviewing the complete implementation and verification evidence. The local deliverable is ready; Developer ID signing and notarization remain prerequisites for a trusted public release.
