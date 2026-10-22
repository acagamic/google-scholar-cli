#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_directory="$repository_root/.build"
dist_directory="$repository_root/dist"
arm64_binary="$build_directory/scholar-arm64"
x86_64_binary="$build_directory/scholar-x86_64"
universal_binary="$dist_directory/scholar"

mkdir -p "$build_directory" "$dist_directory"

source_files=("$repository_root"/Sources/Scholar/*.swift)

print "Compiling arm64..."
/usr/bin/swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -warnings-as-errors \
  -O \
  -framework AppKit \
  -framework WebKit \
  "${source_files[@]}" \
  -o "$arm64_binary"

print "Compiling x86_64..."
/usr/bin/swiftc \
  -swift-version 5 \
  -target x86_64-apple-macosx13.0 \
  -warnings-as-errors \
  -O \
  -framework AppKit \
  -framework WebKit \
  "${source_files[@]}" \
  -o "$x86_64_binary"

/usr/bin/lipo -create "$arm64_binary" "$x86_64_binary" -output "$universal_binary"
/usr/bin/codesign --force --sign - --timestamp=none "$universal_binary"

architecture_list=$(/usr/bin/lipo -archs "$universal_binary")
if [[ "$architecture_list" != *arm64* || "$architecture_list" != *x86_64* ]]; then
  print -u2 "Universal binary has unexpected architectures: $architecture_list"
  exit 1
fi
/usr/bin/codesign --verify "$universal_binary"

version_output=$("$universal_binary" --version)
if [[ "$version_output" != "scholar "* ]]; then
  print -u2 "Could not read the Scholar version from the built binary"
  exit 1
fi
version=${version_output#scholar }
if [[ -z "$version" || "$version" == *[![:alnum:]._-]* ]]; then
  print -u2 "Invalid Scholar version: $version_output"
  exit 1
fi

staging_directory=$(/usr/bin/mktemp -d "$build_directory/package.XXXXXX")
package_directory="$staging_directory/scholar-$version-macos-universal-dev"
staged_archive="$staging_directory/scholar-$version-macos-universal-dev.zip"
staged_checksum="$staged_archive.sha256"
archive_path="$dist_directory/scholar-$version-macos-universal-dev.zip"
checksum_path="$archive_path.sha256"

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  /bin/rm -rf "$staging_directory"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$package_directory"
/usr/bin/ditto "$universal_binary" "$package_directory/scholar"
/usr/bin/ditto "$repository_root/README.md" "$package_directory/README.md"
/usr/bin/ditto "$repository_root/LICENSE" "$package_directory/LICENSE"
/usr/bin/ditto "$repository_root/NOTICE" "$package_directory/NOTICE"
/bin/chmod 755 "$package_directory/scholar"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_directory" "$staged_archive"
(
  cd "$staging_directory"
  /usr/bin/shasum -a 256 "$(basename "$staged_archive")" > "$(basename "$staged_checksum")"
)
/bin/mv "$staged_archive" "$archive_path"
/bin/mv "$staged_checksum" "$checksum_path"

print "Built $universal_binary ($architecture_list)"
print "Ad hoc signature verified"
print "Archive: $archive_path"
print "Checksum: $checksum_path"
