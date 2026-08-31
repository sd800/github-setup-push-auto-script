#!/usr/bin/env bash
# Auto Script for GitHub Setup and Push - lightweight project launcher.
# Managed git-auto project launcher. Copy this file into any project folder.

set -u

PROJECT_ROOT="$({ cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P; } || exit 1)"
ENGINE_PATH="${GIT_AUTO_ENGINE:-}"

use_engine() {
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    ENGINE_PATH="$1"
    return 0
  fi
  return 1
}

if ! use_engine "$ENGINE_PATH"; then
  SAVED_ENGINE="$(git -C "$PROJECT_ROOT" config --local --get github-auto.engine 2>/dev/null || true)"
  use_engine "$SAVED_ENGINE" || true
fi

if ! use_engine "$ENGINE_PATH"; then
  use_engine "$PROJECT_ROOT/git-auto.sh" || true
fi

SEARCH_ROOT="$PROJECT_ROOT"
while ! use_engine "$ENGINE_PATH" && [ "$SEARCH_ROOT" != "/" ]; do
  use_engine "$SEARCH_ROOT/git-auto/git-auto.sh" || true
  PARENT_ROOT="$(dirname "$SEARCH_ROOT")"
  [ "$PARENT_ROOT" != "$SEARCH_ROOT" ] || break
  SEARCH_ROOT="$PARENT_ROOT"
done

if ! use_engine "$ENGINE_PATH" && [ -n "${HOME:-}" ]; then
  use_engine "$HOME/Documents/dev/git-auto/git-auto.sh" ||
    use_engine "$HOME/git-auto/git-auto.sh" || true
fi

if ! use_engine "$ENGINE_PATH"; then
  COMMAND_ENGINE="$(command -v git-auto.sh 2>/dev/null || true)"
  use_engine "$COMMAND_ENGINE" || true
fi

if ! use_engine "$ENGINE_PATH"; then
  printf '%s\n' 'Central git-auto.sh was not found. Paste its file path below.' >&2
  printf '%s\n' '没有自动找到中央 git-auto.sh，请在下面粘贴它的文件路径。' >&2
  printf 'git-auto.sh: ' >&2
  IFS= read -r ENGINE_PATH || exit 1
  ENGINE_PATH="${ENGINE_PATH#\"}"
  ENGINE_PATH="${ENGINE_PATH%\"}"
  if ! use_engine "$ENGINE_PATH"; then
    printf '%s\n' '[Error] The selected git-auto.sh file does not exist.' >&2
    printf '%s\n' '[错误] 选择的 git-auto.sh 文件不存在。' >&2
    exit 1
  fi
fi

GIT_AUTO_PROJECT_ROOT="$PROJECT_ROOT"
GIT_AUTO_LAUNCHER_NAME="$(basename "${BASH_SOURCE[0]}")"
GIT_AUTO_LAUNCHER_ACTIVE=1
export GIT_AUTO_PROJECT_ROOT GIT_AUTO_LAUNCHER_NAME GIT_AUTO_LAUNCHER_ACTIVE
exec bash "$ENGINE_PATH" "$@"
