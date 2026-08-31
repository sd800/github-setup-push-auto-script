#!/usr/bin/env bash

# Auto Script for GitHub Setup and Push
#
# Public commands:
#   ./g.sh
#   ./g.sh new
#   ./g.sh update
#   ./g.sh menu
#
# Compatible with the Bash 3.2 version included with macOS.

set -uo pipefail

LANGUAGE_FIELD_PREFIX="language:"
THEME_FIELD_PREFIX="display-theme:"
SSH_BLOCK_PREFIX="github-auto"
INITIAL_COMMIT_MESSAGE="Initial commit"
DEFAULT_COMMIT_MESSAGE="Update"
RELEASE_PREFIX="Release "
UI_LANGUAGE="en"

# -----------------------------------------------------------------------------
# Central engine, private configuration, and target project
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Small utilities
# -----------------------------------------------------------------------------

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  printf '%s' "$1" |
    sed -E \
      -e 's/^[[:space:]]+//' \
      -e 's/[[:space:]]+$//'
}

repeat_character() {
  local character="$1"
  local count="$2"
  local result=""

  while [ "$count" -gt 0 ]; do
    result="$result$character"
    count=$((count - 1))
  done

  printf '%s' "$result"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_interactive() {
  if [ ! -t 0 ]; then
    fail \
      "Run this command in an interactive terminal." \
      "请在交互式终端中运行这个命令。"
  fi
}

safe_mktemp_file() {
  local directory="$1"
  local prefix="$2"

  mktemp "$directory/.${prefix}.XXXXXX"
}

safe_mktemp_directory() {
  mktemp -d "${TMPDIR:-/tmp}/github-auto.XXXXXX"
}

ensure_private_config() {
  local temporary_file=""

  if ! mkdir -p "$PRIVATE_DIRECTORY" || ! chmod 700 "$PRIVATE_DIRECTORY"; then
    printf '%s\n' "[Error] Could not prepare the private configuration directory: $PRIVATE_DIRECTORY" >&2
    return 1
  fi

  if [ ! -f "$PRIVATE_CONFIG_FILE" ]; then
    temporary_file="$(safe_mktemp_file "$PRIVATE_DIRECTORY" "config")" || return 1
    {
      printf '# Auto Script for GitHub Setup and Push - private configuration\n'
      printf 'language:\n'
      printf 'display-theme: auto\n'
      printf '\n'
      printf '# GitHub accounts: one field per line, with a blank line between accounts.\n'
    } > "$temporary_file"
    chmod 600 "$temporary_file" || {
      rm -f "$temporary_file"
      return 1
    }
    mv "$temporary_file" "$PRIVATE_CONFIG_FILE" || {
      rm -f "$temporary_file"
      return 1
    }
  fi

  chmod 600 "$PRIVATE_CONFIG_FILE" || return 1
}

ensure_private_config || exit 1

file_mode() {
  local file="$1"

  if stat -f '%Lp' "$file" >/dev/null 2>&1; then
    stat -f '%Lp' "$file"
  else
    stat -c '%a' "$file"
  fi
}

human_path() {
  local path="$1"

  case "$path" in
    "${HOME:-}"/*)
      printf '~/%s' "${path#"${HOME:-}"/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

expand_home_path() {
  local path="$1"

  case "$path" in
    '~')
      printf '%s' "${HOME:-}"
      ;;
    '~/'*)
      printf '%s/%s' "${HOME:-}" "${path#\~/}"
      ;;
    '%d/'*)
      printf '%s/%s' "${HOME:-}" "${path#%d/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Theme and accessible colors
# -----------------------------------------------------------------------------

THEME="none"
COLOR_RESET=""
COLOR_HEADING=""
COLOR_INFO=""
COLOR_SUCCESS=""
COLOR_WARNING=""
COLOR_ERROR=""
COLOR_MUTED=""

read_saved_theme() {
  local line=""
  local value=""

  line="$(grep -m 1 -F "$THEME_FIELD_PREFIX" "$PRIVATE_CONFIG_FILE" 2>/dev/null || true)"
  value="$(trim "${line#"$THEME_FIELD_PREFIX"}")"
  value="$(lowercase "$value")"

  case "$value" in
    auto|dark|light|none)
      printf '%s' "$value"
      ;;
    *)
      printf 'auto'
      ;;
  esac
}

detect_automatic_theme() {
  local background=""
  local style=""

  if [ -n "${COLORFGBG:-}" ]; then
    background="${COLORFGBG##*;}"
    case "$background" in
      7|15)
        printf 'light'
        return
        ;;
      0|1|2|3|4|5|6|8)
        printf 'dark'
        return
        ;;
    esac
  fi

  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && command_exists defaults; then
    style="$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)"
    if [ "$(lowercase "$(trim "$style")")" = "dark" ]; then
      printf 'dark'
    else
      printf 'light'
    fi
    return
  fi

  # A conservative dark-terminal fallback is preferable to low-contrast blue.
  printf 'dark'
}

apply_theme() {
  local requested

  requested="${1:-auto}"

  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ] || [ ! -t 1 ]; then
    requested="none"
  elif [ "$requested" = "auto" ]; then
    requested="$(detect_automatic_theme)"
  fi

  THEME="$requested"
  COLOR_RESET='\033[0m'

  case "$THEME" in
    dark)
      COLOR_HEADING='\033[1;97m'
      COLOR_INFO='\033[1;96m'
      COLOR_SUCCESS='\033[1;92m'
      COLOR_WARNING='\033[1;93m'
      COLOR_ERROR='\033[1;91m'
      COLOR_MUTED='\033[0;37m'
      ;;
    light)
      COLOR_HEADING='\033[1;30m'
      COLOR_INFO='\033[0;34m'
      COLOR_SUCCESS='\033[0;32m'
      COLOR_WARNING='\033[0;35m'
      COLOR_ERROR='\033[0;31m'
      COLOR_MUTED='\033[0;90m'
      ;;
    *)
      THEME="none"
      COLOR_RESET=""
      COLOR_HEADING=""
      COLOR_INFO=""
      COLOR_SUCCESS=""
      COLOR_WARNING=""
      COLOR_ERROR=""
      COLOR_MUTED=""
      ;;
  esac
}

apply_theme "$(read_saved_theme)"

# -----------------------------------------------------------------------------
# Persistent interface language
# -----------------------------------------------------------------------------

read_saved_language() {
  local line=""
  local value=""

  line="$(grep -m 1 -F "$LANGUAGE_FIELD_PREFIX" "$PRIVATE_CONFIG_FILE" 2>/dev/null || true)"
  value="$(trim "${line#"$LANGUAGE_FIELD_PREFIX"}")"
  value="$(lowercase "$value")"

  case "$value" in
    en|zh)
      printf '%s' "$value"
      ;;
  esac
}

save_language_preference() {
  save_private_config "$1" "$(read_saved_theme)"
}

choose_interface_language() {
  local allow_return="${1:-no}"
  local choice=""
  local default_choice="1"

  [ "$UI_LANGUAGE" = "zh" ] && default_choice="2"
  printf '\n'
  print_colored "$COLOR_HEADING" "Choose interface language / 选择界面语言"
  printf '  1) English\n'
  printf '  2) 中文\n'
  if [ "$allow_return" = "yes" ]; then
    printf '  0) Return / 返回\n'
  fi

  while true; do
    choice="$(prompt_value "Language / 语言" "$default_choice")" || return 1
    case "$choice" in
      1)
        UI_LANGUAGE="en"
        break
        ;;
      2)
        UI_LANGUAGE="zh"
        break
        ;;
      0)
        if [ "$allow_return" = "yes" ]; then
          return 2
        fi
        ;;
    esac
    print_colored "$COLOR_WARNING" "[Notice / 注意] Enter a listed number / 请输入列表中的序号。"
  done

  if ! save_language_preference "$UI_LANGUAGE"; then
    print_colored "$COLOR_WARNING" "[Notice / 注意] The language preference could not be saved in private/config.txt / 无法把语言偏好保存到 private/config.txt。"
  fi
  return 0
}

initialize_language() {
  local saved_language=""

  saved_language="$(read_saved_language)"
  if [ -n "$saved_language" ]; then
    UI_LANGUAGE="$saved_language"
    return 0
  fi

  if [ -t 0 ] && [ -t 1 ]; then
    choose_interface_language no
  else
    UI_LANGUAGE="en"
  fi
}

INITIAL_SAVED_LANGUAGE="$(read_saved_language)"
if [ -n "$INITIAL_SAVED_LANGUAGE" ]; then
  UI_LANGUAGE="$INITIAL_SAVED_LANGUAGE"
fi
unset INITIAL_SAVED_LANGUAGE

localized_text() {
  local english_text="$1"
  local chinese_text="${2:-$1}"

  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '%s' "$chinese_text"
  else
    printf '%s' "$english_text"
  fi
}

print_colored() {
  local color="$1"
  local text="$2"
  local destination="${3:-stdout}"

  if [ "$destination" = "stderr" ]; then
    printf '%b%s%b\n' "$color" "$text" "$COLOR_RESET" >&2
  else
    printf '%b%s%b\n' "$color" "$text" "$COLOR_RESET"
  fi
}

heading() {
  printf '\n'
  print_colored "$COLOR_HEADING" "$(localized_text "$1" "${2:-$1}")"
}

info() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_INFO" "[信息] ${2:-$1}"
  else
    print_colored "$COLOR_INFO" "[Info] $1"
  fi
}

success() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_SUCCESS" "[完成] ${2:-$1}"
  else
    print_colored "$COLOR_SUCCESS" "[Done] $1"
  fi
}

warn() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_WARNING" "[注意] ${2:-$1}"
  else
    print_colored "$COLOR_WARNING" "[Notice] $1"
  fi
}

error_message() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    print_colored "$COLOR_ERROR" "[错误] ${2:-$1}" stderr
  else
    print_colored "$COLOR_ERROR" "[Error] $1" stderr
  fi
}

muted() {
  print_colored "$COLOR_MUTED" "$(localized_text "$1" "${2:-$1}")"
}

fail() {
  error_message "$1" "${2:-$1}"
  exit 1
}

ui_prompt_value() {
  local english_label="$1"
  local chinese_label="$2"
  local default_value="${3:-}"

  prompt_value "$(localized_text "$english_label" "$chinese_label")" "$default_value"
}

ui_prompt_yes_no() {
  local english_label="$1"
  local chinese_label="$2"
  local default_answer="${3:-yes}"

  prompt_yes_no "$(localized_text "$english_label" "$chinese_label")" "$default_answer"
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""

  if [ -n "$default_value" ]; then
    printf '%b%s [%s]: %b' "$COLOR_INFO" "$label" "$default_value" "$COLOR_RESET" >&2
  else
    printf '%b%s: %b' "$COLOR_INFO" "$label" "$COLOR_RESET" >&2
  fi

  IFS= read -r answer || return 1
  answer="$(trim "$answer")"

  if [ -z "$answer" ]; then
    answer="$default_value"
  fi

  printf '%s' "$answer"
}

prompt_yes_no() {
  local label="$1"
  local default_answer="${2:-yes}"
  local hint="[Y/n]"
  local answer=""

  if [ "$UI_LANGUAGE" = "zh" ]; then
    if [ "$default_answer" = "no" ]; then
      hint="[是/否，默认否]"
    else
      hint="[是/否，默认是]"
    fi
  elif [ "$default_answer" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '%b%s %s: %b' "$COLOR_INFO" "$label" "$hint" "$COLOR_RESET"
    IFS= read -r answer || return 1
    answer="$(lowercase "$(trim "$answer")")"

    if [ -z "$answer" ]; then
      [ "$default_answer" = "yes" ]
      return
    fi

    case "$answer" in
      y|yes|是|好|好的)
        return 0
        ;;
      n|no|否|不)
        return 1
        ;;
      *)
        warn \
          "Enter y or n. Press Enter to use the recommended option." \
          "请输入 y 或 n；直接按 Enter 使用推荐选项。"
        ;;
    esac
  done
}

pause_for_user() {
  local english_label="${1:-Press Enter to continue}"
  local chinese_label="${2:-按 Enter 继续}"
  local ignored=""

  printf '%b%s%b' "$COLOR_INFO" "$(localized_text "$english_label" "$chinese_label")" "$COLOR_RESET"
  IFS= read -r ignored || true
}

# -----------------------------------------------------------------------------
# Human-editable private configuration
# -----------------------------------------------------------------------------

ACCOUNT_USERNAMES=()
ACCOUNT_EMAILS=()
ACCOUNT_COUNT=0

valid_github_username() {
  local username="$1"

  if ! [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; then
    return 1
  fi

  case "$username" in
    *-)
      return 1
      ;;
  esac

  return 0
}

valid_email() {
  local email="$1"

  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

account_index() {
  local username_lc
  local index=0

  username_lc="$(lowercase "$1")"
  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    if [ "$(lowercase "${ACCOUNT_USERNAMES[$index]}")" = "$username_lc" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

append_loaded_account() {
  local username="$1"
  local email="$2"

  if ! valid_github_username "$username"; then
    fail \
      "Invalid GitHub username in the account list: $username" \
      "账号列表中的 GitHub 用户名无效：$username"
  fi

  if ! valid_email "$email"; then
    fail \
      "Invalid email for account $username: $email" \
      "账号 $username 的邮箱格式无效：$email"
  fi

  if account_index "$username" >/dev/null 2>&1; then
    fail \
      "Duplicate username in the account list: $username" \
      "账号列表中存在重复用户名：$username"
  fi

  ACCOUNT_USERNAMES[$ACCOUNT_COUNT]="$username"
  ACCOUNT_EMAILS[$ACCOUNT_COUNT]="$email"
  ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
}

load_accounts() {
  local line=""
  local content=""
  local value=""
  local pending_username=""
  local pending_email=""

  ACCOUNT_USERNAMES=()
  ACCOUNT_EMAILS=()
  ACCOUNT_COUNT=0

  while IFS= read -r line || [ -n "$line" ]; do
    content="$(trim "$line")"
    if [ -z "$content" ]; then
      if [ -n "$pending_username" ] || [ -n "$pending_email" ]; then
        if [ -z "$pending_username" ] || [ -z "$pending_email" ]; then
          fail \
            "An account entry is incomplete. Every account needs username and email." \
            "账号列表中有不完整的记录；每个账号都需要 username 和 email。"
        fi
        append_loaded_account "$pending_username" "$pending_email"
        pending_username=""
        pending_email=""
      fi
      continue
    fi

    case "$content" in
      \#*)
        continue
        ;;
      "$LANGUAGE_FIELD_PREFIX"*|"$THEME_FIELD_PREFIX"*)
        continue
        ;;
    esac

    case "$content" in
      username:*)
        value="$(trim "${content#username:}")"
        if [ -n "$pending_username" ]; then
          if [ -z "$pending_email" ]; then
            fail \
              "Account $pending_username is missing an email field in private/config.txt." \
              "private/config.txt 中的账号 $pending_username 缺少 email 字段。"
          fi
          append_loaded_account "$pending_username" "$pending_email"
          pending_email=""
        fi
        pending_username="$value"
        ;;
      email:*)
        value="$(trim "${content#email:}")"
        if [ -n "$pending_email" ]; then
          fail \
            "An account entry in private/config.txt contains more than one email field." \
            "private/config.txt 的同一条账号记录中出现了重复的 email 字段。"
        fi
        pending_email="$value"
        ;;
      *)
        fail \
          "Unrecognized field in private/config.txt: $content" \
          "private/config.txt 中存在无法识别的字段：$content"
        ;;
    esac
  done < "$PRIVATE_CONFIG_FILE"

  if [ -n "$pending_username" ] || [ -n "$pending_email" ]; then
    if [ -z "$pending_username" ] || [ -z "$pending_email" ]; then
      fail \
        "An account entry in private/config.txt is incomplete. Every account needs username and email." \
        "private/config.txt 中有不完整的账号记录；每个账号都需要 username 和 email。"
    fi
    append_loaded_account "$pending_username" "$pending_email"
  fi
}

account_email() {
  local index

  if index="$(account_index "$1")"; then
    printf '%s' "${ACCOUNT_EMAILS[$index]}"
    return 0
  fi

  return 1
}

add_or_update_account() {
  local username="$1"
  local email="$2"
  local index

  if index="$(account_index "$username")"; then
    ACCOUNT_USERNAMES[$index]="$username"
    ACCOUNT_EMAILS[$index]="$email"
  else
    ACCOUNT_USERNAMES[$ACCOUNT_COUNT]="$username"
    ACCOUNT_EMAILS[$ACCOUNT_COUNT]="$email"
    ACCOUNT_COUNT=$((ACCOUNT_COUNT + 1))
  fi
}

save_private_config() {
  local language_value="${1:-$(read_saved_language)}"
  local theme_value="${2:-$(read_saved_theme)}"
  local temporary_file=""
  local index=0

  ensure_private_config || return 1
  temporary_file="$(safe_mktemp_file "$PRIVATE_DIRECTORY" "config")" || return 1
  {
    printf '# Auto Script for GitHub Setup and Push - private configuration\n'
    printf 'language: %s\n' "$language_value"
    printf 'display-theme: %s\n' "$theme_value"
    printf '\n'
    printf '# GitHub accounts: one field per line, with a blank line between accounts.\n'
    while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
      printf 'username: %s\n' "${ACCOUNT_USERNAMES[$index]}"
      printf 'email: %s\n' "${ACCOUNT_EMAILS[$index]}"
      if [ $((index + 1)) -lt "$ACCOUNT_COUNT" ]; then
        printf '\n'
      fi
      index=$((index + 1))
    done
  } > "$temporary_file"

  chmod 600 "$temporary_file" || {
    rm -f "$temporary_file"
    return 1
  }
  if ! mv "$temporary_file" "$PRIVATE_CONFIG_FILE"; then
    rm -f "$temporary_file"
    return 1
  fi
  return 0
}

write_accounts_to_private_config() {
  if ! save_private_config "$(read_saved_language)" "$(read_saved_theme)"; then
    fail \
      "The account list could not be saved in private/config.txt." \
      "无法把账号列表保存到 private/config.txt。"
  fi
}

list_accounts_compact() {
  local index=0

  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    printf '  %s) %s\n' "$((index + 1))" "${ACCOUNT_USERNAMES[$index]}"
    index=$((index + 1))
  done
}

select_account() {
  local english_prompt="${1:-Choose a GitHub account}"
  local chinese_prompt="${2:-选择 GitHub 账号}"
  local answer=""
  local index=0

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    return 1
  fi

  if [ "$ACCOUNT_COUNT" -eq 1 ]; then
    SELECTED_USERNAME="${ACCOUNT_USERNAMES[0]}"
    SELECTED_EMAIL="${ACCOUNT_EMAILS[0]}"
    return 0
  fi

  heading "$english_prompt" "$chinese_prompt"
  list_accounts_compact

  while true; do
    answer="$(ui_prompt_value "Enter a number" "输入序号" "1")" || return 1
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$ACCOUNT_COUNT" ]; then
      index=$((answer - 1))
      SELECTED_USERNAME="${ACCOUNT_USERNAMES[$index]}"
      SELECTED_EMAIL="${ACCOUNT_EMAILS[$index]}"
      return 0
    fi
    warn "Enter a number from the list." "请输入列表中的序号。"
  done
}

load_accounts

# -----------------------------------------------------------------------------
# SSH discovery and identity isolation
# -----------------------------------------------------------------------------

SSH_DIRECTORY="${HOME:-}/.ssh"
SSH_CONFIG_FILE="$SSH_DIRECTORY/config"
DISCOVERED_SSH_ALIASES=()
DISCOVERED_SSH_ALIAS_COUNT=0
SSH_SCAN_DIRECTORY=""
SSH_SCAN_SEEN_FILE=""
SSH_SCAN_ALIAS_FILE=""

ensure_home_available() {
  if [ -z "${HOME:-}" ]; then
    fail \
      "The user home directory (HOME) could not be determined." \
      "无法确定用户目录（HOME）。"
  fi
}

canonical_existing_file() {
  local file="$1"
  local directory

  directory="$({ cd "$(dirname "$file")" 2>/dev/null && pwd -P; } || return 1)"
  printf '%s/%s' "$directory" "$(basename "$file")"
}

strip_optional_quotes() {
  local value="$1"

  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac

  printf '%s' "$value"
}

collect_ssh_config_file() {
  local requested_file="$1"
  local file=""
  local line=""
  local cleaned=""
  local directive=""
  local remainder=""
  local directive_lc=""
  local token=""
  local pattern=""
  local match=""
  local alias=""
  local include_tokens=()
  local host_tokens=()

  [ -f "$requested_file" ] || return 0
  file="$(canonical_existing_file "$requested_file")" || return 0

  if grep -Fqx "$file" "$SSH_SCAN_SEEN_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$file" >> "$SSH_SCAN_SEEN_FILE"

  while IFS= read -r line || [ -n "$line" ]; do
    cleaned="$(trim "${line%%#*}")"
    [ -n "$cleaned" ] || continue

    directive="${cleaned%%[[:space:]]*}"
    if [ "$directive" = "$cleaned" ]; then
      remainder=""
    else
      remainder="${cleaned#"$directive"}"
      remainder="$(trim "$remainder")"
    fi
    directive_lc="$(lowercase "$directive")"

    case "$directive_lc" in
      include)
        include_tokens=()
        read -r -a include_tokens <<< "$remainder"
        for token in "${include_tokens[@]}"; do
          token="$(strip_optional_quotes "$token")"
          case "$token" in
            '~/'*)
              pattern="${HOME:-}/${token#\~/}"
              ;;
            /*)
              pattern="$token"
              ;;
            *)
              pattern="$SSH_DIRECTORY/$token"
              ;;
          esac

          while IFS= read -r match; do
            [ -n "$match" ] || continue
            collect_ssh_config_file "$match"
          done < <(compgen -G "$pattern" 2>/dev/null || true)
        done
        ;;
      host)
        host_tokens=()
        read -r -a host_tokens <<< "$remainder"
        for alias in "${host_tokens[@]}"; do
          case "$alias" in
            *'*'*|*'?'*|*'!'*|'')
              continue
              ;;
          esac
          printf '%s\n' "$alias" >> "$SSH_SCAN_ALIAS_FILE"
        done
        ;;
    esac
  done < "$file"
}

scan_ssh_aliases() {
  local alias=""

  DISCOVERED_SSH_ALIASES=()
  DISCOVERED_SSH_ALIAS_COUNT=0

  [ -f "$SSH_CONFIG_FILE" ] || return 0

  SSH_SCAN_DIRECTORY="$(safe_mktemp_directory)" || return 1
  SSH_SCAN_SEEN_FILE="$SSH_SCAN_DIRECTORY/seen"
  SSH_SCAN_ALIAS_FILE="$SSH_SCAN_DIRECTORY/aliases"
  : > "$SSH_SCAN_SEEN_FILE"
  : > "$SSH_SCAN_ALIAS_FILE"

  collect_ssh_config_file "$SSH_CONFIG_FILE"

  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    DISCOVERED_SSH_ALIASES[$DISCOVERED_SSH_ALIAS_COUNT]="$alias"
    DISCOVERED_SSH_ALIAS_COUNT=$((DISCOVERED_SSH_ALIAS_COUNT + 1))
  done < <(sort -fu "$SSH_SCAN_ALIAS_FILE")

  rm -rf "$SSH_SCAN_DIRECTORY"
  SSH_SCAN_DIRECTORY=""
}

ssh_alias_exists() {
  local candidate_lc
  local index=0

  candidate_lc="$(lowercase "$1")"
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    if [ "$(lowercase "${DISCOVERED_SSH_ALIASES[$index]}")" = "$candidate_lc" ]; then
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

ssh_effective_value() {
  local alias="$1"
  local key="$2"
  local config_file="$SSH_CONFIG_FILE"

  if [ ! -f "$config_file" ]; then
    config_file="/dev/null"
  fi

  ssh -F "$config_file" -G "$alias" 2>/dev/null |
    awk -v wanted="$(lowercase "$key")" '
      tolower($1) == wanted {
        $1 = ""
        sub(/^[[:space:]]+/, "")
        print
        exit
      }
    '
}

ssh_alias_is_github() {
  local hostname

  hostname="$(ssh_effective_value "$1" hostname)"
  [ "$(lowercase "$hostname")" = "github.com" ]
}

resolve_alias_identity_file() {
  local alias="$1"
  local line=""
  local path=""
  local first_path=""
  local config_file="$SSH_CONFIG_FILE"

  if [ ! -f "$config_file" ]; then
    config_file="/dev/null"
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="$(expand_home_path "$line")"
    path="${path//%d/${HOME:-}}"
    if [ -z "$first_path" ]; then
      first_path="$path"
    fi
    if [ -f "$path" ]; then
      printf '%s' "$path"
      return 0
    fi
  done < <(
    ssh -F "$config_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print }'
  )

  if [ -n "$first_path" ]; then
    printf '%s' "$first_path"
  fi
  return 1
}

key_fingerprint() {
  local private_key="$1"
  local public_key="${private_key}.pub"

  if [ -f "$public_key" ]; then
    ssh-keygen -lf "$public_key" 2>/dev/null |
      awk '{ print $2; exit }'
    return
  fi

  return 1
}

identify_key_username() {
  local private_key="$1"
  local output=""
  local username=""

  VERIFIED_GITHUB_USERNAME=""
  SSH_VERIFICATION_OUTPUT=""

  if [ ! -f "$private_key" ]; then
    return 1
  fi

  output="$(
    ssh \
      -T \
      -F /dev/null \
      -o HostName=github.com \
      -o User=git \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o ConnectTimeout=12 \
      -i "$private_key" \
      github.com \
      2>&1
  )" || true

  username="$(
    printf '%s\n' "$output" |
      sed -nE 's/^Hi ([^!]+)!.*/\1/p' |
      sed -n '1p'
  )"

  if [ -n "$username" ]; then
    VERIFIED_GITHUB_USERNAME="$username"
    return 0
  fi

  SSH_VERIFICATION_OUTPUT="$output"
  return 1
}

