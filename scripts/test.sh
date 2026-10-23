#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}

(
  cd "$repository_root"
  PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest \
    Tests.SkillLauncherTests \
    Tests.SkillPackagingTests
)
"$script_directory/test-core.sh"
"$script_directory/test-browser.sh"
