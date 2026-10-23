#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
build_directory="$repository_root/.build"
dist_directory="$repository_root/dist"

usage() {
  print "Usage: SIGNING_IDENTITY='Developer ID Application: ...' NOTARY_PROFILE='keychain profile' ./scripts/release.sh"
  print ""
  print "Build, sign, notarize, and create the Scholar CLI and skill archives."
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
staged_archive="$staging_directory/scholar-$version-macos-universal.zip"
staged_checksum="$staged_archive.sha256"
staged_skill_archive="$staging_directory/scholar-search-$version-macos-universal.zip"
staged_skill_checksum="$staged_skill_archive.sha256"
cli_notary_result="$staging_directory/cli-notary-result.plist"
skill_notary_result="$staging_directory/skill-notary-result.plist"
public_archive="$dist_directory/scholar-$version-macos-universal.zip"
public_checksum="$public_archive.sha256"
public_skill_archive="$dist_directory/scholar-search-$version-macos-universal.zip"
public_skill_checksum="$public_skill_archive.sha256"

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  /bin/rm -rf "$staging_directory"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$universal_binary"
/usr/bin/codesign --verify --strict "$universal_binary"

"$script_directory/package.sh" \
  --repository-root "$repository_root" \
  --binary "$universal_binary" \
  --output-directory "$staging_directory" \
  --version "$version"

submit_for_notarization() {
  local archive=$1
  local result_file=$2

  print "Submitting ${archive:t} for notarization..."
  /usr/bin/xcrun notarytool submit "$archive" \
    --keychain-profile "$notary_profile" \
    --wait \
    --output-format plist > "$result_file"

  local notary_status
  notary_status=$(/usr/bin/plutil -extract status raw -o - "$result_file" 2>/dev/null) || {
    print -u2 "Notarization response for ${archive:t} did not contain a status."
    return 1
  }
  if [[ "$notary_status" != "Accepted" ]]; then
    print -u2 "Notarization status for ${archive:t}: $notary_status"
    return 1
  fi
}

submit_for_notarization "$staged_archive" "$cli_notary_result"
submit_for_notarization "$staged_skill_archive" "$skill_notary_result"

/bin/mv "$staged_archive" "$public_archive"
/bin/mv "$staged_checksum" "$public_checksum"
/bin/mv "$staged_skill_archive" "$public_skill_archive"
/bin/mv "$staged_skill_checksum" "$public_skill_checksum"

print "Notarization status: Accepted"
print "Archive: $public_archive"
print "Checksum: $public_checksum"
print "Skill archive: $public_skill_archive"
print "Skill checksum: $public_skill_checksum"
print "A raw CLI binary cannot carry a stapled ticket. A notarized ZIP requires an online Gatekeeper lookup."