verify_key_matches_username() {
  local private_key="$1"
  local expected_username="$2"

  info \
    "Asking GitHub which account accepts this exact SSH private key; saved account and repository settings will not be changed." \
    "正在用这把指定的 SSH 私钥向 GitHub 核对账号；这一步不会修改已保存账号或仓库设置。"
  if ! identify_key_username "$private_key"; then
    error_message \
      "GitHub did not accept the private key $(human_path "$private_key") for SSH authentication." \
      "GitHub 没有接受私钥 $(human_path "$private_key") 的 SSH 身份验证。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted "${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi

  if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" != "$(lowercase "$expected_username")" ]; then
    error_message \
      "This key belongs to ${VERIFIED_GITHUB_USERNAME}, not ${expected_username}." \
      "这个密钥实际属于 ${VERIFIED_GITHUB_USERNAME}，并不是 ${expected_username}。"
    return 1
  fi

  success \
    "GitHub confirmed that this key belongs to account $VERIFIED_GITHUB_USERNAME." \
    "GitHub 已确认这把密钥属于账号 ${VERIFIED_GITHUB_USERNAME}。"
  return 0
}

FOUND_SSH_ALIAS=""
FOUND_IDENTITY_FILE=""
FOUND_UNVERIFIED_SSH_ALIAS=""
FOUND_UNVERIFIED_IDENTITY_FILE=""

find_verified_identity_for_username() {
  local username="$1"
  local preferred_alias="${2:-}"
  local alias=""
  local key=""
  local index=0
  local passes=0
  local canonical_key=""
  local checked_keys="|"

  FOUND_SSH_ALIAS=""
  FOUND_IDENTITY_FILE=""
  FOUND_UNVERIFIED_SSH_ALIAS=""
  FOUND_UNVERIFIED_IDENTITY_FILE=""

  scan_ssh_aliases || return 1

  # Prefer the repository's saved alias, then aliases named after the account.
  while [ "$passes" -lt 3 ]; do
    index=0
    while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
      alias="${DISCOVERED_SSH_ALIASES[$index]}"
      index=$((index + 1))

      case "$passes" in
        0)
          [ -n "$preferred_alias" ] &&
            [ "$(lowercase "$alias")" = "$(lowercase "$preferred_alias")" ] || continue
          ;;
        1)
          case "$(lowercase "$alias")" in
            "github-$(lowercase "$username")"|"github-$(lowercase "$username")-"[0-9]*)
              ;;
            *)
              continue
              ;;
          esac
          ;;
        2)
          ;;
      esac

      ssh_alias_is_github "$alias" || continue
      key="$(resolve_alias_identity_file "$alias" || true)"
      [ -f "$key" ] || continue
      canonical_key="$(canonical_existing_file "$key" || true)"
      [ -n "$canonical_key" ] || continue
      case "$checked_keys" in
        *"|$canonical_key|"*)
          continue
          ;;
      esac
      checked_keys="${checked_keys}${canonical_key}|"

      if identify_key_username "$key" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
        FOUND_SSH_ALIAS="$alias"
        FOUND_IDENTITY_FILE="$key"
        return 0
      fi
      if [ -z "$VERIFIED_GITHUB_USERNAME" ] &&
         [ -z "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
        FOUND_UNVERIFIED_SSH_ALIAS="$alias"
        FOUND_UNVERIFIED_IDENTITY_FILE="$key"
      fi
    done
    passes=$((passes + 1))
  done

  return 1
}

find_github_alias_for_identity_file() {
  local identity_file="$1"
  local preferred_alias="${2:-}"
  local canonical_identity=""
  local canonical_candidate=""
  local alias=""
  local candidate_key=""
  local index=0
  local pass=0

  FOUND_SSH_ALIAS=""
  canonical_identity="$(canonical_existing_file "$identity_file" || true)"
  [ -n "$canonical_identity" ] || return 1
  scan_ssh_aliases || return 1

  while [ "$pass" -lt 2 ]; do
    index=0
    while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
      alias="${DISCOVERED_SSH_ALIASES[$index]}"
      index=$((index + 1))

      if [ "$pass" -eq 0 ]; then
        [ -n "$preferred_alias" ] &&
          [ "$(lowercase "$alias")" = "$(lowercase "$preferred_alias")" ] || continue
      fi

      ssh_alias_is_github "$alias" || continue
      candidate_key="$(resolve_alias_identity_file "$alias" || true)"
      canonical_candidate="$(canonical_existing_file "$candidate_key" || true)"
      if [ -n "$canonical_candidate" ] &&
         [ "$canonical_candidate" = "$canonical_identity" ]; then
        FOUND_SSH_ALIAS="$alias"
        return 0
      fi
    done
    pass=$((pass + 1))
  done

  return 1
}

next_available_alias() {
  local username_lc
  local base=""
  local candidate=""
  local suffix=0
  local key_path=""

  username_lc="$(lowercase "$1")"
  base="github-$username_lc"
  candidate="$base"

  scan_ssh_aliases || return 1

  while true; do
    key_path="$SSH_DIRECTORY/id_ed25519_$candidate"
    if ! ssh_alias_exists "$candidate" &&
       [ ! -e "$key_path" ] &&
       [ ! -e "${key_path}.pub" ]; then
      NEW_SSH_ALIAS="$candidate"
      NEW_IDENTITY_FILE="$key_path"
      return 0
    fi
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
}

ensure_ssh_storage() {
  ensure_home_available

  if [ ! -d "$SSH_DIRECTORY" ]; then
    mkdir -p "$SSH_DIRECTORY" || fail \
      "Could not create $(human_path "$SSH_DIRECTORY")." \
      "无法创建 $(human_path "$SSH_DIRECTORY")。"
  fi
  chmod 700 "$SSH_DIRECTORY" || fail \
    "Could not secure the SSH directory permissions." \
    "无法设置 SSH 目录的安全权限。"

  if [ ! -f "$SSH_CONFIG_FILE" ]; then
    : > "$SSH_CONFIG_FILE" || fail \
      "Could not create the SSH configuration file." \
      "无法创建 SSH 配置文件。"
  fi
  chmod 600 "$SSH_CONFIG_FILE" || fail \
    "Could not secure the SSH configuration file permissions." \
    "无法设置 SSH 配置文件的安全权限。"
}

install_ssh_alias_block() {
  local username="$1"
  local alias="$2"
  local private_key="$3"
  local temporary_file=""
  local display_key=""
  local resolved_hostname=""
  local resolved_identity=""

  ensure_ssh_storage
  temporary_file="$(safe_mktemp_file "$SSH_DIRECTORY" "config")" ||
    fail \
      "A temporary SSH configuration file could not be created." \
      "无法创建 SSH 配置临时文件。"

  display_key="$(human_path "$private_key")"

  {
    printf '# >>> %s:%s >>>\n' "$SSH_BLOCK_PREFIX" "$username"
    printf 'Host %s\n' "$alias"
    printf '    HostName github.com\n'
    printf '    User git\n'
    printf '    IdentityFile %s\n' "$display_key"
    printf '    IdentitiesOnly yes\n'
    printf '    AddKeysToAgent yes\n'
    if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
      printf '    UseKeychain yes\n'
    fi
    printf '# <<< %s:%s <<<\n\n' "$SSH_BLOCK_PREFIX" "$username"
    if [ -s "$SSH_CONFIG_FILE" ]; then
      sed -n '1,$p' "$SSH_CONFIG_FILE"
    fi
  } >> "$temporary_file"

  chmod 600 "$temporary_file" || {
    rm -f "$temporary_file"
    fail \
      "Could not secure the new SSH configuration." \
      "无法设置新 SSH 配置的安全权限。"
  }

  resolved_hostname="$(
    ssh -F "$temporary_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "hostname" { print $2; exit }'
  )"
  resolved_identity="$(
    ssh -F "$temporary_file" -G "$alias" 2>/dev/null |
      awk 'tolower($1) == "identityfile" { $1=""; sub(/^[[:space:]]+/, ""); print; exit }'
  )"

  if [ "$(lowercase "$resolved_hostname")" != "github.com" ] || [ -z "$resolved_identity" ]; then
    rm -f "$temporary_file"
    fail \
      "The new SSH configuration failed validation. The original configuration was kept." \
      "新的 SSH 配置没有通过验证，原配置保持不变。"
  fi

  mv "$temporary_file" "$SSH_CONFIG_FILE" || {
    rm -f "$temporary_file"
    fail \
      "The SSH configuration could not be saved." \
      "无法保存 SSH 配置。"
  }
}

try_add_key_to_agent() {
  local private_key="$1"

  [ -n "${SSH_AUTH_SOCK:-}" ] || return 0
  command_exists ssh-add || return 0

  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
    ssh-add --apple-use-keychain "$private_key" >/dev/null 2>&1 ||
      ssh-add "$private_key" >/dev/null 2>&1 || true
  else
    ssh-add "$private_key" >/dev/null 2>&1 || true
  fi
}

copy_public_key() {
  local public_key="$1"

  if command_exists pbcopy; then
    pbcopy < "$public_key"
    return 0
  fi
  if command_exists wl-copy; then
    wl-copy < "$public_key"
    return 0
  fi
  if command_exists xclip; then
    xclip -selection clipboard < "$public_key"
    return 0
  fi

  return 1
}

open_github_key_page() {
  local url="https://github.com/settings/ssh/new"

  if [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && command_exists open; then
    open "$url" >/dev/null 2>&1 || true
  elif command_exists xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

create_new_identity() {
  local username="$1"
  local email="$2"
  local public_key=""

  ensure_ssh_storage
  next_available_alias "$username" || fail \
    "An unused SSH Host name and key filename could not be selected." \
    "无法为新密钥找到不冲突的 SSH 主机名和文件名。"

  heading "Create a GitHub SSH key" "创建 GitHub SSH 密钥"
  muted "GitHub account: $username" "GitHub 账号：$username"
  muted \
    "New private key: $(human_path "$NEW_IDENTITY_FILE")" \
    "新私钥位置：$(human_path "$NEW_IDENTITY_FILE")"
  muted \
    "New SSH Host entry: $NEW_SSH_ALIAS -> github.com" \
    "将写入 SSH 主机配置：$NEW_SSH_ALIAS -> github.com"
  muted \
    "ssh-keygen will ask for an optional key passphrase twice. Press Enter twice to create the key without a passphrase." \
    "接下来 ssh-keygen 会连续两次询问密钥口令；如果不需要口令，请连续按两次 Enter。"

  if ! ssh-keygen -t ed25519 -C "$email" -f "$NEW_IDENTITY_FILE"; then
    fail "The key was not created." "密钥创建未完成。"
  fi
  chmod 600 "$NEW_IDENTITY_FILE" || true
  chmod 644 "${NEW_IDENTITY_FILE}.pub" || true

  install_ssh_alias_block "$username" "$NEW_SSH_ALIAS" "$NEW_IDENTITY_FILE"
  try_add_key_to_agent "$NEW_IDENTITY_FILE"

  public_key="${NEW_IDENTITY_FILE}.pub"
  heading "Add the public key to the correct GitHub account" "把公钥添加到正确的 GitHub 账号"
  if copy_public_key "$public_key"; then
    success "The public key was copied to the clipboard." "公钥已复制到剪贴板。"
  else
    muted "Copy the complete line below:" "请复制下面这一整行："
    sed -n '1p' "$public_key"
  fi
  muted \
    "Make sure the browser is signed in as ${username}, then paste and save the key." \
    "请确认浏览器登录的是 GitHub 账号 ${username}，然后粘贴并保存密钥。"
  muted \
    "Use this computer's name for Title if helpful, and keep Key type as Authentication Key." \
    "Title 可以填写这台电脑的名称，Key type 保持 Authentication Key。"

  if ui_prompt_yes_no \
    "Open GitHub's Add SSH key page now?" \
    "现在打开 GitHub 的 SSH 密钥添加页面？" \
    "yes"; then
    open_github_key_page
  else
    muted \
      "Open: https://github.com/settings/ssh/new" \
      "请打开：https://github.com/settings/ssh/new"
  fi

  pause_for_user \
    "After saving the key on GitHub, press Enter to verify: " \
    "在 GitHub 保存密钥后，按 Enter 开始验证："

  while ! verify_key_matches_username "$NEW_IDENTITY_FILE" "$username"; do
    warn \
      "Make sure the public key was added to the correct GitHub account." \
      "请确认公钥添加到了正确的 GitHub 账号。"
    if ! ui_prompt_yes_no \
      "Verify the same key with GitHub again?" \
      "完成检查后，要再次用同一把密钥向 GitHub 核对账号吗？" \
      "yes"; then
      return 1
    fi
  done

  FOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
  FOUND_IDENTITY_FILE="$NEW_IDENTITY_FILE"
  success \
    "GitHub confirmed that the new key belongs to account $username." \
    "GitHub 已确认这把新密钥属于账号 ${username}。"
  return 0
}

VERIFIED_IDENTITY_USERNAMES=()
VERIFIED_IDENTITY_ALIASES=()
VERIFIED_IDENTITY_FILES=()
VERIFIED_IDENTITY_COUNT=0

verified_identity_index() {
  local username_lc
  local index=0

  username_lc="$(lowercase "$1")"
  while [ "$index" -lt "$VERIFIED_IDENTITY_COUNT" ]; do
    if [ "$(lowercase "${VERIFIED_IDENTITY_USERNAMES[$index]}")" = "$username_lc" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

discover_verified_github_identities() {
  local alias=""
  local key=""
  local canonical_key=""
  local checked_keys="|"
  local index=0

  VERIFIED_IDENTITY_USERNAMES=()
  VERIFIED_IDENTITY_ALIASES=()
  VERIFIED_IDENTITY_FILES=()
  VERIFIED_IDENTITY_COUNT=0

  scan_ssh_aliases || return 1
  [ "$DISCOVERED_SSH_ALIAS_COUNT" -gt 0 ] || return 0

  heading \
    "Find GitHub accounts on this computer" \
    "查找这台电脑上的 GitHub 账号"

  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))

    ssh_alias_is_github "$alias" || continue
    key="$(resolve_alias_identity_file "$alias" || true)"
    [ -f "$key" ] || continue
    canonical_key="$(canonical_existing_file "$key" || true)"
    [ -n "$canonical_key" ] || continue
    case "$checked_keys" in
      *"|$canonical_key|"*)
        continue
        ;;
    esac
    checked_keys="${checked_keys}${canonical_key}|"

    muted \
      "Asking GitHub which account accepts key $(human_path "$key") from SSH Host $alias; saved account and repository settings will not be changed." \
      "正在核对 SSH 主机名 $alias 指定的密钥 $(human_path "$key") 对应哪个 GitHub 账号；这一步不会修改已保存账号或仓库设置。"
    if identify_key_username "$key"; then
      if ! verified_identity_index "$VERIFIED_GITHUB_USERNAME" >/dev/null 2>&1; then
        VERIFIED_IDENTITY_USERNAMES[$VERIFIED_IDENTITY_COUNT]="$VERIFIED_GITHUB_USERNAME"
        VERIFIED_IDENTITY_ALIASES[$VERIFIED_IDENTITY_COUNT]="$alias"
        VERIFIED_IDENTITY_FILES[$VERIFIED_IDENTITY_COUNT]="$key"
        VERIFIED_IDENTITY_COUNT=$((VERIFIED_IDENTITY_COUNT + 1))
        success \
          "Found GitHub account: $VERIFIED_GITHUB_USERNAME" \
          "发现 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
      fi
    fi
  done

  if [ "$VERIFIED_IDENTITY_COUNT" -eq 0 ]; then
    muted \
      "GitHub did not accept any SSH private key referenced by the scanned SSH configuration." \
      "在已扫描的 SSH 配置中，GitHub 没有接受其中引用的任何私钥。"
  fi
}

default_email_for_username() {
  local username="$1"
  local configured=""
  local response=""
  local account_id=""
  local canonical_login=""

  configured="$(account_email "$username" 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    printf '%s' "$configured"
    return
  fi

  # GitHub's current private commit address uses public account ID + login.
  # The public REST endpoint avoids asking users to find that ID manually.
  if command_exists curl && [ "${GITHUB_AUTO_TESTING:-0}" != "1" ]; then
    response="$(
      curl \
        -fsSL \
        --connect-timeout 5 \
        --max-time 10 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: auto-script-for-github-setup-and-push' \
        "https://api.github.com/users/$username" \
        2>/dev/null
    )" || true
    account_id="$(
      printf '%s\n' "$response" |
        sed -nE 's/^[[:space:]]*"id":[[:space:]]*([0-9]+),?.*$/\1/p' |
        sed -n '1p'
    )"
    canonical_login="$(
      printf '%s\n' "$response" |
        sed -nE 's/^[[:space:]]*"login":[[:space:]]*"([^"]+)",?.*$/\1/p' |
        sed -n '1p'
    )"
    if [ -n "$account_id" ] && [ -n "$canonical_login" ] &&
       [ "$(lowercase "$canonical_login")" = "$(lowercase "$username")" ]; then
      printf '%s+%s@users.noreply.github.com' "$account_id" "$canonical_login"
      return
    fi
  fi

  printf '%s@users.noreply.github.com' "$(lowercase "$username")"
}

prompt_account_email() {
  local username="$1"
  local default_email=""
  local email=""

  default_email="$(default_email_for_username "$username")"

  while true; do
    email="$(ui_prompt_value "Commit email" "提交邮箱" "$default_email")" || return 1
    if valid_email "$email"; then
      printf '%s' "$email"
      return 0
    fi
    warn "Enter a valid email address." "这个邮箱地址无法识别，请重新输入。"
  done
}

prompt_github_username() {
  local username=""

  while true; do
    username="$(ui_prompt_value "GitHub username, or :cancel to stop" "GitHub 用户名；如需停止，请输入 :cancel")" || return 1
    username="$(lowercase "$username")"
    if [ "$username" = ":cancel" ]; then
      return 2
    fi
    if valid_github_username "$username"; then
      printf '%s' "$username"
      return 0
    fi
    warn \
      "A GitHub username normally contains only letters, numbers, and hyphens." \
      "GitHub 用户名通常只包含字母、数字和连字符，请重新输入。"
  done
}

register_account_and_identity() {
  local username="$1"
  local email="$2"
  local alias="$3"
  local private_key="$4"

  add_or_update_account "$username" "$email"
  write_accounts_to_private_config

  SELECTED_USERNAME="$username"
  SELECTED_EMAIL="$email"
  FOUND_SSH_ALIAS="$alias"
  FOUND_IDENTITY_FILE="$private_key"

  success \
    "Saved account $username and its commit email after GitHub verified the SSH key." \
    "GitHub 核对 SSH 密钥成功后，已保存账号 $username 及其提交邮箱。"
}

setup_or_reuse_account() {
  local username="$1"
  local email="$2"
  local identity_index=""
  local detail=""

  if identity_index="$(verified_identity_index "$username")"; then
    register_account_and_identity \
      "${VERIFIED_IDENTITY_USERNAMES[$identity_index]}" \
      "$email" \
      "${VERIFIED_IDENTITY_ALIASES[$identity_index]}" \
      "${VERIFIED_IDENTITY_FILES[$identity_index]}"
    return 0
  fi

  if find_verified_identity_for_username "$username"; then
    register_account_and_identity "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
    return 0
  fi

  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "The existing key $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") could not be confirmed for account $username." \
      "暂时无法确认现有密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") 是否属于账号 ${username}。"
    detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "SSH result: $detail" "SSH 返回信息：$detail"
    fi
    muted \
      "This can mean the network cannot reach GitHub, or that the key has not been added to this account." \
      "这通常表示当前网络无法连接 GitHub，或这把密钥的公钥尚未添加到该账号。"
    if ui_prompt_yes_no \
      "Verify this existing key again before creating another key?" \
      "要先重新验证这把现有密钥，再决定是否新建密钥吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
        register_account_and_identity \
          "$username" \
          "$email" \
          "$FOUND_UNVERIFIED_SSH_ALIAS" \
          "$FOUND_UNVERIFIED_IDENTITY_FILE"
        return 0
      fi
      warn \
        "GitHub still did not confirm this key for account $username." \
        "GitHub 仍未确认这把密钥属于账号 ${username}。"
    fi
  fi

  next_available_alias "$username" || return 1
  heading "Create a separate SSH key" "创建独立的 SSH 密钥"
  muted \
    "If you continue, the script will create $(human_path "$NEW_IDENTITY_FILE") and add SSH Host $NEW_SSH_ALIAS to ~/.ssh/config. Existing keys and Host entries will not be replaced." \
    "如果继续，脚本会创建 $(human_path "$NEW_IDENTITY_FILE")，并在 ~/.ssh/config 中加入 SSH 主机名 ${NEW_SSH_ALIAS}；现有密钥和主机配置不会被替换。"
  if ! ui_prompt_yes_no \
    "Create and configure this key for account $username now?" \
    "现在为账号 $username 创建并配置这把密钥吗？" \
    "yes"; then
    warn \
      "Stopped before creating a key or saving account $username." \
      "操作已停止；没有创建新密钥，也没有保存账号 ${username}。"
    return 1
  fi

  if create_new_identity "$username" "$email"; then
    register_account_and_identity "$username" "$email" "$FOUND_SSH_ALIAS" "$FOUND_IDENTITY_FILE"
    return 0
  fi

  return 1
}

run_account_setup() {
  local index=0
  local username=""
  local email=""
  local imported=false

  require_interactive
  ensure_home_available

  heading "Add a GitHub account" "添加 GitHub 账号"
  muted \
    "The script first checks SSH keys already referenced by ~/.ssh/config and reuses a key only when GitHub confirms its exact username." \
    "脚本会先检查 ~/.ssh/config 中已经引用的密钥；只有 GitHub 返回的用户名完全一致时，才会沿用现有密钥。"

  discover_verified_github_identities || true

  while [ "$index" -lt "$VERIFIED_IDENTITY_COUNT" ]; do
    username="${VERIFIED_IDENTITY_USERNAMES[$index]}"
    if ! account_index "$username" >/dev/null 2>&1; then
      if ui_prompt_yes_no \
        "Save account $username and its commit email in private/config.txt, and reuse its verified SSH key?" \
        "要把账号 $username 和提交邮箱保存到 private/config.txt，并沿用刚刚验证通过的 SSH 密钥吗？" \
        "yes"; then
        email="$(prompt_account_email "$username")" || return 1
        add_or_update_account "$username" "$email"
        SELECTED_USERNAME="$username"
        SELECTED_EMAIL="$email"
        FOUND_SSH_ALIAS="${VERIFIED_IDENTITY_ALIASES[$index]}"
        FOUND_IDENTITY_FILE="${VERIFIED_IDENTITY_FILES[$index]}"
        imported=true
      fi
    fi
    index=$((index + 1))
  done

  if [ "$imported" = true ]; then
    write_accounts_to_private_config
    success \
      "Saved the selected existing GitHub account and commit email in private/config.txt." \
      "已把选中的现有 GitHub 账号和提交邮箱保存到 private/config.txt。"
    return 0
  fi

  muted \
    "To add a different account, enter its GitHub username. You can also enter :cancel to leave account setup without changing a project." \
    "如需添加其他账号，请输入对应的 GitHub 用户名；也可以输入 :cancel 退出账号设置，当前项目不会因此发生变化。"
  username="$(prompt_github_username)"
  case "$?" in
    0)
      ;;
    2)
      warn \
        "Account setup canceled. No project was committed or pushed." \
        "已退出账号设置；没有提交或上传任何项目。"
      return 2
      ;;
    *)
      return 1
      ;;
  esac
  email="$(prompt_account_email "$username")" || return 1

  if setup_or_reuse_account "$username" "$email"; then
    return 0
  fi

  fail \
    "The account was not saved because SSH key verification did not finish. Any key created during this attempt remains in ~/.ssh, but no project was committed or pushed." \
    "由于 SSH 密钥验证没有完成，本次没有保存账号。过程中已经创建的密钥会保留在 ~/.ssh 中，但没有提交或上传任何项目。"
}

# -----------------------------------------------------------------------------
# Flexible GitHub repository input
# -----------------------------------------------------------------------------

REPOSITORY_OWNER=""
REPOSITORY_NAME=""
REPOSITORY_INPUT_HOST=""

github_host_or_alias() {
  local host="$1"
  local host_without_port=""

  host_without_port="${host%%:*}"
  case "$(lowercase "$host_without_port")" in
    github.com|www.github.com|ssh.github.com)
      return 0
      ;;
  esac

  if ssh_alias_is_github "$host_without_port"; then
    return 0
  fi

  return 1
}

