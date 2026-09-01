#!/usr/bin/env bash
# Auto Script for GitHub Setup and Push - lightweight project launcher.
# Managed git-auto project launcher. Copy this file into any project folder.

set -u

PROJECT_ROOT="$({ cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P; } || exit 1)"
DEFAULT_ENGINE_PATH=""

normalize_engine_path() {
  local candidate="${1:-}"
  local candidate_directory=""

  case "$candidate" in
    \"*\")
      candidate="${candidate#\"}"
      candidate="${candidate%\"}"
      ;;
    \'*\')
      candidate="${candidate#\'}"
      candidate="${candidate%\'}"
      ;;
  esac

  case "$candidate" in
    '~')
      candidate="${HOME:-}"
      ;;
    '~/'*)
      candidate="${HOME:-}/${candidate#\~/}"
      ;;
  esac

  if [ -d "$candidate" ]; then
    candidate="${candidate%/}/git-auto.sh"
  fi
  [ -f "$candidate" ] || return 1

  candidate_directory="$({ cd "$(dirname "$candidate")" 2>/dev/null && pwd -P; } || return 1)"
  printf '%s/%s' "$candidate_directory" "$(basename "$candidate")"
}

ENGINE_PATH="$(normalize_engine_path "${GIT_AUTO_ENGINE:-$DEFAULT_ENGINE_PATH}" 2>/dev/null || true)"

if [ ! -f "$ENGINE_PATH" ]; then
  SAVED_ENGINE="$(git -C "$PROJECT_ROOT" config --local --get github-auto.engine 2>/dev/null || true)"
  ENGINE_PATH="$(normalize_engine_path "$SAVED_ENGINE" 2>/dev/null || true)"
fi

if [ ! -f "$ENGINE_PATH" ] && [ -f "$PROJECT_ROOT/git-auto.sh" ]; then
  ENGINE_PATH="$PROJECT_ROOT/git-auto.sh"
fi

if [ ! -f "$ENGINE_PATH" ]; then
  printf '%s\n' 'Central git-auto.sh was not found. Paste the file path or its folder path below.' >&2
  printf '%s\n' '没有自动找到中央 git-auto.sh，请在下面粘贴该文件或其所在文件夹的路径。' >&2
  printf 'Path / 路径: ' >&2
  IFS= read -r ENGINE_INPUT || exit 1
  ENGINE_PATH="$(normalize_engine_path "$ENGINE_INPUT" 2>/dev/null || true)"
  if [ ! -f "$ENGINE_PATH" ]; then
    printf '%s\n' '[Error] No git-auto.sh file was found at the selected path.' >&2
    printf '%s\n' '[错误] 在所选路径中没有找到 git-auto.sh 文件。' >&2
    exit 1
  fi
fi

GIT_AUTO_PROJECT_ROOT="$PROJECT_ROOT"
GIT_AUTO_LAUNCHER_NAME="$(basename "${BASH_SOURCE[0]}")"
GIT_AUTO_LAUNCHER_ACTIVE=1
export GIT_AUTO_PROJECT_ROOT GIT_AUTO_LAUNCHER_NAME GIT_AUTO_LAUNCHER_ACTIVE
exec bash "$ENGINE_PATH" "$@"
