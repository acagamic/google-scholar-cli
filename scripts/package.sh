#!/bin/zsh
set -euo pipefail

usage() {
  print "Usage: ./scripts/package.sh --repository-root PATH --binary PATH --output-directory PATH --version VERSION [--development]"
  print ""
  print "Create the Scholar CLI and scholar-search skill archives in an existing staging directory."
}

repository_root=
binary_path=
output_directory=
version=
development=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository-root)
      [[ $# -ge 2 ]] || { print -u2 "Missing value for --repository-root"; exit 2; }
      repository_root=$2
      shift 2
      ;;
    --binary)
      [[ $# -ge 2 ]] || { print -u2 "Missing value for --binary"; exit 2; }
      binary_path=$2
      shift 2
      ;;
    --output-directory)
      [[ $# -ge 2 ]] || { print -u2 "Missing value for --output-directory"; exit 2; }
      output_directory=$2
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || { print -u2 "Missing value for --version"; exit 2; }
      version=$2
      shift 2
      ;;
    --development)
      development=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$repository_root" || -z "$binary_path" || -z "$output_directory" || -z "$version" ]]; then
  print -u2 "--repository-root, --binary, --output-directory, and --version are required"
  exit 2
fi
if [[ "$version" == *[![:alnum:]._-]* ]]; then
  print -u2 "Invalid Scholar version: $version"
  exit 2
fi

skill_source="$repository_root/skills/scholar-search"
required_files=(
  "$binary_path"
  "$repository_root/README.md"
  "$repository_root/LICENSE"
  "$repository_root/NOTICE"
  "$skill_source/SKILL.md"
  "$skill_source/agents/openai.yaml"
  "$skill_source/scripts/run-scholar"
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    print -u2 "Required packaging input is missing: $required_file"
    exit 1
  fi
done
if [[ ! -x "$binary_path" ]]; then
  print -u2 "Scholar binary is not executable: $binary_path"
  exit 1
fi
if [[ ! -x "$skill_source/scripts/run-scholar" ]]; then
  print -u2 "Skill launcher is not executable: $skill_source/scripts/run-scholar"
  exit 1
fi
if [[ ! -d "$output_directory" ]]; then
  print -u2 "Staging directory does not exist: $output_directory"
  exit 1
fi

qualifier=
if [[ "$development" == true ]]; then
  qualifier=-dev
fi

cli_name="scholar-$version-macos-universal$qualifier"
skill_archive_name="scholar-search-$version-macos-universal$qualifier"
cli_package="$output_directory/$cli_name"
standalone_skill="$output_directory/scholar-search"
cli_archive="$output_directory/$cli_name.zip"
skill_archive="$output_directory/$skill_archive_name.zip"

for output_path in "$cli_package" "$standalone_skill" "$cli_archive" "$skill_archive" "$cli_archive.sha256" "$skill_archive.sha256"; do
  if [[ -e "$output_path" ]]; then
    print -u2 "Staging output already exists: $output_path"
    exit 1
  fi
done

copy_skill() {
  local destination=$1

  /bin/mkdir -p "$destination/agents" "$destination/scripts" "$destination/bin"
  /usr/bin/ditto "$skill_source/SKILL.md" "$destination/SKILL.md"
  /usr/bin/ditto "$skill_source/agents/openai.yaml" "$destination/agents/openai.yaml"
  /usr/bin/ditto "$skill_source/scripts/run-scholar" "$destination/scripts/run-scholar"
  /usr/bin/ditto "$binary_path" "$destination/bin/scholar"
  /usr/bin/ditto "$repository_root/LICENSE" "$destination/LICENSE"
  /usr/bin/ditto "$repository_root/NOTICE" "$destination/NOTICE"
  /bin/chmod 755 "$destination/scripts/run-scholar" "$destination/bin/scholar"
}

/bin/mkdir -p "$cli_package/skills"
/usr/bin/ditto "$binary_path" "$cli_package/scholar"
/usr/bin/ditto "$repository_root/README.md" "$cli_package/README.md"
/usr/bin/ditto "$repository_root/LICENSE" "$cli_package/LICENSE"
/usr/bin/ditto "$repository_root/NOTICE" "$cli_package/NOTICE"
/bin/chmod 755 "$cli_package/scholar"
copy_skill "$cli_package/skills/scholar-search"
copy_skill "$standalone_skill"

source_hash=$(/usr/bin/shasum -a 256 "$binary_path" | /usr/bin/awk '{ print $1 }')
cli_hash=$(/usr/bin/shasum -a 256 "$cli_package/scholar" | /usr/bin/awk '{ print $1 }')
bundled_skill_hash=$(/usr/bin/shasum -a 256 "$cli_package/skills/scholar-search/bin/scholar" | /usr/bin/awk '{ print $1 }')
standalone_skill_hash=$(/usr/bin/shasum -a 256 "$standalone_skill/bin/scholar" | /usr/bin/awk '{ print $1 }')
if [[ "$source_hash" != "$cli_hash" || "$source_hash" != "$bundled_skill_hash" || "$source_hash" != "$standalone_skill_hash" ]]; then
  print -u2 "Packaged Scholar binaries do not match the signed source binary"
  exit 1
fi

/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$cli_package" "$cli_archive"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$standalone_skill" "$skill_archive"
(
  cd "$output_directory"
  /usr/bin/shasum -a 256 "${cli_archive:t}" > "${cli_archive:t}.sha256"
  /usr/bin/shasum -a 256 "${skill_archive:t}" > "${skill_archive:t}.sha256"
)