strip_command_prefix() {
  local value="$1"
  local value_lc

  value_lc="$(lowercase "$value")"
  case "$value_lc" in
    'git clone '*)
      value="${value#* }"
      value="${value#* }"
      ;;
    'gh repo clone '*)
      value="${value#* }"
      value="${value#* }"
      value="${value#* }"
      ;;
  esac

  printf '%s' "$value"
}

parse_repository_input() {
  local original="$1"
  local value=""
  local value_lc=""
  local scheme=""
  local authority=""
  local host=""
  local path=""
  local owner=""
  local remainder=""
  local repo=""

  REPOSITORY_OWNER=""
  REPOSITORY_NAME=""
  REPOSITORY_INPUT_HOST=""

  value="$(trim "$original")"
  value="$(strip_optional_quotes "$value")"
  value="$(strip_command_prefix "$value")"
  value="$(trim "$value")"
  [ -n "$value" ] || return 1

  value="${value%%\?*}"
  value="${value%%\#*}"
  while [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done
  value_lc="$(lowercase "$value")"

  if [[ "$value" == git@*:* ]] && [[ "$value" != *://* ]]; then
    host="${value#git@}"
    host="${host%%:*}"
    path="${value#*:}"
    github_host_or_alias "$host" || return 1
  elif [[ "$value_lc" == ssh://* ]] ||
       [[ "$value_lc" == git+ssh://* ]]; then
    scheme="${value%%://*}"
    value="${value#*://}"
    authority="${value%%/*}"
    [ "$authority" != "$value" ] || return 1
    host="${authority##*@}"
    host="${host%%:*}"
    path="${value#*/}"
    github_host_or_alias "$host" || return 1
  elif [[ "$value_lc" == http://* ]] ||
       [[ "$value_lc" == https://* ]] ||
       [[ "$value_lc" == git://* ]]; then
    value="${value#*://}"
    authority="${value%%/*}"
    [ "$authority" != "$value" ] || return 1
    host="${authority##*@}"
    host="${host%%:*}"
    path="${value#*/}"
    case "$(lowercase "$host")" in
      github.com|www.github.com)
        ;;
      *)
        return 1
        ;;
    esac
  else
    case "$value_lc" in
      github.com/*|www.github.com/*)
        host="${value%%/*}"
        path="${value#*/}"
        ;;
      *)
        path="$value"
        ;;
    esac
  fi

  path="${path#/}"
  owner="${path%%/*}"
  remainder="${path#*/}"
  [ "$remainder" != "$path" ] || return 1
  repo="${remainder%%/*}"

  case "$(lowercase "$repo")" in
    *.git)
      repo="${repo%.*}"
      ;;
  esac

  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  REPOSITORY_OWNER="$owner"
  REPOSITORY_NAME="$repo"
  REPOSITORY_INPUT_HOST="$host"
  return 0
}

prompt_repository() {
  local input=""

  heading "Identify the GitHub repository" "指定对应的 GitHub 仓库"
  muted \
    "Paste owner/repository, a GitHub page URL, an HTTPS URL, or an SSH URL." \
    "可以粘贴 owner/repository、GitHub 网页地址、HTTPS 地址或 SSH 地址。"

  while true; do
    input="$(ui_prompt_value "Repository address" "仓库地址")" || return 1
    if parse_repository_input "$input"; then
      return 0
    fi
    warn \
      "That GitHub repository was not recognized. Check the address and paste it again." \
      "没有识别出 GitHub 仓库，请检查地址后重新粘贴。"
  done
}

# -----------------------------------------------------------------------------
# Release version discovery
# -----------------------------------------------------------------------------

SEMVER_PATTERN='[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
STRICT_SEMVER_PATTERN='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?'
SEMVER_COMPARISON=0
RELEASE_VERSION=""
VERSION_SOURCE=""
VERSION_POSITION=""

strip_leading_zeroes() {
  local value="$1"

  while [ "${value#0}" != "$value" ] && [ "${#value}" -gt 1 ]; do
    value="${value#0}"
  done
  printf '%s' "$value"
}

compare_numeric_strings() {
  local left
  local right

  left="$(strip_leading_zeroes "$1")"
  right="$(strip_leading_zeroes "$2")"

  if [ "${#left}" -gt "${#right}" ]; then
    SEMVER_COMPARISON=1
  elif [ "${#left}" -lt "${#right}" ]; then
    SEMVER_COMPARISON=-1
  elif [[ "$left" > "$right" ]]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" < "$right" ]]; then
    SEMVER_COMPARISON=-1
  else
    SEMVER_COMPARISON=0
  fi
}

compare_prerelease_identifier() {
  local left="$1"
  local right="$2"
  local left_numeric=false
  local right_numeric=false

  [[ "$left" =~ ^[0-9]+$ ]] && left_numeric=true
  [[ "$right" =~ ^[0-9]+$ ]] && right_numeric=true

  if [ "$left_numeric" = true ] && [ "$right_numeric" = true ]; then
    compare_numeric_strings "$left" "$right"
  elif [ "$left_numeric" = true ]; then
    SEMVER_COMPARISON=-1
  elif [ "$right_numeric" = true ]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" > "$right" ]]; then
    SEMVER_COMPARISON=1
  elif [[ "$left" < "$right" ]]; then
    SEMVER_COMPARISON=-1
  else
    SEMVER_COMPARISON=0
  fi
}

compare_semver() {
  local left="${1%%+*}"
  local right="${2%%+*}"
  local left_core="$left"
  local right_core="$right"
  local left_pre=""
  local right_pre=""
  local left_parts=()
  local right_parts=()
  local left_pre_parts=()
  local right_pre_parts=()
  local count=0
  local index=0
  local left_value="0"
  local right_value="0"

  if [[ "$left" == *-* ]]; then
    left_core="${left%%-*}"
    left_pre="${left#*-}"
  fi
  if [[ "$right" == *-* ]]; then
    right_core="${right%%-*}"
    right_pre="${right#*-}"
  fi

  IFS='.' read -r -a left_parts <<< "$left_core"
  IFS='.' read -r -a right_parts <<< "$right_core"
  count="${#left_parts[@]}"
  if [ "${#right_parts[@]}" -gt "$count" ]; then
    count="${#right_parts[@]}"
  fi

  index=0
  while [ "$index" -lt "$count" ]; do
    left_value="${left_parts[$index]:-0}"
    right_value="${right_parts[$index]:-0}"
    compare_numeric_strings "$left_value" "$right_value"
    if [ "$SEMVER_COMPARISON" -ne 0 ]; then
      return
    fi
    index=$((index + 1))
  done

  if [ -z "$left_pre" ] && [ -z "$right_pre" ]; then
    SEMVER_COMPARISON=0
    return
  elif [ -z "$left_pre" ]; then
    SEMVER_COMPARISON=1
    return
  elif [ -z "$right_pre" ]; then
    SEMVER_COMPARISON=-1
    return
  fi

  IFS='.' read -r -a left_pre_parts <<< "$left_pre"
  IFS='.' read -r -a right_pre_parts <<< "$right_pre"
  count="${#left_pre_parts[@]}"
  if [ "${#right_pre_parts[@]}" -gt "$count" ]; then
    count="${#right_pre_parts[@]}"
  fi

  index=0
  while [ "$index" -lt "$count" ]; do
    if [ "$index" -ge "${#left_pre_parts[@]}" ]; then
      SEMVER_COMPARISON=-1
      return
    fi
    if [ "$index" -ge "${#right_pre_parts[@]}" ]; then
      SEMVER_COMPARISON=1
      return
    fi
    compare_prerelease_identifier "${left_pre_parts[$index]}" "${right_pre_parts[$index]}"
    if [ "$SEMVER_COMPARISON" -ne 0 ]; then
      return
    fi
    index=$((index + 1))
  done

  SEMVER_COMPARISON=0
}

valid_release_version() {
  [[ "$1" =~ ^${STRICT_SEMVER_PATTERN}$ ]]
}

looks_like_date() {
  local value
  local value_lc
  local month_pattern

  value="$(trim "$1")"
  value="${value#\(}"
  value="${value%\)}"
  value="$(trim "$value")"
  value_lc="$(lowercase "$value")"

  if [[ "$value" =~ ^[0-9]{4}[-./][0-9]{1,2}[-./][0-9]{1,2}$ ]] ||
     [[ "$value" =~ ^[0-9]{1,2}[-./][0-9]{1,2}[-./][0-9]{2,4}$ ]] ||
     [[ "$value" =~ ^[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日$ ]]; then
    return 0
  fi

  month_pattern='(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|jun(e)?|jul(y)?|aug(ust)?|sep(t|tember)?|oct(ober)?|nov(ember)?|dec(ember)?)\.?'
  if [[ "$value_lc" =~ $month_pattern ]] &&
     [[ "$value_lc" =~ [0-9]{4} ]] &&
     [[ "$value_lc" =~ [0-9]{1,2} ]]; then
    return 0
  fi

  return 1
}

file_size_bytes() {
  local file="$1"

  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
  else
    stat -c '%s' "$file"
  fi
}

extract_version_from_changelog() {
  local file="$1"
  local size=""
  local line=""
  local normalized=""
  local version=""
  local date_text=""
  local match_pattern=""
  local entries=()
  local count=0
  local last=0

  CHANGELOG_EXTRACTED_VERSION=""
  CHANGELOG_POSITION=""
  CHANGELOG_ENTRY_COUNT=0

  [ -f "$file" ] || return 1
  size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
  if [ "$size" -gt 1048576 ] 2>/dev/null; then
    return 1
  fi

  match_pattern="^[[:space:]]*#{0,6}[[:space:]]*\\[?[vV]?(${SEMVER_PATTERN})\\]?[[:space:]]*-[[:space:]]*(.+)$"

  while IFS= read -r line || [ -n "$line" ]; do
    normalized="${line%$'\r'}"
    normalized="${normalized//‐/-}"
    normalized="${normalized//‑/-}"
    normalized="${normalized//‒/-}"
    normalized="${normalized//–/-}"
    normalized="${normalized//—/-}"
    normalized="${normalized//−/-}"
    normalized="$(printf '%s' "$normalized" | sed -E 's/[[:space:]]+#+[[:space:]]*$//')"

    if [[ "$normalized" =~ $match_pattern ]]; then
      version="${BASH_REMATCH[1]}"
      date_text="${BASH_REMATCH[5]}"
      if looks_like_date "$date_text"; then
        entries[$count]="$version"
        count=$((count + 1))
      fi
    fi
  done < "$file"

  CHANGELOG_ENTRY_COUNT="$count"
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[0]}"
    CHANGELOG_POSITION="single"
    return 0
  fi

  compare_semver "${entries[0]}" "${entries[1]}"
  if [ "$SEMVER_COMPARISON" -gt 0 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[0]}"
    CHANGELOG_POSITION="top"
    return 0
  fi

  last=$((count - 1))
  compare_semver "${entries[$last]}" "${entries[$((last - 1))]}"
  if [ "$SEMVER_COMPARISON" -gt 0 ]; then
    CHANGELOG_EXTRACTED_VERSION="${entries[$last]}"
    CHANGELOG_POSITION="bottom"
    return 0
  fi

  return 2
}

get_package_version() {
  local file="$GIT_ROOT/package.json"
  local version=""

  [ -f "$file" ] || return 1

  if command_exists node; then
    version="$(
      node -e '
        const fs = require("fs");
        try {
          const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version;
          if (typeof value === "string") process.stdout.write(value.trim());
        } catch (_) { process.exit(1); }
      ' "$file" 2>/dev/null
    )" || true
  elif command_exists python3; then
    version="$(
      python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("version", "")
    print(value.strip() if isinstance(value, str) else "", end="")
except Exception:
    raise SystemExit(1)
' "$file" 2>/dev/null
    )" || true
  elif command_exists jq; then
    version="$(jq -r '.version // empty' "$file" 2>/dev/null)" || true
  else
    version="$(
      sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/p' "$file" |
        sed -n '1p'
    )"
  fi

  if valid_release_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

changelog_basename_kind() {
  local name_lc

  name_lc="$(lowercase "$1")"
  case "$name_lc" in
    changelog)
      printf '0'
      ;;
    changelog.md)
      printf '1'
      ;;
    changelog.txt)
      printf '2'
      ;;
    changelog*)
      printf 'language'
      ;;
    *)
      printf 'none'
      ;;
  esac
}

select_changelog_result() {
  local file="$1"
  local status=0

  if extract_version_from_changelog "$file"; then
    RELEASE_VERSION="$CHANGELOG_EXTRACTED_VERSION"
    VERSION_SOURCE="${file#"$GIT_ROOT"/}"
    VERSION_POSITION="$CHANGELOG_POSITION"
    return 0
  else
    status=$?
    if [ "$status" -eq 2 ]; then
      warn \
        "Skipped a file with ambiguous version order: ${file#"$GIT_ROOT"/}" \
        "已跳过版本顺序不明确的文件：${file#"$GIT_ROOT"/}"
    fi
  fi
  return 1
}

resolve_root_primary_changelog() {
  local priority=0
  local file=""
  local name=""
  local kind=""

  while [ "$priority" -le 2 ]; do
    for file in "$GIT_ROOT"/*; do
      [ -f "$file" ] || continue
      name="$(basename "$file")"
      kind="$(changelog_basename_kind "$name")"
      [ "$kind" = "$priority" ] || continue
      if select_changelog_result "$file"; then
        return 0
      fi
    done
    priority=$((priority + 1))
  done
  return 1
}

resolve_highest_changelog_from_stream() {
  local file=""
  local best_version=""
  local best_file=""
  local best_position=""
  local status=0

  while IFS= read -r file; do
    [ -f "$file" ] || continue
    if extract_version_from_changelog "$file"; then
      if [ -z "$best_version" ]; then
        best_version="$CHANGELOG_EXTRACTED_VERSION"
        best_file="$file"
        best_position="$CHANGELOG_POSITION"
      else
        compare_semver "$CHANGELOG_EXTRACTED_VERSION" "$best_version"
        if [ "$SEMVER_COMPARISON" -gt 0 ]; then
          best_version="$CHANGELOG_EXTRACTED_VERSION"
          best_file="$file"
          best_position="$CHANGELOG_POSITION"
        fi
      fi
    else
      status=$?
      if [ "$status" -eq 2 ]; then
        warn \
          "Skipped a file with ambiguous version order: ${file#"$GIT_ROOT"/}" \
          "已跳过版本顺序不明确的文件：${file#"$GIT_ROOT"/}"
      fi
    fi
  done

  if [ -n "$best_version" ]; then
    RELEASE_VERSION="$best_version"
    VERSION_SOURCE="${best_file#"$GIT_ROOT"/}"
    VERSION_POSITION="$best_position"
    return 0
  fi
  return 1
}

resolve_root_language_changelogs() {
  local file=""
  local name=""
  local kind=""
  local temporary=""

  temporary="$(safe_mktemp_file "${TMPDIR:-/tmp}" "changelogs")" || return 1
  for file in "$GIT_ROOT"/*; do
    [ -f "$file" ] || continue
    name="$(basename "$file")"
    kind="$(changelog_basename_kind "$name")"
    if [ "$kind" = "language" ]; then
      printf '%s\n' "$file" >> "$temporary"
    fi
  done

  if resolve_highest_changelog_from_stream < "$temporary"; then
    rm -f "$temporary"
    return 0
  fi
  rm -f "$temporary"
  return 1
}

resolve_recursive_changelogs() {
  local temporary=""

  temporary="$(safe_mktemp_file "${TMPDIR:-/tmp}" "changelogs")" || return 1
  find "$GIT_ROOT" \
    \( -type d \( \
      -name .git -o \
      -name node_modules -o \
      -name vendor -o \
      -name .venv -o \
      -name venv -o \
      -name dist -o \
      -name build -o \
      -name coverage -o \
      -name .cache -o \
      -name __pycache__ \
    \) -prune \) -o \
    \( -type f -iname 'CHANGELOG*' -print \) > "$temporary"

  # Root files were already considered with stronger precedence.
  awk -v root="$GIT_ROOT" 'index($0, root "/") == 1 && index(substr($0, length(root) + 2), "/") > 0' \
    "$temporary" > "${temporary}.nested"

  if resolve_highest_changelog_from_stream < "${temporary}.nested"; then
    rm -f "$temporary" "${temporary}.nested"
    return 0
  fi
  rm -f "$temporary" "${temporary}.nested"
  return 1
}

extract_version_from_version_file() {
  local file="$1"
  local size=""
  local text=""
  local version=""

  [ -f "$file" ] || return 1
  size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
  if [ "$size" -gt 1048576 ] 2>/dev/null; then
    return 1
  fi

  text="$(sed -n '1,80p' "$file")"
  version="$(
    printf '%s\n' "$text" |
      sed -nE "s/.*([vV]ersion|[rR]elease)[[:space:]]*[:=—–-]?[[:space:]]*[vV]?(${SEMVER_PATTERN}).*/\\2/p" |
      sed -n '1p'
  )"
  if [ -z "$version" ]; then
    version="$(
      printf '%s\n' "$text" |
        sed -nE "s/^[[:space:]]*[vV]?(${SEMVER_PATTERN})[[:space:]]*$/\\1/p" |
        sed -n '1p'
    )"
  fi

  if valid_release_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

version_filename_priority() {
  local name_lc

  name_lc="$(lowercase "$1")"
  case "$name_lc" in
    version)
      printf '0'
      ;;
    version.txt)
      printf '1'
      ;;
    version.md)
      printf '2'
      ;;
    version*)
      printf '3'
      ;;
    *)
      printf '9'
      ;;
  esac
}

