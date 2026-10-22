#!/bin/zsh
set -euo pipefail

script_directory=${0:A:h}

"$script_directory/test-core.sh"
"$script_directory/test-browser.sh"
