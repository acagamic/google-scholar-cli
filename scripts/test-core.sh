#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_directory="$repository_root/.build"
test_binary="$build_directory/core-tests"
machine_architecture=$(/usr/bin/uname -m)

case "$machine_architecture" in
  arm64|x86_64) ;;
  *)
    print -u2 "Unsupported macOS architecture: $machine_architecture"
    exit 1
    ;;
esac

mkdir -p "$build_directory"

/usr/bin/swiftc \
  -swift-version 5 \
  -target "$machine_architecture-apple-macosx13.0" \
  -warnings-as-errors \
  -framework AppKit \
  -framework WebKit \
  "$repository_root/Sources/Scholar/Models.swift" \
  "$repository_root/Sources/Scholar/Options.swift" \
  "$repository_root/Sources/Scholar/Output.swift" \
  "$repository_root/Sources/Scholar/Parser.swift" \
  "$repository_root/Tests/CoreTests.swift" \
  -o "$test_binary"

cd "$repository_root"
exec "$test_binary"