resolve_version_files() {
  local file=""
  local name=""
  local priority=0
  local version=""
  local temporary=""
  local relative=""
  local depth=""

  while [ "$priority" -le 3 ]; do
    for file in "$GIT_ROOT"/*; do
      [ -f "$file" ] || continue
      name="$(basename "$file")"
      case "$(lowercase "$name")" in
        version*)
          ;;
        *)
          continue
          ;;
      esac
      [ "$(version_filename_priority "$name")" = "$priority" ] || continue
      if version="$(extract_version_from_version_file "$file")"; then
        RELEASE_VERSION="$version"
        VERSION_SOURCE="${file#"$GIT_ROOT"/}"
        VERSION_POSITION="version-file"
        return 0
      fi
    done
    priority=$((priority + 1))
  done

  temporary="$(safe_mktemp_file "${TMPDIR:-/tmp}" "versions")" || return 1
  while IFS= read -r file; do
    [ "$(dirname "$file")" != "$GIT_ROOT" ] || continue
    relative="${file#"$GIT_ROOT"/}"
    depth="$(printf '%s' "$relative" | awk -F/ '{ print NF }')"
    printf '%s|%s|%s\n' \
      "$depth" \
      "$(version_filename_priority "$(basename "$file")")" \
      "$file" >> "$temporary"
  done < <(
    find "$GIT_ROOT" \
      \( -type d -name .git -prune \) -o \
      \( -type f -iname 'VERSION*' -print \)
  )

  while IFS='|' read -r depth priority file; do
    if version="$(extract_version_from_version_file "$file")"; then
      RELEASE_VERSION="$version"
      VERSION_SOURCE="${file#"$GIT_ROOT"/}"
      VERSION_POSITION="version-file"
      rm -f "$temporary"
      return 0
    fi
  done < <(sort -t '|' -k1,1n -k2,2n -k3,3 "$temporary")

  rm -f "$temporary"
  return 1
}

resolve_release_version() {
  local package_version=""

  RELEASE_VERSION=""
  VERSION_SOURCE=""
  VERSION_POSITION=""

  if package_version="$(get_package_version)"; then
    RELEASE_VERSION="$package_version"
    VERSION_SOURCE="package.json"
    VERSION_POSITION="package"
    return 0
  fi

  if resolve_root_primary_changelog; then
    return 0
  fi
  if resolve_root_language_changelogs; then
    return 0
  fi
  if resolve_recursive_changelogs; then
    return 0
  fi
  if resolve_version_files; then
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# Git repository binding and strict push identity
# -----------------------------------------------------------------------------

GIT_ROOT=""
PROJECT_GIT_STATE=""
CURRENT_BRANCH=""
CURRENT_ORIGIN_URL=""
CURRENT_ORIGIN_HOST=""
ORIGIN_VERIFIED_USERNAME=""
ORIGIN_VERIFIED_ALIAS=""
ORIGIN_VERIFIED_IDENTITY_FILE=""
CURRENT_REPOSITORY_OWNER=""
CURRENT_REPOSITORY_NAME=""
BOUND_USERNAME=""
BOUND_EMAIL=""
BOUND_SSH_ALIAS=""
BOUND_IDENTITY_FILE=""

require_core_commands() {
  local missing=""
  local command_name=""

  for command_name in git ssh ssh-keygen awk sed find; do
    if ! command_exists "$command_name"; then
      missing="$missing $command_name"
    fi
  done

  if [ -n "$missing" ]; then
    fail \
      "Required tools are missing: $(trim "$missing")" \
      "缺少必要工具：$(trim "$missing")"
  fi
}

locate_project() {
  local initialize="${1:-yes}"
  local existing_root=""

  if existing_root="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null)"; then
    existing_root="$({ cd "$existing_root" 2>/dev/null && pwd -P; } || return 1)"
    # macOS can spell the same directory with different case or an equivalent
    # physical prefix (for example /var and /private/var). Compare the actual
    # directory objects instead of their displayed path strings.
    if [ ! "$existing_root" -ef "$SCRIPT_DIRECTORY" ]; then
      fail \
        "$SCRIPT_NAME is in $(human_path "$SCRIPT_DIRECTORY"), but the Git repository root is $(human_path "$existing_root"). Place $SCRIPT_NAME in that repository root before running it." \
        "$SCRIPT_NAME 位于 $(human_path "$SCRIPT_DIRECTORY")，但这个 Git 仓库的根目录是 $(human_path "$existing_root")。请把 $SCRIPT_NAME 放到该仓库根目录后再运行。"
    fi
    GIT_ROOT="$existing_root"
    PROJECT_GIT_STATE="existing"
    return 0
  fi

  if [ "$initialize" != "yes" ]; then
    return 1
  fi

  heading "Prepare the local Git repository" "准备本地 Git 仓库"
  warn \
    "No Git repository exists at $(human_path "$SCRIPT_DIRECTORY")." \
    "$(human_path "$SCRIPT_DIRECTORY") 还不是 Git 仓库。"
  muted \
    "The script will run git init in this folder. This creates local .git metadata only; it does not create a GitHub repository or upload files." \
    "接下来只会在这个文件夹中执行 git init，创建本地 .git 记录；此时不会创建 GitHub 仓库，也不会上传文件。"
  if ! git -C "$SCRIPT_DIRECTORY" init >/dev/null; then
    fail "The Git project could not be initialized." "Git 项目初始化失败。"
  fi
  GIT_ROOT="$SCRIPT_DIRECTORY"
  PROJECT_GIT_STATE="initialized"
  success \
    "Created the local Git repository: $(human_path "$GIT_ROOT")" \
    "已创建本地 Git 仓库：$(human_path "$GIT_ROOT")"
}

git_operation_in_progress() {
  local git_directory=""
  local state_name=""

  git_directory="$(git -C "$GIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$git_directory" ] || return 1
  for state_name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$git_directory/$state_name" ] && return 0
  done
  for state_name in rebase-merge rebase-apply; do
    [ -d "$git_directory/$state_name" ] && return 0
  done
  return 1
}

describe_and_validate_project_state() {
  local unmerged=""

  CURRENT_BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || true)"
  heading "Current local project" "当前本地项目"

  if [ "$PROJECT_GIT_STATE" = "existing" ]; then
    success \
      "Existing Git repository detected: $(human_path "$GIT_ROOT")" \
      "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")"
    muted \
      "git init will not run again. Existing commits, branches, staged changes, and remotes will be preserved." \
      "不会再次执行 git init；现有提交记录、分支、暂存内容和远端设置都会保留。"
  else
    success \
      "Using the Git repository just created in $(human_path "$GIT_ROOT")." \
      "将使用刚刚在 $(human_path "$GIT_ROOT") 创建的 Git 仓库。"
  fi

  if [ -n "$CURRENT_BRANCH" ]; then
    muted "Current branch: $CURRENT_BRANCH" "当前分支：$CURRENT_BRANCH"
  elif git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    error_message \
      "HEAD is detached, so there is no current branch to push. Check out the intended branch and run ./$SCRIPT_NAME again." \
      "当前处于 detached HEAD 状态，没有可直接上传的当前分支。请先切换到目标分支，再重新运行 ./${SCRIPT_NAME}。"
    return 1
  else
    muted \
      "This repository has no commits yet; the first branch will be named main." \
      "这个仓库还没有提交记录；首次提交后分支名将统一为 main。"
  fi

  unmerged="$(git -C "$GIT_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)"
  if [ -n "$unmerged" ]; then
    error_message \
      "Unresolved merge conflicts were found. Resolve the files listed by git status before running this script." \
      "检测到尚未解决的合并冲突。请先按照 git status 列出的文件完成处理，再运行本脚本。"
    git -C "$GIT_ROOT" status --short
    return 1
  fi
  if git_operation_in_progress; then
    error_message \
      "A merge, rebase, cherry-pick, or revert is still in progress. Finish or cancel that Git operation before running this script." \
      "当前还有尚未完成的 merge、rebase、cherry-pick 或 revert。请先完成或取消该 Git 操作，再运行本脚本。"
    return 1
  fi
}

ensure_script_excluded() {
  local exclude_file=""
  local temporary_file=""
  local line=""
  local skipping=false
  local marker_start="# >>> github-auto script >>>"
  local marker_end="# <<< github-auto script <<<"

  # The public launcher in the central repository is intentionally tracked.
  # Only standalone project copies belong in the repository-local exclude file.
  if git -C "$GIT_ROOT" ls-files --error-unmatch -- "$SCRIPT_NAME" >/dev/null 2>&1; then
    return 0
  fi

  exclude_file="$(git -C "$GIT_ROOT" rev-parse --git-path info/exclude)"
  case "$exclude_file" in
    /*)
      ;;
    *)
      exclude_file="$GIT_ROOT/$exclude_file"
      ;;
  esac

  mkdir -p "$(dirname "$exclude_file")" || fail \
    "The local Git exclusion settings could not be prepared." \
    "无法准备 Git 本地排除设置。"
  [ -f "$exclude_file" ] || : > "$exclude_file"
  if grep -Fqx "$marker_start" "$exclude_file" 2>/dev/null &&
     grep -Fqx "/$SCRIPT_NAME" "$exclude_file" 2>/dev/null &&
     grep -Fqx "$marker_end" "$exclude_file" 2>/dev/null; then
    return 0
  fi
  temporary_file="$(safe_mktemp_file "$(dirname "$exclude_file")" "exclude")" ||
    fail \
      "The local Git exclusion settings could not be updated." \
      "无法更新 Git 本地排除设置。"

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$marker_start" ]; then
      skipping=true
      continue
    fi
    if [ "$skipping" = true ]; then
      if [ "$line" = "$marker_end" ]; then
        skipping=false
      fi
      continue
    fi
    printf '%s\n' "$line" >> "$temporary_file"
  done < "$exclude_file"

  if [ -s "$temporary_file" ]; then
    printf '\n' >> "$temporary_file"
  fi
  printf '%s\n/%s\n%s\n' "$marker_start" "$SCRIPT_NAME" "$marker_end" >> "$temporary_file"
  mv "$temporary_file" "$exclude_file" || fail \
    "The local Git exclusion settings could not be saved." \
    "无法保存 Git 本地排除设置。"
}

read_origin_repository() {
  local url=""

  ORIGIN_VERIFIED_USERNAME=""
  ORIGIN_VERIFIED_ALIAS=""
  ORIGIN_VERIFIED_IDENTITY_FILE=""
  if ! url="$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null)"; then
    return 1
  fi
  if ! parse_repository_input "$url"; then
    return 1
  fi

  CURRENT_ORIGIN_URL="$url"
  CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
  CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
  return 0
}

identify_origin_ssh_account() {
  local key=""

  [ -n "$CURRENT_ORIGIN_HOST" ] || return 1
  ssh_alias_is_github "$CURRENT_ORIGIN_HOST" || return 1
  key="$(resolve_alias_identity_file "$CURRENT_ORIGIN_HOST" || true)"
  [ -f "$key" ] || return 1

  info \
    "The existing origin uses SSH Host $CURRENT_ORIGIN_HOST. Asking GitHub which account accepts its key; saved account and repository settings will not be changed." \
    "现有 origin 使用 SSH 主机名 ${CURRENT_ORIGIN_HOST}。正在向 GitHub 核对该主机名所用密钥对应的账号；这一步不会修改已保存账号或仓库设置。"
  if ! identify_key_username "$key"; then
    warn \
      "GitHub did not confirm the key currently referenced by origin SSH Host $CURRENT_ORIGIN_HOST." \
      "GitHub 暂时没有确认 origin 的 SSH 主机名 ${CURRENT_ORIGIN_HOST} 所引用的密钥。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted \
        "SSH result: ${SSH_VERIFICATION_OUTPUT##*$'\n'}" \
        "SSH 返回信息：${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi

  ORIGIN_VERIFIED_USERNAME="$VERIFIED_GITHUB_USERNAME"
  ORIGIN_VERIFIED_ALIAS="$CURRENT_ORIGIN_HOST"
  ORIGIN_VERIFIED_IDENTITY_FILE="$key"
  return 0
}

select_verified_origin_account() {
  local allow_registration="${1:-yes}"
  local index=""
  local email=""

  if [ -z "$ORIGIN_VERIFIED_USERNAME" ]; then
    identify_origin_ssh_account || return 1
  fi

  if index="$(account_index "$ORIGIN_VERIFIED_USERNAME")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The existing origin authenticates as saved account $BOUND_USERNAME, so that account was selected." \
      "现有 origin 使用的密钥已验证为已保存账号 ${BOUND_USERNAME}，因此本次直接使用该账号。"
    return 0
  fi

  [ "$allow_registration" = "yes" ] || return 1
  heading "Use the account already connected to this repository" "使用当前仓库已经连接的账号"
  success \
    "GitHub confirmed that origin SSH Host $ORIGIN_VERIFIED_ALIAS authenticates as $ORIGIN_VERIFIED_USERNAME." \
    "GitHub 已确认 origin 的 SSH 主机名 ${ORIGIN_VERIFIED_ALIAS} 使用账号 ${ORIGIN_VERIFIED_USERNAME}。"
  muted \
    "Only the commit email is still needed. The existing SSH key will be reused, and Git will not be initialized again." \
    "现在只需确认提交邮箱。脚本会继续使用现有 SSH 密钥，也不会重新初始化 Git 仓库。"
  email="$(prompt_account_email "$ORIGIN_VERIFIED_USERNAME")" || return 1
  register_account_and_identity \
    "$ORIGIN_VERIFIED_USERNAME" \
    "$email" \
    "$ORIGIN_VERIFIED_ALIAS" \
    "$ORIGIN_VERIFIED_IDENTITY_FILE"
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
  return 0
}

select_account_for_repository() {
  local owner="$1"
  local preferred_username="${2:-}"
  local saved_username=""
  local index=""

  if [ -n "$preferred_username" ] && index="$(account_index "$preferred_username")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "Using the account selected for this command: $BOUND_USERNAME" \
      "本次操作使用指定账号：$BOUND_USERNAME"
    return 0
  fi

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ -n "$saved_username" ] && index="$(account_index "$saved_username")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "Using this repository's saved GitHub account: $BOUND_USERNAME" \
      "使用当前仓库已经保存的 GitHub 账号：$BOUND_USERNAME"
    return 0
  fi

  if select_verified_origin_account yes; then
    return 0
  fi

  if index="$(account_index "$owner")"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
    info \
      "The repository owner matches saved account $BOUND_USERNAME, so that account was selected." \
      "仓库所属用户名与已保存账号 $BOUND_USERNAME 一致，因此本次使用该账号。"
    return 0
  fi

  if ! select_account \
    "Which GitHub account should this project use?" \
    "这个项目使用哪个 GitHub 账号？"; then
    return 1
  fi
  BOUND_USERNAME="$SELECTED_USERNAME"
  BOUND_EMAIL="$SELECTED_EMAIL"
}

ensure_bound_identity() {
  local preferred_alias=""
  local saved_key=""
  local verification_detail=""

  preferred_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_key="$(expand_home_path "$saved_key")"
  saved_key="${saved_key//%d/${HOME:-}}"

  if [ -n "$ORIGIN_VERIFIED_USERNAME" ] &&
     [ "$(lowercase "$ORIGIN_VERIFIED_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ] &&
     [ -f "$ORIGIN_VERIFIED_IDENTITY_FILE" ]; then
    BOUND_SSH_ALIAS="$ORIGIN_VERIFIED_ALIAS"
    BOUND_IDENTITY_FILE="$ORIGIN_VERIFIED_IDENTITY_FILE"
    success \
      "Using the origin identity GitHub already confirmed: account $BOUND_USERNAME, SSH Host $BOUND_SSH_ALIAS, key $(human_path "$BOUND_IDENTITY_FILE")." \
      "将使用刚刚由 GitHub 确认的 origin 身份：账号 ${BOUND_USERNAME}、SSH 主机名 ${BOUND_SSH_ALIAS}、密钥 $(human_path "$BOUND_IDENTITY_FILE")。"
    return 0
  fi

  if [ -z "$preferred_alias" ] && [ -n "$CURRENT_ORIGIN_HOST" ]; then
    case "$(lowercase "$CURRENT_ORIGIN_HOST")" in
      github.com|www.github.com|ssh.github.com)
        ;;
      *)
        if ssh_alias_is_github "$CURRENT_ORIGIN_HOST"; then
          preferred_alias="$CURRENT_ORIGIN_HOST"
          info \
            "The existing origin uses SSH Host $preferred_alias; that existing key will be checked first." \
            "现有 origin 使用 SSH 主机名 ${preferred_alias}，将优先核对它指定的现有密钥。"
        fi
        ;;
    esac
  fi

  if [ -n "$saved_key" ] && [ -f "$saved_key" ]; then
    if identify_key_username "$saved_key" &&
       [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
      BOUND_IDENTITY_FILE="$saved_key"
      if find_github_alias_for_identity_file "$saved_key" "$preferred_alias"; then
        BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
      else
        next_available_alias "$BOUND_USERNAME" || fail \
          "An unused SSH Host name could not be selected for this repository's existing key." \
          "无法为当前仓库已有的密钥找到不冲突的 SSH 主机名。"
        BOUND_SSH_ALIAS="$NEW_SSH_ALIAS"
        info \
          "The saved key has no usable GitHub SSH Host entry. Adding $BOUND_SSH_ALIAS to ~/.ssh/config for this existing key." \
          "当前仓库保存的密钥还没有可用的 GitHub SSH 主机配置。将把 ${BOUND_SSH_ALIAS} 添加到 ~/.ssh/config，并继续使用这把现有密钥。"
        install_ssh_alias_block "$BOUND_USERNAME" "$BOUND_SSH_ALIAS" "$BOUND_IDENTITY_FILE"
      fi
      success \
        "GitHub confirmed that this repository uses account $BOUND_USERNAME through SSH Host $BOUND_SSH_ALIAS and key $(human_path "$BOUND_IDENTITY_FILE")." \
        "GitHub 已确认当前仓库通过 SSH 主机名 ${BOUND_SSH_ALIAS} 和密钥 $(human_path "$BOUND_IDENTITY_FILE") 使用账号 ${BOUND_USERNAME}。"
      return 0
    fi
  fi

  if find_verified_identity_for_username "$BOUND_USERNAME" "$preferred_alias"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    success \
      "Reusing SSH Host $BOUND_SSH_ALIAS and key $(human_path "$BOUND_IDENTITY_FILE") for account $BOUND_USERNAME." \
      "将沿用账号 ${BOUND_USERNAME} 已有的 SSH 配置：主机名 ${BOUND_SSH_ALIAS}，密钥 $(human_path "$BOUND_IDENTITY_FILE")。"
    return 0
  fi

  heading "GitHub SSH identity" "核对 GitHub SSH 身份"
  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "An existing key was found at $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE"), but GitHub did not confirm it for account $BOUND_USERNAME." \
      "找到了现有密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE")，但暂时无法确认它属于 GitHub 账号 ${BOUND_USERNAME}。"
    verification_detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$verification_detail" ]; then
      muted "SSH result: $verification_detail" "SSH 返回信息：$verification_detail"
    fi
    muted \
      "This can mean the network cannot reach GitHub, or that this public key is not registered with the account." \
      "这通常表示当前网络无法连接 GitHub，或这把密钥的公钥尚未添加到该账号。"
    if ui_prompt_yes_no \
      "Verify this existing key with GitHub again before creating anything?" \
      "要先重新验证这把现有密钥，再决定是否创建新密钥吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$BOUND_USERNAME")" ]; then
        BOUND_SSH_ALIAS="$FOUND_UNVERIFIED_SSH_ALIAS"
        BOUND_IDENTITY_FILE="$FOUND_UNVERIFIED_IDENTITY_FILE"
        success \
          "GitHub confirmed that the existing key belongs to account $BOUND_USERNAME." \
          "GitHub 已确认这把现有密钥属于账号 ${BOUND_USERNAME}。"
        return 0
      fi
      warn \
        "GitHub still did not confirm this key for account $BOUND_USERNAME." \
        "GitHub 仍未确认这把密钥属于账号 ${BOUND_USERNAME}。"
    fi
  else
    warn \
      "No SSH private key accepted by GitHub for account $BOUND_USERNAME was found in ~/.ssh/config or its Include files." \
      "在 ~/.ssh/config 及其 Include 文件中，没有找到可由 GitHub 确认为账号 $BOUND_USERNAME 的现有私钥。"
  fi

  next_available_alias "$BOUND_USERNAME" || fail \
    "An unused SSH Host name and key filename could not be selected." \
    "无法为新密钥找到不冲突的 SSH 主机名和文件名。"
  muted \
    "Continuing will create $(human_path "$NEW_IDENTITY_FILE") and add SSH Host $NEW_SSH_ALIAS to ~/.ssh/config." \
    "如果继续，脚本将创建 $(human_path "$NEW_IDENTITY_FILE")，并在 ~/.ssh/config 中加入 SSH 主机名 ${NEW_SSH_ALIAS}。"
  muted \
    "The public key will be shown for you to add to GitHub. No commit or push will run until GitHub confirms that the key belongs to exactly $BOUND_USERNAME." \
    "随后会显示公钥，供你添加到 GitHub。只有 GitHub 确认该密钥对应的账号正是 $BOUND_USERNAME 后，脚本才会继续提交和上传。"
  if ! ui_prompt_yes_no \
    "Create and configure this separate SSH key now?" \
    "现在创建并配置这把独立的 SSH 密钥吗？" \
    "yes"; then
    warn \
      "Stopped before creating a key, changing the repository's account settings, committing, or pushing." \
      "操作已停止；没有创建新密钥，也没有修改当前仓库的账号设置、提交或上传。"
    return 1
  fi

  if create_new_identity "$BOUND_USERNAME" "$BOUND_EMAIL"; then
    BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
    BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    return 0
  fi
  return 1
}

save_project_binding() {
  local remote_url=""

  remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"

  git -C "$GIT_ROOT" config --local user.name "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local user.email "$BOUND_EMAIL" || return 1
  git -C "$GIT_ROOT" config --local github-auto.username "$BOUND_USERNAME" || return 1
  git -C "$GIT_ROOT" config --local github-auto.ssh-alias "$BOUND_SSH_ALIAS" || return 1
  git -C "$GIT_ROOT" config --local github-auto.identity-file "$BOUND_IDENTITY_FILE" || return 1
  git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH" || return 1

  if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$GIT_ROOT" remote set-url origin "$remote_url" || return 1
  else
    git -C "$GIT_ROOT" remote add origin "$remote_url" || return 1
  fi
  git -C "$GIT_ROOT" config --local --replace-all remote.origin.pushurl "$remote_url" || return 1

  return 0
}

create_pinned_ssh_wrapper() {
  PINNED_SSH_DIRECTORY="$(safe_mktemp_directory)" || return 1
  PINNED_SSH_WRAPPER="$PINNED_SSH_DIRECTORY/ssh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec ssh -F /dev/null '
    printf '%s ' \
      '-o HostName=github.com' \
      '-o User=git' \
      '-o IdentitiesOnly=yes' \
      '-o PreferredAuthentications=publickey' \
      '-o PasswordAuthentication=no'
    printf '%s ' '-i "$GITHUB_AUTO_IDENTITY_FILE"'
    printf '"$@"\n'
  } > "$PINNED_SSH_WRAPPER"
  chmod 700 "$PINNED_SSH_WRAPPER"
}

run_git_with_identity() {
  local private_key="$1"
  shift

  create_pinned_ssh_wrapper || return 1
  GITHUB_AUTO_IDENTITY_FILE="$private_key" \
    GIT_SSH_COMMAND="$PINNED_SSH_WRAPPER" \
    GIT_SSH_VARIANT=ssh \
    git -C "$GIT_ROOT" "$@"
  local status=$?
  rm -rf "$PINNED_SSH_DIRECTORY"
  return "$status"
}

verify_repository_access() {
  local retry="${1:-yes}"
  local target="${2:-origin}"
  local output=""
  local detail=""

  while true; do
    info \
      "Reading ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with account $BOUND_USERNAME; this check does not upload or change the repository." \
      "正在用账号 $BOUND_USERNAME 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 的远端信息；这一步不会上传或修改仓库。"
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote "$target" HEAD 2>&1)" && {
      success \
        "GitHub allowed account $BOUND_USERNAME to read ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
        "GitHub 已允许账号 $BOUND_USERNAME 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
      return 0
    }

    error_message \
      "GitHub did not allow account $BOUND_USERNAME to read ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
      "GitHub 未允许账号 $BOUND_USERNAME 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    muted \
      "Check the network, confirm that the repository exists, and confirm that this exact account has access." \
      "请检查网络，并确认仓库确实存在且这个账号拥有访问权限。"
    muted \
      "Create a repository: https://github.com/new" \
      "创建仓库：https://github.com/new"

    if [ "$retry" != "yes" ] ||
       ! ui_prompt_yes_no \
         "Run the same read-only access check again?" \
         "要再次执行同一项只读访问检查吗？" \
         "yes"; then
      return 1
    fi
  done
}

configure_project() {
  local preferred_username="${1:-}"
  local proposed_remote_url=""

  if read_origin_repository; then
    success \
      "Recognized the existing origin as ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
      "已从现有 origin 识别出 GitHub 仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
    muted "Current origin: $CURRENT_ORIGIN_URL" "当前 origin：$CURRENT_ORIGIN_URL"
  else
    warn \
      "This local Git repository has no origin that identifies a GitHub repository." \
      "这个本地 Git 仓库还没有能够识别为 GitHub 仓库的 origin。"
    muted \
      "Paste the GitHub repository that should receive this existing local history. No files will be uploaded until the address and account access are verified." \
      "请粘贴这个现有本地仓库应当上传到的 GitHub 仓库地址；在地址和账号权限核对完成前，不会上传任何文件。"
    if ! prompt_repository; then
      return 1
    fi
    CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
    CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"
    CURRENT_ORIGIN_URL=""
    CURRENT_ORIGIN_HOST="$REPOSITORY_INPUT_HOST"
  fi

  if ! select_account_for_repository "$CURRENT_REPOSITORY_OWNER" "$preferred_username"; then
    return 1
  fi
  if ! ensure_bound_identity; then
    return 1
  fi

  proposed_remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"

  heading "Verify the exact GitHub destination" "核对准确的 GitHub 上传目标"
  muted \
    "GitHub repository: ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}" \
    "GitHub 仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}"
  muted "GitHub account: $BOUND_USERNAME" "GitHub 账号：$BOUND_USERNAME"
  muted "Commit author name: $BOUND_USERNAME" "提交作者名称：$BOUND_USERNAME"
  muted "Commit email: $BOUND_EMAIL" "提交邮箱：$BOUND_EMAIL"
  muted "SSH private key: $(human_path "$BOUND_IDENTITY_FILE")" "SSH 私钥：$(human_path "$BOUND_IDENTITY_FILE")"
  muted "Push address: $proposed_remote_url" "上传地址：$proposed_remote_url"

  verify_repository_access yes "$proposed_remote_url" || return 1

  if [ -n "$CURRENT_ORIGIN_URL" ] && [ "$CURRENT_ORIGIN_URL" != "$proposed_remote_url" ]; then
    info \
      "origin will change from $CURRENT_ORIGIN_URL to $proposed_remote_url so future fetches and pushes use the verified account." \
      "为确保以后拉取和推送都使用核对无误的账号，origin 将从 ${CURRENT_ORIGIN_URL} 更新为 ${proposed_remote_url}。"
  elif [ -z "$CURRENT_ORIGIN_URL" ]; then
    info "origin will be added as $proposed_remote_url." "将新增 origin：${proposed_remote_url}。"
  else
    muted \
      "The existing origin already uses the verified account and will not change." \
      "现有 origin 已经使用核对无误的账号，不需要修改。"
  fi

  if ! save_project_binding; then
    fail \
      "The account settings for this project could not be saved." \
      "无法保存当前项目的账号设置。"
  fi
  success \
    "Saved the account, commit author, SSH key, and origin in this repository's local Git configuration." \
    "账号、提交作者、SSH 密钥和 origin 已保存到当前仓库自己的本地 Git 配置中。"
}

prompt_commit_message() {
  local proposed="$1"
  local entered=""

  heading "Confirm commit" "确认提交"
  muted "Suggested commit message: $proposed" "建议的提交说明：$proposed"
  entered="$(ui_prompt_value \
    "Press Enter to use it, type another message, or enter :cancel to stop before staging" \
    "直接按 Enter 使用建议内容；也可以输入其他说明，或输入 :cancel 在暂存前停止" \
    "$proposed")" || return 1
  if [ "$(lowercase "$entered")" = ":cancel" ]; then
    return 2
  fi
  COMMIT_MESSAGE="$entered"
}

show_staged_changes() {
  heading "Changes in this commit" "本次改动"
  git -C "$GIT_ROOT" diff --cached --stat
}

prepare_and_commit() {
  local has_commits=true
  local proposed="$DEFAULT_COMMIT_MESSAGE"

  if ! git -C "$GIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    has_commits=false
  fi

  if [ -z "$(git -C "$GIT_ROOT" status --porcelain 2>/dev/null)" ]; then
    if [ "$has_commits" = false ]; then
      warn \
        "This repository has no commit and no project files available to commit. Nothing was pushed." \
        "当前仓库还没有提交记录，也没有可提交的项目文件，因此本次不会上传。"
      return 3
    fi
    info \
      "The working tree has no uncommitted changes. No commit will be created; any existing local commits will still be considered for push." \
      "工作区没有尚未提交的改动，因此不会创建新提交；如果本地已有尚未上传的提交，后续仍会尝试推送。"
    return 0
  fi

  if [ "$has_commits" = false ]; then
    proposed="$INITIAL_COMMIT_MESSAGE"
  elif resolve_release_version; then
    proposed="${RELEASE_PREFIX}${RELEASE_VERSION}"
    info \
      "Detected version ${RELEASE_VERSION} (${VERSION_SOURCE})" \
      "识别到版本 ${RELEASE_VERSION}（${VERSION_SOURCE}）"
    case "$VERSION_POSITION" in
      bottom)
        warn \
          "This changelog is ordered oldest to newest, so the bottom version was used." \
          "这个 CHANGELOG 按旧版本到新版本排列，已采用底部版本。"
        ;;
      single)
        muted \
          "Only one version was found in this changelog." \
          "这个 CHANGELOG 中只识别到一个版本。"
        ;;
    esac
  else
    muted \
      "No release version was found, so a general commit message will be used." \
      "没有发现版本号，将使用通用提交说明。"
  fi

  heading "Review changes before committing" "提交前检查改动"
  muted \
    "The following output is from git status --short. A means added, M modified, D deleted, and ?? an untracked file." \
    "下面是 git status --short 的结果：A 表示新增，M 表示修改，D 表示删除，?? 表示尚未跟踪的新文件。"
  git -C "$GIT_ROOT" status --short
  muted \
    "After the commit message is confirmed, git add -A will include every change shown above, including deletions." \
    "确认提交说明后，脚本会执行 git add -A，把上面显示的全部改动一并纳入提交，其中也包括删除的文件。"

  prompt_commit_message "$proposed"
  case "$?" in
    0)
      ;;
    2)
      warn \
        "Commit canceled before git add -A. This step did not stage, commit, or push any files." \
        "已在执行 git add -A 前取消；这一步没有暂存、提交或上传任何文件。"
      return 2
      ;;
    *)
      return 1
      ;;
  esac

  if ! git -C "$GIT_ROOT" add -A; then
    error_message \
      "git add -A failed. Git may have staged some paths before stopping; inspect git status. No commit or push was attempted." \
      "git add -A 执行失败。Git 可能已经暂存了部分文件，请用 git status 检查；脚本没有继续提交或上传。"
    return 1
  fi
  show_staged_changes

  if ! git -C "$GIT_ROOT" commit -m "$COMMIT_MESSAGE"; then
    error_message \
      "The commit failed. The selected changes remain staged for inspection, and no push was attempted." \
      "提交失败。本次选择的改动仍保留在暂存区，便于检查；脚本没有执行上传。"
    return 1
  fi
  success "Committed: $COMMIT_MESSAGE" "已提交：$COMMIT_MESSAGE"

  if [ "$has_commits" = false ]; then
    git -C "$GIT_ROOT" branch -M main || fail \
      "The initial branch could not be named main." \
      "无法把初始分支设置为 main。"
  fi
}

push_current_branch() {
  local branch=""

  branch="$(git -C "$GIT_ROOT" branch --show-current)"
  if [ -z "$branch" ]; then
    fail \
      "The repository is in detached HEAD state, so a branch cannot be selected safely." \
      "当前处于 detached HEAD 状态，无法安全判断要推送的分支。"
  fi

  heading "Push to GitHub" "上传到 GitHub"
  muted "GitHub repository: ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}" "GitHub 仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}"
  muted "GitHub account: $BOUND_USERNAME" "GitHub 账号：$BOUND_USERNAME"
  muted "Local branch: $branch" "本地分支：$branch"
  muted \
    "The script will run git push -u origin $branch with only $(human_path "$BOUND_IDENTITY_FILE"). It will not force-push." \
    "接下来只使用密钥 $(human_path "$BOUND_IDENTITY_FILE") 执行 git push -u origin ${branch}；不会强制推送。"

  if ! run_git_with_identity "$BOUND_IDENTITY_FILE" push -u origin "$branch"; then
    fail \
      "The push failed. No force push was used and no remote content was overwritten." \
      "上传失败。脚本没有强制推送，也没有覆盖远端内容。"
  fi
  success \
    "Pushed branch $branch to ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with account $BOUND_USERNAME." \
    "已使用账号 $BOUND_USERNAME 将分支 $branch 上传到 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
}

run_project_flow() {
  local preferred_username="${1:-}"
  local commit_status=0

  require_interactive
  require_core_commands
  locate_project yes
  describe_and_validate_project_state || return 1
  ensure_script_excluded

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    heading "GitHub account required" "需要选择 GitHub 账号"
    if [ "$PROJECT_GIT_STATE" = "existing" ]; then
      muted \
        "The local Git repository was already initialized and its existing history will be preserved, but private/config.txt has no saved GitHub account. The next step configures an account; it does not run git init again." \
        "当前文件夹原本就是 Git 仓库，现有提交历史会完整保留；只是 private/config.txt 中还没有保存 GitHub 账号。接下来只配置账号，不会再次执行 git init。"
    else
      muted \
        "The empty local Git metadata was just initialized. private/config.txt has no saved GitHub account, so the next step configures one before any commit or push." \
        "本地 Git 元数据刚刚完成初始化。由于 private/config.txt 中还没有保存 GitHub 账号，接下来会先配置账号，再进入提交和上传步骤。"
    fi
    if read_origin_repository && select_verified_origin_account yes; then
      preferred_username="$BOUND_USERNAME"
    else
      run_account_setup || return 1
      preferred_username="$SELECTED_USERNAME"
    fi
  fi

  configure_project "$preferred_username" || return 1
  prepare_and_commit || commit_status=$?
  if [ "$commit_status" -eq 2 ]; then
    return 0
  elif [ "$commit_status" -eq 3 ]; then
    return 0
  elif [ "$commit_status" -ne 0 ]; then
    return 1
  fi
  push_current_branch
}

# -----------------------------------------------------------------------------
# Advanced features and historical release import
# -----------------------------------------------------------------------------

ADVANCED_LANGUAGE="en"
HISTORY_RELEASE_VERSIONS=()
HISTORY_RELEASE_DIRECTORIES=()
HISTORY_RELEASE_DATES=()
HISTORY_RELEASE_NEEDS_GITIGNORE=()
HISTORY_RELEASE_COUNT=0
HISTORY_CONFLICT_DIRECTORIES=()
HISTORY_CONFLICT_FOLDER_VERSIONS=()
HISTORY_CONFLICT_CONTENT_VERSIONS=()
HISTORY_CONFLICT_COUNT=0
HISTORY_SKIPPED_DIRECTORIES=()
HISTORY_SKIPPED_COUNT=0
HISTORY_SENSITIVE_FILES=()
HISTORY_SENSITIVE_COUNT=0
HISTORY_LARGE_FILES=()
HISTORY_LARGE_COUNT=0
HISTORY_MAX_FILE_BYTES=104857600
HISTORY_GITIGNORE_CONTENT=""
HISTORY_ADD_GITIGNORE=false
HISTORY_WORK_DIRECTORY=""
HISTORY_CREATE_TAGS=true

advanced_heading() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    heading "$1"
  else
    heading "$2"
  fi
}

advanced_muted() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    muted "$1"
  else
    muted "$2"
  fi
}

advanced_info() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_INFO" "[Info] $1"
  else
    print_colored "$COLOR_INFO" "[信息] $2"
  fi
}

advanced_success() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_SUCCESS" "[Done] $1"
  else
    print_colored "$COLOR_SUCCESS" "[完成] $2"
  fi
}

advanced_warn() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_WARNING" "[Notice] $1"
  else
    print_colored "$COLOR_WARNING" "[注意] $2"
  fi
}

advanced_error() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    print_colored "$COLOR_ERROR" "[Error] $1" stderr
  else
    print_colored "$COLOR_ERROR" "[错误] $2" stderr
  fi
}

advanced_prompt_value() {
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    prompt_value "$1" "${3:-}"
  else
    prompt_value "$2" "${3:-}"
  fi
}

advanced_prompt_yes_no() {
  local english_label="$1"
  local chinese_label="$2"
  local default_answer="${3:-yes}"
  local label="$english_label"
  local hint="[Y/n]"
  local answer=""

  if [ "$ADVANCED_LANGUAGE" != "en" ]; then
    label="$chinese_label"
    if [ "$default_answer" = "no" ]; then
      hint="[是/否，默认否]"
    else
      hint="[是/否，默认是]"
    fi
  elif [ "$default_answer" = "no" ]; then
    hint="[y/N]"
  fi

  while true; do
    printf '%b%s %s: %b' "$COLOR_INFO" "$label" "$hint" "$COLOR_RESET"
    IFS= read -r answer || return 1
    answer="$(lowercase "$(trim "$answer")")"

    if [ -z "$answer" ]; then
      [ "$default_answer" = "yes" ]
      return
    fi

    case "$answer" in
      y|yes|是|好|好的)
        return 0
        ;;
      n|no|否|不)
        return 1
        ;;
      *)
        advanced_warn \
          "Enter y or n. Press Enter to use the recommended option." \
          "请输入 y 或 n；直接按 Enter 使用推荐选项。"
        ;;
    esac
  done
}

advanced_pause() {
  local ignored=""

  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '%bPress Enter to continue%b' "$COLOR_INFO" "$COLOR_RESET"
  else
    printf '%b按 Enter 继续%b' "$COLOR_INFO" "$COLOR_RESET"
  fi
  IFS= read -r ignored || true
}

normalize_history_directory_input() {
  local path=""

  HISTORY_NORMALIZED_DIRECTORY=""
  path="$(trim "$1")"
  path="$(strip_optional_quotes "$path")"
  case "$path" in
    file://localhost/*)
      path="/${path#file://localhost/}"
      ;;
    file:///*)
      path="${path#file://}"
      ;;
  esac

  path="${path//%20/ }"
  path="${path//%5B/[}"
  path="${path//%5D/]}"
  path="${path//%28/(}"
  path="${path//%29/)}"
  path="${path//\\ / }"
  path="${path//\\(/(}"
  path="${path//\\)/)}"
  path="${path//\\[/[}"
  path="${path//\\]/]}"
  path="$(expand_home_path "$path")"

  [ -d "$path" ] || return 1
  HISTORY_NORMALIZED_DIRECTORY="$({ cd "$path" 2>/dev/null && pwd -P; } || return 1)"
}

extract_version_from_directory_name() {
  local name="$1"

  HISTORY_DIRECTORY_VERSION=""
  if [[ "$name" =~ (^|[^0-9A-Za-z])[vV]?(${STRICT_SEMVER_PATTERN})($|[^0-9A-Za-z]) ]]; then
    HISTORY_DIRECTORY_VERSION="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

detect_release_version_from_contents() {
  local directory="$1"
  local original_root="$GIT_ROOT"
  local file=""
  local version=""
  local best=""

  HISTORY_CONTENT_VERSION=""
  GIT_ROOT="$directory"

  if version="$(get_package_version 2>/dev/null)"; then
    HISTORY_CONTENT_VERSION="$version"
    GIT_ROOT="$original_root"
    return 0
  fi

  while IFS= read -r -d '' file; do
    if extract_version_from_changelog "$file" &&
       valid_release_version "$CHANGELOG_EXTRACTED_VERSION"; then
      version="$CHANGELOG_EXTRACTED_VERSION"
      if [ -z "$best" ]; then
        best="$version"
      else
        compare_semver "$version" "$best"
        if [ "$SEMVER_COMPARISON" -gt 0 ]; then
          best="$version"
        fi
      fi
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'CHANGELOG*' -print0)

  if [ -z "$best" ]; then
    while IFS= read -r -d '' file; do
      if version="$(extract_version_from_version_file "$file" 2>/dev/null)"; then
        if [ -z "$best" ]; then
          best="$version"
        else
          compare_semver "$version" "$best"
          if [ "$SEMVER_COMPARISON" -gt 0 ]; then
            best="$version"
          fi
        fi
      fi
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'VERSION*' -print0)
  fi

  GIT_ROOT="$original_root"
  if [ -n "$best" ]; then
    HISTORY_CONTENT_VERSION="$best"
    return 0
  fi
  return 1
}

history_month_number() {
  case "$(lowercase "$1")" in
    jan|january) printf '1' ;;
    feb|february) printf '2' ;;
    mar|march) printf '3' ;;
    apr|april) printf '4' ;;
    may) printf '5' ;;
    jun|june) printf '6' ;;
    jul|july) printf '7' ;;
    aug|august) printf '8' ;;
    sep|sept|september) printf '9' ;;
    oct|october) printf '10' ;;
    nov|november) printf '11' ;;
    dec|december) printf '12' ;;
    *) return 1 ;;
  esac
}

normalize_history_date() {
  local value=""
  local year=""
  local month=""
  local day=""
  local first=""
  local second=""
  local third=""
  local extra=""

  HISTORY_NORMALIZED_DATE=""
  value="$(trim "$1")"
  value="${value#\(}"
  value="${value%\)}"
  value="${value//,/}"
  value="$(trim "$value")"

  if [[ "$value" =~ ^([0-9]{4})[-./]([0-9]{1,2})[-./]([0-9]{1,2})$ ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  elif [[ "$value" =~ ^([0-9]{4})年([0-9]{1,2})月([0-9]{1,2})日$ ]]; then
    year="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    day="${BASH_REMATCH[3]}"
  else
    IFS=' ' read -r first second third extra <<< "$value"
    [ -z "$extra" ] || return 1
    if month="$(history_month_number "$first" 2>/dev/null)"; then
      day="$second"
      year="$third"
    elif month="$(history_month_number "$second" 2>/dev/null)"; then
      day="$first"
      year="$third"
    else
      return 1
    fi
  fi

  [[ "$year" =~ ^[0-9]{4}$ ]] || return 1
  [[ "$month" =~ ^[0-9]{1,2}$ ]] || return 1
  [[ "$day" =~ ^[0-9]{1,2}$ ]] || return 1
  month="$((10#$month))"
  day="$((10#$day))"
  [ "$month" -ge 1 ] && [ "$month" -le 12 ] || return 1
  [ "$day" -ge 1 ] && [ "$day" -le 31 ] || return 1

  case "$month" in
    4|6|9|11)
      [ "$day" -le 30 ] || return 1
      ;;
    2)
      if [ $((10#$year % 400)) -eq 0 ] ||
         { [ $((10#$year % 4)) -eq 0 ] && [ $((10#$year % 100)) -ne 0 ]; }; then
        [ "$day" -le 29 ] || return 1
      else
        [ "$day" -le 28 ] || return 1
      fi
      ;;
  esac

  printf -v HISTORY_NORMALIZED_DATE '%04d-%02d-%02d' "$year" "$month" "$day"
  return 0
}

extract_history_date_from_changelog() {
  local file="$1"
  local expected_version="$2"
  local line=""
  local normalized=""
  local found_version=""
  local date_text=""
  local match_pattern=""

  HISTORY_CHANGELOG_DATE=""
  match_pattern="^[[:space:]]*#{0,6}[[:space:]]*\\[?[vV]?(${SEMVER_PATTERN})\\]?[[:space:]]*-[[:space:]]*(.+)$"

  while IFS= read -r line || [ -n "$line" ]; do
    normalized="${line%$'\r'}"
    normalized="${normalized//‐/-}"
    normalized="${normalized//‑/-}"
    normalized="${normalized//‒/-}"
    normalized="${normalized//–/-}"
    normalized="${normalized//—/-}"
    normalized="${normalized//−/-}"
    if [[ "$normalized" =~ $match_pattern ]]; then
      found_version="${BASH_REMATCH[1]}"
      date_text="${BASH_REMATCH[5]}"
      if [ "$found_version" = "$expected_version" ] && normalize_history_date "$date_text"; then
        HISTORY_CHANGELOG_DATE="$HISTORY_NORMALIZED_DATE"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

detect_history_release_date() {
  local directory="$1"
  local version="$2"
  local file=""
  local detected=""

  HISTORY_DETECTED_DATE=""
  while IFS= read -r -d '' file; do
    if extract_history_date_from_changelog "$file" "$version"; then
      if [ -z "$detected" ]; then
        detected="$HISTORY_CHANGELOG_DATE"
      elif [ "$detected" != "$HISTORY_CHANGELOG_DATE" ]; then
        return 1
      fi
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -type f -iname 'CHANGELOG*' -print0)

  if [ -n "$detected" ]; then
    HISTORY_DETECTED_DATE="$detected"
    return 0
  fi
  return 1
}

reset_history_releases() {
  HISTORY_RELEASE_VERSIONS=()
  HISTORY_RELEASE_DIRECTORIES=()
  HISTORY_RELEASE_DATES=()
  HISTORY_RELEASE_NEEDS_GITIGNORE=()
  HISTORY_RELEASE_COUNT=0
  HISTORY_CONFLICT_DIRECTORIES=()
  HISTORY_CONFLICT_FOLDER_VERSIONS=()
  HISTORY_CONFLICT_CONTENT_VERSIONS=()
  HISTORY_CONFLICT_COUNT=0
  HISTORY_SKIPPED_DIRECTORIES=()
  HISTORY_SKIPPED_COUNT=0
  HISTORY_GITIGNORE_CONTENT=""
  HISTORY_ADD_GITIGNORE=false
}

history_release_index() {
  local version="$1"
  local index=0

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    if [ "${HISTORY_RELEASE_VERSIONS[$index]}" = "$version" ]; then
      printf '%s' "$index"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

history_add_release() {
  local version="$1"
  local directory="$2"
  local date="${3:-}"

  valid_release_version "$version" || return 1
  [ -d "$directory" ] || return 1
  if history_release_index "$version" >/dev/null 2>&1; then
    return 2
  fi

  HISTORY_RELEASE_VERSIONS[$HISTORY_RELEASE_COUNT]="$version"
  HISTORY_RELEASE_DIRECTORIES[$HISTORY_RELEASE_COUNT]="$directory"
  HISTORY_RELEASE_DATES[$HISTORY_RELEASE_COUNT]="$date"
  if [ -e "$directory/.gitignore" ] || [ -L "$directory/.gitignore" ]; then
    HISTORY_RELEASE_NEEDS_GITIGNORE[$HISTORY_RELEASE_COUNT]="no"
  else
    HISTORY_RELEASE_NEEDS_GITIGNORE[$HISTORY_RELEASE_COUNT]="yes"
  fi
  HISTORY_RELEASE_COUNT=$((HISTORY_RELEASE_COUNT + 1))
  return 0
}

history_sort_releases() {
  local index=1
  local position=0
  local key_version=""
  local key_directory=""
  local key_date=""
  local key_gitignore=""
  local should_shift=false

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    key_version="${HISTORY_RELEASE_VERSIONS[$index]}"
    key_directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    key_date="${HISTORY_RELEASE_DATES[$index]}"
    key_gitignore="${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}"
    position="$index"

    while [ "$position" -gt 0 ]; do
      compare_semver "$key_version" "${HISTORY_RELEASE_VERSIONS[$((position - 1))]}"
      should_shift=false
      if [ "$SEMVER_COMPARISON" -lt 0 ]; then
        should_shift=true
      elif [ "$SEMVER_COMPARISON" -eq 0 ] &&
           [[ "$key_version" < "${HISTORY_RELEASE_VERSIONS[$((position - 1))]}" ]]; then
        should_shift=true
      fi
      [ "$should_shift" = true ] || break

      HISTORY_RELEASE_VERSIONS[$position]="${HISTORY_RELEASE_VERSIONS[$((position - 1))]}"
      HISTORY_RELEASE_DIRECTORIES[$position]="${HISTORY_RELEASE_DIRECTORIES[$((position - 1))]}"
      HISTORY_RELEASE_DATES[$position]="${HISTORY_RELEASE_DATES[$((position - 1))]}"
      HISTORY_RELEASE_NEEDS_GITIGNORE[$position]="${HISTORY_RELEASE_NEEDS_GITIGNORE[$((position - 1))]}"
      position=$((position - 1))
    done

    HISTORY_RELEASE_VERSIONS[$position]="$key_version"
    HISTORY_RELEASE_DIRECTORIES[$position]="$key_directory"
    HISTORY_RELEASE_DATES[$position]="$key_date"
    HISTORY_RELEASE_NEEDS_GITIGNORE[$position]="$key_gitignore"
    index=$((index + 1))
  done
}

history_scan_parent_directory() {
  local parent="$1"
  local directory=""
  local name=""
  local folder_version=""
  local content_version=""
  local chosen_version=""
  local date=""

  while IFS= read -r -d '' directory; do
    name="$(basename "$directory")"
    folder_version=""
    content_version=""
    chosen_version=""
    date=""

    if extract_version_from_directory_name "$name"; then
      folder_version="$HISTORY_DIRECTORY_VERSION"
    fi
    if detect_release_version_from_contents "$directory"; then
      content_version="$HISTORY_CONTENT_VERSION"
    fi

    if [ -n "$folder_version" ] && [ -n "$content_version" ] &&
       [ "$folder_version" != "$content_version" ]; then
      HISTORY_CONFLICT_DIRECTORIES[$HISTORY_CONFLICT_COUNT]="$directory"
      HISTORY_CONFLICT_FOLDER_VERSIONS[$HISTORY_CONFLICT_COUNT]="$folder_version"
      HISTORY_CONFLICT_CONTENT_VERSIONS[$HISTORY_CONFLICT_COUNT]="$content_version"
      HISTORY_CONFLICT_COUNT=$((HISTORY_CONFLICT_COUNT + 1))
      continue
    fi

    if [ -n "$folder_version" ]; then
      chosen_version="$folder_version"
    else
      chosen_version="$content_version"
    fi

    if [ -z "$chosen_version" ]; then
      HISTORY_SKIPPED_DIRECTORIES[$HISTORY_SKIPPED_COUNT]="$directory"
      HISTORY_SKIPPED_COUNT=$((HISTORY_SKIPPED_COUNT + 1))
      continue
    fi

    if detect_history_release_date "$directory" "$chosen_version"; then
      date="$HISTORY_DETECTED_DATE"
    fi
    if ! history_add_release "$chosen_version" "$directory" "$date"; then
      HISTORY_SKIPPED_DIRECTORIES[$HISTORY_SKIPPED_COUNT]="$directory"
      HISTORY_SKIPPED_COUNT=$((HISTORY_SKIPPED_COUNT + 1))
    fi
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -print0)
}

history_sensitive_name() {
  local name_lc=""

  name_lc="$(lowercase "$1")"
  case "$name_lc" in
    .env.example|.env.sample|.env.template|.env.defaults)
      return 1
      ;;
    .env|.env.*|.netrc|.npmrc|.pypirc|.git-credentials|credentials|credentials.json|id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.p12|*.pfx|*.key|*.kdbx)
      return 0
      ;;
  esac
  return 1
}

history_scan_risks() {
  local index=0
  local version=""
  local directory=""
  local file=""
  local relative=""
  local size=0

  HISTORY_SENSITIVE_FILES=()
  HISTORY_SENSITIVE_COUNT=0
  HISTORY_LARGE_FILES=()
  HISTORY_LARGE_COUNT=0

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    version="${HISTORY_RELEASE_VERSIONS[$index]}"
    directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    while IFS= read -r -d '' file; do
      relative="${file#"$directory"/}"
      [ "$(basename "$file")" != ".DS_Store" ] || continue
      size="$(file_size_bytes "$file" 2>/dev/null || printf '0')"
      if [ "$size" -gt "$HISTORY_MAX_FILE_BYTES" ] 2>/dev/null; then
        HISTORY_LARGE_FILES[$HISTORY_LARGE_COUNT]="$version: $relative ($size bytes)"
        HISTORY_LARGE_COUNT=$((HISTORY_LARGE_COUNT + 1))
      fi
      if history_sensitive_name "$(basename "$file")" ||
         LC_ALL=C grep -Iq -m 1 -- '-----BEGIN .*PRIVATE KEY-----' "$file" 2>/dev/null; then
        HISTORY_SENSITIVE_FILES[$HISTORY_SENSITIVE_COUNT]="$version: $relative"
        HISTORY_SENSITIVE_COUNT=$((HISTORY_SENSITIVE_COUNT + 1))
      fi
    done < <(
      find "$directory" \
        \( -name .git -prune \) -o \
        \( -type f -print0 \)
    )
    index=$((index + 1))
  done
}

history_collect_gitignore_content() {
  local line=""
  local first=true

  HISTORY_GITIGNORE_CONTENT=""
  advanced_muted \
    "Paste the .gitignore rules below, one rule per line." \
    "请逐行粘贴要写入 .gitignore 的规则。"
  advanced_muted \
    "Enter :done on a line by itself when finished, or :cancel to continue without adding one." \
    "全部输入完成后，请另起一行输入 :done；如果不想添加，请输入 :cancel。"

  while true; do
    printf '> '
    IFS= read -r line || return 1
    case "$line" in
      :done)
        break
        ;;
      :cancel)
        HISTORY_GITIGNORE_CONTENT=""
        return 1
        ;;
    esac
    if [ "$first" = true ]; then
      HISTORY_GITIGNORE_CONTENT="$line"
      first=false
    else
      HISTORY_GITIGNORE_CONTENT="$HISTORY_GITIGNORE_CONTENT
$line"
    fi
  done

  [ "$first" = false ]
}

history_resolve_version_conflicts() {
  local index=0
  local choice=""
  local version=""
  local date=""

  while [ "$index" -lt "$HISTORY_CONFLICT_COUNT" ]; do
    advanced_heading "Version conflict" "同一版本文件夹中出现了两个版本号"
    advanced_muted \
      "Folder: ${HISTORY_CONFLICT_DIRECTORIES[$index]}" \
      "文件夹：${HISTORY_CONFLICT_DIRECTORIES[$index]}"
    advanced_muted \
      "Folder name says ${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}, but its files say ${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}." \
      "从文件夹名称识别到 ${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}，从文件夹内容识别到 ${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}。"
    if [ "$ADVANCED_LANGUAGE" = "en" ]; then
      printf '  1) Use the folder-name version (recommended)\n'
      printf '  2) Use the version found inside the folder\n'
      printf '  0) Skip this folder\n'
    else
      printf '  1) 采用文件夹名称中的版本号（推荐）\n'
      printf '  2) 采用文件夹内容中的版本号\n'
      printf '  0) 跳过这个文件夹\n'
    fi

    while true; do
      choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
      case "$choice" in
        1)
          version="${HISTORY_CONFLICT_FOLDER_VERSIONS[$index]}"
          break
          ;;
        2)
          version="${HISTORY_CONFLICT_CONTENT_VERSIONS[$index]}"
          break
          ;;
        0)
          version=""
          break
          ;;
        *)
          advanced_warn "Enter a number from the list." "请输入列表中的序号。"
          ;;
      esac
    done

    if [ -n "$version" ]; then
      date=""
      if detect_history_release_date "${HISTORY_CONFLICT_DIRECTORIES[$index]}" "$version"; then
        date="$HISTORY_DETECTED_DATE"
      fi
      if ! history_add_release "$version" "${HISTORY_CONFLICT_DIRECTORIES[$index]}" "$date"; then
        advanced_warn \
          "Version $version is already in the release list, so this folder was skipped." \
          "版本 $version 已经在列表中，这个重复文件夹不会加入。"
      fi
    fi
    index=$((index + 1))
  done
}

history_add_manual_releases() {
  local default_answer="no"
  local input=""
  local directory=""
  local suggested=""
  local version=""
  local date=""

  if [ "$HISTORY_RELEASE_COUNT" -eq 0 ]; then
    default_answer="yes"
  fi

  while advanced_prompt_yes_no \
    "Add a release folder manually?" \
    "还要手动添加其他版本文件夹吗？" \
    "$default_answer"; do
    while true; do
      input="$(advanced_prompt_value "Release folder" "版本文件夹")" || return 1
      if normalize_history_directory_input "$input"; then
        directory="$HISTORY_NORMALIZED_DIRECTORY"
        break
      fi
      advanced_warn "That folder could not be opened." "无法打开这个文件夹。"
    done

    suggested=""
    if extract_version_from_directory_name "$(basename "$directory")"; then
      suggested="$HISTORY_DIRECTORY_VERSION"
    elif detect_release_version_from_contents "$directory"; then
      suggested="$HISTORY_CONTENT_VERSION"
    fi

    while true; do
      version="$(advanced_prompt_value "Release version" "版本号" "$suggested")" || return 1
      version="${version#v}"
      version="${version#V}"
      if valid_release_version "$version"; then
        break
      fi
      advanced_warn \
        "Use a semantic version such as 1.2.3 or 2.0.0-beta.1." \
        "请输入类似 1.2.3 或 2.0.0-beta.1 的语义化版本号。"
    done

    date=""
    if detect_history_release_date "$directory" "$version"; then
      date="$HISTORY_DETECTED_DATE"
    fi
    if history_add_release "$version" "$directory" "$date"; then
      advanced_success "Added release $version." "版本 ${version} 已加入列表。"
    else
      advanced_warn \
        "Version $version is already listed; the duplicate was not added." \
        "版本 $version 已存在，没有重复添加。"
    fi
    default_answer="no"
  done
}

history_show_release_plan() {
  local index=0
  local date_label=""
  local gitignore_label=""

  advanced_heading "Release plan" "确认要重建的版本与顺序"
  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    date_label="${HISTORY_RELEASE_DATES[$index]}"
    if [ -z "$date_label" ]; then
      if [ "$ADVANCED_LANGUAGE" = "en" ]; then
        date_label="import time"
      else
        date_label="导入时间"
      fi
    fi
    gitignore_label=""
    if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ]; then
      if [ "$ADVANCED_LANGUAGE" = "en" ]; then
        gitignore_label="; no .gitignore"
      else
        gitignore_label="；缺少 .gitignore"
      fi
    fi
    printf '  %s) %s  [%s%s]\n' \
      "$((index + 1))" \
      "${HISTORY_RELEASE_VERSIONS[$index]}" \
      "$date_label" \
      "$gitignore_label"
    printf '     %s\n' "${HISTORY_RELEASE_DIRECTORIES[$index]}"
    index=$((index + 1))
  done
}

history_offer_missing_gitignore() {
  local index=0
  local missing_count=0
  local versions=""

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ]; then
      missing_count=$((missing_count + 1))
      if [ -z "$versions" ]; then
        versions="${HISTORY_RELEASE_VERSIONS[$index]}"
      else
        versions="$versions, ${HISTORY_RELEASE_VERSIONS[$index]}"
      fi
    fi
    index=$((index + 1))
  done

  [ "$missing_count" -gt 0 ] || return 0
  advanced_heading "Missing .gitignore" "部分版本没有 .gitignore"
  advanced_muted \
    "$missing_count release(s) have no root .gitignore: $versions" \
    "以下 $missing_count 个版本的根目录中没有 .gitignore：$versions"
  advanced_muted \
    "You can supply one shared file for only those missing releases. Existing .gitignore files will not be replaced." \
    "你可以输入一份通用规则，脚本只会把它补到缺失的版本中，不会覆盖已经存在的 .gitignore。"
  if advanced_prompt_yes_no \
    "Add .gitignore content to the missing releases?" \
    "为缺失版本补充 .gitignore 内容？" \
    "yes"; then
    if history_collect_gitignore_content; then
      HISTORY_ADD_GITIGNORE=true
      advanced_success \
        "The supplied .gitignore will be added to missing snapshots." \
        "重建时会为缺失的版本补上这份 .gitignore。"
    else
      HISTORY_ADD_GITIGNORE=false
      advanced_warn \
        "No .gitignore content will be added." \
        "不会补充 .gitignore 内容。"
    fi
  fi
}

history_print_limited_list() {
  local kind="$1"
  local count=0
  local index=0
  local limit=12

  if [ "$kind" = "large" ]; then
    count="$HISTORY_LARGE_COUNT"
    while [ "$index" -lt "$count" ] && [ "$index" -lt "$limit" ]; do
      printf '  - %s\n' "${HISTORY_LARGE_FILES[$index]}"
      index=$((index + 1))
    done
  else
    count="$HISTORY_SENSITIVE_COUNT"
    while [ "$index" -lt "$count" ] && [ "$index" -lt "$limit" ]; do
      printf '  - %s\n' "${HISTORY_SENSITIVE_FILES[$index]}"
      index=$((index + 1))
    done
  fi

  if [ "$count" -gt "$limit" ]; then
    advanced_muted \
      "...and $((count - limit)) more." \
      "……以及另外 $((count - limit)) 项。"
  fi
}

history_review_risks() {
  history_scan_risks

  if [ "$HISTORY_LARGE_COUNT" -gt 0 ]; then
    advanced_heading "Files too large for a normal GitHub push" "发现 GitHub 无法直接接收的大文件"
    history_print_limited_list large
    advanced_error \
      "Remove or redesign these files before rebuilding history. No temporary repository was created." \
      "请先从存档中移除这些文件，或改用适合大文件的方案。脚本尚未创建临时仓库。"
    return 1
  fi

  if [ "$HISTORY_SENSITIVE_COUNT" -gt 0 ]; then
    advanced_heading "Sensitive-looking files found" "发现可能不适合公开的文件"
    history_print_limited_list sensitive
    advanced_muted \
      "Complete snapshots include these files. Confirm only after checking that they are safe to publish." \
      "完整快照会原样包含这些文件。请逐项确认它们可以上传到 GitHub。"
    if ! advanced_prompt_yes_no \
      "Include these files and continue?" \
      "已经检查完毕，仍然包含这些文件并继续吗？" \
      "no"; then
      advanced_warn "Import stopped before any repository was created." "操作已停止；尚未创建临时仓库，也没有修改远端。"
      return 1
    fi
  fi
  return 0
}

advanced_verify_key_matches_username() {
  local private_key="$1"
  local expected_username="$2"

  advanced_info "Verifying the exact GitHub account..." "正在核对这把密钥对应的 GitHub 账号……"
  if ! identify_key_username "$private_key"; then
    advanced_error \
      "GitHub did not accept this account's key." \
      "GitHub 无法使用这把密钥完成身份验证。"
    if [ -n "${SSH_VERIFICATION_OUTPUT:-}" ]; then
      muted "${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    fi
    return 1
  fi
  if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" != "$(lowercase "$expected_username")" ]; then
    advanced_error \
      "This key authenticates as $VERIFIED_GITHUB_USERNAME, not $expected_username." \
      "该密钥实际属于 ${VERIFIED_GITHUB_USERNAME}，而不是 ${expected_username}。"
    return 1
  fi
  advanced_success \
    "Verified GitHub account: $VERIFIED_GITHUB_USERNAME" \
    "已确认 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
}

advanced_add_account() {
  local username=""
  local email=""
  local default_email=""

  while true; do
    username="$(advanced_prompt_value "GitHub username" "GitHub 用户名")" || return 1
    username="$(lowercase "$username")"
    if valid_github_username "$username"; then
      break
    fi
    advanced_warn \
      "GitHub usernames normally contain only letters, numbers, and hyphens." \
      "GitHub 用户名通常只包含字母、数字和连字符。"
  done

  default_email="$(default_email_for_username "$username")"
  while true; do
    email="$(advanced_prompt_value "Commit email" "提交邮箱" "$default_email")" || return 1
    if valid_email "$email"; then
      break
    fi
    advanced_warn "The email format was not recognized." "邮箱格式无法识别。"
  done

  if ! check_saved_account_identity "$username" "$email"; then
    return 1
  fi

  add_or_update_account "$username" "$email"
  write_accounts_to_private_config
  BOUND_USERNAME="$username"
  BOUND_EMAIL="$email"
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  advanced_success \
    "Saved account $username and its commit email in private/config.txt." \
    "已把账号 $username 和提交邮箱保存到 private/config.txt。"
}

advanced_select_account_for_history() {
  local owner="$1"
  local index=""
  local answer=""

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    advanced_info \
      "No GitHub account is configured yet. The next two answers are the only account details needed." \
      "还没有可用的 GitHub 账号配置。你只需填写用户名和提交邮箱，其余连接设置由脚本完成。"
    advanced_add_account || return 1
    return 0
  fi

  if index="$(account_index "$owner" 2>/dev/null)"; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
  elif [ "$ACCOUNT_COUNT" -eq 1 ]; then
    BOUND_USERNAME="${ACCOUNT_USERNAMES[0]}"
    BOUND_EMAIL="${ACCOUNT_EMAILS[0]}"
  else
    advanced_heading "Choose the GitHub account" "选择此次上传使用的 GitHub 账号"
    list_accounts_compact
    if [ "$ADVANCED_LANGUAGE" = "en" ]; then
      printf '  n) Add another account\n'
    else
      printf '  n) 添加另一个账号\n'
    fi
    while true; do
      answer="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
      if [ "$(lowercase "$answer")" = "n" ]; then
        advanced_add_account || return 1
        return 0
      fi
      if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$ACCOUNT_COUNT" ]; then
        index=$((answer - 1))
        BOUND_USERNAME="${ACCOUNT_USERNAMES[$index]}"
        BOUND_EMAIL="${ACCOUNT_EMAILS[$index]}"
        break
      fi
      advanced_warn "Enter a number from the list." "请输入列表中的序号。"
    done
  fi

  check_saved_account_identity "$BOUND_USERNAME" "$BOUND_EMAIL" || return 1
  BOUND_SSH_ALIAS="$FOUND_SSH_ALIAS"
  BOUND_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
  return 0
}

advanced_verify_repository_access() {
  local target="$1"
  local GIT_ROOT="$SCRIPT_DIRECTORY"
  local output=""
  local detail=""

  while true; do
    advanced_info \
      "Reading ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} with account $BOUND_USERNAME; this check does not upload or change the repository." \
      "正在用账号 $BOUND_USERNAME 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME} 的远端信息；这一步不会上传或修改仓库。"
    output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote "$target" HEAD 2>&1)" && {
      advanced_success \
        "GitHub allowed account $BOUND_USERNAME to read ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
        "GitHub 已允许账号 $BOUND_USERNAME 读取 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
      return 0
    }
    advanced_error \
      "Account $BOUND_USERNAME cannot currently access ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}." \
      "账号 $BOUND_USERNAME 当前无法访问 ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      advanced_muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    advanced_muted \
      "Make sure the repository exists and this account has access: https://github.com/new" \
      "请确认仓库已经创建，且该账号拥有访问权限：https://github.com/new"
    if ! advanced_prompt_yes_no \
      "Run the same read-only access check again?" \
      "要再次执行同一项只读访问检查吗？" \
      "yes"; then
      return 1
    fi
  done
}

advanced_prepare_history_destination() {
  local input=""
  local remote_url=""

  advanced_heading "Destination repository" "选择接收重建历史的仓库"
  advanced_muted \
    "Paste owner/repository, a GitHub page URL, HTTPS URL, or SSH URL." \
    "可以粘贴 owner/repository、GitHub 网页地址、HTTPS 或 SSH 地址。"
  while true; do
    input="$(advanced_prompt_value "Repository" "仓库地址")" || return 1
    if parse_repository_input "$input"; then
      break
    fi
    advanced_warn "That GitHub repository address was not recognized." "未能从输入内容中识别出 GitHub 仓库，请检查后重试。"
  done
  CURRENT_REPOSITORY_OWNER="$REPOSITORY_OWNER"
  CURRENT_REPOSITORY_NAME="$REPOSITORY_NAME"

  advanced_select_account_for_history "$CURRENT_REPOSITORY_OWNER" || return 1
  if ! advanced_verify_key_matches_username "$BOUND_IDENTITY_FILE" "$BOUND_USERNAME"; then
    return 1
  fi
  remote_url="git@${BOUND_SSH_ALIAS}:${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}.git"
  advanced_verify_repository_access "$remote_url" || return 1
  HISTORY_REMOTE_URL="$remote_url"
}

history_safe_temporary_path() {
  local path="$1"
  local kind="$2"
  local base="${TMPDIR:-/tmp}"

  base="${base%/}"
  [ -n "$path" ] || return 1
  [ "$path" != "/" ] || return 1
  [ "$path" != "${HOME:-}" ] || return 1
  case "$path" in
    "$base/github-auto-${kind}."*)
      return 0
      ;;
  esac
  return 1
}

history_temporary_base() {
  local base="${TMPDIR:-/tmp}"

  printf '%s' "${base%/}"
}

history_remove_temporary_directory() {
  local path="$1"
  local kind="$2"

  history_safe_temporary_path "$path" "$kind" || return 1
  rm -rf "$path"
}

history_prepare_snapshot_copy() {
  local source_directory="$1"
  local snapshot_directory=""
  local unwanted=""

  snapshot_directory="$(mktemp -d "$(history_temporary_base)/github-auto-snapshot.XXXXXX")" || return 1
  if ! cp -Rp "$source_directory/." "$snapshot_directory/"; then
    history_remove_temporary_directory "$snapshot_directory" snapshot || true
    return 1
  fi

  chmod -R u+w "$snapshot_directory" 2>/dev/null || true
  while IFS= read -r -d '' unwanted; do
    rm -rf "$unwanted"
  done < <(
    find "$snapshot_directory" \
      \( -name .git -print0 -prune \) -o \
      \( -name .DS_Store -print0 \)
  )
  HISTORY_SNAPSHOT_DIRECTORY="$snapshot_directory"
}

history_replace_worktree_snapshot() {
  local work_directory="$1"
  local source_directory="$2"
  local entry=""

  [ -f "$work_directory/.git/github-auto-history-workspace" ] || return 1
  history_prepare_snapshot_copy "$source_directory" || return 1

  while IFS= read -r -d '' entry; do
    chmod -R u+w "$entry" 2>/dev/null || true
    rm -rf "$entry"
  done < <(find "$work_directory" -mindepth 1 -maxdepth 1 ! -name .git -print0)

  if ! cp -Rp "$HISTORY_SNAPSHOT_DIRECTORY/." "$work_directory/"; then
    history_remove_temporary_directory "$HISTORY_SNAPSHOT_DIRECTORY" snapshot || true
    return 1
  fi
  history_remove_temporary_directory "$HISTORY_SNAPSHOT_DIRECTORY" snapshot || return 1
}

history_build_repository() {
  local index=0
  local version=""
  local source_directory=""
  local release_date=""
  local commit_date=""
  local work_directory=""
  local short_commit=""
  local GIT_ROOT=""

  work_directory="$(mktemp -d "$(history_temporary_base)/github-auto-history.XXXXXX")" || return 1
  HISTORY_WORK_DIRECTORY="$work_directory"
  GIT_ROOT="$work_directory"

  if ! git -C "$work_directory" init -q; then
    return 1
  fi
  : > "$work_directory/.git/github-auto-history-workspace"
  git -C "$work_directory" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$work_directory" config --local user.name "$BOUND_USERNAME" || return 1
  git -C "$work_directory" config --local user.email "$BOUND_EMAIL" || return 1
  git -C "$work_directory" config --local github-auto.username "$BOUND_USERNAME" || return 1
  git -C "$work_directory" config --local github-auto.ssh-alias "$BOUND_SSH_ALIAS" || return 1
  git -C "$work_directory" config --local github-auto.identity-file "$BOUND_IDENTITY_FILE" || return 1
  git -C "$work_directory" remote add origin "$HISTORY_REMOTE_URL" || return 1

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    version="${HISTORY_RELEASE_VERSIONS[$index]}"
    source_directory="${HISTORY_RELEASE_DIRECTORIES[$index]}"
    release_date="${HISTORY_RELEASE_DATES[$index]}"
    advanced_info \
      "Building complete snapshot for release $version..." \
      "正在整理版本 $version 的完整文件快照……"

    if ! history_replace_worktree_snapshot "$work_directory" "$source_directory"; then
      return 1
    fi
    if [ "${HISTORY_RELEASE_NEEDS_GITIGNORE[$index]}" = "yes" ] &&
       [ "$HISTORY_ADD_GITIGNORE" = true ] &&
       [ ! -e "$work_directory/.gitignore" ] &&
       [ ! -L "$work_directory/.gitignore" ]; then
      printf '%s\n' "$HISTORY_GITIGNORE_CONTENT" > "$work_directory/.gitignore" || return 1
    fi

    git -C "$work_directory" add -A -f || return 1
    if [ -n "$release_date" ]; then
      commit_date="${release_date}T12:00:00 +0000"
      if ! GIT_AUTHOR_DATE="$commit_date" GIT_COMMITTER_DATE="$commit_date" \
        git -C "$work_directory" commit --allow-empty -q -m "Release $version"; then
        return 1
      fi
    elif ! git -C "$work_directory" commit --allow-empty -q -m "Release $version"; then
      return 1
    fi

    if [ "$HISTORY_CREATE_TAGS" = true ]; then
      git -C "$work_directory" tag "v$version" || return 1
    fi
    short_commit="$(git -C "$work_directory" rev-parse --short HEAD)"
    advanced_success \
      "Release $version created at $short_commit." \
      "版本 ${version} 已生成提交 ${short_commit}。"
    index=$((index + 1))
  done
  return 0
}

HISTORY_REMOTE_MAIN_OID=""
HISTORY_NEW_TAGS=()
HISTORY_NEW_TAG_COUNT=0
HISTORY_CONFLICT_TAGS=()
HISTORY_CONFLICT_TAG_REMOTE_OIDS=()
HISTORY_CONFLICT_TAG_COUNT=0
HISTORY_REPLACE_CONFLICTING_TAGS=false

history_read_remote_main() {
  local output=""

  HISTORY_REMOTE_MAIN_OID=""
  output="$(run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote --heads origin refs/heads/main 2>/dev/null)" || return 1
  HISTORY_REMOTE_MAIN_OID="$(printf '%s\n' "$output" | awk '$2 == "refs/heads/main" { print $1; exit }')"
}

history_collect_remote_tag_state() {
  local output_file=""
  local index=0
  local tag=""
  local local_oid=""
  local remote_oid=""

  HISTORY_NEW_TAGS=()
  HISTORY_NEW_TAG_COUNT=0
  HISTORY_CONFLICT_TAGS=()
  HISTORY_CONFLICT_TAG_REMOTE_OIDS=()
  HISTORY_CONFLICT_TAG_COUNT=0
  [ "$HISTORY_CREATE_TAGS" = true ] || return 0

  output_file="$(safe_mktemp_file "${TMPDIR:-/tmp}" "remote-tags")" || return 1
  if ! run_git_with_identity "$BOUND_IDENTITY_FILE" ls-remote --tags origin > "$output_file" 2>/dev/null; then
    rm -f "$output_file"
    return 1
  fi

  while [ "$index" -lt "$HISTORY_RELEASE_COUNT" ]; do
    tag="v${HISTORY_RELEASE_VERSIONS[$index]}"
    local_oid="$(git -C "$GIT_ROOT" rev-parse "refs/tags/$tag")"
    remote_oid="$(awk -v ref="refs/tags/$tag" '$2 == ref { print $1; exit }' "$output_file")"
    if [ -z "$remote_oid" ]; then
      HISTORY_NEW_TAGS[$HISTORY_NEW_TAG_COUNT]="$tag"
      HISTORY_NEW_TAG_COUNT=$((HISTORY_NEW_TAG_COUNT + 1))
    elif [ "$remote_oid" != "$local_oid" ]; then
      HISTORY_CONFLICT_TAGS[$HISTORY_CONFLICT_TAG_COUNT]="$tag"
      HISTORY_CONFLICT_TAG_REMOTE_OIDS[$HISTORY_CONFLICT_TAG_COUNT]="$remote_oid"
      HISTORY_CONFLICT_TAG_COUNT=$((HISTORY_CONFLICT_TAG_COUNT + 1))
    fi
    index=$((index + 1))
  done
  rm -f "$output_file"
}

history_confirm_tag_conflicts() {
  local index=0

  HISTORY_REPLACE_CONFLICTING_TAGS=false
  [ "$HISTORY_CONFLICT_TAG_COUNT" -gt 0 ] || return 0
  advanced_heading "Existing version tags" "远端存在同名版本标签"
  advanced_muted \
    "These remote tags point to the old history:" \
    "以下远端版本标签仍指向旧历史："
  while [ "$index" -lt "$HISTORY_CONFLICT_TAG_COUNT" ]; do
    printf '  - %s\n' "${HISTORY_CONFLICT_TAGS[$index]}"
    index=$((index + 1))
  done
  advanced_muted \
    "Replacing them makes the tags match the rebuilt release commits. Declining leaves those existing tags unchanged." \
    "选择替换后，这些标签会改为指向重建后的版本提交；选择不替换则保持现状。"
  if advanced_prompt_yes_no \
    "Replace these conflicting tags?" \
    "把这些同名标签更新到重建后的提交吗？" \
    "yes"; then
    HISTORY_REPLACE_CONFLICTING_TAGS=true
  fi
}

history_push_main_branch() {
  local initial_oid="$HISTORY_REMOTE_MAIN_OID"
  local expected_oid=""

  if [ -z "$initial_oid" ]; then
    advanced_info \
      "The remote has no main branch. A normal push will create it without overwriting another branch." \
      "远端目前没有 main 分支。脚本会正常新建 main，不会覆盖已有分支。"
    run_git_with_identity "$BOUND_IDENTITY_FILE" push -u origin main:main
    return
  fi

  advanced_heading "Remote main already has history" "远端的 main 分支已有提交记录"
  advanced_muted \
    "Replacing main will make the rebuilt releases the new main history. Other remote branches are not changed." \
    "继续后，重建的版本记录会取代现有的 main 历史；其他远端分支不会受到影响。"
  advanced_muted \
    "No backup branch will be created. Anyone using the old main history will need to resynchronize." \
    "脚本不会额外创建备份分支。已经拉取过旧 main 的协作者需要重新同步本地仓库。"
  advanced_muted "Current remote main: $initial_oid" "当前远端 main：$initial_oid"
  if ! advanced_prompt_yes_no \
    "Replace remote main with the rebuilt history?" \
    "确认用重建后的历史替换远端 main 吗？" \
    "no"; then
    return 2
  fi

  if ! run_git_with_identity "$BOUND_IDENTITY_FILE" fetch -q origin \
    +refs/heads/main:refs/remotes/origin/main; then
    return 1
  fi
  expected_oid="$(git -C "$GIT_ROOT" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  if [ -z "$expected_oid" ] || [ "$expected_oid" != "$initial_oid" ]; then
    advanced_error \
      "Remote main changed during confirmation. Nothing was overwritten; run the check again." \
      "确认期间远端 main 已发生变化；当前没有覆盖任何内容，请重新检查。"
    return 1
  fi

  run_git_with_identity "$BOUND_IDENTITY_FILE" push -u \
    "--force-with-lease=refs/heads/main:$expected_oid" \
    origin main:main
}

history_push_tags() {
  local index=0
  local tag=""
  local expected_oid=""

  [ "$HISTORY_CREATE_TAGS" = true ] || return 0
  while [ "$index" -lt "$HISTORY_NEW_TAG_COUNT" ]; do
    tag="${HISTORY_NEW_TAGS[$index]}"
    if ! run_git_with_identity "$BOUND_IDENTITY_FILE" push origin \
      "refs/tags/$tag:refs/tags/$tag" >/dev/null; then
      return 1
    fi
    index=$((index + 1))
  done

  if [ "$HISTORY_REPLACE_CONFLICTING_TAGS" = true ]; then
    index=0
    while [ "$index" -lt "$HISTORY_CONFLICT_TAG_COUNT" ]; do
      tag="${HISTORY_CONFLICT_TAGS[$index]}"
      expected_oid="${HISTORY_CONFLICT_TAG_REMOTE_OIDS[$index]}"
      if ! run_git_with_identity "$BOUND_IDENTITY_FILE" push \
        "--force-with-lease=refs/tags/$tag:$expected_oid" \
        origin "refs/tags/$tag:refs/tags/$tag" >/dev/null; then
        return 1
      fi
      index=$((index + 1))
    done
  fi
  return 0
}

history_publish_repository() {
  local GIT_ROOT="$HISTORY_WORK_DIRECTORY"
  local push_status=0

  advanced_info "Reading the latest remote state..." "正在确认远端仓库是否发生变化……"
  history_read_remote_main || return 1
  history_collect_remote_tag_state || return 1
  history_confirm_tag_conflicts

  history_push_main_branch || push_status=$?
  if [ "$push_status" -eq 2 ]; then
    advanced_warn \
      "No remote changes were made. The rebuilt repository remains available locally." \
      "没有更改远端；重建仓库仍保留在本地。"
    return 2
  elif [ "$push_status" -ne 0 ]; then
    advanced_error \
      "The main branch was not uploaded. No unprotected force push was attempted." \
      "main 分支未上传；脚本没有执行普通强制推送，远端内容保持不变。"
    return 1
  fi

  if ! history_push_tags; then
    advanced_error \
      "The main branch was uploaded, but one or more version tags failed. The temporary repository was kept for repair." \
      "main 分支已经上传，但部分版本标签上传失败。临时仓库已保留，可用于补充处理。"
    return 1
  fi
  return 0
}

run_historical_release_import() {
  local input=""
  local parent=""
  local index=0
  local choice=""
  local publish_status=0

  reset_history_releases
  HISTORY_WORK_DIRECTORY=""
  HISTORY_CREATE_TAGS=true

  advanced_heading "Rebuild Git history from historical releases" "用历史版本文件夹重建 Git 历史"
  advanced_muted \
    "Use this when complete release snapshots exist as folders but no useful Git history exists." \
    "如果各个历史版本只保存在独立文件夹里、没有可用的 Git 提交记录，可以使用这个功能。"
  advanced_muted \
    "The source folders stay read-only. Each release becomes one complete snapshot commit in semantic-version order." \
    "脚本不会改动这些存档，而是在临时仓库中按语义化版本从旧到新生成完整快照提交。"
  advanced_muted \
    ".git entries and .DS_Store files are excluded. Other hidden and ignored files are included after a safety review." \
    "每一层的 .git 和 .DS_Store 都会自动排除；其他隐藏文件和被忽略文件会在安全检查后保留。"
  advanced_muted \
    "Nothing is uploaded until the rebuilt log is shown and you explicitly approve the remote action." \
    "完成重建后会先展示提交顺序和结果；只有你明确确认，脚本才会上传。"
  if ! advanced_prompt_yes_no "Start the guided import?" "开始检查这些历史版本吗？" "yes"; then
    return 0
  fi

  advanced_heading "Historical release folders" "选择历史版本所在位置"
  advanced_muted \
    "Enter or drag in the parent folder whose immediate subfolders contain the releases." \
    "请输入或直接拖入父文件夹。脚本会把其中的直接子文件夹分别视为候选版本。"
  while true; do
    input="$(advanced_prompt_value "Parent folder" "父文件夹")" || return 1
    if normalize_history_directory_input "$input"; then
      parent="$HISTORY_NORMALIZED_DIRECTORY"
      break
    fi
    advanced_warn "That folder could not be opened." "无法打开这个文件夹。"
  done

  advanced_info "Scanning release folders..." "正在识别版本号和发布日期……"
  history_scan_parent_directory "$parent"
  history_resolve_version_conflicts || return 1

  if [ "$HISTORY_SKIPPED_COUNT" -gt 0 ]; then
    advanced_warn \
      "$HISTORY_SKIPPED_COUNT folder(s) had no usable unique version and were skipped." \
      "有 $HISTORY_SKIPPED_COUNT 个子文件夹未识别出唯一版本号，因此没有自动加入列表。"
    index=0
    while [ "$index" -lt "$HISTORY_SKIPPED_COUNT" ] && [ "$index" -lt 8 ]; do
      printf '  - %s\n' "${HISTORY_SKIPPED_DIRECTORIES[$index]}"
      index=$((index + 1))
    done
  fi

  history_add_manual_releases || return 1
  if [ "$HISTORY_RELEASE_COUNT" -eq 0 ]; then
    advanced_error "No release folders were selected." "没有找到可导入的版本文件夹。"
    return 1
  fi

  history_sort_releases
  history_show_release_plan
  if ! advanced_prompt_yes_no \
    "Use this order and these versions?" \
    "以上版本号和排列顺序是否正确？" \
    "yes"; then
    advanced_warn "Import canceled before any files were copied." "导入已取消；尚未复制文件，也没有修改远端。"
    return 0
  fi

  history_offer_missing_gitignore
  history_review_risks || return 1
  if advanced_prompt_yes_no \
    "Create a vX.Y.Z tag for every release commit?" \
    "为每个版本创建对应的 vX.Y.Z 标签吗？" \
    "yes"; then
    HISTORY_CREATE_TAGS=true
  else
    HISTORY_CREATE_TAGS=false
  fi

  advanced_prepare_history_destination || return 1

  advanced_heading "Review the temporary history construction" "核对即将创建的临时历史"
  advanced_muted \
    "$HISTORY_RELEASE_COUNT release commit(s) will be created on main in a new temporary repository." \
    "脚本将在一个全新的临时 Git 仓库中创建 $HISTORY_RELEASE_COUNT 个版本提交，并统一使用 main 分支。"
  advanced_muted "GitHub account: $BOUND_USERNAME" "GitHub 账号：$BOUND_USERNAME"
  advanced_muted \
    "Repository: ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}" \
    "仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}"
  if ! advanced_prompt_yes_no \
    "Build the temporary repository now without uploading it?" \
    "现在只创建临时仓库、暂不上传吗？" \
    "yes"; then
    return 0
  fi

  if ! history_build_repository; then
    advanced_error "History construction stopped." "未能完成历史重建。"
    if [ -n "$HISTORY_WORK_DIRECTORY" ]; then
      advanced_muted \
        "The temporary workspace was kept for inspection: $HISTORY_WORK_DIRECTORY" \
        "临时仓库已保留，可以在这里检查：$HISTORY_WORK_DIRECTORY"
    fi
    return 1
  fi

  advanced_heading "Rebuilt history" "历史重建完成"
  git -C "$HISTORY_WORK_DIRECTORY" log --oneline --reverse
  advanced_muted \
    "These are newly reconstructed commits. They preserve snapshot order and reliable release dates, not any missing original commit metadata." \
    "这些提交由版本快照重新生成，能够还原文件变化顺序和可靠的发布日期，但无法恢复已经遗失的原始提交信息。"

  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '  1) Upload this history to GitHub\n'
    printf '  2) Keep the temporary repository without uploading\n'
    printf '  0) Delete the temporary repository and cancel\n'
  else
    printf '  1) 确认无误，上传到 GitHub\n'
    printf '  2) 暂不上传，保留临时仓库\n'
    printf '  0) 取消并删除临时仓库\n'
  fi
  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        break
        ;;
      2)
        advanced_success \
          "Temporary repository kept at: $HISTORY_WORK_DIRECTORY" \
          "临时仓库已保留：$HISTORY_WORK_DIRECTORY"
        return 0
        ;;
      0)
        history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
        HISTORY_WORK_DIRECTORY=""
        advanced_success "Temporary repository deleted. No remote changes were made." "临时仓库已删除，没有修改远端仓库。"
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done

  history_publish_repository || publish_status=$?
  if [ "$publish_status" -ne 0 ]; then
    advanced_muted \
      "Temporary repository kept at: $HISTORY_WORK_DIRECTORY" \
      "临时仓库已保留：$HISTORY_WORK_DIRECTORY"
    return "$publish_status"
  fi

  advanced_success \
    "Historical releases were uploaded successfully." \
    "历史版本已按顺序重建并上传。"
  history_remove_temporary_directory "$HISTORY_WORK_DIRECTORY" history || true
  HISTORY_WORK_DIRECTORY=""
  return 0
}

run_advanced_menu() {
  local choice=""

  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  while true; do
    advanced_heading "Advanced features" "高级功能"
    if [ "$ADVANCED_LANGUAGE" = "en" ]; then
      printf '  1) Rebuild Git history from historical release folders\n'
      printf '  0) Return\n'
    else
      printf '  1) 用历史版本文件夹重建 Git 历史\n'
      printf '  0) 返回\n'
    fi
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        run_historical_release_import || true
        advanced_pause
        ;;
      0)
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Guided account and repository updates
# -----------------------------------------------------------------------------

UPDATE_OLD_USERNAME=""
UPDATE_OLD_EMAIL=""
UPDATE_OLD_OWNER=""
UPDATE_OLD_REPOSITORY=""
UPDATE_NEW_USERNAME=""
UPDATE_NEW_EMAIL=""
UPDATE_NEW_OWNER=""
UPDATE_NEW_REPOSITORY=""
UPDATE_OLD_ALIAS=""
UPDATE_NEW_ALIAS=""
UPDATE_IDENTITY_FILE=""
UPDATE_ACCOUNT_USERNAME=""
UPDATE_INSTALL_ALIAS=false

update_select_current_account() {
  local saved_username=""
  local index=""
  local choice=""

  saved_username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
  if [ -n "$saved_username" ] && index="$(account_index "$saved_username")"; then
    UPDATE_ACCOUNT_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_EMAIL="${ACCOUNT_EMAILS[$index]}"
    return 0
  fi

  if index="$(account_index "$CURRENT_REPOSITORY_OWNER")"; then
    UPDATE_ACCOUNT_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_USERNAME="${ACCOUNT_USERNAMES[$index]}"
    UPDATE_OLD_EMAIL="${ACCOUNT_EMAILS[$index]}"
    return 0
  fi

  if [ "$ACCOUNT_COUNT" -eq 1 ]; then
    UPDATE_ACCOUNT_USERNAME="${ACCOUNT_USERNAMES[0]}"
    UPDATE_OLD_USERNAME="${ACCOUNT_USERNAMES[0]}"
    UPDATE_OLD_EMAIL="${ACCOUNT_EMAILS[0]}"
    return 0
  fi

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    advanced_error \
      "No GitHub account is configured in private/config.txt. Run ./$SCRIPT_NAME new first." \
      "private/config.txt 中还没有 GitHub 账号。请先运行 ./$SCRIPT_NAME new。"
    return 1
  fi

  advanced_heading \
    "Which account does this project use?" \
    "这个项目原来使用哪个 GitHub 账号？"
  index=0
  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    printf '  %s) %s\n' "$((index + 1))" "${ACCOUNT_USERNAMES[$index]}"
    index=$((index + 1))
  done

  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] &&
       [ "$choice" -ge 1 ] && [ "$choice" -le "$ACCOUNT_COUNT" ]; then
      index=$((choice - 1))
      UPDATE_ACCOUNT_USERNAME="${ACCOUNT_USERNAMES[$index]}"
      UPDATE_OLD_USERNAME="${ACCOUNT_USERNAMES[$index]}"
      UPDATE_OLD_EMAIL="${ACCOUNT_EMAILS[$index]}"
      return 0
    fi
    advanced_warn "Enter a number from the list." "请输入列表中的序号。"
  done
}

update_prompt_username() {
  local suggested_username="${1:-}"
  local username=""

  while true; do
    username="$(advanced_prompt_value "New GitHub username" "新的 GitHub 用户名" "$suggested_username")" || return 1
    username="$(lowercase "$username")"
    if ! valid_github_username "$username"; then
      advanced_warn \
        "A GitHub username normally contains only letters, numbers, and hyphens." \
        "GitHub 用户名通常只包含字母、数字和连字符，请重新输入。"
      continue
    fi
    if [ "$(lowercase "$username")" = "$(lowercase "$UPDATE_OLD_USERNAME")" ]; then
      advanced_warn \
        "That is the current username. Enter the new username." \
        "这仍是当前用户名，请填写修改后的新用户名。"
      suggested_username=""
      continue
    fi
    printf '%s' "$username"
    return 0
  done
}

update_suggest_email() {
  local username="$1"
  local current_email="$2"

  case "$(lowercase "$current_email")" in
    *@users.noreply.github.com)
      default_email_for_username "$username"
      ;;
    *)
      printf '%s' "$current_email"
      ;;
  esac
}

update_prompt_email() {
  local username="$1"
  local suggested_email=""
  local email=""

  suggested_email="$(update_suggest_email "$username" "$UPDATE_OLD_EMAIL")"
  while true; do
    email="$(advanced_prompt_value "Commit email" "提交邮箱" "$suggested_email")" || return 1
    if valid_email "$email"; then
      printf '%s' "$email"
      return 0
    fi
    advanced_warn "Enter a valid email address." "这个邮箱地址无法识别，请重新输入。"
  done
}

valid_repository_name() {
  local name="$1"

  [ -n "$name" ] || return 1
  [ "$name" != "." ] && [ "$name" != ".." ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

update_parse_repository_target() {
  local value=""
  local default_owner="$2"

  UPDATE_NEW_OWNER=""
  UPDATE_NEW_REPOSITORY=""
  value="$(trim "$1")"
  value="$(strip_optional_quotes "$value")"

  if [[ "$value" != */* ]] && [[ "$value" != *:* ]]; then
    case "$(lowercase "$value")" in
      *.git)
        value="${value%.*}"
        ;;
    esac
    if valid_repository_name "$value"; then
      UPDATE_NEW_OWNER="$default_owner"
      UPDATE_NEW_REPOSITORY="$value"
      return 0
    fi
    return 1
  fi

  if parse_repository_input "$value"; then
    UPDATE_NEW_OWNER="$REPOSITORY_OWNER"
    UPDATE_NEW_REPOSITORY="$REPOSITORY_NAME"
    return 0
  fi
  return 1
}

