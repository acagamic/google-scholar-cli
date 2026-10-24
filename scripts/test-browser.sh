#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_directory="$repository_root/.build"
test_binary="$build_directory/browser-tests"
cli_binary="$build_directory/scholar"
machine_architecture=$(/usr/bin/uname -m)

case "$machine_architecture" in
  arm64|x86_64) ;;
  *)
    print -u2 "Unsupported macOS architecture: $machine_architecture"
    exit 1
    ;;
esac

mkdir -p "$build_directory"

common_sources=(
  "$repository_root/Sources/Scholar/Diagnosis.swift"
  "$repository_root/Sources/Scholar/Models.swift"
  "$repository_root/Sources/Scholar/Options.swift"
  "$repository_root/Sources/Scholar/Output.swift"
  "$repository_root/Sources/Scholar/Parser.swift"
  "$repository_root/Sources/Scholar/Browser.swift"
)

/usr/bin/swiftc \
  -swift-version 5 \
  -target "$machine_architecture-apple-macosx13.0" \
  -warnings-as-errors \
  -framework AppKit \
  -framework WebKit \
  "${common_sources[@]}" \
  "$repository_root/Tests/BrowserTests.swift" \
  -o "$test_binary"

cd "$repository_root"
"$test_binary"

/usr/bin/swiftc \
  -swift-version 5 \
  -target "$machine_architecture-apple-macosx13.0" \
  -warnings-as-errors \
  -framework AppKit \
  -framework WebKit \
  "${common_sources[@]}" \
  "$repository_root/Sources/Scholar/main.swift" \
  -o "$cli_binary"

help_output=$("$cli_binary" --help)
[[ "$help_output" == *"Usage:"* ]]
[[ "$help_output" == *"logged-in macOS desktop session"* ]]
[[ "$("$cli_binary" --version)" == "scholar 0.1.0" ]]

set +e
invalid_stdout=$("$cli_binary" search --limit 0 query 2>"$build_directory/invalid.stderr")
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]]
[[ -z "$invalid_stdout" ]]
[[ -s "$build_directory/invalid.stderr" ]]

set -o pipefail
"$cli_binary" --help | /usr/bin/true

print "PASS CLI help, version, invalid arguments, and closed pipe"
