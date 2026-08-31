#!/usr/bin/env bash

# Auto Script for GitHub Setup and Push
#
# Public commands:
#   ./g.sh
#   ./g.sh new
#   ./g.sh update
#   ./g.sh menu
#
# This file is the central dispatcher. The Bash modules in src/ contain the
# implementation and use only commands already required by the public tool.

set -uo pipefail

LANGUAGE_FIELD_PREFIX="language:"
THEME_FIELD_PREFIX="display-theme:"
HISTORY_TAGS_FIELD_PREFIX="add-tags-to-historical-release:"
SSH_BLOCK_PREFIX="github-auto"
INITIAL_COMMIT_MESSAGE="Initial commit"
DEFAULT_COMMIT_MESSAGE="Update"
RELEASE_PREFIX="Release "
UI_LANGUAGE="en"

ENGINE_SOURCE="${BASH_SOURCE[0]}"
ENGINE_DIRECTORY="$({ cd "$(dirname "$ENGINE_SOURCE")" 2>/dev/null && pwd -P; } || exit 1)"
ENGINE_NAME="$(basename "$ENGINE_SOURCE")"
ENGINE_PATH="$ENGINE_DIRECTORY/$ENGINE_NAME"
PRIVATE_DIRECTORY="${GIT_AUTO_PRIVATE_DIRECTORY:-$ENGINE_DIRECTORY/private}"
PRIVATE_CONFIG_FILE="$PRIVATE_DIRECTORY/config.txt"

if [ -n "${GIT_AUTO_PROJECT_ROOT:-}" ]; then
  SCRIPT_DIRECTORY="$({ cd "$GIT_AUTO_PROJECT_ROOT" 2>/dev/null && pwd -P; } || exit 1)"
else
  SCRIPT_DIRECTORY="$({ pwd -P; } || exit 1)"
fi
SCRIPT_NAME="${GIT_AUTO_LAUNCHER_NAME:-$ENGINE_NAME}"
RUNNING_FROM_LAUNCHER="${GIT_AUTO_LAUNCHER_ACTIVE:-0}"

GIT_AUTO_MODULES=(
  "00-core.sh"
  "10-ssh.sh"
  "20-repository.sh"
  "30-workflow.sh"
  "40-history.sh"
  "50-update.sh"
  "60-menu.sh"
)

for GIT_AUTO_MODULE in "${GIT_AUTO_MODULES[@]}"; do
  if [ ! -r "$ENGINE_DIRECTORY/src/$GIT_AUTO_MODULE" ]; then
    printf '%s\n' \
      "[Error] Required program module is missing: $ENGINE_DIRECTORY/src/$GIT_AUTO_MODULE" \
      "[错误] 缺少程序运行所需的模块：$ENGINE_DIRECTORY/src/$GIT_AUTO_MODULE" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$ENGINE_DIRECTORY/src/$GIT_AUTO_MODULE" || exit 1
done
unset GIT_AUTO_MODULE GIT_AUTO_MODULES

if [ "${GITHUB_AUTO_TESTING:-0}" != "1" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