update_prompt_repository() {
  local default_owner="$1"
  local value=""

  advanced_muted \
    "Enter only the new repository name, or paste any common GitHub repository address." \
    "只填写新的仓库名即可，也可以直接粘贴常见格式的 GitHub 仓库地址。"
  while true; do
    value="$(advanced_prompt_value "New repository name or address" "新的仓库名或地址" "$UPDATE_OLD_REPOSITORY")" || return 1
    if update_parse_repository_target "$value" "$default_owner"; then
      return 0
    fi
    advanced_warn \
      "That repository name or GitHub address was not recognized." \
      "没有识别出有效的仓库名或 GitHub 地址，请检查后重新输入。"
  done
}

update_resolve_identity_file() {
  local expected_username="$1"
  local saved_key=""
  local saved_alias=""
  local resolved_key=""

  UPDATE_IDENTITY_FILE=""
  UPDATE_OLD_ALIAS=""
  saved_key="$(git -C "$GIT_ROOT" config --local --get github-auto.identity-file 2>/dev/null || true)"
  saved_alias="$(git -C "$GIT_ROOT" config --local --get github-auto.ssh-alias 2>/dev/null || true)"
  if [ -z "$saved_alias" ] && [ -n "$CURRENT_ORIGIN_HOST" ] &&
     ssh_alias_is_github "$CURRENT_ORIGIN_HOST"; then
    saved_alias="$CURRENT_ORIGIN_HOST"
  fi

  if [ -n "$saved_key" ]; then
    saved_key="$(expand_home_path "$saved_key")"
    saved_key="${saved_key//%d/${HOME:-}}"
  fi
  if [ -n "$saved_key" ] && [ -f "$saved_key" ]; then
    UPDATE_IDENTITY_FILE="$saved_key"
    UPDATE_OLD_ALIAS="$saved_alias"
    return 0
  fi

  if [ -n "$saved_alias" ]; then
    resolved_key="$(resolve_alias_identity_file "$saved_alias" || true)"
    if [ -n "$resolved_key" ] && [ -f "$resolved_key" ]; then
      UPDATE_IDENTITY_FILE="$resolved_key"
      UPDATE_OLD_ALIAS="$saved_alias"
      return 0
    fi
  fi

  advanced_info \
    "Looking for the account key already configured on this computer..." \
    "正在查找这台电脑上已经配置好的账号密钥……"
  if find_verified_identity_for_username "$expected_username" "$saved_alias"; then
    UPDATE_IDENTITY_FILE="$FOUND_IDENTITY_FILE"
    UPDATE_OLD_ALIAS="$FOUND_SSH_ALIAS"
    return 0
  fi

  advanced_error \
    "No existing private key for this account was found through the repository settings, origin SSH Host, or ~/.ssh/config." \
    "从当前仓库设置、origin 使用的 SSH 主机名以及 ~/.ssh/config 中，都没有找到这个账号原来使用的私钥。"
  advanced_muted \
    "Run ./$SCRIPT_NAME menu and choose Verify accounts and current project before retrying update." \
    "请先运行 ./$SCRIPT_NAME menu，选择“核对账号和当前项目”，完成密钥检查后再重试 update。"
  return 1
}

