#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_directory="$repository_root/.build"
dist_directory="$repository_root/dist"

usage() {
  print "Usage: SIGNING_IDENTITY='Developer ID Application: ...' NOTARY_PROFILE='keychain profile' ./scripts/release.sh"
  print ""
  print "Build, sign, notarize, and create the Scholar universal macOS archive."
  print "SIGNING_IDENTITY must name an installed Developer ID Application certificate."
  print "NOTARY_PROFILE must name an existing xcrun notarytool keychain profile."
  print "A raw CLI binary cannot carry a stapled ticket. A notarized ZIP requires an online Gatekeeper lookup."
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  print -u2 "Unknown argument: $1"
  usage >&2
  exit 2
fi

signing_identity=${SIGNING_IDENTITY:-}
notary_profile=${NOTARY_PROFILE:-}

if [[ -z "$signing_identity" ]]; then
  print -u2 "SIGNING_IDENTITY is required and must name a Developer ID Application certificate."
  exit 2
fi
if [[ -z "$notary_profile" ]]; then
  print -u2 "NOTARY_PROFILE is required and must name an xcrun notarytool keychain profile."
  exit 2
fi
if [[ "$signing_identity" != "Developer ID Application: "* ]]; then
  print -u2 "SIGNING_IDENTITY must be a Developer ID Application certificate."
  exit 2
fi

available_identities=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null) || {
  print -u2 "Could not inspect the local codesigning identities."
  exit 2
}
if [[ "$available_identities" != *"\"$signing_identity\""* ]]; then
  print -u2 "Developer ID Application certificate not found: $signing_identity"
  exit 2
fi

"$script_directory/build.sh"

universal_binary="$dist_directory/scholar"
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

staging_directory=$(/usr/bin/mktemp -d "$build_directory/release.XXXXXX")
package_directory="$staging_directory/scholar-$version-macos-universal"
staged_archive="$staging_directory/scholar-$version-macos-universal.zip"
staged_checksum="$staged_archive.sha256"
notary_result="$staging_directory/notary-result.plist"
public_archive="$dist_directory/scholar-$version-macos-universal.zip"
public_checksum="$public_archive.sha256"

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

/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$package_directory/scholar"
/usr/bin/codesign --verify --strict "$package_directory/scholar"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_directory" "$staged_archive"
(
  cd "$staging_directory"
  /usr/bin/shasum -a 256 "$(basename "$staged_archive")" > "$(basename "$staged_checksum")"
)

print "Submitting notarization request..."
/usr/bin/xcrun notarytool submit "$staged_archive" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format plist > "$notary_result"

notary_status=$(/usr/bin/plutil -extract status raw -o - "$notary_result" 2>/dev/null) || {
  print -u2 "Notarization response did not contain a status."
  exit 1
}
if [[ "$notary_status" != "Accepted" ]]; then
  print -u2 "Notarization status: $notary_status"
  exit 1
fi

/bin/mv "$staged_archive" "$public_archive"
/bin/mv "$staged_checksum" "$public_checksum"

print "Notarization status: Accepted"
print "Archive: $public_archive"
print "Checksum: $public_checksum"
print "A raw CLI binary cannot carry a stapled ticket. A notarized ZIP requires an online Gatekeeper lookup."