update_verify_identity() {
  local expected_username="$1"

  while true; do
    advanced_info \
      "Asking GitHub which username now accepts the existing private key $(human_path "$UPDATE_IDENTITY_FILE")..." \
      "正在用现有私钥 $(human_path "$UPDATE_IDENTITY_FILE") 向 GitHub 核对更名后的用户名……"
    if identify_key_username "$UPDATE_IDENTITY_FILE"; then
      if [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$expected_username")" ]; then
        advanced_success \
          "GitHub account confirmed: $VERIFIED_GITHUB_USERNAME" \
          "已确认 GitHub 账号：$VERIFIED_GITHUB_USERNAME"
        return 0
      fi
      advanced_error \
        "This key currently authenticates as $VERIFIED_GITHUB_USERNAME, not $expected_username." \
        "这个密钥目前登录的是 ${VERIFIED_GITHUB_USERNAME}，并不是 ${expected_username}。"
    else
      advanced_error \
        "GitHub did not accept the key previously used by this project." \
        "GitHub 没有接受这个项目原来使用的密钥。"
    fi

    advanced_muted \
      "If the username was just changed, wait for GitHub to finish the change and make sure the key is still attached to that account." \
      "如果刚刚修改用户名，请稍等片刻，并确认这个密钥仍然添加在同一个 GitHub 账号中。"
    advanced_muted \
      "GitHub account settings: https://github.com/settings/admin" \
      "GitHub 账号设置：https://github.com/settings/admin"
    if ! advanced_prompt_yes_no \
      "Verify the same existing key with GitHub again?" \
      "要再次用这把现有密钥向 GitHub 核对用户名吗？" \
      "yes"; then
      return 1
    fi
  done
}

update_alias_points_to_key() {
  local alias="$1"
  local expected_key="$2"
  local alias_key=""
  local canonical_alias_key=""
  local canonical_expected_key=""

  [ -n "$alias" ] || return 1
  ssh_alias_is_github "$alias" || return 1
  alias_key="$(resolve_alias_identity_file "$alias" || true)"
  [ -f "$alias_key" ] || return 1
  canonical_alias_key="$(canonical_existing_file "$alias_key" || true)"
  canonical_expected_key="$(canonical_existing_file "$expected_key" || true)"
  [ -n "$canonical_alias_key" ] && [ "$canonical_alias_key" = "$canonical_expected_key" ]
}

update_find_named_alias_for_key() {
  local username_lc=""
  local alias=""
  local index=0

  username_lc="$(lowercase "$1")"
  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    case "$(lowercase "$alias")" in
      "github-$username_lc"|"github-$username_lc-"[0-9]*)
        if update_alias_points_to_key "$alias" "$UPDATE_IDENTITY_FILE"; then
          UPDATE_NEW_ALIAS="$alias"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

update_find_any_alias_for_key() {
  local alias=""
  local index=0

  scan_ssh_aliases || return 1
  while [ "$index" -lt "$DISCOVERED_SSH_ALIAS_COUNT" ]; do
    alias="${DISCOVERED_SSH_ALIASES[$index]}"
    index=$((index + 1))
    if update_alias_points_to_key "$alias" "$UPDATE_IDENTITY_FILE"; then
      UPDATE_NEW_ALIAS="$alias"
      return 0
    fi
  done
  return 1
}

update_next_available_alias() {
  local base="github-$(lowercase "$1")"
  local candidate="$base"
  local suffix=0

  scan_ssh_aliases || return 1
  while ssh_alias_exists "$candidate"; do
    suffix=$((suffix + 1))
    candidate="$base-$suffix"
  done
  UPDATE_NEW_ALIAS="$candidate"
}

update_prepare_alias() {
  local username_changed="$1"

  UPDATE_NEW_ALIAS=""
  UPDATE_INSTALL_ALIAS=false

  if [ "$username_changed" != "yes" ] &&
     update_alias_points_to_key "$UPDATE_OLD_ALIAS" "$UPDATE_IDENTITY_FILE"; then
    UPDATE_NEW_ALIAS="$UPDATE_OLD_ALIAS"
    return 0
  fi

  if [ "$username_changed" = "yes" ]; then
    if update_find_named_alias_for_key "$UPDATE_NEW_USERNAME"; then
      return 0
    fi
  elif update_find_any_alias_for_key; then
    return 0
  fi

  update_next_available_alias "$UPDATE_NEW_USERNAME" || return 1
  UPDATE_INSTALL_ALIAS=true
  return 0
}

update_verify_repository() {
  local remote_url="git@github.com:${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}.git"
  local output=""
  local detail=""

  while true; do
    advanced_info \
      "Reading ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} with account $UPDATE_NEW_USERNAME; this check does not change the repository." \
      "正在用账号 $UPDATE_NEW_USERNAME 读取 ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} 的远端信息；这一步不会修改仓库。"
    output="$(run_git_with_identity "$UPDATE_IDENTITY_FILE" ls-remote "$remote_url" HEAD 2>&1)" && {
      advanced_success \
        "GitHub allowed account $UPDATE_NEW_USERNAME to read ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}." \
        "GitHub 已允许账号 $UPDATE_NEW_USERNAME 读取 ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}。"
      return 0
    }

    advanced_error \
      "$UPDATE_NEW_USERNAME cannot access ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY} yet." \
      "$UPDATE_NEW_USERNAME 目前还无法访问 ${UPDATE_NEW_OWNER}/${UPDATE_NEW_REPOSITORY}。"
    detail="${output##*$'\n'}"
    if [ -n "$detail" ]; then
      advanced_muted "Git result: $detail" "Git 返回信息：$detail"
    fi
    advanced_muted \
      "GitHub may still be processing the change. Also make sure this account can access the repository." \
      "GitHub 可能仍在同步刚才的更名，也请确认这个账号拥有该仓库的访问权限。"
    advanced_muted \
      "Current repository settings: https://github.com/${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}/settings" \
      "当前仓库设置：https://github.com/${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}/settings"
    if ! advanced_prompt_yes_no \
      "Run the same read-only access check again?" \
      "要再次执行同一项只读访问检查吗？" \
      "yes"; then
      return 1
    fi
  done
}

remove_account_at_index() {
  local remove_index="$1"
  local index="$remove_index"
  local last_index=""

  while [ "$index" -lt $((ACCOUNT_COUNT - 1)) ]; do
    ACCOUNT_USERNAMES[$index]="${ACCOUNT_USERNAMES[$((index + 1))]}"
    ACCOUNT_EMAILS[$index]="${ACCOUNT_EMAILS[$((index + 1))]}"
    index=$((index + 1))
  done
  if [ "$ACCOUNT_COUNT" -gt 0 ]; then
    last_index=$((ACCOUNT_COUNT - 1))
    unset "ACCOUNT_USERNAMES[$last_index]"
    unset "ACCOUNT_EMAILS[$last_index]"
    ACCOUNT_COUNT=$((ACCOUNT_COUNT - 1))
  fi
}

update_account_entry() {
  local old_username="$1"
  local new_username="$2"
  local new_email="$3"
  local old_index=""
  local new_index=""

  old_index="$(account_index "$old_username" 2>/dev/null || true)"
  new_index="$(account_index "$new_username" 2>/dev/null || true)"

  if [ -n "$old_index" ] && [ -n "$new_index" ] && [ "$old_index" != "$new_index" ]; then
    ACCOUNT_USERNAMES[$new_index]="$new_username"
    ACCOUNT_EMAILS[$new_index]="$new_email"
    remove_account_at_index "$old_index"
  elif [ -n "$old_index" ]; then
    ACCOUNT_USERNAMES[$old_index]="$new_username"
    ACCOUNT_EMAILS[$old_index]="$new_email"
  else
    add_or_update_account "$new_username" "$new_email"
  fi
}

update_apply_validated_settings() {
  local username_changed="$1"

  if [ "$UPDATE_INSTALL_ALIAS" = true ]; then
    install_ssh_alias_block "$UPDATE_NEW_USERNAME" "$UPDATE_NEW_ALIAS" "$UPDATE_IDENTITY_FILE"
  fi

  if [ "$username_changed" = "yes" ]; then
    update_account_entry "$UPDATE_ACCOUNT_USERNAME" "$UPDATE_NEW_USERNAME" "$UPDATE_NEW_EMAIL"
    write_accounts_to_private_config
  fi

  CURRENT_REPOSITORY_OWNER="$UPDATE_NEW_OWNER"
  CURRENT_REPOSITORY_NAME="$UPDATE_NEW_REPOSITORY"
  BOUND_USERNAME="$UPDATE_NEW_USERNAME"
  BOUND_EMAIL="$UPDATE_NEW_EMAIL"
  BOUND_SSH_ALIAS="$UPDATE_NEW_ALIAS"
  BOUND_IDENTITY_FILE="$UPDATE_IDENTITY_FILE"

  save_project_binding
}

run_update_command() {
  local choice=""
  local username_changed="no"
  local repository_changed="no"
  local default_owner=""

  require_interactive
  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  require_core_commands
  if ! locate_project no; then
    advanced_error \
      "This folder is not a Git project. Place $SCRIPT_NAME in the project root and run ./$SCRIPT_NAME first." \
      "当前文件夹还不是 Git 项目。请把 ${SCRIPT_NAME} 放到项目根目录，并先运行 ./${SCRIPT_NAME}。"
    return 1
  fi
  advanced_success \
    "Existing Git repository detected: $(human_path "$GIT_ROOT"). git init will not run." \
    "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")。不会执行 git init。"
  if ! read_origin_repository; then
    advanced_error \
      "The current project does not have a recognizable GitHub origin." \
      "当前项目还没有可识别的 GitHub 远端仓库。"
    advanced_muted \
      "Run ./$SCRIPT_NAME first and provide the GitHub repository address when prompted." \
      "请先运行 ./${SCRIPT_NAME}，并在提示时填写这个项目对应的 GitHub 仓库地址。"
    return 1
  fi

  UPDATE_OLD_OWNER="$CURRENT_REPOSITORY_OWNER"
  UPDATE_OLD_REPOSITORY="$CURRENT_REPOSITORY_NAME"
  update_select_current_account || return 1

  advanced_heading "Current project" "当前项目信息"
  advanced_muted \
    "Account: $UPDATE_OLD_USERNAME" \
    "GitHub 账号：$UPDATE_OLD_USERNAME"
  advanced_muted \
    "Repository: ${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}" \
    "仓库：${UPDATE_OLD_OWNER}/${UPDATE_OLD_REPOSITORY}"
  advanced_muted \
    "This flow assumes the change is already complete on GitHub and now synchronizes this computer." \
    "这里会按照 GitHub 上已经完成的更名，同步并核对这台电脑上的设置。"

  advanced_heading "What changed?" "需要同步哪项改名？"
  if [ "$ADVANCED_LANGUAGE" = "en" ]; then
    printf '  1) GitHub username\n'
    printf '  2) Repository name or location\n'
    printf '  3) Both username and repository\n'
    printf '  0) Cancel\n'
  else
    printf '  1) GitHub 用户名\n'
    printf '  2) 仓库名称或所在账号\n'
    printf '  3) 用户名和仓库都变了\n'
    printf '  0) 取消\n'
  fi
  while true; do
    choice="$(advanced_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        username_changed="yes"
        break
        ;;
      2)
        repository_changed="yes"
        break
        ;;
      3)
        username_changed="yes"
        repository_changed="yes"
        break
        ;;
      0)
        return 0
        ;;
      *)
        advanced_warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done

  UPDATE_NEW_USERNAME="$UPDATE_OLD_USERNAME"
  UPDATE_NEW_EMAIL="$UPDATE_OLD_EMAIL"
  if [ "$username_changed" = "yes" ]; then
    UPDATE_NEW_USERNAME="$(update_prompt_username)" || return 1
    UPDATE_NEW_EMAIL="$(update_prompt_email "$UPDATE_NEW_USERNAME")" || return 1
  fi

  default_owner="$UPDATE_OLD_OWNER"
  if [ "$username_changed" = "yes" ] &&
     [ "$(lowercase "$UPDATE_OLD_OWNER")" = "$(lowercase "$UPDATE_OLD_USERNAME")" ]; then
    default_owner="$UPDATE_NEW_USERNAME"
  fi
  UPDATE_NEW_OWNER="$default_owner"
  UPDATE_NEW_REPOSITORY="$UPDATE_OLD_REPOSITORY"
  if [ "$repository_changed" = "yes" ]; then
    while true; do
      update_prompt_repository "$default_owner" || return 1
      if [ "$(lowercase "$UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY")" != \
           "$(lowercase "$UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY")" ]; then
        break
      fi
      advanced_warn \
        "That is still the current repository. Enter the new name or address." \
        "这仍是当前仓库，请填写改名后的仓库名或地址。"
    done
  fi

  update_resolve_identity_file "$UPDATE_NEW_USERNAME" || return 1
  update_verify_identity "$UPDATE_NEW_USERNAME" || return 1
  update_prepare_alias "$username_changed" || {
    advanced_error \
      "An unused SSH Host name for the existing key could not be selected." \
      "无法为现有密钥找到不冲突的 SSH 主机名。"
    return 1
  }
  update_verify_repository || return 1

  advanced_heading "Review the local settings that will change" "核对即将修改的本机设置"
  advanced_muted \
    "Account: $UPDATE_OLD_USERNAME -> $UPDATE_NEW_USERNAME" \
    "GitHub 账号：$UPDATE_OLD_USERNAME -> $UPDATE_NEW_USERNAME"
  advanced_muted \
    "Repository: $UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY -> $UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY" \
    "仓库：$UPDATE_OLD_OWNER/$UPDATE_OLD_REPOSITORY -> $UPDATE_NEW_OWNER/$UPDATE_NEW_REPOSITORY"
  if [ "$username_changed" = "yes" ]; then
    advanced_muted \
      "Commit email: $UPDATE_NEW_EMAIL" \
      "提交邮箱：$UPDATE_NEW_EMAIL"
    advanced_muted \
      "The existing account key will be reused. No new key will be created." \
      "原账号密钥会继续使用，不会重复创建新密钥。"
    advanced_muted \
      "private/config.txt: replace the saved username and commit email." \
      "private/config.txt：更新已保存的用户名和提交邮箱。"
  fi
  if [ "$UPDATE_INSTALL_ALIAS" = true ]; then
    advanced_muted \
      "~/.ssh/config: add SSH Host $UPDATE_NEW_ALIAS for the existing private key; the previous Host entry will remain." \
      "~/.ssh/config：为现有私钥新增 SSH 主机名 ${UPDATE_NEW_ALIAS}；原来的主机配置会继续保留。"
  fi
  advanced_muted \
    ".git/config: update the repository-local commit author, selected account, exact private key, and origin fetch/push address." \
    ".git/config：更新当前仓库的提交作者、所选账号、指定私钥以及 origin 的拉取和推送地址。"
  advanced_muted \
    "Project files, commits, branches, and the GitHub repository will not be changed or pushed." \
    "项目文件、提交记录、分支和 GitHub 远端仓库都不会被修改，也不会执行推送。"

  if ! advanced_prompt_yes_no "Apply these updates?" "确认更新本机设置？" "yes"; then
    advanced_warn \
      "Canceled. private/config.txt, ~/.ssh/config, this repository's .git/config, project files, and the GitHub repository were not changed." \
      "已取消；private/config.txt、~/.ssh/config、当前仓库的 .git/config、项目文件和 GitHub 远端仓库均未修改。"
    return 0
  fi

  if ! update_apply_validated_settings "$username_changed"; then
    advanced_error \
      "The project settings could not be saved completely. Run this command again to finish the update." \
      "项目设置未能全部保存。请重新运行这个命令完成更新。"
    return 1
  fi

  advanced_success \
    "Saved the verified username, repository address, commit author, SSH key, and origin in the local configuration files shown above." \
    "已把核对无误的用户名、仓库地址、提交作者、SSH 密钥和 origin 保存到上面列出的本机配置文件中。"
  if [ "$username_changed" = "yes" ] && [ -n "$UPDATE_OLD_ALIAS" ]; then
    advanced_muted \
      "The previous SSH Host entry was kept so other local projects that reference it continue to work." \
      "原来的 SSH 主机配置已保留，避免影响仍在引用它的其他本地项目。"
  fi
}

# -----------------------------------------------------------------------------
# Minimal menu and public commands
# -----------------------------------------------------------------------------

launcher_is_managed() {
  local launcher_file="$1"

  [ -f "$launcher_file" ] &&
    grep -Fq '# Managed git-auto project launcher' "$launcher_file" 2>/dev/null
}

write_project_launcher() {
  local project_directory="$1"
  local launcher_file="$project_directory/g.sh"
  local temporary_file=""
  local project_git_root=""
  local saved_script_directory="$SCRIPT_DIRECTORY"
  local saved_script_name="$SCRIPT_NAME"
  local saved_git_root="${GIT_ROOT:-}"

  temporary_file="$(safe_mktemp_file "$project_directory" "g.sh")" || return 1
  if ! cp "$ENGINE_DIRECTORY/g.sh" "$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if ! bash -n "$temporary_file" >/dev/null 2>&1 ||
     ! chmod 755 "$temporary_file" ||
     ! mv "$temporary_file" "$launcher_file"; then
    rm -f "$temporary_file"
    return 1
  fi

  if project_git_root="$(git -C "$project_directory" rev-parse --show-toplevel 2>/dev/null)" &&
     [ "$project_git_root" -ef "$project_directory" ]; then
    SCRIPT_DIRECTORY="$project_directory"
    SCRIPT_NAME="g.sh"
    GIT_ROOT="$project_directory"
    ensure_script_excluded
    if ! git -C "$GIT_ROOT" config --local github-auto.engine "$ENGINE_PATH"; then
      SCRIPT_DIRECTORY="$saved_script_directory"
      SCRIPT_NAME="$saved_script_name"
      GIT_ROOT="$saved_git_root"
      return 1
    fi
  fi

  SCRIPT_DIRECTORY="$saved_script_directory"
  SCRIPT_NAME="$saved_script_name"
  GIT_ROOT="$saved_git_root"
  return 0
}

create_or_repair_project_launcher() {
  local default_directory="$SCRIPT_DIRECTORY"
  local input=""
  local project_directory=""
  local launcher_file=""

  require_interactive
  if [ "$SCRIPT_DIRECTORY" -ef "$ENGINE_DIRECTORY" ]; then
    default_directory=""
  fi

  heading "Create a project launcher" "创建项目启动器"
  muted \
    "Choose the project folder that should receive the lightweight g.sh file." \
    "请选择需要放置轻量级 g.sh 的项目文件夹。"
  while true; do
    input="$(ui_prompt_value "Project folder" "项目文件夹" "$default_directory")" || return 1
    if normalize_history_directory_input "$input"; then
      project_directory="$HISTORY_NORMALIZED_DIRECTORY"
      break
    fi
    warn "That folder could not be opened." "无法打开这个文件夹，请重新输入。"
  done

  if [ "$project_directory" -ef "$ENGINE_DIRECTORY" ]; then
    warn \
      "The central git-auto repository already contains its public, copy-ready g.sh, so no file was replaced." \
      "中央 git-auto 仓库已经包含公开且可直接复制的 g.sh，因此没有替换任何文件。"
    return 0
  fi

  launcher_file="$project_directory/g.sh"
  if [ -e "$launcher_file" ] && ! launcher_is_managed "$launcher_file"; then
    warn \
      "This project already contains a g.sh file that was not created by git-auto." \
      "这个项目中已经存在一个并非由 git-auto 创建的 g.sh。"
    if ! ui_prompt_yes_no \
      "Replace it with the lightweight launcher?" \
      "要用新的轻量级启动器替换它吗？" \
      "no"; then
      return 0
    fi
  fi

  if ! write_project_launcher "$project_directory"; then
    fail \
      "The project launcher could not be created." \
      "无法创建项目启动器。"
  fi
  success \
    "Created the lightweight launcher: $launcher_file" \
    "已创建轻量启动器：$launcher_file"
  muted \
    "From now on, use ./g.sh, ./g.sh new, ./g.sh update, or ./g.sh menu in that project." \
    "以后在这个项目中直接使用 ./g.sh、./g.sh new、./g.sh update 或 ./g.sh menu。"
}

check_saved_account_identity() {
  local username="$1"
  local email="$2"
  local detail=""

  muted \
    "Checking SSH keys for GitHub account $username..." \
    "正在核对 GitHub 账号 $username 的 SSH 密钥……"
  if find_verified_identity_for_username "$username"; then
    success \
      "GitHub accepted $(human_path "$FOUND_IDENTITY_FILE") as account $username through SSH Host $FOUND_SSH_ALIAS." \
      "GitHub 已确认密钥 $(human_path "$FOUND_IDENTITY_FILE") 属于账号 ${username}；对应的 SSH 主机名是 ${FOUND_SSH_ALIAS}。"
    return 0
  fi

  if [ -n "$FOUND_UNVERIFIED_IDENTITY_FILE" ]; then
    warn \
      "The key $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") exists, but GitHub did not confirm it for account $username." \
      "密钥 $(human_path "$FOUND_UNVERIFIED_IDENTITY_FILE") 确实存在，但 GitHub 暂时没有确认它属于账号 ${username}。"
    detail="${SSH_VERIFICATION_OUTPUT##*$'\n'}"
    if [ -n "$detail" ]; then
      muted "SSH result: $detail" "SSH 返回信息：$detail"
    fi
    if ui_prompt_yes_no \
      "Verify this existing key with GitHub one more time?" \
      "要再用这把现有密钥向 GitHub 核对一次账号吗？" \
      "yes"; then
      if identify_key_username "$FOUND_UNVERIFIED_IDENTITY_FILE" &&
         [ "$(lowercase "$VERIFIED_GITHUB_USERNAME")" = "$(lowercase "$username")" ]; then
        FOUND_SSH_ALIAS="$FOUND_UNVERIFIED_SSH_ALIAS"
        FOUND_IDENTITY_FILE="$FOUND_UNVERIFIED_IDENTITY_FILE"
        success \
          "GitHub confirmed that the existing key belongs to account $username." \
          "GitHub 已确认这把现有密钥属于账号 ${username}。"
        return 0
      fi
    fi
  else
    warn \
      "No SSH private key accepted by GitHub for account $username was found in ~/.ssh/config or its Include files." \
      "在 ~/.ssh/config 及其 Include 文件中，没有找到可由 GitHub 确认为账号 $username 的现有私钥。"
  fi

  next_available_alias "$username" || return 1
  muted \
    "Creating another key will add private key $(human_path "$NEW_IDENTITY_FILE") and SSH Host $NEW_SSH_ALIAS; existing keys and Host entries will remain unchanged." \
    "如果新建，将增加私钥 $(human_path "$NEW_IDENTITY_FILE") 和 SSH 主机名 ${NEW_SSH_ALIAS}；已有密钥和主机配置不会被删除或覆盖。"
  if ! ui_prompt_yes_no \
    "Create and verify this separate SSH key for account $username?" \
    "要为账号 $username 创建并验证这把独立的 SSH 密钥吗？" \
    "yes"; then
    warn \
      "No new SSH key was created for account $username." \
      "没有为账号 $username 创建新的 SSH 密钥。"
    return 1
  fi
  create_new_identity "$username" "$email"
}

check_private_accounts() {
  local index=0
  local username=""
  local email=""
  local missing_count=0

  require_core_commands
  heading "Verify saved GitHub SSH keys" "核对已保存账号的 SSH 密钥"
  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    warn "No GitHub account has been added yet." "还没有添加 GitHub 账号。"
    if ui_prompt_yes_no \
      "Add a GitHub username, commit email, and verified SSH key now?" \
      "现在添加 GitHub 用户名、提交邮箱并验证对应的 SSH 密钥吗？" \
      "yes"; then
      run_account_setup || return 1
    fi
    return 0
  fi

  while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
    username="${ACCOUNT_USERNAMES[$index]}"
    email="${ACCOUNT_EMAILS[$index]}"
    if ! check_saved_account_identity "$username" "$email"; then
      missing_count=$((missing_count + 1))
    fi
    index=$((index + 1))
  done

  if [ "$missing_count" -eq 0 ]; then
    success \
      "GitHub accepted an SSH key for every saved account." \
      "GitHub 已分别确认每个已保存账号对应的 SSH 密钥。"
  else
    warn \
      "$missing_count saved account(s) still have no SSH key verified by GitHub." \
      "仍有 $missing_count 个已保存账号没有通过 GitHub 验证的 SSH 密钥。"
  fi
}

run_central_menu() {
  local choice=""

  require_interactive
  while true; do
    heading "Auto Script for GitHub Setup and Push" \
      "Auto Script for GitHub Setup and Push"
    muted \
      "Central engine: $ENGINE_PATH" \
      "中央脚本：$ENGINE_PATH"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 为项目创建或修复 g.sh\n'
      printf '  2) 添加 GitHub 账号\n'
      printf '  3) 核对各账号的 SSH 密钥\n'
      printf '  4) 界面语言\n'
      printf '  5) 显示模式\n'
      printf '  6) 高级功能\n'
      printf '  0) 退出\n'
    else
      printf '  1) Create or repair a project g.sh\n'
      printf '  2) Add a GitHub account\n'
      printf '  3) Verify account SSH keys\n'
      printf '  4) Interface language\n'
      printf '  5) Display mode\n'
      printf '  6) Advanced features\n'
      printf '  0) Exit\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        create_or_repair_project_launcher || true
        pause_for_user
        ;;
      2)
        run_account_setup || true
        pause_for_user
        ;;
      3)
        check_private_accounts || true
        pause_for_user
        ;;
      4)
        language_menu || true
        ;;
      5)
        appearance_menu || true
        ;;
      6)
        run_advanced_menu || true
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}

theme_label() {
  case "$1" in
    auto)
      localized_text "Automatic" "自动"
      ;;
    dark)
      localized_text "Dark" "深色"
      ;;
    light)
      localized_text "Light" "浅色"
      ;;
    none)
      localized_text "No color" "无颜色"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

save_theme_preference() {
  local preference="$1"

  if ! save_private_config "$(read_saved_language)" "$preference"; then
    fail \
      "The display preference could not be saved in private/config.txt." \
      "无法把显示偏好保存到 private/config.txt。"
  fi
  apply_theme "$preference"
}

appearance_menu() {
  local choice=""
  local selected=""

  while true; do
    heading "Display mode" "显示模式"
    muted \
      "Current: $(theme_label "$(read_saved_theme)")" \
      "当前：$(theme_label "$(read_saved_theme)")"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 自动（推荐）\n'
      printf '  2) 深色\n'
      printf '  3) 浅色\n'
      printf '  4) 无颜色\n'
      printf '  0) 返回\n'
    else
      printf '  1) Automatic (recommended)\n'
      printf '  2) Dark\n'
      printf '  3) Light\n'
      printf '  4) No color\n'
      printf '  0) Return\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        selected="auto"
        ;;
      2)
        selected="dark"
        ;;
      3)
        selected="light"
        ;;
      4)
        selected="none"
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        continue
        ;;
    esac

    save_theme_preference "$selected"
    success \
      "Display mode set to: $(theme_label "$selected")" \
      "显示模式已设为：$(theme_label "$selected")"
    return 0
  done
}

language_menu() {
  local status=0

  choose_interface_language yes || status=$?
  if [ "$status" -eq 2 ]; then
    return 0
  elif [ "$status" -ne 0 ]; then
    return 1
  fi

  ADVANCED_LANGUAGE="$UI_LANGUAGE"
  success \
    "Interface language set to English." \
    "界面语言已设为中文。"
}

switch_project_account() {
  require_core_commands
  if ! locate_project no; then
    warn "The current folder is not a Git project." "当前文件夹还不是 Git 项目。"
    return 1
  fi
  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    warn "No GitHub account has been added yet." "还没有 GitHub 账号，请先添加。"
    return 1
  fi
  if ! read_origin_repository; then
    warn \
      "The current project does not have a recognizable GitHub repository." \
      "当前项目还没有可识别的 GitHub 仓库。"
    return 1
  fi
  if ! select_account \
    "Which GitHub account should this project use?" \
    "要把当前项目切换到哪个 GitHub 账号？"; then
    return 1
  fi

  configure_project "$SELECTED_USERNAME" || return 1
  success \
    "This project now uses account ${SELECTED_USERNAME}." \
    "当前项目已经切换到账号 ${SELECTED_USERNAME}。"
}

check_and_repair() {
  local index=0
  local username=""
  local email=""
  local missing_count=0

  require_core_commands
  heading "Verify saved accounts and the current project" "核对已保存账号和当前项目"

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    warn "No GitHub account has been added yet." "还没有 GitHub 账号。"
    if ui_prompt_yes_no \
      "Add a GitHub username, commit email, and verified SSH key now?" \
      "现在添加 GitHub 用户名、提交邮箱并验证对应的 SSH 密钥吗？" \
      "yes"; then
      run_account_setup || return 1
    fi
  else
    while [ "$index" -lt "$ACCOUNT_COUNT" ]; do
      username="${ACCOUNT_USERNAMES[$index]}"
      email="${ACCOUNT_EMAILS[$index]}"
      if ! check_saved_account_identity "$username" "$email"; then
        missing_count=$((missing_count + 1))
      fi
      index=$((index + 1))
    done
  fi

  if locate_project no; then
    success \
      "Existing Git repository detected: $(human_path "$GIT_ROOT"). git init will not run." \
      "已识别现有 Git 仓库：$(human_path "$GIT_ROOT")。不会执行 git init。"
    if read_origin_repository; then
      muted \
        "Current repository: ${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}" \
        "当前仓库：${CURRENT_REPOSITORY_OWNER}/${CURRENT_REPOSITORY_NAME}"
      username="$(git -C "$GIT_ROOT" config --local --get github-auto.username 2>/dev/null || true)"
      if [ -n "$username" ] && account_index "$username" >/dev/null 2>&1; then
        success \
          "Current project account: $username" \
          "当前项目使用的账号：$username"
      else
        warn \
          "This repository has no saved github-auto.username in its local .git/config." \
          "当前仓库的本地 .git/config 中还没有保存 github-auto.username。"
        muted \
          "The next step selects an account, verifies its SSH key and repository access, then saves only repository-local Git settings." \
          "下一步会选择账号，核对 SSH 密钥和仓库访问权限，然后只保存当前仓库自己的本地 Git 设置。"
        if ui_prompt_yes_no \
          "Choose and verify the account for this repository now?" \
          "现在为这个仓库选择并核对 GitHub 账号吗？" \
          "yes"; then
          configure_project || return 1
        fi
      fi
    else
      warn \
        "This Git repository has no origin that identifies a GitHub repository." \
        "这个 Git 仓库还没有能够识别为 GitHub 仓库的 origin。"
    fi
  else
    muted \
      "The current folder is not a Git repository; this verification command did not run git init." \
      "当前文件夹还不是 Git 仓库；本次核对不会执行 git init。"
  fi

  if [ "$missing_count" -eq 0 ]; then
    success \
      "GitHub accepted an SSH key for every saved account checked above." \
      "GitHub 已分别确认上面每个已保存账号对应的 SSH 密钥。"
  else
    warn \
      "$missing_count saved account(s) still have no SSH key verified by GitHub." \
      "仍有 $missing_count 个已保存账号没有通过 GitHub 验证的 SSH 密钥。"
  fi
}

run_new_command() {
  local account_ready=false

  require_core_commands
  if locate_project no &&
     read_origin_repository &&
     identify_origin_ssh_account &&
     ! account_index "$ORIGIN_VERIFIED_USERNAME" >/dev/null 2>&1; then
    if select_verified_origin_account yes; then
      account_ready=true
    fi
  fi

  if [ "$account_ready" = false ]; then
    if ! run_account_setup; then
      return 1
    fi
  fi

  if ui_prompt_yes_no \
    "Use account $SELECTED_USERNAME for this project, review its changes, commit them, and push its current branch?" \
    "要使用账号 $SELECTED_USERNAME 核对当前项目、检查改动、创建提交并上传当前分支吗？" \
    "yes"; then
    run_project_flow "$SELECTED_USERNAME"
  else
    success \
      "The account and commit email were saved. The current project was not changed or pushed." \
      "账号和提交邮箱已经保存；当前项目没有被修改，也没有上传。"
  fi
}

run_menu() {
  local choice=""

  require_interactive
  while true; do
    heading "Auto Script for GitHub Setup and Push"
    if [ "$UI_LANGUAGE" = "zh" ]; then
      printf '  1) 提交并上传当前项目\n'
      printf '  2) 添加 GitHub 账号\n'
      printf '  3) 切换当前项目的账号\n'
      printf '  4) 同步用户名或仓库改名\n'
      printf '  5) 核对账号和当前项目\n'
      printf '  6) 界面语言\n'
      printf '  7) 显示模式\n'
      printf '  8) 高级功能\n'
      printf '  0) 退出\n'
    else
      printf '  1) Commit and push the current project\n'
      printf '  2) Add a GitHub account\n'
      printf '  3) Switch the current project account\n'
      printf '  4) Sync a renamed username or repository\n'
      printf '  5) Verify accounts and current project\n'
      printf '  6) Interface language\n'
      printf '  7) Display mode\n'
      printf '  8) Advanced features\n'
      printf '  0) Exit\n'
    fi

    choice="$(ui_prompt_value "Choose" "选择" "1")" || return 1
    case "$choice" in
      1)
        run_project_flow
        return
        ;;
      2)
        run_new_command
        return
        ;;
      3)
        switch_project_account || true
        pause_for_user
        ;;
      4)
        run_update_command || true
        advanced_pause
        ;;
      5)
        check_and_repair || true
        pause_for_user
        ;;
      6)
        language_menu || true
        ;;
      7)
        appearance_menu || true
        ;;
      8)
        run_advanced_menu || true
        ;;
      0)
        return 0
        ;;
      *)
        warn "Enter a number from the list." "请输入列表中的序号。"
        ;;
    esac
  done
}

show_usage() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '用法：\n'
    printf '  ./%s         提交并上传当前项目\n' "$SCRIPT_NAME"
    printf '  ./%s new     添加 GitHub 账号\n' "$SCRIPT_NAME"
    printf '  ./%s update  同步用户名或仓库改名\n' "$SCRIPT_NAME"
    printf '  ./%s menu    打开菜单\n' "$SCRIPT_NAME"
  else
    printf 'Usage:\n'
    printf '  ./%s         Commit and push the current project\n' "$SCRIPT_NAME"
    printf '  ./%s new     Add a GitHub account\n' "$SCRIPT_NAME"
    printf '  ./%s update  Sync a renamed username or repository\n' "$SCRIPT_NAME"
    printf '  ./%s menu    Open the menu\n' "$SCRIPT_NAME"
  fi
}

show_central_usage() {
  if [ "$UI_LANGUAGE" = "zh" ]; then
    printf '用法：\n'
    printf '  ./%s         打开中央管理菜单\n' "$ENGINE_NAME"
    printf '  ./%s new     添加 GitHub 账号\n' "$ENGINE_NAME"
    printf '  ./%s menu    打开中央管理菜单\n' "$ENGINE_NAME"
  else
    printf 'Usage:\n'
    printf '  ./%s         Open the central management menu\n' "$ENGINE_NAME"
    printf '  ./%s new     Add a GitHub account\n' "$ENGINE_NAME"
    printf '  ./%s menu    Open the central management menu\n' "$ENGINE_NAME"
  fi
}

main() {
  local command_name="${1:-push}"
  local at_engine_home=false

  initialize_language || return 1
  ADVANCED_LANGUAGE="$UI_LANGUAGE"

  if [ "$RUNNING_FROM_LAUNCHER" != "1" ] &&
     [ "$SCRIPT_DIRECTORY" -ef "$ENGINE_DIRECTORY" ]; then
    at_engine_home=true
    command_name="${1:-menu}"
  fi

  if [ "$#" -gt 1 ]; then
    if [ "$at_engine_home" = true ]; then
      show_central_usage
    else
      show_usage
    fi
    return 1
  fi

  if [ "$at_engine_home" = true ]; then
    case "$command_name" in
      menu)
        run_central_menu
        ;;
      new)
        run_account_setup
        ;;
      *)
        show_central_usage
        return 1
        ;;
    esac
    return
  fi

  case "$command_name" in
    push)
      run_project_flow
      ;;
    new)
      run_new_command
      ;;
    update)
      run_update_command
      ;;
    menu)
      run_menu
      ;;
    *)
      show_usage
      return 1
      ;;
  esac
}

if [ "${GITHUB_AUTO_TESTING:-0}" != "1" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
